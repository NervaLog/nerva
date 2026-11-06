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

(defn start-gateway!
  "Starts gateway `index` once."
  [test index]
  (apply cu/start-daemon!
         {:logfile           (gateway-log index)
          :pidfile           (gateway-pidfile index)
          :chdir             dir
          :match-executable? false
          :env               {:NERVA_KEY http/api-key}}
         (concat [binary :api (str "--cluster=" cluster)
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
    (loop [tries 1]
      (start-gateway! test index)
      (let [deadline (+ (System/nanoTime) (* gateway-start-wait-s 1000000000))
            state    (loop []
                       (cond (http/healthy? c/*host* (gateway-port index)) :up
                             (not (cu/daemon-running? (gateway-pidfile index))) :dead
                             (< deadline (System/nanoTime)) :pending
                             :else (do (Thread/sleep 500) (recur))))]
        (when (and (= :dead state) (< tries gateway-start-tries))
          (info "Gateway" index "on" c/*host* "exited at start; starting it again")
          (recur (inc tries)))))))

(defn kill-all!
  "SIGKILLs the gateways and the replica. The pidfile of a gateway the test did not start is
  harmless: `stop-daemon!` ignores a missing one."
  []
  (doseq [index (range 2)]
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
