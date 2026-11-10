(ns jepsen.nerva.lazyfs-test
  "The lose-unfsynced-writes fault's shapes: what it draws, the order it acts in, what its undo
  starts, and that it composes with the other packages."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [jepsen.checker :as checker]
            [jepsen.control :as c]
            [jepsen.generator :as gen]
            [jepsen.generator.context :as ctx]
            [jepsen.nemesis :as n]
            [jepsen.nerva.core :as core]
            [jepsen.nerva.db :as db]
            [jepsen.lazyfs :as upstream-lazyfs]
            [jepsen.nerva.lazyfs :as lazyfs]))

(def five {:nodes ["n1" "n2" "n3" "n4" "n5"], :concurrency 1})

(defn package []
  (lazyfs/package {:faults #{lazyfs/fault}, :interval 0, :dir "/opt/nerva", :nodes (:nodes five)}))

(deftest fault-values
  (let [vs (repeatedly 300 #(lazyfs/fault-value (assoc five :lazyfs-all-nodes true)))]
    (is (= #{:minority :all} (set (map :scope vs))))
    (is (= #{:minority} (set (map :scope (repeatedly 100 #(lazyfs/fault-value five))))))
    (doseq [v vs]
      (case (:scope v)
        :minority (do (is (<= 1 (count (:nodes v)) 2))
                      (is (apply distinct? (:nodes v)))
                      (is (every? (set (:nodes five)) (:nodes v)))
                      (is (nil? (:crash v))))
        :all      (do (is (= (:nodes five) (:nodes v)))
                      (is (= 3 (count (:crash v))))
                      (is (apply distinct? (:crash v))))))
    (testing "a minority of a 3-node cluster is one node"
      (is (every? #(= 1 (count (:nodes %)))
                  (filter #(= :minority (:scope %))
                          (repeatedly 100 #(lazyfs/fault-value {:nodes ["a" "b" "c"]}))))))))

(deftest package-only-when-asked
  (let [off (lazyfs/package {:faults #{:kill}, :dir "/opt/nerva"})]
    (is (nil? (:generator off)))
    (is (nil? (:final-generator off)))
    (is (empty? (:perf off))))
  (let [on (package)]
    (is (some? (:generator on)))
    (is (= [:lazyfs-recover] (map :f (:final-generator on))))
    (is (= ["lose-unfsynced-writes"] (map :name (:perf on))))))

(deftest generator-alternates-fault-and-recover
  (let [g       (:generator (package))
        context (ctx/context five)
        fs      (loop [g g, fs [], context context]
                  (if (= 6 (count fs))
                    fs
                    (let [[o g'] (gen/op g five context)
                          o      (assoc o :process :nemesis)]
                      (recur (gen/update g' five context o) (conj fs (:f o))
                             (ctx/busy-thread context (:time o) :nemesis)))))]
    (is (= [:lose-unfsynced-writes :lazyfs-recover :lose-unfsynced-writes :lazyfs-recover
            :lose-unfsynced-writes :lazyfs-recover]
           fs))))

(deftest the-first-fault-is-all-when-the-test-allows-it
  (let [g       (:generator (package))
        context (ctx/context five)
        scopes  (fn [test]
                  (loop [g g, fs [], context context]
                    (if (= 8 (count fs))
                      fs
                      (let [[o g'] (gen/op g test context)
                            o      (assoc o :process :nemesis)]
                        (recur (gen/update g' test context o)
                               (cond-> fs (= :lose-unfsynced-writes (:f o))
                                       (conj (:scope (:value o))))
                               (ctx/busy-thread context (:time o) :nemesis))))))]
    (is (= :all (first (scopes (assoc five :lazyfs-all-nodes true)))) "a canary draws an :all")
    (is (= #{:minority} (set (scopes five))))))

(deftest acts-in-order-and-recovers-what-it-killed
  (let [calls   (atom [])
        nemesis (lazyfs/nemesis "/opt/nerva" nil)]
    (with-redefs [lazyfs/kill!    (fn [_ nodes] (swap! calls conj [:kill nodes]) (vec nodes))
                  lazyfs/lose!    (fn [_ _ nodes] (swap! calls conj [:lose nodes])
                                    (zipmap nodes (repeat {:before 4096, :after 0, :sentinel :gone})))
                  lazyfs/recover! (fn [_ nodes _ final? _]
                                    (swap! calls conj [:recover nodes final?])
                                    {:nodes (vec nodes), :down [], :pending [], :replica-down []
                                     :unsettled []})]
      (let [done (n/invoke! nemesis five
                            {:type :info, :f :lose-unfsynced-writes
                             :value {:scope :all, :crash ["n4" "n1" "n5"], :nodes (:nodes five)}})]
        (is (= ["n4" "n1" "n5" "n2" "n3"] (:killed (:value done))))
        (is (= {"n1" 4096, "n2" 4096, "n3" 4096, "n4" 4096, "n5" 4096}
               (:unsynced-bytes (:value done))))
        (is (= {"n1" 0, "n2" 0, "n3" 0, "n4" 0, "n5" 0} (:remaining (:value done)))))
      (is (= [[:kill ["n4" "n1" "n5"]]
              [:kill ["n2" "n3"]]
              [:lose ["n1" "n2" "n3" "n4" "n5"]]]
             @calls)
          "the quorum dies first, then the rest, and only then is the cache cleared")
      (let [done (n/invoke! nemesis five {:type :info, :f :lazyfs-recover})]
        (is (= ["n1" "n2" "n3" "n4" "n5"] (:started (:value done))))
        (is (false? (:final? (:value done)))))
      (is (= [:recover ["n1" "n2" "n3" "n4" "n5"] false] (last @calls)))
      (let [done (n/invoke! nemesis five {:type :info, :f :lazyfs-recover :value {:final? true}})]
        (is (true? (:final? (:value done)))))
      (is (= [:recover [] true] (last @calls)) "nothing is pending the second time")
      (n/invoke! nemesis five {:type :info, :f :lose-unfsynced-writes
                               :value {:scope :minority, :nodes ["n2"]}})
      (is (= [:lose ["n2"]] (last @calls)))
      (let [done (n/invoke! nemesis five {:type :info, :f :lazyfs-recover})]
        (is (= ["n2"] (:started (:value done))))))))

(deftest a-throw-after-the-kill-leaves-the-victims-for-the-final-recover
  (testing "MUST 3: the victims are queued before anything that can throw"
    (let [calls   (atom [])
          nemesis (lazyfs/nemesis "/opt/nerva" nil)]
      (with-redefs [lazyfs/kill!    (fn [_ nodes] (vec nodes))
                    lazyfs/lose!    (fn [& _] (throw (ex-info "fifo timeout" {})))
                    lazyfs/recover! (fn [_ nodes _ final? _]
                                      (swap! calls conj [nodes final?])
                                      {:nodes nodes, :down [], :pending [], :replica-down []
                                       :unsettled []})]
        (is (thrown? Exception
                     (n/invoke! nemesis five {:type :info, :f :lose-unfsynced-writes
                                              :value {:scope :minority, :nodes ["n2" "n4"]}})))
        (let [done (n/invoke! nemesis five {:type :info, :f :lazyfs-recover
                                            :value {:final? true}})]
          (is (= ["n2" "n4"] (:started (:value done)))))
        (is (= [[["n2" "n4"] true]] @calls))))))

(deftest recover-reports-what-it-left-down
  (let [nemesis (lazyfs/nemesis "/opt/nerva" nil)]
    (with-redefs [lazyfs/recover! (fn [_ nodes _ _ _]
                                    {:nodes nodes, :down [["n2" 1]], :pending [["n3" 0]]
                                     :replica-down ["n2"], :unsettled ["n2"]})]
      (let [done (n/invoke! nemesis five {:type :info, :f :lazyfs-recover})]
        (is (= [["n2" 1]] (:down (:value done))))
        (is (= [["n3" 0]] (:pending (:value done))))
        (is (= ["n2"] (:replica-down (:value done))))))))

(deftest a-fault-waits-for-the-previous-victims-to-catch-up
  (testing "MUST 1: never more than a minority behind"
    (let [calls    (atom [])
          behind   (atom ["n1"])
          nemesis  (lazyfs/nemesis "/opt/nerva" nil)
          fault-op {:type :info, :f :lose-unfsynced-writes
                    :value {:scope :minority, :nodes ["n3"]}}]
      (with-redefs [lazyfs/kill!     (fn [_ nodes] (vec nodes))
                    lazyfs/lose!     (fn [_ _ nodes] (swap! calls conj [:lose nodes])
                                       (zipmap nodes (repeat {:before 10, :after 0})))
                    lazyfs/catch-up! (fn [_ nodes _] (swap! calls conj [:catch-up (vec nodes)])
                                       @behind)
                    lazyfs/recover!  (fn [_ nodes _ _ _]
                                       {:nodes nodes, :down [], :pending [], :replica-down []
                                        :unsettled @behind})]
        (n/invoke! nemesis five (assoc fault-op :value {:scope :minority, :nodes ["n1"]}))
        (n/invoke! nemesis five {:type :info, :f :lazyfs-recover})
        (reset! calls [])
        (let [done (n/invoke! nemesis five fault-op)]
          (is (= :not-caught-up (:skipped (:value done))))
          (is (= ["n1"] (:behind (:value done))))
          (is (= [] (:killed (:value done))))
          (is (= [[:catch-up ["n1"]]] @calls) "nothing was killed or cleared"))
        (reset! behind [])
        (let [done (n/invoke! nemesis five fault-op)]
          (is (= ["n3"] (:killed (:value done)))))))))

(deftest an-empty-recover-keeps-the-nodes-still-behind
  (testing "MUST 2: fault, unsettled recover, skip, empty recover, fault"
    (let [calls    (atom [])
          behind   (atom ["n1"])
          nemesis  (lazyfs/nemesis "/opt/nerva" nil)
          fault-op (fn [node] {:type :info, :f :lose-unfsynced-writes
                               :value {:scope :minority, :nodes [node]}})]
      (with-redefs [lazyfs/kill!     (fn [_ nodes] (vec nodes))
                    lazyfs/lose!     (fn [_ _ nodes] (swap! calls conj [:lose nodes])
                                       (zipmap nodes (repeat {:before 10, :after 0})))
                    lazyfs/catch-up! (fn [_ _ _] @behind)
                    lazyfs/recover!  (fn [_ nodes _ _ _]
                                       {:nodes nodes, :judged nodes, :down [], :pending []
                                        :replica-down [], :unsettled (vec (filter (set @behind) nodes))})]
        (n/invoke! nemesis five (fault-op "n1"))
        (n/invoke! nemesis five {:type :info, :f :lazyfs-recover})
        (is (= :not-caught-up (:skipped (:value (n/invoke! nemesis five (fault-op "n3"))))))
        (let [done (n/invoke! nemesis five {:type :info, :f :lazyfs-recover})]
          (is (= [] (:started (:value done)))))
        (reset! calls [])
        (is (= :not-caught-up (:skipped (:value (n/invoke! nemesis five (fault-op "n3")))))
            "the empty recover settled nothing, so the gate still holds")
        (is (= [] @calls))))))

(deftest the-final-recovery-settles-every-node-the-fault-hit
  (let [seen    (atom nil)
        nemesis (lazyfs/nemesis "/opt/nerva" nil)]
    (with-redefs [lazyfs/kill!    (fn [_ nodes] (vec nodes))
                  lazyfs/lose!    (fn [_ _ nodes] (zipmap nodes (repeat {:before 10, :after 0})))
                  lazyfs/recover! (fn [_ nodes _ final? watch]
                                    (when final? (reset! seen [nodes (set watch)]))
                                    {:nodes nodes, :judged nodes, :down [], :pending []
                                     :replica-down [], :unsettled []})]
      (n/invoke! nemesis five {:type :info, :f :lose-unfsynced-writes
                               :value {:scope :minority, :nodes ["n2"]}})
      (n/invoke! nemesis five {:type :info, :f :lazyfs-recover})
      (n/invoke! nemesis five {:type :info, :f :lazyfs-recover :value {:final? true}})
      (is (= [[] #{"n2"}] @seen)
          "nothing was pending, but n2 was hit and the last recover was mid-run"))))

(deftest parse-report-reads-both-endings
  (testing "hosted run 42202316064: a clear leaves no total, LazyFS says everything is synced"
    (is (= 0 (lazyfs/parse-report "[..] [lazyfs.cmds]: report: all data blocks are synced!")))
    (is (= 270336 (lazyfs/parse-report
                    "[..] [lazyfs.cmds]: report: total number of bytes un-fsynced: 270336 bytes.")))
    (is (nil? (lazyfs/parse-report "")))))

(deftest settle-recovery-waits-for-a-stable-node
  (let [clock  (atom 0)
        opts   {:wait-ms 1000, :stable-ms 300, :now #(deref clock)
                :sleep! #(swap! clock + 100)}
        probes (fn [outcomes]
                 (let [q (atom outcomes)]
                   #(let [o (first @q)] (swap! q (fn [x] (if (next x) (next x) x))) o)))]
    (testing "gateways pending at first (as after #244's short start), then up for long enough"
      (let [r (lazyfs/settle-recovery
                (probes [{:replica :up, :pending [0]} {:replica :up, :pending [0]}
                         {:replica :up}])
                opts)]
        (is (true? (:settled? r)))
        (is (<= 300 (:waited-ms r)))))
    (testing "a replica that is dead never settles, and the wait is bounded"
      (reset! clock 0)
      (let [r (lazyfs/settle-recovery (probes [{:replica :dead}]) opts)]
        (is (false? (:settled? r)))
        (is (= :dead (:replica r)))
        (is (<= 1000 (:waited-ms r) 1100))))
    (testing "a replica that dies again resets the stable window"
      (reset! clock 0)
      (let [r (lazyfs/settle-recovery
                (probes [{:replica :up} {:replica :up} {:replica :dead} {:replica :dead}])
                (assoc opts :wait-ms 600))]
        (is (false? (:settled? r)))))
    (testing "no probe: settled at once"
      (is (true? (:settled? (lazyfs/settle-recovery nil opts)))))))

(deftest recover-reports-a-dead-replica-the-gateways-hide
  (testing "MUST 2: recover! asks the probe, which sees the replica"
    (with-redefs [c/on-nodes        (fn [_ nodes f]
                                      (into {} (for [n nodes]
                                                 [n (binding [c/*host* n] (f {} n))])))
                  lazyfs/recover-wait-ms {:mid 1500, :final 1500}
                  lazyfs/stable-ms 200
                  lazyfs/start-node! (fn [& _] nil)]
      (let [r (lazyfs/recover! {} ["n1" "n2"]
                               {:probe (fn [_] (if (= "n2" c/*host*)
                                                 {:replica :dead, :up [0]}
                                                 {:replica :up, :up [0]}))}
                               true [])]
        (is (= ["n2"] (:replica-down r)))
        (is (= ["n2"] (:unsettled r)))))))

(defn- check-recover
  ([history] (check-recover {:lazyfs true} history))
  ([test history] (checker/check (lazyfs/recover-checker) test history {})))

(defn- pair [f value & {:as extra}]
  [{:type :info, :f f, :process :nemesis, :value (select-keys value [:final?])}
   (merge {:type :info, :f f, :process :nemesis, :value value} extra)])

(defn- fault-pair [& {:as extra}]
  (pair :lose-unfsynced-writes
        {:killed ["n1"], :unsynced-bytes {"n1" 100}, :remaining {"n1" 0}
         :sentinel {"n1" :gone}}
        extra))

(defn- recover-pair [value & {:as extra}]
  (pair :lazyfs-recover (merge {:started ["n1"], :judged ["n1"], :final? true, :down [], :pending []
                                :replica-down []}
                               value)
        extra))

(defn- history [& pairs] (vec (apply concat pairs)))

(deftest recover-checker
  (testing "a fault that lost bytes and a final recovery that serves passes; pairs count once"
    (let [r (check-recover (history (fault-pair) (recover-pair {})))]
      (is (true? (:valid? r)))
      (is (= 1 (:faults r)))
      (is (= 1 (:recovers r)) "the invocation is not a completion")
      (is (= 100 (:lost-bytes r)))))
  (testing "a gateway left down, or pending, in the final recovery fails with NRV-E0604"
    (let [r (check-recover (history (fault-pair)
                                    (recover-pair {:down [["n1" 1]] :pending [["n3" 0]]})))]
      (is (false? (:valid? r)))
      (is (= "NRV-E0604" (:code r)))
      (is (= [["n1" 1] ["n3" 0]] (:gateways r)))))
  (testing "MUST 2: a dead replica fails even when every gateway answers"
    (let [r (check-recover (history (fault-pair) (recover-pair {:replica-down ["n1"]})))]
      (is (false? (:valid? r)))
      (is (= "NRV-E0604" (:code r)))
      (is (= ["n1"] (:replica-down r)))))
  (testing "MUST 4: a mid-run recovery that left gateways down is recorded, not judged"
    (let [r (check-recover (history (fault-pair)
                                    (recover-pair {:final? false, :down [["n1" 0]]
                                                   :replica-down ["n1"]})
                                    (recover-pair {})))]
      (is (true? (:valid? r)))
      (is (= 2 (:recovers r)))
      (is (= 1 (:final r)))))
  (testing "an exception in the final recovery fails"
    (is (false? (:valid? (check-recover (history (fault-pair)
                                                 (recover-pair {} :exception {:cause "boom"})))))))
  (testing "MUST 3: a fault that threw is invalid, and so is a run with no final recovery"
    (let [r (check-recover (history (pair :lose-unfsynced-writes {:nodes ["n1"]}
                                          :exception {:cause "fifo timeout"})
                                    (recover-pair {})))]
      (is (= :unknown (:valid? r)) "the harness failed: not a Nerva finding")
      (is (some #{:fault-threw} (:problems r))))
    (let [r (check-recover (history (fault-pair)))]
      (is (some #{:no-final-recover} (:problems r)))))
  (testing "the fault was asked for but took nothing"
    (is (some #{:no-fault-took} (:problems (check-recover [])))
        "zero faults and zero recovers are invalid when the test asked for the fault"))
  (testing "P242e: no bytes lost is reported, not judged, when the sentinel is gone"
    (let [r (check-recover (history (pair :lose-unfsynced-writes
                                          {:killed ["n1"], :unsynced-bytes {"n1" 0}
                                           :remaining {"n1" 0}, :sentinel {"n1" :gone}})
                                    (recover-pair {})))]
      (is (true? (:valid? r)))
      (is (= 0 (:lost-bytes r)))
      (is (= {:gone 1} (:sentinel r))))
    (let [r (check-recover (history (pair :lose-unfsynced-writes
                                          {:killed ["n1"], :unsynced-bytes {"n1" 0}
                                           :remaining {"n1" 0}, :sentinel {"n1" :truncated}})
                                    (recover-pair {})))]
      (is (true? (:valid? r)))))
  (testing "P242e: a sentinel that survives the clear means the fault did not bite"
    (let [r (check-recover (history (pair :lose-unfsynced-writes
                                          {:killed ["n1"], :unsynced-bytes {"n1" 4096}
                                           :remaining {"n1" 0}, :sentinel {"n1" :survived}})
                                    (recover-pair {})))]
      (is (= :unknown (:valid? r)))
      (is (= "NRV-E0607" (:code r)))
      (is (some #{:sentinel-survived} (:problems r)))
      (is (re-find #"did not bite" (:reason r)))))
  (testing "P242e: a sentinel that was never checked proves nothing"
    (doseq [sentinel [{} {"n1" :unwritten}]]
      (let [r (check-recover (history (pair :lose-unfsynced-writes
                                            {:killed ["n1"], :unsynced-bytes {"n1" 0}
                                             :remaining {"n1" 0}, :sentinel sentinel})
                                      (recover-pair {})))]
        (is (= :unknown (:valid? r)))
        (is (some #{:sentinel-unchecked} (:problems r))))))
  (testing "P242e: a clear LazyFS did not confirm is unknown even with the sentinel gone"
    (let [r (check-recover (history (pair :lose-unfsynced-writes
                                          {:killed ["n1"], :unsynced-bytes {"n1" 10}
                                           :remaining {"n1" 10}, :sentinel {"n1" :gone}})
                                    (recover-pair {})))]
      (is (= :unknown (:valid? r)))
      (is (some #{:clear-unconfirmed} (:problems r)))))
  (testing "a clear not seen to take is invalid"
    (let [r (check-recover (history (pair :lose-unfsynced-writes
                                          {:killed ["n1"], :unsynced-bytes {"n1" 10}
                                           :remaining {"n1" 10}})
                                    (recover-pair {})))]
      (is (some #{:clear-unconfirmed} (:problems r)))))
  (testing "a final recovery that judged no node proves nothing"
    (let [r (check-recover (history (fault-pair) (recover-pair {:started [], :judged []})))]
      (is (= :unknown (:valid? r)))
      (is (some #{:final-judged-nothing} (:problems r)))
      (is (= "NRV-E0607" (:code r)) "the harness's, not Nerva's")))
  (testing "a skipped fault is counted, not judged; no fault asked, nothing judged"
    (let [r (check-recover (history (fault-pair)
                                    (pair :lose-unfsynced-writes
                                          {:killed [], :skipped :not-caught-up, :behind ["n1"]})
                                    (recover-pair {})))]
      (is (true? (:valid? r)))
      (is (= 1 (:skipped r))))
    (is (true? (:valid? (check-recover {} []))))))

(deftest a-run-that-never-asked-for-the-fault-is-not-judged-by-it
  ;; Review MUST 1: kill, partition and gateway runs (the nightly, the default jepsen.yml run,
  ;; demo steps 1 and 2) have nemesis ops and `:lazyfs false`; they were `:unknown` NRV-E0607.
  (let [others (history (pair :kill {:nodes ["n1"]}) (pair :start {:nodes ["n1"]})
                        (pair :start-partition {:grudge {}}) (pair :stop-partition {}))]
    (doseq [test [{:lazyfs false} {}]]
      (let [r (check-recover test others)]
        (is (true? (:valid? r)) (pr-str test))
        (is (nil? (:code r)))
        (is (nil? (:problems r)))))
    (testing "a run that asked for the fault, and only killed, is still unknown"
      (is (= :unknown (:valid? (check-recover {:lazyfs true} others)))))
    (testing "a fault or recover op in the history is asking, whatever the test map says"
      (is (some #{:no-fault-took} (:problems (check-recover {} (history (recover-pair {})))))))))

(deftest sentinel-classification
  (is (= :gone (lazyfs/classify-sentinel 4096 nil)))
  (is (= :truncated (lazyfs/classify-sentinel 4096 0)))
  (is (= :truncated (lazyfs/classify-sentinel 4096 100)))
  (is (= :survived (lazyfs/classify-sentinel 4096 4096)))
  (is (= :unwritten (lazyfs/classify-sentinel nil nil)))
  (is (= :unwritten (lazyfs/classify-sentinel 0 0))))

(deftest data-file-follows-the-fault
  (binding [c/*host* "n1"]
    (is (= "/opt/nerva/data/replica.nerva"
           (lazyfs/data-file (assoc five :lazyfs true) "/opt/nerva" "/x")))
    (is (= "/x" (lazyfs/data-file five "/opt/nerva" "/x"))))
  (is (= "/opt/nerva/data" (:dir (lazyfs/lazyfs-map "/opt/nerva"))))
  (is (= "/opt/nerva/data.lazyfs/log" (:log-file (lazyfs/lazyfs-map "/opt/nerva")))))

(deftest composes-with-the-other-packages
  ;; n/compose throws when two nemeses claim the same f.
  (let [pkg (core/nemesis-package {:nodes (:nodes five)
                                   :nemesis [:kill :partition :gateway lazyfs/fault]
                                   :nemesis-interval 0}
                                  (db/db (fn [_ _])))]
    (is (some #{:lazyfs-recover} (keep :f (flatten (:final-generator pkg)))))
    (is (contains? (set (map :name (:perf pkg))) "lose-unfsynced-writes"))))

(deftest cli-accepts-the-fault
  (is (= [:lose-unfsynced-writes :kill] (core/parse-faults "lose-unfsynced-writes,kill")))
  (is (contains? core/faults lazyfs/fault)))

(defn- fake-node
  "Redefs for `lose!` against one node whose LazyFS cache is `full?` or empty: a sentinel written
  into a full cache is durable, into an empty one is lost by the clear."
  [st f]
  (with-redefs [c/on-nodes (fn [_ nodes g]
                             (into {} (for [n nodes] [n (binding [c/*host* n] (g {} n))])))
                c/exec     (fn [& _] "")
                lazyfs/on-mount (fn [cmd]
                                  (when (re-find #"^dd " cmd)
                                    (swap! st assoc :file (if (:full? @st) :durable :cached)))
                                  [0 ""])
                lazyfs/cache-usage    (fn [_] (if (:full? @st) 100.0 12.5))
                lazyfs/unsynced-bytes (fn [_] 0)
                lazyfs/size-of        (fn [_] (when (#{:durable :cached} (:file @st)) 4096))
                upstream-lazyfs/lose-unfsynced-writes!
                (fn [_] (swap! st #(cond-> % (= :cached (:file %)) (assoc :file :lost))))]
    (f)))

(deftest lose-writes-the-sentinel-before-the-first-clear
  (testing "P242h: an empty cache loses the sentinel on the very first clear"
    (let [st (atom {:full? false, :file nil})
          r  (fake-node st #(get (lazyfs/lose! {} {:dir "/opt/nerva/data"} ["n1"]) "n1"))]
      (is (= :gone (:sentinel r)))
      (is (= 12.5 (:cache-usage r)))
      (is (= 0 (:before r)) "the sentinel is not counted as the replica's bytes")))
  (testing "P242h: a full cache wrote the sentinel through; the first fault is not hidden"
    (let [st (atom {:full? true, :file nil})
          r  (fake-node st #(get (lazyfs/lose! {} {:dir "/opt/nerva/data"} ["n1"]) "n1"))]
      (is (= :survived (:sentinel r)))
      (is (= 100.0 (:cache-usage r))))))

(deftest a-wedged-mount-is-unchecked-not-a-hang
  (is (= :unchecked (lazyfs/classify-sentinel 4096 :timeout)))
  (with-redefs [c/exec (fn [& _] "124\n")]
    (is (= :timeout (#'lazyfs/size-of "/m/x"))))
  (with-redefs [c/exec (fn [& _] "1\nstat: cannot statx '/m/x': No such file or directory")]
    (is (nil? (#'lazyfs/size-of "/m/x"))))
  ;; A dead FUSE mount is not a missing file (review of 9a78be9): never the sentinel's `:gone`.
  (with-redefs [c/exec (fn [& _] "1\nstat: cannot statx '/m/x': Transport endpoint is not connected")]
    (is (= :error (#'lazyfs/size-of "/m/x")))
    (is (= :unchecked (lazyfs/classify-sentinel 4096 (#'lazyfs/size-of "/m/x")))))
  (with-redefs [c/exec (fn [& _] "0\n4096")]
    (is (= 4096 (#'lazyfs/size-of "/m/x"))))
  ;; Exit 0 with output that is not a bare integer (stderr rides along) is not proof either.
  (with-redefs [c/exec (fn [& _] "0\nstat: warning: something\n4096")]
    (is (= :error (#'lazyfs/size-of "/m/x")))
    (is (= :unchecked (lazyfs/classify-sentinel 4096 (#'lazyfs/size-of "/m/x"))))))

(deftest cache-usage-lines
  (is (= 29.3 (lazyfs/parse-usage "[lazyfs.cmds]: cache usage (%pages) is 29.3%")))
  (is (= 0.0 (lazyfs/parse-usage "[x] cache usage (%pages) is 0%")))
  (is (nil? (lazyfs/parse-usage "nothing")))
  (is (lazyfs/cache-full? 100.0))
  (is (not (lazyfs/cache-full? 99.9)))
  (is (not (lazyfs/cache-full? nil))))

(deftest data-is-formatted-outside-the-mount
  (binding [c/*host* "n1"]
    (is (= "/opt/nerva/data.lazyfs/data/replica.nerva"
           (lazyfs/format-file (assoc five :lazyfs true) "/opt/nerva" "/x")))
    (is (= "/x" (lazyfs/format-file five "/opt/nerva" "/x")))))

(deftest a-full-cache-is-reported-not-counted-clean
  (let [r (check-recover (history (pair :lose-unfsynced-writes
                                        {:killed ["n1"], :unsynced-bytes {"n1" 0}
                                         :remaining {"n1" 0}, :sentinel {"n1" :gone}
                                         :cache-usage {"n1" 100.0}})
                                  (recover-pair {})))]
    (is (= :unknown (:valid? r)))
    (is (some #{:cache-full} (:problems r)))
    (is (= ["n1"] (:cache-full r)))
    (is (= 100.0 (:cache-usage-max r))))
  (let [r (check-recover (history (pair :lose-unfsynced-writes
                                        {:killed ["n1"], :unsynced-bytes {"n1" 0}
                                         :remaining {"n1" 0}, :sentinel {"n1" :truncated}
                                         :cache-usage {"n1" 3.5}})
                                  (recover-pair {})))]
    (is (true? (:valid? r)))
    (is (= 3.5 (:cache-usage-max r)))))

(deftest the-cache-covers-the-data-file-so-it-cannot-fill
  ;; P242i: `nerva format --development` writes 1,141,374,976 bytes.
  (is (lazyfs/cache-covers? 1141374976))
  (is (not (lazyfs/cache-covers? 1200000000)))
  (is (not (lazyfs/cache-covers? nil)))
  (is (not (lazyfs/cache-covers? 134217728000)))
  (testing "nothing is checked, and nothing run, with the fault off"
    (with-redefs [c/exec (fn [& _] (throw (ex-info "no command" {})))]
      (is (nil? (lazyfs/check-cache-bound! {} "/opt/nerva" "/opt/nerva/replica.nerva")))))
  (testing "a data file that does not fit is a harness failure"
    (with-redefs [c/exec (fn [& _] "5000000000\n")]
      (binding [c/*host* "n1"]
        (is (thrown-with-msg? clojure.lang.ExceptionInfo #"NRV-E0607"
              (lazyfs/check-cache-bound! (assoc five :lazyfs true) "/opt/nerva"
                                         "/opt/nerva/replica.nerva"))))))
  (testing "the format's size fits"
    (with-redefs [c/exec (fn [& _] "1141374976\n")]
      (binding [c/*host* "n1"]
        (is (nil? (lazyfs/check-cache-bound! (assoc five :lazyfs true) "/opt/nerva"
                                             "/opt/nerva/replica.nerva")))))))

(deftest lost-bytes-and-unread-usage-are-reported
  (let [r (check-recover (history (pair :lose-unfsynced-writes
                                        {:killed ["n1" "n2"], :unsynced-bytes {"n1" 4096 "n2" 0}
                                         :remaining {"n1" 0 "n2" 0}
                                         :sentinel {"n1" :truncated "n2" :truncated}
                                         :cache-usage {"n1" nil "n2" 3.5}})
                                  (recover-pair {})))]
    (is (true? (:valid? r)))
    (is (= [:unsynced-bytes-lost] (:warnings r)))
    (is (= 1 (:cache-usage-unread r))))
  (is (nil? (:warnings (check-recover (history (pair :lose-unfsynced-writes
                                                     {:killed ["n1"], :unsynced-bytes {"n1" 0}
                                                      :remaining {"n1" 0}
                                                      :sentinel {"n1" :truncated}
                                                      :cache-usage {"n1" 3.5}})
                                               (recover-pair {})))))))

(deftest the-checker-reports-each-fault-scope
  (let [r (check-recover (history (pair :lose-unfsynced-writes
                                        {:scope :all, :killed ["n1"], :unsynced-bytes {"n1" 0}
                                         :remaining {"n1" 0}, :sentinel {"n1" :gone}})
                                  (recover-pair {})
                                  (pair :lose-unfsynced-writes
                                        {:scope :minority, :killed ["n1"]
                                         :unsynced-bytes {"n1" 0}, :remaining {"n1" 0}
                                         :sentinel {"n1" :gone}})
                                  (recover-pair {})))]
    (is (= {:all 1, :minority 1} (:scopes r)))))

(deftest keyed-workloads-keep-two-gateways-under-the-fault
  ;; P242j: LazyFS on a minority of nodes leaves the memory for them again.
  (is (= 2 (core/default-gateways {:workload :bank, :nemesis #{lazyfs/fault}})))
  (is (= 2 (core/default-gateways {:workload :retry, :nemesis [:kill lazyfs/fault]})))
  (is (= 1 (core/default-gateways {:workload :bank, :keyed false, :nemesis #{lazyfs/fault}}))))

(deftest lazyfs-is-on-a-minority-unless-all-nodes
  (let [t (assoc five :lazyfs true)]
    (is (= ["n1" "n2"] (lazyfs/lazyfs-nodes t)))
    (is (= (:nodes five) (lazyfs/lazyfs-nodes (assoc t :lazyfs-all-nodes true))))
    (is (= ["a"] (lazyfs/lazyfs-nodes {:nodes ["a" "b" "c"]})))
    (is (lazyfs/mounted? t "n2"))
    (is (not (lazyfs/mounted? t "n3")))
    (is (lazyfs/mounted? (assoc t :lazyfs-all-nodes true) "n5"))
    (is (not (lazyfs/mounted? five "n1")) "never without the fault"))
  (testing "a minority fault only takes nodes that have a mount"
    (is (every? #{"n1" "n2"}
                (mapcat :nodes (repeatedly 200 #(lazyfs/fault-value (assoc five :lazyfs true))))))
    (is (= (set (:nodes five))
           (set (mapcat :nodes (filter #(= :minority (:scope %))
                                       (repeatedly 300 #(lazyfs/fault-value
                                                          (assoc five :lazyfs true
                                                                 :lazyfs-all-nodes true))))))))))

(deftest paths-follow-the-node-that-has-a-mount
  (let [t (assoc five :lazyfs true)]
    (binding [c/*host* "n1"]
      (is (= "/opt/nerva/data/replica.nerva" (lazyfs/data-file t "/opt/nerva" "/x")))
      (is (= "/opt/nerva/data.lazyfs/data/replica.nerva" (lazyfs/format-file t "/opt/nerva" "/x"))))
    (binding [c/*host* "n4"]
      (is (= "/x" (lazyfs/data-file t "/opt/nerva" "/x")))
      (is (= "/x" (lazyfs/format-file t "/opt/nerva" "/x")))
      (with-redefs [c/exec (fn [& _] (throw (ex-info "no command" {})))]
        (is (nil? (lazyfs/check-cache-bound! t "/opt/nerva" "/x")))))))

(deftest all-nodes-is-refused-on-a-small-host
  (let [meminfo (fn mi ([kib] (mi kib kib))
                    ([kib avail]
                     (str "MemTotal:       " kib " kB\nMemFree:        123 kB\nMemAvailable:   " avail " kB\n")))
        t       {:lazyfs-all-nodes true}]
    (is (= 16358920 (lazyfs/mem-total-kib (meminfo 16358920))))
    (is (nil? (lazyfs/mem-total-kib "nothing")))
    (testing "a 16 GB runner is refused, with NRV-E0607"
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #"NRV-E0607.*16 GB runner"
            (lazyfs/check-host-memory! t (meminfo 16358920)))))
    (testing "unreadable memory is refused too"
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #"NRV-E0607.*unreadable"
            (lazyfs/check-host-memory! t nil)))
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #"unreadable /proc/meminfo: Invalid argument"
            (lazyfs/check-host-memory! t nil "Invalid argument"))
          "the cause is named"))
    (testing "a missing field is named, not called unreadable"
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #"no MemAvailable[^a-z]"
            (lazyfs/check-host-memory! t "MemTotal: 65536000 kB\n")))
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #"no MemTotal or MemAvailable"
            (lazyfs/check-host-memory! t "Other: 1 kB\n"))))
    (testing "read-meminfo reads this host's procfs, or returns the cause"
      (let [[text cause] (lazyfs/read-meminfo)]
        (is (or (some? text) (string? cause)))
        (when text (is (some? (lazyfs/mem-total-kib text))))))
    (testing "a big host with little available (the fleet still running) is refused"
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #"NRV-E0607.*available"
            (lazyfs/check-host-memory! t (meminfo 65536000 4000000))))
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #"NRV-E0607"
            (lazyfs/check-host-memory! t "MemTotal: 65536000 kB\n"))
          "a missing MemAvailable is unreadable"))
    (testing "the 64 GB host passes, and so does a test without the option"
      (is (nil? (lazyfs/check-host-memory! t (meminfo 65536000))))
      (is (nil? (lazyfs/check-host-memory! {} (meminfo 16358920)))))
    (testing "core refuses before building anything"
      (is (thrown-with-msg? clojure.lang.ExceptionInfo #"NRV-E0607"
            (with-redefs [lazyfs/read-meminfo (fn [] [(meminfo 16358920) nil])]
              (core/nerva-test {:workload :bank, :nemesis [lazyfs/fault], :lazyfs-all-nodes true}))))
      (testing "test-all too: the refusal comes out of `all-tests` once realised"
        (is (thrown-with-msg? clojure.lang.ExceptionInfo #"NRV-E0607"
              (with-redefs [lazyfs/read-meminfo (fn [] [(meminfo 16358920) nil])]
                (doall (core/all-tests {:lazyfs-all-nodes true})))))))))

(deftest a-memory-refusal-is-marked-for-main
  ;; `core/refusing` (`refusing-test`, `refusing-all-tests`) turns a `:refusal` ex-info into one stderr line and exit 2 (it exits the
  ;; JVM, so only the mark is tested here).
  (let [e (try (lazyfs/check-host-memory! {:lazyfs-all-nodes true} "MemTotal: 1 kB\n")
               nil
               (catch clojure.lang.ExceptionInfo e e))]
    (is (true? (:refusal (ex-data e))))
    (is (not (re-find #"\n" (.getMessage e))) "one line")))

(deftest strict-sync-fails-the-run-on-unsynced-bytes
  (let [h (history (pair :lose-unfsynced-writes
                         {:killed ["n1"], :unsynced-bytes {"n1" 4096}
                          :remaining {"n1" 0}, :sentinel {"n1" :gone}
                          :cache-usage {"n1" 3.5}})
                   (recover-pair {}))
        r (check-recover {:lazyfs true, :lazyfs-strict-sync true} h)]
    (is (false? (:valid? r)))
    (is (= [:unsynced-bytes-lost] (:warnings r)))
    (is (re-find #"lazyfs-strict-sync" (:reason r)))
    (is (= "NRV-E0608" (:code r)) "a finding about the node, not a harness code")
    (testing "a harness problem beside it keeps the strict verdict, reason and code (P242j)"
      (let [r (check-recover
                {:lazyfs true, :lazyfs-strict-sync true}
                (history (pair :lose-unfsynced-writes
                               {:killed ["n1"], :unsynced-bytes {"n1" 4096}
                                :remaining {"n1" 0}, :sentinel {"n1" :survived}
                                :cache-usage {"n1" 3.5}})
                         (recover-pair {})))]
        (is (false? (:valid? r)))
        (is (some #{:sentinel-survived} (:problems r)))
        (is (= "NRV-E0608" (:code r)))
        (is (re-find #"lazyfs-strict-sync" (:reason r)))
        (is (re-find #"did not bite" (:harness-reason r)))))
    (testing "without the option it stays a warning"
      (is (true? (:valid? (check-recover {:lazyfs true} h)))))
    (testing "with the option and nothing lost it is valid"
      (is (true? (:valid? (check-recover
                            {:lazyfs true, :lazyfs-strict-sync true}
                            (history (pair :lose-unfsynced-writes
                                           {:killed ["n1"], :unsynced-bytes {"n1" 0}
                                            :remaining {"n1" 0}, :sentinel {"n1" :gone}
                                            :cache-usage {"n1" 3.5}})
                                     (recover-pair {})))))))))

(def id1 (apply str (repeat 64 "a")))
(def id2 (apply str (repeat 64 "b")))

(defn- kill-line
  "The kernel's `oom-kill:` line for a LazyFS in container `id`, at time `t`."
  [t id]
  (str "[ " t " ] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),cpuset=/,mems_allowed=0,"
       "global_oom,task_memcg=/docker/" id ",task=lazyfs,pid=" (long (* 10 t)) ",uid=0"))

(defn- oom-text [id & lines] (str/join "\n" (cons (str "NRV-ID:" id) lines)))

(deftest an-oom-kill-of-lazyfs-is-read-from-the-kernel-log-for-this-container
  (let [mine  (kill-line 4012 id1)
        other (kill-line 4013 id2)
        java  (str/replace mine "task=lazyfs" "task=java")]
    (is (= #{mine} (lazyfs/oom-kill-lines (oom-text id1 mine other java "noise")))
        "this container's kill only: not another node's, another process's or noise")
    (is (= #{} (lazyfs/oom-kill-lines (oom-text id1 "[ 1.0] docker0: entered disabled state"))))
    (is (nil? (lazyfs/oom-kill-lines nil)) "an unreadable log is not empty")
    (is (nil? (lazyfs/oom-kill-lines "")) "no container id: no claim")
    (is (nil? (lazyfs/oom-kill-lines (str mine "\n"))) "no container id line: no claim"))
  (testing "evidence needs a new line, a readable log and a process seen gone"
    (let [old #{(kill-line 1 id1)}, new (conj old (kill-line 2 id1))]
      (is (true? (lazyfs/oom-evidence? old new false)))
      (is (false? (lazyfs/oom-evidence? old old false)) "an old kill (an earlier run) is not this one's")
      (is (false? (lazyfs/oom-evidence? old new true)) "the process is up")
      (is (false? (lazyfs/oom-evidence? old new nil)) "could not ask whether it is up: no claim")
      (is (false? (lazyfs/oom-evidence? nil new false)) "no baseline: no claim")
      (is (false? (lazyfs/oom-evidence? old nil false)) "the log is unreadable now")
      (testing "the ring buffer rotating: counts going down hide nothing and invent nothing"
        (let [base #{(kill-line 1 id1) (kill-line 2 id1) (kill-line 3 id1)}]
          (is (true? (lazyfs/oom-evidence? base #{(kill-line 3 id1) (kill-line 9 id1)} false))
              "two old lines rotated out, one new one arrived: a count would say 2 < 3")
          (is (false? (lazyfs/oom-evidence? base #{(kill-line 3 id1)} false))
              "old lines rotating out are not a kill"))))))

(deftest oom-nodes-are-those-with-a-new-kill-and-no-process
  (let [old     #{(kill-line 1 id1)}
        lines   (atom {"n1" old, "n2" old})
        running (atom {"n1" false, "n2" false})]
    (with-redefs [c/on-nodes (fn [_ nodes g]
                               (into {} (for [n nodes] [n (binding [c/*host* n] (g {} n))])))
                  lazyfs/oom-kills (fn [] (get @lines c/*host*))
                  lazyfs/lazyfs-running? (fn [] (get @running c/*host*))]
      (let [base {"n1" old, "n2" old}]
        (is (= [] (lazyfs/oom-killed-nodes {} base ["n1" "n2"])) "nothing new")
        (swap! lines update "n1" conj (kill-line 2 id1))
        (is (= ["n1"] (lazyfs/oom-killed-nodes {} base ["n1" "n2"]))
            "n2's LazyFS died too, but no line names it: not claimed")
        (swap! lines update "n2" conj (kill-line 2 id2))
        (swap! running assoc "n2" true)
        (is (= ["n1"] (lazyfs/oom-killed-nodes {} base ["n1" "n2"])) "the process is up")
        (swap! running assoc "n2" nil)
        (is (= ["n1"] (lazyfs/oom-killed-nodes {} base ["n1" "n2"])) "unknown whether it is up")
        (is (= [] (lazyfs/oom-killed-nodes {} {"n2" old} ["n1"])) "no baseline: not claimed"))
      (testing "one node's ssh failing does not drop another's evidence"
        (swap! running assoc "n2" false)
        (with-redefs [lazyfs/oom-kills (fn []
                                         (if (= "n2" c/*host*)
                                           (throw (ex-info "ssh" {}))
                                           (get @lines c/*host*)))]
          (is (= ["n1"] (lazyfs/oom-killed-nodes {} {"n1" old, "n2" old} ["n1" "n2"])))
          (swap! lines assoc "n1" old)
          (is (= {"n1" old} (lazyfs/oom-baselines (assoc five :lazyfs true)))
              "a baseline survives another node's failure")))
      (testing "an interrupt is not swallowed"
        (with-redefs [c/on-nodes (fn [& _] (throw (InterruptedException.)))]
          (is (thrown? InterruptedException
                       (lazyfs/oom-killed-nodes {} {"n1" old} ["n1"]))))))))

(defn- oom-fault [& nodes]
  (pair :lose-unfsynced-writes
        {:killed (vec nodes), :unsynced-bytes (zipmap nodes (repeat nil)), :remaining (zipmap nodes (repeat nil))
         :sentinel (zipmap nodes (repeat :unchecked)), :cache-usage (zipmap nodes (repeat nil))
         :oom-killed (vec nodes)}))

(deftest a-lazyfs-oom-kill-is-nrv-e0611-on-its-own-node-only
  (let [r (check-recover {:lazyfs true} (history (oom-fault "n1") (recover-pair {})))]
    (is (= :unknown (:valid? r)))
    (is (= "NRV-E0611" (:code r)))
    (is (= ["n1"] (:oom-killed r)))
    (is (re-find #"memory killed LazyFS on n1" (:reason r))))
  (testing "its own node's replica left down is the kill's: NRV-E0611, not NRV-E0604"
    (let [r (check-recover {:lazyfs true}
                           (history (oom-fault "n1")
                                    (recover-pair {:replica-down ["n1"] :oom-killed ["n1"]})))]
      (is (= "NRV-E0611" (:code r)))
      (is (= :unknown (:valid? r)))))
  (testing "its own node's gateway left down or pending is still NRV-E0604: it does not use the mount"
    (doseq [k [:down :pending]]
      (let [r (check-recover {:lazyfs true}
                             (history (oom-fault "n1")
                                      (recover-pair {:replica-down ["n1"] k [["n1" 0]]
                                                     :oom-killed ["n1"]})))]
        (is (false? (:valid? r)))
        (is (= "NRV-E0604" (:code r)))
        (is (= [["n1" 0]] (:gateways r)))
        (is (= [] (:replica-down r)))
        (is (= ["n1"] (:oom-killed r))))))
  (testing "another node's replica left down is still NRV-E0604, and the verdict is false"
    (let [r (check-recover {:lazyfs true}
                           (history (oom-fault "n1")
                                    (recover-pair {:replica-down ["n3"] :down [["n3" 0]]
                                                   :oom-killed ["n1"]})))]
      (is (false? (:valid? r)))
      (is (= "NRV-E0604" (:code r)))
      (is (= ["n3"] (:replica-down r)))
      (is (= [["n3" 0]] (:gateways r)))
      (is (= ["n1"] (:oom-killed r)))
      (is (some? (:oom-reason r)) "the kill stays as context")))
  (testing "both nodes' replicas down: only the other node's is reported"
    (let [r (check-recover {:lazyfs true}
                           (history (oom-fault "n1")
                                    (recover-pair {:replica-down ["n1" "n3"]
                                                   :oom-killed ["n1"]})))]
      (is (= ["n3"] (:replica-down r)))
      (is (= [] (:gateways r)))))
  (testing "another node's sentinel-survived reason is kept beside the kill's"
    (let [r (check-recover {:lazyfs true}
                           (history (pair :lose-unfsynced-writes
                                          {:killed ["n1" "n2"]
                                           :unsynced-bytes {"n1" nil "n2" 4096}
                                           :remaining {"n1" nil "n2" 0}
                                           :sentinel {"n1" :unchecked "n2" :survived}
                                           :cache-usage {"n1" nil "n2" nil}
                                           :oom-killed ["n1"]})
                                    (recover-pair {})))]
      (is (= "NRV-E0611" (:code r)))
      (is (re-find #"memory killed LazyFS on n1" (:reason r)))
      (is (re-find #"did not bite" (:harness-reason r)))))
  (testing "a final recovery that threw has no node: never excused"
    (let [r (check-recover {:lazyfs true}
                           (history (oom-fault "n1")
                                    (recover-pair {:oom-killed ["n1"]} :exception {:cause "boom"})))]
      (is (false? (:valid? r)))
      (is (= "NRV-E0604" (:code r)))))
  (testing "found only by the final recovery"
    (let [r (check-recover {:lazyfs true}
                           (history (fault-pair) (recover-pair {:oom-killed ["n1"]})))]
      (is (= "NRV-E0611" (:code r))))))

(deftest an-oom-kill-never-outranks-lost-bytes
  (let [h (history (pair :lose-unfsynced-writes
                         {:killed ["n3"], :unsynced-bytes {"n3" 8192}
                          :remaining {"n3" 0}, :sentinel {"n3" :gone}
                          :oom-killed []})
                   (recover-pair {:oom-killed ["n1"]}))
        r (check-recover {:lazyfs true, :lazyfs-strict-sync true} h)]
    (is (false? (:valid? r)))
    (is (= "NRV-E0608" (:code r)))
    (is (= 8192 (:lost-bytes r)))
    (is (= ["n1"] (:oom-killed r)))
    (is (some? (:oom-reason r))))
  (testing "without strict sync the lost bytes are a warning and the kill is NRV-E0611"
    (let [r (check-recover {:lazyfs true}
                           (history (pair :lose-unfsynced-writes
                                          {:killed ["n3"], :unsynced-bytes {"n3" 8192}
                                           :remaining {"n3" 0}, :sentinel {"n3" :gone}})
                                    (recover-pair {:oom-killed ["n1"]})))]
      (is (= "NRV-E0611" (:code r))))))

(deftest without-oom-evidence-strict-sync-is-still-nrv-e0608
  (let [r (check-recover {:lazyfs true, :lazyfs-strict-sync true}
                         (history (pair :lose-unfsynced-writes
                                        {:killed ["n1"], :unsynced-bytes {"n1" 4096}
                                         :remaining {"n1" 0}, :sentinel {"n1" :gone}
                                         :oom-killed []})
                                  (recover-pair {:oom-killed []})))]
    (is (false? (:valid? r)))
    (is (= "NRV-E0608" (:code r)))
    (is (nil? (:oom-killed r)))))

(defn- stub-recover [_ nodes _ _ _]
  {:nodes (vec nodes), :judged (vec nodes), :down [], :pending [], :replica-down [], :unsettled []})

(deftest the-nemesis-records-the-oom-nodes
  (let [nemesis (lazyfs/nemesis "/opt/nerva" nil)
        probed  (atom [])]
    (with-redefs [lazyfs/oom-baselines   (fn [_] {"n1" #{}})
                  lazyfs/oom-killed-nodes (fn [_ b nodes] (swap! probed conj (vec nodes))
                                            (vec (filter b nodes)))
                  lazyfs/lazyfs-nodes    (fn [_] ["n1" "n2" "n3" "n4" "n5"])
                  lazyfs/kill!    (fn [_ nodes] (vec nodes))
                  lazyfs/lose!    (fn [_ _ nodes] (zipmap nodes (repeat {:before nil, :after nil})))
                  lazyfs/recover! stub-recover]
      (let [n    (n/setup! nemesis five)
            done (n/invoke! n five {:type :info, :f :lose-unfsynced-writes
                                    :value {:scope :minority, :nodes ["n1" "n2"]}})]
        (is (= ["n1"] (:oom-killed (:value done))))
        (is (= ["n1"] (:oom-killed (:value (n/invoke! n five {:type :info, :f :lazyfs-recover
                                                              :value {:final? true}})))))
        (is (= ["n1" "n2" "n3" "n4" "n5"] (last @probed))
            "the final recovery probes every mounted node, not only the ones the fault hit")))))

(deftest a-dead-lazyfs-that-makes-the-fault-throw-is-still-seen
  (let [nemesis (lazyfs/nemesis "/opt/nerva" nil)]
    (with-redefs [lazyfs/oom-baselines   (fn [_] {"n1" #{}})
                  ;; The kill is seen at the fault (the process is gone), not at the recovery
                  ;; (which restarted it).
                  lazyfs/oom-killed-nodes (let [calls (atom 0)]
                                            (fn [_ b nodes]
                                              (if (< (swap! calls inc) 2)
                                                (vec (filter b nodes))
                                                [])))
                  lazyfs/lazyfs-nodes    (fn [_] ["n1"])
                  lazyfs/kill!    (fn [_ nodes] (vec nodes))
                  lazyfs/lose!    (fn [& _] (throw (ex-info "fifo timeout" {})))
                  lazyfs/recover! stub-recover]
      (let [n (n/setup! nemesis five)]
        (is (thrown? clojure.lang.ExceptionInfo
                     (n/invoke! n five {:type :info, :f :lose-unfsynced-writes
                                        :value {:scope :minority, :nodes ["n1"]}})))
        (is (= ["n1"] (:oom-killed (:value (n/invoke! n five {:type :info, :f :lazyfs-recover
                                                              :value {:final? true}})))))))))

(deftest a-final-recovery-that-throws-after-an-oom-keeps-the-evidence
  (let [nemesis (lazyfs/nemesis "/opt/nerva" nil)]
    (with-redefs [lazyfs/oom-baselines   (fn [_] {"n1" #{}})
                  lazyfs/oom-killed-nodes (fn [_ b nodes] (vec (filter b nodes)))
                  lazyfs/lazyfs-nodes    (fn [_] ["n1"])
                  lazyfs/recover! (fn [& _] (throw (ex-info "boom" {})))]
      (let [n    (n/setup! nemesis five)
            done (n/invoke! n five {:type :info, :f :lazyfs-recover :value {:final? true}})]
        (is (= ["n1"] (:oom-killed (:value done))))
        (is (= "boom" (:cause (:exception done)))))
      (with-redefs [lazyfs/oom-killed-nodes (fn [& _] [])]
        (is (thrown? clojure.lang.ExceptionInfo
                     (n/invoke! (n/setup! (lazyfs/nemesis "/opt/nerva" nil) five) five
                                {:type :info, :f :lazyfs-recover :value {:final? true}}))
            "without evidence the throw propagates as before")))))

(deftest lazyfs-running-answers-gone-only-on-exit-1
  (let [ask (fn [out] (with-redefs [c/exec (fn [& _] out)] (lazyfs/lazyfs-running?)))]
    (is (true? (ask "up\n")))
    (is (false? (ask "gone\n")))
    (is (nil? (ask "unknown\n")) "a timed-out or failed pgrep claims nothing")
    (is (nil? (ask "")))
    (is (nil? (with-redefs [c/exec (fn [& _] (throw (ex-info "x" {})))] (lazyfs/lazyfs-running?))))))
