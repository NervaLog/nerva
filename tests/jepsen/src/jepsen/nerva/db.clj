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

(def cluster
  "The cluster id (0 is reserved for testing)."
  1)

(def replica-port 3000)

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
                     :match-executable? false}
                    binary :start (str "--addresses=" (addresses test)) :--development
                    data-file))

(defn start-api!
  [test]
  (cu/start-daemon! {:logfile           api-log
                     :pidfile           api-pidfile
                     :chdir             dir
                     :match-executable? false
                     :env               {:NERVA_KEY http/api-key}}
                    binary :api (str "--cluster=" cluster) (str "--addresses=" (addresses test))
                    (str "--listen=0.0.0.0:" http/api-port)))

(defn kill-all!
  "SIGKILLs the gateway and the replica."
  []
  (cu/stop-daemon! api-pidfile)
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
      (http/await-healthy! node healthy-timeout-s)
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
      {replica-log "replica.log"
       api-log     "api.log"})))
