(ns jepsen.nerva.bank-test
  "The bank workload's checkers fail on the histories they exist to catch, and pass a correct
  one; replies parse into the values the checkers read."
  (:require [clojure.test :refer [deftest is testing]]
            [jepsen.checker :as checker]
            [jepsen.client :as client]
            [jepsen.history :as h]
            [jepsen.nerva.bank :as bank]
            [jepsen.tests.bank :as jepsen-bank]
            [jepsen.nerva.http :as http]
            [jepsen.nerva.keyed :as keyed]))

(def test-map
  {:accounts     bank/accounts
   :total-amount bank/total-amount
   :max-transfer bank/max-transfer})

(def funded
  "Balances right after the bootstrap: every row's available funded, nothing held."
  (into {} (for [[_ field :as account] bank/accounts]
             [account (if (= "available" field) bank/funding-per-row 0)])))

(defn history
  "A history of completed operations, each preceded by its invocation."
  [& completions]
  (h/history
    (mapcat (fn [op] [(assoc op :type :invoke, :process 0) (assoc op :process 0)])
            completions)
    {:dense-indices? true, :have-indices? false, :already-ordered? true}))

(defn valid?
  [checker hist]
  (:valid? (checker/check checker test-map hist {})))

(def good-read {:type :ok, :f :read, :value funded, :source (- bank/total-amount)})
(def good-view {:type :ok, :f :view, :value bank/total-amount})
(def good-transfer {:type :ok, :f :transfer
                    :value {:from [1 "available"], :to [1 "held"], :amount 5}})

(deftest a-correct-history-passes
  (let [hist (history good-read good-view good-transfer
                      {:type :fail, :f :transfer, :error :out_of_bounds
                       :value {:from [1 "held"], :to [2 "held"], :amount 30}})]
    (is (valid? (:checker (bank/workload {:keyed false})) hist))))

(deftest lost-or-created-value-fails
  (testing "a read that totals less than was funded"
    (is (not (valid? (jepsen-bank/checker {:negative-balances? false})
                     (history (assoc-in good-read [:value [2 "held"]] -1))))))
  (testing "a field below its floor, even with the right total"
    (is (not (valid? (:checker (bank/workload {:keyed false}))
                     (history (-> good-read
                                  (assoc-in [:value [1 "available"]] -5)
                                  (assoc-in [:value [1 "held"]] 5))))))))

(deftest a-missing-row-fails
  (is (not (valid? (:checker (bank/workload {:keyed false}))
                   (history (assoc-in good-read [:value [3 "held"]] nil))))))

(deftest the-source-must-not-move
  (is (not (valid? (bank/source-checker)
                   (history (assoc good-read :source (- 1 bank/total-amount)))))))

(deftest the-view-must-total-what-was-funded
  (is (not (valid? (bank/view-checker)
                   (history (assoc good-view :value (dec bank/total-amount)))))))

(deftest only-out-of-bounds-may-refuse-a-transfer
  (doseq [status [:unpaired :conserved_write :conflict]]
    (is (not (valid? (bank/refusal-checker)
                     (history (assoc good-transfer :type :fail, :error status))))
        (name status)))
  (is (valid? (bank/refusal-checker)
              (history (assoc good-transfer :type :fail
                              :error [:not-sent "java.net.ConnectException" nil])))
      "a transfer never sent was not refused"))

(deftest a-transfer-is-a-pair-of-adds
  (let [[first-half partner] (bank/transfer-entries
                               {:from [2 "held"], :to [3 "available"], :amount 7, :clamp? true})]
    (is (= {"kind" "add", "table" bank/accounts-table, "id" "2", "field" "held",
            "delta" "-7", "pair" true, "clamp" true}
           first-half))
    (is (= {"kind" "add", "table" bank/accounts-table, "id" "3", "field" "available",
            "delta_from" 0}
           partner)))
  (is (not (contains? (first (bank/transfer-entries {:from [1 "held"], :to [2 "held"]
                                                     :amount 1, :clamp? false}))
                      "clamp"))))

(deftest a-lookup-parses-into-balances
  (let [row    (fn [available held] {"exists" true, "op" "9"
                                     "fields" {"available" (str available), "held" (str held)}})
        lookup {"op"   "12"
                "rows" [(row 90 10) (row 100 0) (row 100 0) {"exists" false, "op" "0"}
                        {"exists" true, "op" "5", "fields" {"balance" "-400"}}]}
        {:keys [balances source]} (bank/read-value lookup)]
    (is (= -400 source))
    (is (= 90 (balances [1 "available"])))
    (is (= 10 (balances [1 "held"])))
    (is (nil? (balances [4 "available"])) "an absent row reads as nil, which the checker flags")))

