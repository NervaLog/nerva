(ns jepsen.nerva.nemesis-test
  "The gateway nemesis's shapes: which faults a spec asks for, what the generator emits and
  what the final generator undoes."
  (:require [clojure.test :refer [deftest is testing]]
            [jepsen.generator :as gen]
            [jepsen.generator.context :as ctx]
            [jepsen.nemesis :as n]
            [jepsen.nemesis.combined :as combined]
            [jepsen.nerva.core :as core]
            [jepsen.nerva.db :as db]
            [jepsen.nerva.nemesis :as nemesis]))

(def test-map {:nodes ["n1" "n2" "n3"], :concurrency 1})

(defn emitted
  "The first `limit` ops a generator hands the nemesis thread."
  [generator limit]
  (let [context (ctx/context test-map)]
    (loop [g generator, ops [], context context]
      (if (= limit (count ops))
        ops
        (let [[o g'] (gen/op g test-map context)]
          (cond (nil? o) ops
                (= :pending o) ops
                :else (let [o (assoc o :process :nemesis)]
                        (recur (gen/update g' test-map context o)
                               (conj ops o)
                               (ctx/busy-thread context (:time o) :nemesis)))))))))

(defn package [& fault-keys]
  (nemesis/package {:db nil, :faults (set fault-keys), :interval 0}))

(deftest enabled-faults
  (is (= nemesis/faults (nemesis/enabled #{:gateway})))
  (is (= #{:gateway-pause} (nemesis/enabled #{:gateway-pause :kill})))
  (is (= #{} (nemesis/enabled #{:kill :partition}))))

(deftest no-gateway-fault-no-generator
  (let [p (package :kill :partition)]
    (is (nil? (:generator p)))
    (is (nil? (:final-generator p)))
    (is (empty? (:perf p)))))

(deftest gateway-covers-all-three
  (let [p (package :gateway)]
    (is (= #{"gateway-kill" "gateway-partition" "gateway-pause"} (set (map :name (:perf p)))))
    (is (= [:gateway-resume :gateway-heal :gateway-start] (map :f (:final-generator p))))
    (is (every? #(= {:nodes :all, :gateway :all} (:value %)) (:final-generator p)))))

(deftest one-fault-only
  (let [p (package :gateway-partition)]
    (is (= ["gateway-partition"] (map :name (:perf p))))
    (is (= [:gateway-heal] (map :f (:final-generator p))))))

(deftest generator-shape
  (testing "each fault is followed by its undo on everything"
    (let [ops (->> (emitted (:generator (package :gateway-kill)) 6))]
      (is (= 6 (count ops)))
      (is (= [:gateway-kill :gateway-start :gateway-kill :gateway-start :gateway-kill
              :gateway-start]
             (map :f ops)))
      (doseq [o ops :when (= :gateway-kill (:f o))]
        (is (contains? (set nemesis/targets) (:nodes (:value o))))
        (is (contains? (set nemesis/gateway-choices) (:gateway (:value o)))))
      (doseq [o ops :when (= :gateway-start (:f o))]
        (is (= {:nodes :all, :gateway :all} (:value o))))))
  (testing "a mix of all three emits every kind"
    (let [fs (set (map :f (emitted (:generator (package :gateway)) 200)))]
      (is (every? fs [:gateway-kill :gateway-partition :gateway-pause])))))

(deftest nemesis-fs-are-distinct
  (let [gw (set (n/fs (nemesis/nemesis nil)))
        others (into #{:start :kill :pause :resume :start-partition :stop-partition} [])]
    (is (= 6 (count gw)))
    (is (empty? (clojure.set/intersection gw others)))))

(deftest core-takes-the-faults
  (is (every? core/faults [:gateway :gateway-kill :gateway-partition :gateway-pause]))
  (is (some #{[:gateway]} core/all-nemeses))
  (is (some #{[:kill :partition :gateway]} core/all-nemeses)))

(deftest backoff-is-bounded
  (is (= [500 1000 2000 4000 4000 4000] (map db/gateway-backoff-ms (range 1 7))))
  (is (<= (apply + (map db/gateway-backoff-ms (range 1 db/gateway-start-tries)))
          30000)))

(deftest gateway-rule-names-the-gateway-user
  (is (re-find #"--uid-owner nerva-gw1 .*--dport 3000 -j DROP" (db/gateway-rule 1)))
  (is (not= (db/gateway-rule 0) (db/gateway-rule 1))))
