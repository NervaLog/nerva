(ns jepsen.nerva.db
  "Installs and runs Nerva on each node: one replica and one `nerva api` gateway.

  Node names are IPv4 addresses (`--addresses` takes host:port, and run.sh gives the
  containers fixed addresses). The binary is uploaded from the control node, so a test runs
  exactly the build it was given."
  (:require [clojure.string :as str]
            [clojure.tools.logging :refer [info warn]]
            [jepsen [control :as c]
                    [core :as jepsen]
                    [db :as db]]
            [jepsen.control.util :as cu]
            [jepsen.nerva.http :as http]
            [jepsen.nerva.lazyfs :as lazyfs]))

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
                    (lazyfs/data-file test dir data-file)))

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

(def gateway-registration-ms-default
  "A gateway's `--request-timeout` when the test sets none: 30,000 ms
  (`request_timeout_default_ms`, src/nerva/cli.zig). The deadline covers a call including the
  client's registration, so a gateway whose cluster does not answer exits with NRV-E0604 after
  this long."
  30000)

(def gateway-wait-margin-s
  "Seconds a wait lasts beyond the gateway's registration window, so a gateway that is going to
  exit with NRV-E0604 has done so when the wait ends."
  5)

(defn gateway-wait-s
  "How long one wait for a started gateway lasts: its registration window (the test's
  `:request-timeout`, else `gateway-registration-ms-default`) rounded up to seconds, plus
  `gateway-wait-margin-s`. Longer than the window, so a wait ends with the gateway up or dead,
  not merely still registering."
  [test]
  (+ gateway-wait-margin-s
     (long (Math/ceil (/ (or (:request-timeout test) gateway-registration-ms-default) 1000.0)))))

(def gateway-waits-max
  "How many waits (`gateway-wait-s`) one start gets while the gateway stays alive and does not
  answer. A pending gateway is waited for, not restarted."
  2)

(def gateway-backoff-ms-max
  "The longest wait between a gateway's starts."
  4000)

(defn gateway-backoff-ms
  "How long to wait before start number `tries + 1`: 500 ms, doubling, at most
  `gateway-backoff-ms-max`. A gateway killed over and over, or cut off, does not spin."
  [tries]
  (min gateway-backoff-ms-max (* 500 (bit-shift-left 1 (dec tries)))))