(deftest a-request-never-sent-failed
  (is (= :fail (:type (http/no-reply {:f :transfer} true (java.net.ConnectException. "refused")))))
  (is (= :info (:type (http/no-reply {:f :transfer} true (java.io.IOException. "reset")))))
  (is (= :info (:type (http/no-reply {:f :transfer} true
                                     (java.net.http.HttpTimeoutException. "35 s"))))))

(deftest the-protocol-checker-fails-a-marked-history
  (let [marked (http/violation {:f :transfer} {:status 400, :body nil})]
    (is (not (valid? (http/protocol-checker) (history good-read marked))))
    (is (valid? (http/protocol-checker) (history good-read good-view good-transfer)))))

;; ---------------------------------------------------------------------------------------
;; Keys and records

(defn answered
  "An attempt answered by a 200 at op."
  ([op] (answered op {}))
  ([op more] (merge {:kind :committed, :op op, :gateway "n1:8080"} more)))

(def out-of-bounds {:kind :refused, :http 409, :code "NRV-E0203", :status "out_of_bounds",
                    :gateway "n1:8080"})
(def busy {:kind :refused, :http 503, :code "NRV-E0602", :gateway "n1:8080"})
(def views-busy {:kind :refused, :http 503, :code "NRV-E0211", :status "views_busy",
                 :gateway "n1:8080"})
(def views-too-large {:kind :refused, :http 413, :code "NRV-E0212", :status "views_too_large",
                      :gateway "n1:8080"})
(def lost {:kind :unknown, :error "java.net.http.HttpTimeoutException", :gateway "n1:8081"})

(defn transfer
  "A completed keyed :transfer operation, from [1 \"available\"] to [2 \"held\"]."
  [type key amount attempts]
  {:f :transfer, :type type, :attempts attempts
   :value {:key key, :from [1 "available"], :to [2 "held"], :amount amount, :clamp? false}})

(defn resolve-op
  [& entries]
  {:f :resolve, :type :ok, :resolved (vec entries)})

(defn entry
  [key amount attempts]
  {:key key, :from [1 "available"], :to [2 "held"], :amount amount, :clamp? false,
   :attempts attempts})

(defn record
  "A record as the index serves it: from index 0 ([1 \"available\"]) to 3 ([2 \"held\"])."
  [key amount]
  {:id key, :from 0, :to 3, :amount amount})

(defn records-read
  ([records] (records-read records (count records)))
  ([records n] {:f :records, :type :ok, :value (vec records), :count n}))

(defn clean
  "k1 committed at once; k2's reply was lost and its resend replayed; k3 was refused by Nerva
  (no record); k4 was refused by a busy gateway and committed by the final phase."
  []
  [good-read good-view
   (transfer :ok "k1" 5 [(answered 10)])
   (transfer :ok "k2" 6 [(answered 11 {:dropped? true}) (answered 11 {:replayed? true})])
   (transfer :fail "k3" 30 [out-of-bounds])
   (transfer :fail "k4" 7 [busy busy])
   (resolve-op (entry "k4" 7 [(answered 14)]))
   (records-read [(record "k1" 5) (record "k2" 6) (record "k4" 7)])])

(defn history-of
  "A history of the completed operations given as a vector."
  [ops]
  (apply history ops))

(defn keyed-valid?
  [ops]
  (:valid? (bank/analyze-keys (history-of ops))))

(deftest a-correct-keyed-history-passes
  (let [result (bank/analyze-keys (history-of (clean)))]
    (is (true? (:valid? result)))
    (is (= 3 (:committed result)))
    (is (= 1 (:replayed result)))
    (is (= 3 (:records result))))
  (is (true? (valid? (:checker (bank/workload {})) (history-of (clean))))
      "and so does the whole workload checker"))

(deftest a-missing-record-fails
  (let [ops    (clean)
        ops    (conj (pop ops) (records-read [(record "k1" 5) (record "k4" 7)]))
        result (bank/analyze-keys (history-of ops))]
    (is (false? (:valid? result)))
    (is (= [{:key "k2"}] (get-in result [:missing :examples])))))

