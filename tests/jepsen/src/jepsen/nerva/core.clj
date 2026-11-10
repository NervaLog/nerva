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
                          [lazyfs :as lazyfs]
                          [nemesis :as nemesis]
                          [retry :as retry]])
  (:gen-class))

(def workloads
  {:bank  bank/workload
   :retry retry/workload})

(defn default-gateways
  "Gateways per node when --gateways is not given: a keyed workload resends to another gateway."
  [{:keys [workload keyed]}]
  (if (or (= :retry workload) (and (= :bank workload) (not (false? keyed)))) 2 1))

(def faults
  "The faults --nemesis may name."
  #{:kill :pause :partition :gateway :gateway-kill :gateway-partition :gateway-pause
    lazyfs/fault})

(def all-nemeses
  "What test-all runs, each for every workload."
  [[] [:kill] [:pause] [:partition] [:gateway] [:kill :partition] [:kill :partition :gateway]])

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
                      :dir       db/dir
                      :node-probe  db/node-health
                      :start-mid!  db/start-node-bounded!
                      :kill      {:targets [:one :minority :majority :all]}
                      :pause     {:targets [:one :minority :majority]}
                      :partition {:targets [:one :majority :majorities-ring]}}]
    ;; Final generators run in this order. The lazyfs recovery is judged, so it comes after the
    ;; replica restart (db-package) and the partition heal, which may otherwise leave it no
    ;; quorum, and before nemesis/package's final gateway start.
    (combined/compose-packages [(nemesis/heal-package package-opts)
                                (combined/db-package package-opts)
                                (combined/partition-package package-opts)
                                (lazyfs/package package-opts)
                                (nemesis/package package-opts)])))

(defn nerva-test
  "A test map from CLI options."
  [opts]
  (when (:lazyfs-all-nodes opts)
    (let [[text cause] (lazyfs/read-meminfo)]
      (lazyfs/check-host-memory! opts text cause)))
  (let [workload ((workloads (:workload opts)) opts)
        opts     (assoc opts
                        :gateways (or (:gateways opts) (default-gateways opts))
                        :lazyfs   (contains? (set (:nemesis opts)) lazyfs/fault))
        db       (db/db (:bootstrap workload))
        package  (nemesis-package opts db)]
    (merge tests/noop-test
           opts
           (:test-keys workload)
           {:name      (str "nerva " (name (:workload opts))
                            (when (and (= :bank (:workload opts)) (false? (:keyed opts)))
                              " no-keys")
                            (when (seq (:nemesis opts))
                              (str " " (str/join "," (map name (:nemesis opts))))))
            :os        os/noop
            :db        db
            :client    (:client workload)
            :nemesis   (:nemesis package)
            :nemesis-faults (set (:nemesis opts))
            :checker   (checker/compose
                         {:perf       (checker/perf {:nemeses (:perf package)})
                          :timeline   (timeline/html)
                          :stats      (checker/stats)
                          :exceptions (checker/unhandled-exceptions)
                          :protocol   (http/protocol-checker)
                          :gateways   (nemesis/final-start-checker)
                          :lazyfs     (lazyfs/recover-checker)
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
   [nil "--nemesis FAULTS" "Comma-separated faults: kill, pause, partition, gateway (= gateway-kill, gateway-partition, gateway-pause), lose-unfsynced-writes (LazyFS)."
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
   [nil "--gateways N" "Gateways per node: 1, or 2 (ports 8080 and 8081), as R4's sidecars. Default: 2 for retry and for bank with keys, else 1."
    :parse-fn parse-long
    :validate [#{1 2} "Must be 1 or 2"]]
   [nil "--[no-]keys" "bank: send each transfer under a commit key, with a record, retried as retry's are (default), or unkeyed."
    :id      :keyed
    :default true]
   [nil "--drop-reply P" "keyed workloads: the probability that the client discards a 200 and resends."
    :default  0.1
    :parse-fn parse-double
    :validate [#(<= 0 % 1) "Must be between 0 and 1"]]
   [nil "--attempts N" "keyed workloads: attempts per operation before it ends unresolved."
    :default  8
    :parse-fn parse-long
    :validate [pos? "Must be positive"]]
   [nil "--lazyfs-all-nodes" "lose-unfsynced-writes: LazyFS on all 5 nodes, and also lose writes on every node after a quorum crash. Refused (NRV-E0607) on a host with under 32 GiB: a hosted runner puts LazyFS on a minority of nodes (P242j)."]
   [nil "--lazyfs-strict-sync" "lose-unfsynced-writes: any unsynced byte LazyFS holds after a kill fails the run (the hosted canary: an unpatched LazyFS, P242j)."]
   [nil "--nerva-binary PATH" "The nerva binary to install on every node."
    :default "../../zig-out/bin/nerva"]])

(def all-variants
  "What test-all runs under every nemesis: [workload keyed?]. `bank` runs both ways, so that
  the unkeyed run stays covered."
  [[:bank true] [:bank false] [:retry true]])

(defn all-tests
  "test-all: every workload variant under every nemesis in all-nemeses."
  [opts]
  (for [[workload keyed] all-variants
        nemesis          all-nemeses
        _                (range (:test-count opts 1))]
    (nerva-test (assoc opts :workload workload, :keyed keyed, :nemesis nemesis))))

(defn refusing
  "`f`, except that a refusal (`check-host-memory!`: an ex-info with `:refusal`) is one line on
  stderr and exit 2, not Jepsen's fatal stack trace and exit 255. Exits the JVM."
  [f]
  (fn [opts]
    (try (f opts)
         (catch clojure.lang.ExceptionInfo e
           (if (:refusal (ex-data e))
             (do (binding [*out* *err*] (println (.getMessage e)))
                 (flush)
                 (System/exit 2))
             (throw e))))))

(def refusing-test
  "`nerva-test`, refusing as `refusing` says."
  (refusing nerva-test))

(def refusing-all-tests
  "`all-tests`, refusing as `refusing` says. Realised here (`doall`): `test-all` builds the tests
  lazily, outside its per-test `try`, so a refusal would otherwise reach Jepsen's fatal handler."
  (refusing (comp doall all-tests)))

(defn -main
  [& args]
  (cli/run! (merge (cli/single-test-cmd {:test-fn refusing-test, :opt-spec cli-opts})
                   (cli/test-all-cmd {:tests-fn refusing-all-tests, :opt-spec cli-opts})
                   (cli/serve-cmd))
            args))
