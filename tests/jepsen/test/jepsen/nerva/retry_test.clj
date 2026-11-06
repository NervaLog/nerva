(ns jepsen.nerva.retry-test
  "The retry checker against hand-written histories: a clean one passes, and each anomaly the
  workload exists to find fails it."
  (:require [clojure.test :refer [deftest is testing]]
            [jepsen.nerva.retry :as retry]))

(defn answered
  "An attempt answered by a 200 at op."
  ([op] (answered op {}))
  ([op more] (merge {:kind :committed, :op op, :gateway "n1:8080"} more)))

(def refused {:kind :refused, :http 503, :code "NRV-E0605", :gateway "n1:8080"})
(def lost {:kind :unknown, :error "java.net.http.HttpTimeoutException", :gateway "n1:8081"})

(defn pay
  "A completed :pay operation."
  [type key account amount attempts]
  {:f :pay, :type type, :value {:key key, :account account, :amount amount}, :attempts attempts})

(defn resolve-op
  [& entries]
  {:f :resolve, :type :ok, :resolved (vec entries)})

(defn entry
  [key account amount attempts]
  {:key key, :account account, :amount amount, :attempts attempts})

(defn final-read
  "A final read: every account at `balances` (default 0), and the source."
  ([balances source]
   {:f :read, :type :ok,
    :value (merge (zipmap retry/account-rows (repeat 0)) balances), :source source}))

(defn clean
  "k1 paid 10 into account 1 and answered at once; k2 paid 5 into account 2, its reply lost and
  its resend replayed; k3 paid 7 into account 1, refused, then committed by the final phase."
  []
  [(pay :ok "k1" 1 10 [(answered 10)])
   (pay :ok "k2" 2 5 [(answered 11 {:dropped? true}) (answered 11 {:replayed? true})])
   (pay :fail "k3" 1 7 [refused refused])
   (resolve-op (entry "k3" 1 7 [(answered 14)]))
   (final-read {1 17, 2 5} -22)])

(defn valid? [history] (:valid? (retry/analyze history)))

(deftest a-clean-history-passes
  (let [result (retry/analyze (clean))]
    (is (true? (:valid? result)))
    (is (= 3 (:committed result)))
    (is (= 1 (:replayed result)))
    (is (= 1 (:dropped result)))))

(deftest a-key-committed-at-two-ops-is-a-duplicate
  (let [history (-> (clean)
                    (assoc 1 (pay :ok "k2" 2 5 [(answered 11 {:dropped? true})
                                                (answered 15)]))
                    (assoc 4 (final-read {1 17, 2 10} -27)))
        result  (retry/analyze history)]
    (is (false? (:valid? result)))
    (is (= [{:key "k2", :ops [11 15]}] (get-in result [:duplicate :examples])))
    (is (= 2 (get-in result [:balance :count]))
        "the second commit also moved the account and the source, but the key counts once")))

(deftest a-duplicate-is-seen-across-the-final-phase
  (let [history (conj (vec (butlast (clean)))
                      (resolve-op (entry "k1" 1 10 [(answered 20)]))
                      (final-read {1 27, 2 5} -32))
        result  (retry/analyze history)]
    (is (false? (:valid? result)))
    (is (= [{:key "k1", :ops [10 20]}] (get-in result [:duplicate :examples])))))

(deftest a-balance-one-pay-in-too-high-fails
  (let [history (assoc (clean) 4 (final-read {1 17, 2 10} -22))
        result  (retry/analyze history)]
    (is (false? (:valid? result)))
    (is (= [{:account 2, :actual 10, :expected 5, :at-most 5, :op nil}]
           (get-in result [:balance :examples])))
    (is (zero? (get-in result [:duplicate :count])) "no key was answered twice"))
  (testing "or too low"
    (is (false? (valid? (assoc (clean) 4 (final-read {1 10, 2 5} -22)))))))

(deftest a-source-that-does-not-balance-fails
  (is (false? (valid? (assoc (clean) 4 (final-read {1 17, 2 5} -21))))))

(deftest a-replay-after-only-applied-false-is-an-applied-lie
  (let [history (assoc (clean) 2 (pay :fail "k3" 1 7 [refused refused])
                       3 (resolve-op (entry "k3" 1 7 [(answered 14 {:replayed? true})])))
        result  (retry/analyze history)]
    (is (false? (:valid? result)))
    (is (= [{:key "k3", :refused-before 2, :op 14}] (get-in result [:applied-lie :examples]))))
  (testing "a replay after a lost reply is no lie"
    (is (true? (valid? (assoc (clean) 2 (pay :info "k3" 1 7 [refused lost])
                              3 (resolve-op (entry "k3" 1 7 [(answered 14 {:replayed? true})]))))))))