(deftest an-extra-record-fails
  (testing "of a key nobody sent"
    (let [ops    (conj (pop (clean)) (records-read [(record "k1" 5) (record "k2" 6) (record "k4" 7)
                                                    (record "ghost" 1)]))
          result (bank/analyze-keys (history-of ops))]
      (is (false? (:valid? result)))
      (is (= [{:id "ghost"}] (get-in result [:extra :examples])))))
  (testing "of a key Nerva refused"
    (let [ops (conj (pop (clean)) (records-read [(record "k1" 5) (record "k2" 6) (record "k3" 30)
                                                 (record "k4" 7)]))]
      (is (false? (keyed-valid? ops))))))

(deftest a-record-that-differs-from-its-transfer-fails
  (let [ops    (conj (pop (clean)) (records-read [(record "k1" 4) (record "k2" 6) (record "k4" 7)]))
        result (bank/analyze-keys (history-of ops))]
    (is (false? (:valid? result)))
    (is (= 1 (get-in result [:wrong :count])))))

(deftest a-record-listed-twice-fails
  (let [ops (conj (pop (clean)) (records-read [(record "k1" 5) (record "k1" 5) (record "k2" 6)
                                               (record "k4" 7)]))]
    (is (= 1 (get-in (bank/analyze-keys (history-of ops)) [:duplicated :count])))
    (is (false? (keyed-valid? ops)))))

(deftest a-key-committed-at-two-ops-fails
  (let [ops    (assoc (clean) 3 (transfer :ok "k2" 6 [(answered 11 {:dropped? true})
                                                      (answered 15)]))
        result (bank/analyze-keys (history-of ops))]
    (is (false? (:valid? result)))
    (is (= [{:key "k2", :ops [11 15]}] (get-in result [:duplicate :examples])))))

(deftest the-count-view-must-equal-the-records
  (testing "the view below the records, or above the keys that may have committed"
    (doseq [n [2 4]]
      (let [ops (conj (pop (clean)) (records-read [(record "k1" 5) (record "k2" 6) (record "k4" 7)]
                                                  n))]
        (is (false? (keyed-valid? ops)) (str n)))))
  (testing "the view equal to the records, but fewer than the committed keys"
    (let [ops (conj (pop (clean)) (records-read [(record "k1" 5) (record "k2" 6)] 2))]
      (is (false? (keyed-valid? ops))))))

(deftest a-key-that-may-have-committed-may-have-a-record
  (let [lost-key (transfer :info "k5" 3 [lost lost])
        ops      (fn [records] (concat (butlast (clean)) [lost-key] [(records-read records)]))
        base     [(record "k1" 5) (record "k2" 6) (record "k4" 7)]]
    (testing "with its record"
      (is (= :unknown (keyed-valid? (ops (conj base (record "k5" 3)))))
          "unresolved keys leave the result unknown"))
    (testing "without it, or once resolved with it"
      (is (= :unknown (keyed-valid? (ops base))))
      (is (true? (keyed-valid?
                   (concat (butlast (clean)) [lost-key (resolve-op (entry "k5" 3 [(answered 20)]))
                                              (records-read (conj base (record "k5" 3)))])))))))

(deftest nothing-read-leaves-the-result-unknown
  (is (= :unknown (keyed-valid? (butlast (clean))))))

(deftest a-gateways-refusal-is-no-refusal-by-nerva
  (is (valid? (bank/refusal-checker)
              (history (assoc good-transfer :type :fail, :error bank/gateway-refusal))))
  (is (not (valid? (bank/refusal-checker)
                   (history (assoc good-transfer :type :fail, :error :key_reused))))))

(deftest a-keyed-transfer-is-its-pair-of-adds-and-a-record
  (let [value   {:key "0123456789abcdef0123456789abcdef", :from [2 "held"], :to [3 "available"],
                 :amount 7, :clamp? true}
        entries (bank/keyed-entries value)]
    (is (= (bank/transfer-entries value) (take 2 entries)) "the adds come first, as a pair")
    (is (= {"kind" "put", "table" bank/transfers-table, "id" (:key value),
            "fields" {"from" 3, "to" 4, "amount" "7"}}
           (nth entries 2)))
    (is (<= 0x80000000 bank/transfers-table 0xFFFEFFFF) "a record table")))

