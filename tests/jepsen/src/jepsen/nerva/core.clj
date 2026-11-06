(ns jepsen.nerva.core
  "Jepsen tests for Nerva, through `nerva api`. See tests/jepsen/README.md.

    lein run test --workload bank --nemesis kill,partition --time-limit 300 \\
      --nodes 10.77.0.11,... --username root --ssh-private-key .ssh/id_ed25519 \\
      --nerva-binary ../../zig-out/bin/nerva

  run.sh starts the nodes (Docker containers) and passes the node and SSH options."
  (:require [clojure.string :as str]
            [jepsen [checker :as checker]
                    [cli :as cli]
                    [generator :as gen]
                    [os :as os]
                    [tests :as tests]]
            [jepsen.checker.timeline :as timeline]
            [jepsen.nemesis.combined :as combined]
            [jepsen.nerva [bank :as bank]
                          [db :as db]
                          [http :as http]
                          [retry :as retry]])
  (:gen-class))

(def workloads
  {:bank  bank/workload
   :retry retry/workload})

(def default-gateways
  "Gateways per node when --gateways is not given: `retry` resends to another gateway."
  {:bank 1, :retry 2})

(def faults
  "The faults --nemesis may name."
  #{:kill :pause :partition})

(def all-nemeses
  "What test-all runs, each for every workload."
  [[] [:kill] [:pause] [:partition] [:kill :partition]])

(defn parse-faults
  [spec]
  (->> (str/split spec #",")
       (remove str/blank?)
       (mapv keyword)))

(defn nemesis-package
  "Only the packages these faults need: `combined/nemesis-package` sets up every package's
  tools (a clock tool built on the nodes, a bit-flipper downloaded), enabled or not."
  [opts db]
  (let [package-opts {:db        db
                      :nodes     (:nodes opts)
                      :faults    (set (:nemesis opts))
                      :interval  (:nemesis-interval opts)
                      :kill      {:targets [:one :minority :majority :all]}
                      :pause     {:targets [:one :minority :majority]}
                      :partition {:targets [:one :majority :majorities-ring]}}]
    (combined/compose-packages [(combined/db-package package-opts)
                                (combined/partition-package package-opts)])))

(defn nerva-test
  "A test map from CLI options."
  [opts]
  (let [workload ((workloads (:workload opts)) opts)
        opts     (assoc opts :gateways (or (:gateways opts) (default-gateways (:workload opts))))
        db       (db/db (:bootstrap workload))
        package  (nemesis-package opts db)]
    (merge tests/noop-test
           opts
           (:test-keys workload)
           {:name      (str "nerva " (name (:workload opts))
                            (when (seq (:nemesis opts))
                              (str " " (str/join "," (map name (:nemesis opts))))))
            :os        os/noop
            :db        db
            :client    (:client workload)
            :nemesis   (:nemesis package)
            :checker   (checker/compose
                         {:perf       (checker/perf {:nemeses (:perf package)})
                          :timeline   (timeline/html)
                          :stats      (checker/stats)
                          :exceptions (checker/unhandled-exceptions)
                          :protocol   (http/protocol-checker)
                          :workload   (:checker workload)})
            :generator (gen/phases
                         (->> (:generator workload)
                              (gen/stagger (/ (:rate opts)))
                              (gen/nemesis (:generator package))
                              (gen/time-limit (:time-limit opts)))
                         (gen/log "Healing the cluster")
                         (gen/nemesis (:final-generator package))
                         (gen/log "Waiting for recovery")
                         (gen/sleep (:recovery-time opts))
                         (gen/clients (:final-generator workload)))})))

(def cli-opts
  [["-w" "--workload NAME" "Workload to run."
    :default  :bank
    :parse-fn keyword
    :validate [workloads (str "Must be one of " (str/join ", " (map name (keys workloads))))]]
   [nil "--nemesis FAULTS" "Comma-separated faults: kill, pause, partition."
    :default  []
    :parse-fn parse-faults
    :validate [(partial every? faults) (str "Faults are " (str/join ", " (map name faults)))]]
   [nil "--nemesis-interval SECONDS" "Mean seconds between faults."
    :default  10
    :parse-fn parse-long]
   ["-r" "--rate HZ" "Requests per second, over all workers."
    :default  20
    :parse-fn parse-double]
   [nil "--recovery-time SECONDS" "Seconds between healing and the final reads."
    :default  20
    :parse-fn parse-long]
   [nil "--gateways N" "Gateways per node: 1, or 2 (ports 8080 and 8081), as R4's sidecars. Default: 2 for retry, else 1."
    :parse-fn parse-long
    :validate [#{1 2} "Must be 1 or 2"]]
   [nil "--drop-reply P" "retry: the probability that the client discards a 200 and resends."
    :default  0.1
    :parse-fn parse-double
    :validate [#(<= 0 % 1) "Must be between 0 and 1"]]
   [nil "--attempts N" "retry: attempts per operation before it ends unresolved."
    :default  8
    :parse-fn parse-long
    :validate [pos? "Must be positive"]]
   [nil "--nerva-binary PATH" "The nerva binary to install on every node."
    :default "../../zig-out/bin/nerva"]])

(defn all-tests
  "test-all: every workload under every nemesis in all-nemeses."
  [opts]
  (for [workload (keys workloads)
        nemesis  all-nemeses
        _        (range (:test-count opts 1))]
    (nerva-test (assoc opts :workload workload, :nemesis nemesis))))

(defn -main
  [& args]
  (cli/run! (merge (cli/single-test-cmd {:test-fn nerva-test, :opt-spec cli-opts})
                   (cli/test-all-cmd {:tests-fn all-tests, :opt-spec cli-opts})
                   (cli/serve-cmd))
            args))