(deftest a-key-reused-fails
  (let [reused  {:kind :refused, :http 409, :code "NRV-E0207", :status "key_reused", :gateway "n1:8080"}
        history (assoc (clean) 0 (pay :ok "k1" 1 10 [reused (answered 10)]))
        result  (retry/analyze history)]
    (is (false? (:valid? result)))
    (is (= [{:key "k1", :gateway "n1:8080"}] (get-in result [:key-reused :examples])))))

(deftest a-key-collision-fails-naming-its-key
  (let [collision {:kind :refused, :http 409, :code "NRV-E0208", :status "key_collision"}
        history   (assoc (clean) 0 (pay :ok "k1" 1 10 [collision (answered 10)]))
        result    (retry/analyze history)]
    (is (false? (:valid? result)))
    (is (= "k1" (-> result :key-collision :examples first :key)))))

(deftest a-key-no-one-answered-is-unknown-not-invalid
  (let [history (assoc (clean) 3 (resolve-op (entry "k3" 1 7 [lost]))
                       4 (final-read {1 10, 2 5} -15))
        result  (retry/analyze history)]
    (is (= :unknown (:valid? result)))
    (is (= [{:key "k3"}] (get-in result [:unresolved :examples])))
    (testing "its pay-in may or may not be in the balances"
      (is (= :unknown (valid? (assoc history 4 (final-read {1 17, 2 5} -22)))))
      (is (false? (valid? (assoc history 4 (final-read {1 18, 2 5} -23))))))))

(deftest a-history-without-a-final-read-is-unknown
  (is (= :unknown (valid? (butlast (clean))))))

(deftest keys-are-128-bit-hex-and-never-repeat
  (let [keys (repeatedly 200 #(:key (retry/pay-value)))]
    (is (every? #(re-matches #"[0-9a-f]{32}" %) keys))
    (is (= 200 (count (set keys))))))

(deftest a-pay-in-is-a-pair-of-adds-with-no-clamp
  (let [[from to] (retry/pay-entries {:key "k", :account 3, :amount 12})]
    (is (= "-12" (get from "delta")))
    (is (true? (get from "pair")))
    (is (nil? (get from "clamp")))
    (is (= 0 (get to "delta_from")))
    (is (= "3" (get to "id")))))

(deftest the-final-phase-has-one-deadline-for-all-keys
  (let [phase    (atom nil)
        pending  (atom [{:key "a", :account 1, :amount 1}
                        {:key "b", :account 2, :amount 2}
                        {:key "c", :account 3, :amount 3}])
        client   (retry/map->Client {:pending pending, :phase phase})
        test-map {:nodes ["n1"]}
        started  (System/nanoTime)]
    (reset! phase (dec started))
    (let [done (retry/invoke-resolve client test-map {:f :resolve})]
      (is (= :info (:type done)))
      (is (= ["c" "b" "a"] (map :key (:resolved done))))
      (is (every? empty? (map :attempts (:resolved done))))
      (is (< (- (System/nanoTime) started) 1000000000)))
    (testing "the first asker sets the deadline, the rest read it"
      (let [fresh (atom nil)
            first-deadline (retry/phase-deadline! fresh 1000)]
        (is (= first-deadline (retry/phase-deadline! fresh 5)))))))

(deftest a-crash-in-the-attempts-keeps-them-and-the-key
  (let [pending (atom [])
        client  (retry/map->Client {:pending pending, :phase (atom nil), :drop-reply 0,
                                    :attempts 8})
        calls   (atom 0)
        value   {:key "k", :account 1, :amount 5}]
    (with-redefs [retry/attempt! (fn [& _]
                                   (if (= 1 (swap! calls inc))
                                     (answered 7 {:dropped? true})
                                     (throw (ClassCastException. "not an object"))))]
      (let [done (retry/invoke-pay client {:nodes ["n1"]} {:f :pay, :value value})]
        (is (= :info (:type done)))
        (is (= :crashed (:error done)))
        (is (= [7] (map :op (:attempts done))))
        (is (= [value] @pending))))))