(deftest an-index-page-parses-into-records
  (is (= {:id "ab", :from 1, :to 2, :amount 9}
         (bank/parse-record {"id" "ab", "op" "5", "fields" {"from" 1, "to" 2, "amount" "9"}}))))

(deftest nerva-refusing-a-keyed-transfer-ends-it-at-once
  (let [client (bank/map->Client {:keyed? true, :pending (atom []), :phase (atom nil)
                                  :drop-reply 0, :attempts 2})
        value  {:key "k", :from [1 "held"], :to [2 "held"], :amount 30, :clamp? false}
        run    (fn [attempts]
                 (let [calls (atom 0)]
                   (reset! (:pending client) [])
                   (with-redefs [bank/attempt! (fn [& _] (nth attempts (dec (swap! calls inc))))]
                     [(client/invoke! client {:nodes ["n1"]} {:f :transfer, :value value})
                      @(:pending client)])))]
    (testing "a refusal with a status is definite: :fail with that status, nothing pending"
      (let [[done pending] (run [busy out-of-bounds])]
        (is (= :fail (:type done)))
        (is (= :out_of_bounds (:error done)))
        (is (empty? pending))))
    (testing "but not after an attempt that got no answer: the original may commit later"
      (let [[done pending] (run [lost out-of-bounds])]
        (is (= :info (:type done)))
        (is (= :unresolved (:error done)))
        (is (= [value] pending) "the final phase resends it")))
    (testing "only a 409 is Nerva's refusal: views_busy (503) and views_too_large (413) are not"
      (doseq [reply [views-busy views-too-large]]
        (is (not (bank/refused? reply)) (str (:http reply)))
        (is (not (bank/definite? reply)))
        (let [[done pending] (run [reply reply])]
          (is (= :fail (:type done)))
          (is (= bank/gateway-refusal (:error done)) "no refusal by Nerva")
          (is (= [value] pending))))
      (is (bank/refused? out-of-bounds)))
    (testing "a gateway's refusal is not: the key waits for the final phase"
      (let [[done pending] (run [busy busy])]
        (is (= :fail (:type done)))
        (is (= bank/gateway-refusal (:error done)))
        (is (= [value] pending))))
    (testing "a commit is :ok, with its op"
      (let [[done] (run [(answered 12 {:applied 5})])]
        (is (= :ok (:type done)))
        (is (= 12 (:op done)))))))

(deftest a-refusal-after-a-lost-attempt-leaves-room-for-the-original
  (let [ops [good-read good-view
             (transfer :info "k1" 30 [lost out-of-bounds])
             (resolve-op (entry "k1" 30 [out-of-bounds]))]]
    (testing "the original never committed: no record, all valid"
      (is (true? (keyed-valid? (conj ops (records-read []))))))
    (testing "the original committed after the refusal: its record is accounted for"
      (let [hist (history-of (conj ops (records-read [(record "k1" 30)])))
            result (bank/analyze-keys hist)]
        (is (true? (:valid? result)))
        (is (zero? (:count (:extra result))))
        (is (zero? (:count (:count-view result))))))
    (testing "a count view that does not match the records still fails"
      (is (false? (keyed-valid? (conj ops (assoc (records-read [(record "k1" 30)]) :count 0))))))
    (testing "the same refusal as the first attempt was definite: a record is then extra"
      (is (false? (keyed-valid?
                    [good-read good-view (transfer :fail "k1" 30 [out-of-bounds])
                     (records-read [(record "k1" 30)])]))))))

(deftest a-doubtful-key-the-final-phase-never-answered-is-unknown
  (let [doubtful (transfer :info "k1" 30 [lost out-of-bounds])
        unanswered {:f :resolve, :type :info, :resolved [(entry "k1" 30 [])]}]
    (testing "a refusal after an attempt with no answer does not resolve the key"
      (doseq [read [(records-read []) (records-read [(record "k1" 30)])]]
        (let [result (bank/analyze-keys
                       (history-of [good-read good-view doubtful unanswered read]))]
          (is (= :unknown (:valid? result)))
          (is (= [{:key "k1"}] (get-in result [:unresolved :examples]))))))
    (testing "the final phase's own refusal does"
      (is (true? (keyed-valid? [good-read good-view doubtful
                                (resolve-op (entry "k1" 30 [out-of-bounds]))
                                (records-read [])]))))
    (testing "and so does a refusal with no attempt before it that got no answer"
      (is (true? (keyed-valid? [good-read good-view
                                (transfer :fail "k1" 30 [busy out-of-bounds])
                                (records-read [])]))))))