(defn wait-for-gateway
  "Probes gateway `index` until it answers `/healthz` (`:up`), its process is gone (`:dead`) or
  `wait-s` seconds have passed with it alive and silent (`:pending`). Each probe takes at most
  `http/probe-timeout-ms`, so the wait is `wait-s` plus one probe."
  [index wait-s]
  (let [deadline (+ (System/nanoTime) (* wait-s 1000000000))]
    (loop []
      (cond (http/healthy? c/*host* (gateway-port index)) :up
            (not (cu/daemon-running? (gateway-pidfile index))) :dead
            (< deadline (System/nanoTime)) :pending
            :else (do (Thread/sleep 500) (recur))))))

(defn settle-gateway
  "`wait-for-gateway`, repeated while the gateway is alive and silent, at most
  `gateway-waits-max` waits in all: a pending gateway is waited for, never restarted here."
  [test index]
  (let [wait-s (gateway-wait-s test)]
    (loop [waits 1]
      (let [state (wait-for-gateway index wait-s)]
        (if (and (= :pending state) (< waits gateway-waits-max))
          (recur (inc waits))
          state)))))

(defn start-gateway-until-up!
  "Starts gateway `index` and returns `:up`, `:dead` or `:pending`. Each wait is
  `(gateway-wait-s test)`, longer than the gateway's registration window (30 s by default,
  cli.zig `request_timeout_default_ms`). A `:pending` gateway is alive: it is waited for again
  (`settle-gateway`), not restarted. A `:dead` one is started again after a backoff, at most
  `gateway-start-tries` starts in all. Bound: `gateway-start-tries` x `gateway-waits-max` x
  (`gateway-wait-s` + a probe) + the backoffs (11.5 s), about 7 minutes at the default; a dead
  gateway ends its wait at once, so in practice far less. Returns `:dead` or `:pending` when the
  bounds are spent."
  [test index]
  (loop [tries 1]
    (start-gateway! test index)
    (let [state (settle-gateway test index)]
      (if (and (= :dead state) (< tries gateway-start-tries))
        (do (info "Gateway" index "on" c/*host* "exited at start; starting it again")
            (Thread/sleep (long (gateway-backoff-ms tries)))
            (recur (inc tries)))
        state))))

(defn start-api!
  "Starts the test's gateways at setup, each until it is up (`start-gateway-until-up!`). The
  control node reaches them over the network, so they listen on every address and say so:
  `--listen-remote` (P168, NRV-E0009). A test's `:request-timeout` (milliseconds) becomes their
  `--request-timeout`. Setup only: the replica `kill` nemesis's `:start` uses `restart-api!`,
  because this one can hold the single nemesis worker for minutes (P244)."
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

(defn node-gateway-outcome
  "On this node, whether each of its gateways answers now: `(start-outcome ...)` of
  `gateway-state` for every index. For a caller that restarted the node through `db/start!`
  (the LazyFS recovery, P242b), which reports no outcome of its own."
  [test]
  (start-outcome (into {} (for [i (range (gateways test c/*host*))] [i (gateway-state i)]))))

(defn node-health
  "On this node: `node-gateway-outcome` plus `:replica`, `:up` while the replica process is alive
  and `:dead` otherwise. A gateway answers through the other replicas, so it cannot show that
  this node's own replica came back; the LazyFS recovery (P242c) judges both."
  [test]
  (assoc (node-gateway-outcome test)
         :replica (if (cu/daemon-running? replica-pidfile) :up :dead)))

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

(defn restart-api!
  "The replica `kill` nemesis's `:start` (`db/start!`): starts this node's gateways that are not
  running and probes them for `start-settle-s` plus one round, as the gateway nemesis's start
  does, then goes on. Not `start-api!`: its waits (35 s each) and restarts would hold the
  nemesis's single worker for about 3 minutes per gateway under a `partition`, and the faults
  scheduled meanwhile would not run (P244). A gateway left down or pending is warned about, not
  retried; the final phase's `gateway-start` (`:final? true`, always run after a `kill`) starts
  it and the `gateways` checker judges it."
  [test]
  (let [{:keys [down pending] :as outcome} (start-gateways! test)]
    (when (seq down)
      (warn "Gateways" down "on" c/*host* "exited at start (the gateway's NRV-E0604); the final start retries"))
    (when (seq pending)
      (warn "Gateways" pending "on" c/*host* "were not answering at the deadline"))
    outcome))

(defn start-gateways-final!
  "The final phase's start: leaves no gateway down, because no start op follows it. Each of this
  node's gateways is probed (`gateway-state`): `:up` is left; `:dead` is started with
  `start-gateway-until-up!`; `:pending` (running, not answering) is waited for (`settle-gateway`)
  and, if it exits or stays silent, killed and started with `start-gateway-until-up!`. Bounded as
  that function is, per gateway, gateways in turn. Returns `{:up [...] :down [...] :pending
  [...]}` (`start-outcome`); a gateway that is not up (NRV-E0604) is returned, not thrown, so the
  node's other gateways and the other nodes keep their results. Each gateway is handled in its
  own `try`: one whose probe or start threw (ssh, the harness) is left out of the states and named
  in `:error` (`\"gateway N: message\"`, joined with `; `), and the node's other gateways keep
  their `:up`, `:down` and `:pending`, so a gateway left down is never hidden by another's harness
  failure (P244e). `nemesis/final-start-checker` judges both."
  [test]
  (let [restart! (fn [index]
                   (cu/stop-daemon! (gateway-pidfile index))
                   (start-gateway-until-up! test index))
        one      (fn [index]
                   (try [index (case (gateway-state index)
                                 :up      :up
                                 :dead    (start-gateway-until-up! test index)
                                 :pending (let [s (settle-gateway test index)]
                                            (if (= :up s) :up (restart! index))))]
                        (catch InterruptedException e (throw e))
                        (catch Exception e
                          [index (str "gateway " index ": " (or (.getMessage e) e))])))
        results  (mapv one (range (gateways test c/*host*)))
        states   (into {} (remove (comp string? second)) results)
        errors   (vec (keep (fn [[_ r]] (when (string? r) r)) results))]
    (doseq [[index state] states :when (not= :up state)]
      (warn "NRV-E0604: gateway" index "on" c/*host* "is" (name state) "after the final start"))
    (doseq [e errors]
      (warn "NRV-E0607:" e "on" c/*host* "(the probe or the start threw)"))
    (cond-> (start-outcome states)
      (seq errors) (assoc :error (str/join "; " errors)))))

(defn signal-script
  "One shell command that sends `signal` to gateway `index`'s pid only if that process is the
  gateway's own user's (`gateway-user`; `setpriv` drops to it before the exec). The pidfile is
  read once, so the check and the signal cannot see two pids; but `stat` and `kill` are still
  two steps, so a pid that exits and is reused in between is signalled (the window is one shell
  command, and only a process of the gateway's own user passes the check). A stale pidfile after
  an NRV-E0604 exit may name a pid another user's process now has, which this refuses; a pid that
  is gone fails the command."
  [index signal]
  (str "p=$(cat " (gateway-pidfile index) ") && [ \"$(stat -c %U /proc/$p)\" = "
       (gateway-user index) " ] && kill " signal " $p"))

(defn signal-gateways!
  "Sends `signal` to those of gateways `indices` whose pidfile names a live process of the
  gateway's own user (`signal-script`), so a reused pid is not signalled and counted; a gateway
  that is gone is not an error. Returns the indices signalled."
  [indices signal]
  (vec (for [index indices
             :when (try (c/exec :sh :-c (signal-script index signal))
                        true
                        (catch Exception e
                          (info "Gateway" index "on" c/*host* "was not signalled:" (.getMessage e))
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

(defn heal-script
  "The shell script that lifts every gateway cut for gateway `index` on a node of `nodes`: for
  each replica node it deletes the rule up to `heal-deletes-max` times, stopping when `iptables
  -D` fails, then asks `iptables -C`. Only `-C` exit 1 means \"no such rule\"; exit 0 (the rule
  is still there) or any other code (iptables itself failed: 2, 3, 4) is NRV-E0607 naming the
  rule, as `-D` fails both when no rule is left and when iptables is broken. A gateway user that
  does not exist yet (a fresh node, before `create-gateway-users!`) can have no rule, and
  iptables refuses to parse its name (exit 2): the script prints 0 for it. Prints the number
  deleted; exits 1 if any rule is left or could not be checked."
  [nodes index]
  (str "id -u " (gateway-user index) " >/dev/null 2>&1 || { echo 0; exit 0; }; "
       "n=0; left=0; for d in " (str/join " " nodes) "; do"
       " for i in $(seq " heal-deletes-max "); do"
       " iptables -w -t mangle -D OUTPUT " (gateway-rule index "$d")
       " 2>/dev/null || break; n=$((n+1)); done;"
       " iptables -w -t mangle -C OUTPUT " (gateway-rule index "$d") " 2>/dev/null; rc=$?;"
       " if [ $rc -ne 1 ]; then echo \"NRV-E0607: gateway " index ": the rule to $d is still in"
       " place or cannot be checked after the heal (iptables -C exit $rc)\" >&2; left=1; fi;"
       " done; [ $left = 0 ] || exit 1; echo $n"))

(defn heal-gateways!
  "Lifts every gateway cut on this node (all indices and replicas, whatever was cut) and
  confirms none is left (`heal-script`); a rule that survives, or iptables failing, throws, which
  fails the op. Only the final heal (`:final? true`) is judged: `nemesis/final-start-checker`
  makes the run `:unknown` (NRV-E0607) for it; a mid-run heal that threw is only listed
  (`:mid-run-heal-failures`). Returns the indices that had a rule."
  [test]
  (vec (for [index (range max-gateways)
             :let [n (parse-long (str/trim (c/exec :sh :-c (heal-script (:nodes test) index))))]
             :when (pos? n)]
         index)))

(defn start-node-bounded!
  "Starts the replica, then the gateways that are not running with `start-gateways!`, whose wait
  is bounded (`start-settle-s`): a mid-run restart that a concurrent `kill` or `partition` has
  left without quorum returns instead of retrying for minutes (`start-gateway-until-up!`). The
  outcome is not returned; the caller probes (`node-health`)."
  [test]
  (c/su
    (start-replica! test)
    (start-gateways! test)))

(defn kill-all!
  "SIGKILLs the gateways and the replica. The pidfile of a gateway the test did not start is
  harmless: `stop-daemon!` ignores a missing one."
  []
  (doseq [index (range max-gateways)]
    (cu/stop-daemon! (gateway-pidfile index)))
  (cu/stop-daemon! replica-pidfile))

(defn teardown-node!
  "A node's teardown: heals the gateways, then kills everything and removes the data directory
  even if the heal threw. `after-run?` (setup ran in this DB): a heal failure is logged, not
  rethrown, because Jepsen runs this in a `finally` around the run and a throw would skip the
  analysis and lose the verdict; the final phase's heal op carries it to the checker (P244c).
  Before a run (`db/cycle!`) it is rethrown: a node that cannot be cleaned must not start."
  [test after-run?]
  (try (heal-gateways! test)
       (catch Exception e
         (if after-run?
           (warn "NRV-E0607: the gateway heal at teardown failed on" c/*host* ":" (.getMessage e))
           (throw e)))
       (finally
         (kill-all!)
         (when (lazyfs/enabled? test) (lazyfs/umount! dir))
         (c/exec :rm :-rf dir))))

(defn db
  "A Nerva DB. bootstrap is (fn [test node]), run once, against one node's gateway, after every
  gateway is healthy and before any client starts: the workload's layouts, ledgers, views and
  initial rows."
  [bootstrap]
  (let [ran? (atom false)]
    (reify
      db/DB
      (setup! [_ test node]
        (reset! ran? true)
        (c/su
          (c/exec :mkdir :-p dir)
          (c/upload (:nerva-binary test) binary)
          (c/exec :chmod "+x" binary)
          (install-cluster-key!)
          (create-gateway-users!)
          (when (lazyfs/enabled? test) (lazyfs/mount! dir))
          (c/exec binary :format (str "--cluster=" cluster)
                  (str "--replica=" (replica-index test node))
                  (str "--replica-count=" (count (:nodes test)))
                  :--development (lazyfs/data-file test dir data-file))
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
        (c/su (teardown-node! test @ran?)))

      db/Kill
      (kill! [_ test node]
        (c/su (kill-all!)))

      (start! [_ test node]
        (c/su
          (start-replica! test)
          (restart-api! test)))

      ;; A pause stops the replica alone: its gateway goes on taking requests that time out.
      db/Pause
      (pause! [_ test node]
        (c/su (c/exec :kill :-STOP (c/lit (str "$(cat " replica-pidfile ")")))))

      (resume! [_ test node]
        (c/su (c/exec :kill :-CONT (c/lit (str "$(cat " replica-pidfile ")")))))

      db/LogFiles
      (log-files [_ test node]
        (into (merge {replica-log "replica.log"}
                     (when (lazyfs/enabled? test) (lazyfs/log-files dir)))
              (for [index (range (gateways test node))]
                [(gateway-log index) (if (zero? index) "api.log" (str "api-" index ".log"))]))))))
