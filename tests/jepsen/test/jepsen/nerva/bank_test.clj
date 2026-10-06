(ns jepsen.nerva.bank-test
  "The bank workload's checkers fail on the histories they exist to catch, and pass a correct
  one; replies parse into the values the checkers read."
  (:require [clojure.test :refer [deftest is testing]]
            [jepsen.checker :as checker]
            [jepsen.history :as h]
            [jepsen.nerva.bank :as bank]
            [jepsen.tests.bank :as jepsen-bank]
            [jepsen.nerva.http :as http]))

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
    (is (valid? (:checker (bank/workload {})) hist))))

(deftest lost-or-created-value-fails
  (testing "a read that totals less than was funded"
    (is (not (valid? (jepsen-bank/checker {:negative-balances? false})
                     (history (assoc-in good-read [:value [2 "held"]] -1))))))
  (testing "a field below its floor, even with the right total"
    (is (not (valid? (:checker (bank/workload {}))
                     (history (-> good-read
                                  (assoc-in [:value [1 "available"]] -5)
                                  (assoc-in [:value [1 "held"]] 5))))))))

(deftest a-missing-row-fails
  (is (not (valid? (:checker (bank/workload {}))
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

(deftest replies-map-to-outcomes
  (is (= :ok (http/outcome {:status 200})))
  (is (= :refused (http/outcome {:status 409})))
  (is (= :unknown (http/outcome {:status 503})))
  (is (= :unknown (http/outcome {:status 504})))
  (is (thrown? clojure.lang.ExceptionInfo (http/outcome {:status 400})))
  (is (= :info (:type (http/unknown {:f :transfer} true :x))))
  (is (= :fail (:type (http/unknown {:f :read} false :x)))))

(deftest a-request-never-sent-failed
  (is (= :fail (:type (http/no-reply {:f :transfer} true (java.net.ConnectException. "refused")))))
  (is (= :info (:type (http/no-reply {:f :transfer} true (java.io.IOException. "reset")))))
  (is (= :info (:type (http/no-reply {:f :transfer} true
                                     (java.net.http.HttpTimeoutException. "35 s"))))))
