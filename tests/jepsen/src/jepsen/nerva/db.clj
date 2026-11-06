(ns jepsen.nerva.db
  "Installs and runs Nerva on each node: one replica and one `nerva api` gateway.

  Node names are IPv4 addresses (`--addresses` takes host:port, and run.sh gives the
  containers fixed addresses). The binary is uploaded from the control node, so a test runs
  exactly the build it was given."
  (:require [clojure.string :as str]
            [clojure.tools.logging :refer [info]]
            [jepsen [control :as c]
                    [core :as jepsen]
                    [db :as db]]
            [jepsen.control.util :as cu]
            [jepsen.nerva.http :as http]))

(def dir "/opt/nerva")
(def binary (str dir "/nerva"))
(def data-file (str dir "/replica.nerva"))
(def replica-log (str dir "/replica.log"))
(def api-log (str dir "/api.log"))
(def cluster-key-file (str dir "/cluster.key"))
(def replica-pidfile (str dir "/replica.pid"))
(def api-pidfile (str dir "/api.pid"))

(def two-gateway-nodes
  "With `--gateways 2`, only this many nodes run two: a development replica takes at most 8
  client connections (`pipeline_prepare_queue_max`, no `--pipeline-requests-limit`), and a
  gateway is one client on every replica. Ten gateways left the last one unable to connect."
  3)

(defn gateways
  "How many `nerva api` gateways `node` runs (`--gateways`, 1 or 2): R4's sidecar topology has
  one per client process, so two gateways share a replica. With 2, only the first
  `two-gateway-nodes` nodes run two (6 gateways, 2 spare client slots per replica)."
  [test node]
  (let [n (:gateways test 1)]
    (if (and (= 2 n) (<= two-gateway-nodes (.indexOf ^java.util.List (vec (:nodes test)) node)))
      1
      n)))

(defn gateway-port
  "Gateway `index` listens on `http/api-port` plus its index."
  [index]
  (+ http/api-port index))

(defn gateway-pidfile
  [index]
  (if (zero? index) api-pidfile (str dir "/api-" index ".pid")))

(defn gateway-log
  [index]
  (if (zero? index) api-log (str dir "/api-" index ".log")))

(def cluster
  "The cluster id (0 is reserved for testing)."
  1)

(def replica-port 3000)

(def cluster-key-bytes-min
  "P102: a cluster key has at least 32 bytes."
  32)

