(ns jepsen.nerva.lazyfs-test
  "The lose-unfsynced-writes fault's shapes: what it draws, the order it acts in, what its undo
  starts, and that it composes with the other packages."
  (:require [clojure.test :refer [deftest is testing]]
            [jepsen.checker :as checker]
            [jepsen.generator :as gen]
            [jepsen.generator.context :as ctx]
            [jepsen.nemesis :as n]
            [jepsen.nerva.core :as core]
            [jepsen.nerva.db :as db]
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

(deftest acts-in-order-and-recovers-what-it-killed
  (let [calls   (atom [])
        nemesis (lazyfs/nemesis "/opt/nerva" nil)]
    (with-redefs [lazyfs/kill!    (fn [_ nodes] (swap! calls conj [:kill nodes]) (vec nodes))
                  lazyfs/lose!    (fn [_ _ nodes] (swap! calls conj [:lose nodes])
                                    (zipmap nodes (repeat 4096)))
                  lazyfs/recover! (fn [_ nodes _] (swap! calls conj [:recover nodes])
                                    {:nodes (vec nodes), :down [], :pending []})]
      (let [done (n/invoke! nemesis five
                            {:type :info, :f :lose-unfsynced-writes
                             :value {:scope :all, :crash ["n4" "n1" "n5"], :nodes (:nodes five)}})]
        (is (= ["n4" "n1" "n5" "n2" "n3"] (:killed (:value done))))
        (is (= {"n1" 4096, "n2" 4096, "n3" 4096, "n4" 4096, "n5" 4096}
               (:unsynced-bytes (:value done)))))
      (is (= [[:kill ["n4" "n1" "n5"]]
              [:kill ["n2" "n3"]]
              [:lose ["n1" "n2" "n3" "n4" "n5"]]]
             @calls)
          "the quorum dies first, then the rest, and only then is the cache cleared")
      (let [done (n/invoke! nemesis five {:type :info, :f :lazyfs-recover})]
        (is (= ["n1" "n2" "n3" "n4" "n5"] (:started (:value done)))))
      (is (= [:recover ["n1" "n2" "n3" "n4" "n5"]] (last @calls)))
      (n/invoke! nemesis five {:type :info, :f :lazyfs-recover})
      (is (= [:recover []] (last @calls)) "nothing is pending the second time")
      (n/invoke! nemesis five {:type :info, :f :lose-unfsynced-writes
                               :value {:scope :minority, :nodes ["n2"]}})
      (is (= [:lose ["n2"]] (last @calls)))
      (let [done (n/invoke! nemesis five {:type :info, :f :lazyfs-recover})]
        (is (= ["n2"] (:started (:value done))))))))

(deftest recover-reports-the-gateways-it-left-down
  (let [nemesis (lazyfs/nemesis "/opt/nerva" nil)]
    (with-redefs [lazyfs/recover! (fn [_ nodes _] {:nodes nodes, :down [["n2" 1]], :pending [["n3" 0]]})]
      (let [done (n/invoke! nemesis five {:type :info, :f :lazyfs-recover})]
        (is (= [["n2" 1]] (:down (:value done))))
        (is (= [["n3" 0]] (:pending (:value done))))))))

(defn- check-recover [history]
  (checker/check (lazyfs/recover-checker) {} history {}))

(defn- recover-op [& {:as extra}]
  (merge {:type :info, :f :lazyfs-recover, :process :nemesis
          :value {:started ["n1"], :down [], :pending []}}
         extra))

(deftest recover-checker
  (testing "a LazyFS-only history with every gateway up passes"
    (let [r (check-recover [(recover-op)])]
      (is (true? (:valid? r)))
      (is (= 1 (:recovers r)))))
  (testing "no recover at all is valid, with nothing judged"
    (is (= 0 (:recovers (check-recover [])))))
  (testing "a gateway left down fails with NRV-E0604"
    (let [r (check-recover [(recover-op :value {:started ["n2"] :down [["n2" 1]] :pending []})])]
      (is (false? (:valid? r)))
      (is (= "NRV-E0604" (:code r)))
      (is (= [["n2" 1]] (:gateways r)))))
  (testing "a gateway left pending, or an exception, fails"
    (is (false? (:valid? (check-recover [(recover-op :value {:pending [["n3" 0]]})]))))
    (is (false? (:valid? (check-recover [(recover-op :exception {:cause "boom"})]))))))

(deftest data-file-follows-the-fault
  (is (= "/opt/nerva/data/replica.nerva" (lazyfs/data-file {:lazyfs true} "/opt/nerva" "/x")))
  (is (= "/x" (lazyfs/data-file {} "/opt/nerva" "/x")))
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
