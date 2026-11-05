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
(def replica-pidfile (str dir "/replica.pid"))
(def api-pidfile (str dir "/api.pid"))

(defn gateways
  "How many `nerva api` gateways each node runs (`--gateways`, 1 or 2): R4's sidecar topology
  has one per client process, so two gateways share every replica."
  [test]
  (:gateways test 1))

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

(def cluster-key
  "The key replicas authenticate each other with (P102): at least 32 bytes."
  "jepsen-cluster-key-0123456789abcdefghij")

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
                     :env               {:NERVA_CLUSTER_KEY cluster-key}}
                    binary :start (str "--addresses=" (addresses test)) :--development
                    data-file))

(defn start-api!
  "Starts the test's gateways. The control node reaches them over the network, so they listen
  on every address and say so: `--listen-remote` (P168, NRV-E0009)."
  [test]
  (doseq [index (range (gateways test))]
    (cu/start-daemon! {:logfile           (gateway-log index)
                       :pidfile           (gateway-pidfile index)
                       :chdir             dir
                       :match-executable? false
                       :env               {:NERVA_KEY http/api-key}}
                      binary :api (str "--cluster=" cluster) (str "--addresses=" (addresses test))
                      (str "--listen=0.0.0.0:" (gateway-port index))
                      :--listen-remote)))

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
        (c/exec binary :format (str "--cluster=" cluster)
                (str "--replica=" (replica-index test node))
                (str "--replica-count=" (count (:nodes test)))
                :--development data-file)
        (start-replica! test)
        (start-api! test))
      (doseq [index (range (gateways test))]
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
            (for [index (range (gateways test))]
              [(gateway-log index) (if (zero? index) "api.log" (str "api-" index ".log"))])))))