(defn random-cluster-key
  "64 hex digits from a SecureRandom: 32 random bytes."
  []
  (let [bytes (byte-array 32)]
    (.nextBytes (java.security.SecureRandom.) bytes)
    (apply str (map #(format "%02x" %) bytes))))

(def cluster-key
  "The key replicas authenticate each other with (P102): $NERVA_CLUSTER_KEY on the control node
  (jepsen.yml sets a fresh one per run), else a fresh random one for this process. Never a
  constant, so a run never uses a key that anything else knows. It reaches a node over stdin
  into a 600 file (`install-cluster-key!`), never in a command line, a log or `store/`."
  (delay
    (let [key (or (not-empty (System/getenv "NERVA_CLUSTER_KEY")) (random-cluster-key))]
      (assert (<= cluster-key-bytes-min (count (.getBytes ^String key "UTF-8")))
              (str "NERVA_CLUSTER_KEY needs at least " cluster-key-bytes-min " bytes"))
      key)))

(defn install-cluster-key!
  "Writes the cluster key to the node's key file, mode 600 before the key is in it, and over
  stdin, so it is in no command line."
  []
  (c/exec :install :-m "600" "/dev/null" cluster-key-file)
  (cu/write-file! @cluster-key cluster-key-file))

(def healthy-timeout-s
  "How long a fresh cluster may take until every gateway has a session."
  120)

(defn addresses
  "Every replica's address, in replica index order."
  [test]
  (->> (:nodes test)
       (map #(str % ":" replica-port))
       (str/join ",")))

(defn replica-index
  [test node]
  (let [index (.indexOf ^java.util.List (vec (:nodes test)) node)]
    (assert (<= 0 index) (str node " is not one of the test's nodes"))
    index))

;; The replica and the gateway are the same binary, so a daemon is known by its pidfile alone
;; (`:match-executable? false`): otherwise starting the gateway finds the replica "running".

(defn start-replica!
  [test]
  (cu/start-daemon! {:logfile           replica-log
                     :pidfile           replica-pidfile
                     :chdir             dir
                     :match-executable? false
                     ;; The shell that starts the replica reads the key file: start-daemon! writes
                     ;; its env into the daemon's log, which is in store/, and P102's key is
                     ;; never logged.
                     :env               (str "NERVA_CLUSTER_KEY=\"$(cat " cluster-key-file ")\"")}
                    binary :start (str "--addresses=" (addresses test)) :--development
                    data-file))

(defn gateway-user
  "The Unix user gateway `index` runs as, so iptables can name one gateway
  (`-m owner --uid-owner`) without touching the replica, which runs as root."
  [index]
  (str "nerva-gw" index))

(def max-gateways 2)

(defn create-gateway-users!
  "Creates the gateways' users, once. `useradd` is in the node image's base packages."
  []
  (doseq [index (range max-gateways)]
    (c/exec :sh :-c (str "id -u " (gateway-user index) " > /dev/null 2>&1 || useradd --system "
                         "--no-create-home --shell /usr/sbin/nologin " (gateway-user index)))))

(defn start-gateway!
  "Starts gateway `index` once, as its own user: `setpriv` drops to it and execs, so the
  pidfile names the gateway."
  [test index]
  (apply cu/start-daemon!
         {:logfile           (gateway-log index)
          :pidfile           (gateway-pidfile index)
          :chdir             dir
          :match-executable? false
          :env               {:NERVA_KEY http/api-key}}
         "/usr/bin/setpriv"
         (concat [(str "--reuid=" (gateway-user index)) (str "--regid=" (gateway-user index))
                  "--clear-groups" binary :api (str "--cluster=" cluster)
                  (str "--addresses=" (addresses test))
                  (str "--listen=0.0.0.0:" (gateway-port index))
                  :--listen-remote]
                 (when-let [ms (:request-timeout test)]
                   [(str "--request-timeout=" ms)]))))

(def gateway-start-tries
  "A gateway exits (NRV-E0604) when the cluster does not answer within its `--request-timeout`
  at start, as while the replicas are still starting or cut off. Botpike's supervisor would
  restart it; the suite does the same, this many times."
  6)

(def gateway-start-wait-s
  "How long `start-api!` waits for a started gateway to be healthy or dead."
  15)

(def gateway-backoff-ms-max
  "The longest wait between a gateway's starts."
  4000)

(defn gateway-backoff-ms
  "How long to wait before start number `tries + 1`: 500 ms, doubling, at most
  `gateway-backoff-ms-max`. A gateway killed over and over, or cut off, does not spin."
  [tries]
  (min gateway-backoff-ms-max (* 500 (bit-shift-left 1 (dec tries)))))

(defn start-gateway-until-up!
  "Starts gateway `index` and waits for it to be healthy or dead; a dead one is started again
  after a backoff, at most `gateway-start-tries` times in all. Each probe of `/healthz` takes at
  most `http/probe-timeout-ms`, so the wait is bounded by `gateway-start-wait-s` per try."
  [test index]
  (loop [tries 1]
    (start-gateway! test index)
    (let [deadline (+ (System/nanoTime) (* gateway-start-wait-s 1000000000))
          state    (loop []
                     (cond (http/healthy? c/*host* (gateway-port index)) :up
                           (not (cu/daemon-running? (gateway-pidfile index))) :dead
                           (< deadline (System/nanoTime)) :pending
                           :else (do (Thread/sleep 500) (recur))))]
      (if (and (= :dead state) (< tries gateway-start-tries))
        (do (info "Gateway" index "on" c/*host* "exited at start; starting it again")
            (Thread/sleep (long (gateway-backoff-ms tries)))
            (recur (inc tries)))
        state))))

(defn start-api!
  "Starts the test's gateways. The control node reaches them over the network, so they listen
  on every address and say so: `--listen-remote` (P168, NRV-E0009). A test's `:request-timeout`
  (milliseconds) becomes their `--request-timeout`. A gateway that exits at start is started
  again (`gateway-start-tries`); one that is neither healthy nor dead after
  `gateway-start-wait-s` is left. Under `partition` a gateway can stay dead: with a 3 s
  `--request-timeout` its tries are spent in about 18 s, and nothing starts it again until the
  nemesis's next `:start`; the run then has fewer gateways until then, never wrong results."
  [test]
  (doseq [index (range (gateways test c/*host*))]
    (start-gateway-until-up! test index)))

(defn node-gateways
  "The `[node index]` pairs of the gateways `node` runs: none beyond `gateways`."
  [test node]
  (mapv (fn [index] [node index]) (range (gateways test node))))

(defn all-gateways
  "Every `[node index]` pair the test runs, in node order."
  [test]
  (into [] (mapcat #(node-gateways test %)) (:nodes test)))

(defn gateway-running?
  "Whether gateway `index` on this node has a live process (a paused one has)."
  [index]
  (cu/daemon-running? (gateway-pidfile index)))

(defn kill-gateways!
  "SIGKILLs those of gateways `indices` that are running on this node, the replica untouched.
  Returns the indices it killed: a gateway already down was not reached. \"Running\" is as of the
  check: a gateway that exits between the check and the kill is still returned."
  [indices]
  (let [reached (filterv gateway-running? indices)]
    (doseq [index reached]
      (cu/stop-daemon! (gateway-pidfile index)))
    reached))

(def start-settle-s
  "How long `start-gateways!` keeps probing the gateways it started. The deadline is checked
  after a whole round of probes, so a wait is at most this plus one round (see `settle-states`)."
  10)

(defn start-outcome
  "`states` maps a started gateway's index to `:up`, `:dead` or `:pending`; returns
  `{:up [...] :down [...] :pending [...]}`, indices sorted. `:up` answers `/healthz`; `:down`
  exited at start (NRV-E0604, still cut off); `:pending` is alive but did not answer by the
  deadline and may yet come up. The history never calls a live process down."
  [states]
  (let [of (fn [k] (vec (sort (for [[i s] states :when (= k s)] i))))]
    {:up (of :up), :down (of :dead), :pending (of :pending)}))

(defn gateway-state
  "`:up` when gateway `index` answers `/healthz` (a probe takes at most
  `http/probe-timeout-ms`), `:dead` when its process is gone, else `:pending`."
  [index]
  (cond (http/healthy? c/*host* (gateway-port index)) :up
        (not (gateway-running? index))                :dead
        :else                                         :pending))

(defn settle-states
  "Probes every `:pending` gateway in `states` (index to state) with `probe` in rounds, until
  none is pending or `(now)` passes `deadline`; between rounds it calls `(sleep!)`. The deadline
  is checked after a round, so the wait is at most the time to the deadline plus one round, and
  a round probes each pending gateway in turn (each probe: an HTTP probe, then a `ps` over ssh).
  Returns the final states."
  [states probe {:keys [deadline now sleep!]}]
  (loop [states states]
    (let [states (into {} (for [[i s] states] [i (if (= :pending s) (probe i) s)]))]
      (if (or (not-any? #{:pending} (vals states)) (< deadline (now)))
        states
        (do (sleep!) (recur states))))))

(defn start-gateways!
  "Starts this node's gateways that are not running; a paused or cut-off gateway is running and
  is left alone. Then waits (`settle-states`, `start-settle-s` plus one round at most) for each
  to be healthy or dead. Returns `{:up [...] :down [...] :pending [...]}` (`start-outcome`,
  P238): a gateway started while still cut off from its replicas exits (NRV-E0604) and is
  `:down`; one still alive at the deadline is `:pending`. Neither is retried here: the next
  start op starts the down ones again."
  [test]
  (let [started (vec (for [index (range (gateways test c/*host*))
                           :when (not (gateway-running? index))
                           :let [_ (start-gateway! test index)]]
                       index))]
    (start-outcome
      (settle-states (zipmap started (repeat :pending)) gateway-state
                     {:deadline (+ (System/nanoTime) (* start-settle-s 1000000000))
                      :now      #(System/nanoTime)
                      :sleep!   #(Thread/sleep 500)}))))

(defn start-gateways-final!
  "The final phase's start: brings every gateway that is not running up with
  `start-gateway-until-up!` (bounded retries and backoff), because no start op follows it and a
  gateway also exits (NRV-E0604) while the replicas that just restarted have not formed a view.
  Returns `{:up [...] :down [] :pending []}`; throws, naming NRV-E0604, if a gateway never
  comes up."
  [test]
  (let [states (into {} (for [index (range (gateways test c/*host*))
                              :when (not (gateway-running? index))]
                          [index (start-gateway-until-up! test index)]))
        failed (vec (sort (for [[i s] states :when (not= :up s)] i)))]
    (when (seq failed)
      (throw (ex-info (str "NRV-E0604: gateway(s) " failed " on " c/*host* " did not come up in "
                           gateway-start-tries " tries")
                      {:node c/*host* :gateways failed :states states})))
    (start-outcome states)))

(defn signal-gateways!
  "Sends `signal` to gateways `indices` on this node; a gateway that is gone is not an error.
  Returns the indices signalled."
  [indices signal]
  (vec (for [index indices
             :when (try (c/exec :kill signal (c/lit (str "$(cat " (gateway-pidfile index) ")")))
                        true
                        (catch Exception e
                          (info "Gateway" index "on" c/*host* "is not running:" (.getMessage e))
                          false))]
         index)))

(defn gateway-rule
  "The iptables arguments (after the table and chain; the table is `mangle`) that drop gateway
  `index`'s traffic to the replica at `dest`. In the mangle table: Jepsen's partitioner heals
  with `iptables -F`, which flushes only the filter table."
  [index dest]
  (str "-m owner --uid-owner " (gateway-user index) " -p tcp -d " dest " --dport " replica-port
       " -j DROP"))

(defn partition-gateways!
  "Cuts gateways off from replicas on this node: `cuts` is `[[index [replica-node ...]] ...]`.
  Their clients still reach them. Only a gateway running when checked is cut, and only it is
  returned: a rule for a gateway that is down would cut it off when it restarts. The check and
  the rule are two steps, so a gateway that exits in between is still cut and returned; its
  rule stays until the next heal."
  [cuts]
  (let [reached (filterv (comp gateway-running? first) cuts)]
    (doseq [[index dests] reached
            dest dests
            :let [rule (gateway-rule index dest)]]
      (c/exec :sh :-c (str "iptables -w -t mangle -C OUTPUT " rule " 2>/dev/null"
                           " || iptables -w -t mangle -A OUTPUT " rule)))
    (mapv first reached)))

(def heal-deletes-max
  "At most this many copies of one rule are deleted (each cut adds at most one)."
  8)

(defn heal-gateways!
  "Lifts every gateway cut on this node (all indices and replicas, whatever was cut). Returns
  the indices that had a rule."
  [test]
  (vec (for [index (range max-gateways)
             :let [script (str "n=0; for d in " (str/join " " (:nodes test)) "; do"
                               " for i in $(seq " heal-deletes-max "); do"
                               " iptables -w -t mangle -D OUTPUT " (gateway-rule index "$d")
                               " 2>/dev/null || break; n=$((n+1)); done; done; echo $n")
                   n      (parse-long (str/trim (c/exec :sh :-c script)))]
             :when (pos? n)]
         index)))

(defn kill-all!
  "SIGKILLs the gateways and the replica. The pidfile of a gateway the test did not start is
  harmless: `stop-daemon!` ignores a missing one."
  []
  (doseq [index (range max-gateways)]
    (cu/stop-daemon! (gateway-pidfile index)))
  (cu/stop-daemon! replica-pidfile))

(defn db
  "A Nerva DB. bootstrap is (fn [test node]), run once, against one node's gateway, after every
  gateway is healthy and before any client starts: the workload's layouts, ledgers, views and
  initial rows."
  [bootstrap]
  (reify
    db/DB
    (setup! [_ test node]
      (c/su
        (c/exec :mkdir :-p dir)
        (c/upload (:nerva-binary test) binary)
        (c/exec :chmod "+x" binary)
        (install-cluster-key!)
        (create-gateway-users!)
        (c/exec binary :format (str "--cluster=" cluster)
                (str "--replica=" (replica-index test node))
                (str "--replica-count=" (count (:nodes test)))
                :--development data-file)
        (start-replica! test)
        (start-api! test))
      (doseq [index (range (gateways test node))]
        (http/await-healthy! node (gateway-port index) healthy-timeout-s))
      (jepsen/synchronize test)
      (when (= node (jepsen/primary test))
        (info "Bootstrapping the workload through" node)
        (bootstrap test node))
      (jepsen/synchronize test))

    (teardown! [_ test node]
      (c/su
        (heal-gateways! test)
        (kill-all!)
        (c/exec :rm :-rf dir)))

    db/Kill
    (kill! [_ test node]
      (c/su (kill-all!)))

    (start! [_ test node]
      (c/su
        (start-replica! test)
        (start-api! test)))

    ;; A pause stops the replica alone: its gateway goes on taking requests that time out.
    db/Pause
    (pause! [_ test node]
      (c/su (c/exec :kill :-STOP (c/lit (str "$(cat " replica-pidfile ")")))))

    (resume! [_ test node]
      (c/su (c/exec :kill :-CONT (c/lit (str "$(cat " replica-pidfile ")")))))

    db/LogFiles
    (log-files [_ test node]
      (into {replica-log "replica.log"}
            (for [index (range (gateways test node))]
              [(gateway-log index) (if (zero? index) "api.log" (str "api-" index ".log"))])))))