(deftest a-key-refused-after-it-committed-fails
  (testing "a dropped 200, then a resend refused"
    (let [ops [good-read good-view
               (transfer :fail "k1" 30 [(answered 10 {:dropped? true}) out-of-bounds])
               (records-read [(record "k1" 30)])]
          result (bank/analyze-keys (history-of ops))]
      (is (false? (:valid? result)))
      (is (= 1 (get-in result [:refused-after-commit :count])))
      (is (= [{:key "k1", :statuses ["out_of_bounds"]}]
             (get-in result [:refused-after-commit :examples])))))
  (testing "a final-phase refusal of a key that committed"
    (is (false? (keyed-valid? [good-read good-view
                               (transfer :info "k1" 30 [(answered 10 {:dropped? true}) lost])
                               (resolve-op (entry "k1" 30 [out-of-bounds]))
                               (records-read [(record "k1" 30)])]))))
  (testing "a refusal before the commit, or a replay after it, is fine"
    (is (true? (keyed-valid? [good-read good-view
                              (transfer :ok "k1" 30 [busy (answered 10 {:dropped? true})
                                                     (answered 10 {:replayed? true})])
                              (records-read [(record "k1" 30)])])))))

(deftest a-final-phase-refusal-is-judged-like-any-other
  (let [bad-resolve (fn [status]
                      (resolve-op (entry "k4" 7 [(assoc out-of-bounds :status status)])))
        check       (fn [ops] (valid? (bank/refusal-checker) (history-of ops)))]
    (testing "out_of_bounds is expected"
      (is (check [good-read (transfer :fail "k4" 7 [busy busy]) (bad-resolve "out_of_bounds")])))
    (testing "unpaired, key_reused and conflict are not"
      (doseq [status ["unpaired" "key_reused" "conflict"]]
        (is (not (check [good-read (transfer :fail "k4" 7 [busy busy]) (bad-resolve status)]))
            status)))
    (testing "nor is one among a doubtful operation's attempts"
      (is (not (check [good-read
                       (transfer :info "k4" 7 [lost (assoc out-of-bounds :status "unpaired")])]))))
    (testing "the whole workload checker fails on it"
      (is (not (valid? (:checker (bank/workload {}))
                       (history-of [good-read good-view
                                    (transfer :fail "k4" 7 [busy busy])
                                    (bad-resolve "unpaired") (records-read [])])))))))

(defn scan-reply
  [records next]
  {:status 200, :body (cond-> {"records" records} next (assoc "next" next))})

(deftest a-scan-is-bounded
  (let [rec {"id" "a", "fields" {"from" 0, "to" 1, "amount" "1"}}]
    (testing "pages are followed to the end"
      (let [replies [(scan-reply [rec] "c1") (scan-reply [rec] nil)]
            calls   (atom -1)]
        (with-redefs [http/request! (fn [& _] (nth replies (swap! calls inc)))]
          (is (= 2 (count (bank/scan-from! "n1" 8080 0)))))))
    (testing "a cursor that does not advance throws"
      (let [replies (atom [(scan-reply [rec] "c1") (scan-reply [rec] "c1")])
            calls   (atom -1)]
        (with-redefs [http/request! (fn [& _] (nth @replies (swap! calls inc)))]
          (is (thrown? clojure.lang.ExceptionInfo (bank/scan-from! "n1" 8080 0))))))
    (testing "a scan that never ends throws after the page limit"
      (let [calls (atom 0)]
        (with-redefs [http/request! (fn [& _] (scan-reply [rec] (str "c" (swap! calls inc))))]
          (is (thrown? clojure.lang.ExceptionInfo (bank/scan-from! "n1" 8080 0)))
          (is (= bank/scan-pages-max @calls)))))))

(deftest the-keys-flag-picks-the-workload
  (is (true? (:keyed? (:client (bank/workload {})))) "keys are the default")
  (is (false? (:keyed? (:client (bank/workload {:keyed false})))))
  (is (= :unknown (valid? (:checker (bank/workload {}))
                          (history good-read good-view good-transfer)))
      "a keyed run that never read its records is not known to be valid")
  (is (valid? (:checker (bank/workload {:keyed false}))
              (history good-read good-view good-transfer))))
