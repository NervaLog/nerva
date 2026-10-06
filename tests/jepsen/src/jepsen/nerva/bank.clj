(ns jepsen.nerva.bank
  "Conservation in a declared ledger (NV-1, README \"Ledgers\"), with Jepsen's bank test.

  Four account rows each have two conserved fields, `available` and `held`, floored at 0; a
  source row's `balance` (no floor) funds them, once, before the test. Jepsen's eight
  \"accounts\" are the eight (row, field) pairs, and a transfer is the only change a ledger
  allows: a pair of adds, the first (`pair`, maybe `clamp`) taking up to `amount` from one
  field, its partner (`delta_from`) giving exactly that to another. So every move the bank
  test makes is one of reserve (available to held), post (held to another row), void (held
  back to available) or a plain transfer.

  Checked:
  - every read (one lookup, so one op) totals what was funded, with no field below 0
    (Jepsen's bank checker), and the source still holds minus that total;
  - every answer of a sum view over the accounts totals what was funded;
  - a transfer is refused only with `out_of_bounds`: anything else (`unpaired`,
    `conserved_write`, `conflict`) means Nerva refused a move it should have taken."
  (:require [jepsen [checker :as checker]
                    [client :as client]
                    [generator :as gen]]
            [jepsen.tests.bank :as bank]
            [jepsen.nerva.http :as http]))

(def accounts-table 20)
(def sources-table 21)
(def ledger-id 1)
(def view-name "bank_totals")
(def rows [1 2 3 4])
(def source-row 1)
(def funding-per-row 100)

(def accounts
  "Jepsen's accounts: every conserved (row, field) of the account table."
  (vec (for [row rows, field ["available" "held"]] [row field])))

(def total-amount (* funding-per-row (count rows)))

(def max-transfer 30)

(defn add
  "One add entry on the accounts table."
  [[row field] options]
  (merge {"kind" "add", "table" accounts-table, "id" (str row), "field" field} options))

(defn transfer-entries
  "A transfer as the pair of adds a ledger allows."
  [{:keys [from to amount clamp?]}]
  [(add from (cond-> {"delta" (str (- amount)), "pair" true}
               clamp? (assoc "clamp" true)))
   (add to {"delta_from" 0})])

(defn fund-entries
  "Moves funding-per-row from the source into row's available."
  [row]
  [{"kind" "add", "table" sources-table, "id" (str source-row), "field" "balance",
    "delta" (str (- funding-per-row)), "pair" true, "create" true}
   (add [row "available"] {"delta_from" 0, "create" true})])

(defn bootstrap!
  "Layouts, the ledger and the view, then the funding: once, before the test."
  [_test node]
  (http/ok! node "PUT" (str "/v1/tables/" accounts-table)
            {"name"   "accounts"
             "fields" [{"name" "available", "type" "i64"} {"name" "held", "type" "i64"}]})
  (http/ok! node "PUT" (str "/v1/tables/" sources-table)
            {"name" "sources", "fields" [{"name" "balance", "type" "i64"}]})
  (http/ok! node "PUT" (str "/v1/ledgers/" ledger-id)
            {"fields" [{"table" accounts-table, "field" "available", "floor" "0"}
                       {"table" accounts-table, "field" "held", "floor" "0"}
                       {"table" sources-table, "field" "balance", "floor" nil}]})
  (http/ok! node "PUT" (str "/v1/views/" view-name)
            {"table"      accounts-table
             "aggregates" [{"fn" "sum", "field" "available"} {"fn" "sum", "field" "held"}]})
  (doseq [row rows]
    (http/ok! node "POST" "/v1/commit" {"entries" (fund-entries row)})))

(defn lookup-rows
  "The rows a read takes, in one lookup: every account row, then the source."
  []
  (conj (mapv (fn [row] {"table" accounts-table, "id" (str row)}) rows)
        {"table" sources-table, "id" (str source-row)}))

(defn field-value
  [row field]
  (some-> (get-in row ["fields" field]) parse-long))

(defn read-value
  "The bank test's balances, and the source's balance, from a lookup's rows."
  [lookup]
  (let [by-row (zipmap rows (get lookup "rows"))]
    {:balances (into {} (for [[row field :as account] accounts]
                          [account (field-value (by-row row) field)]))
     :source   (field-value (last (get lookup "rows")) "balance")}))

(defn invoke-read
  [node op]
  (let [{:keys [body] :as reply} (http/request! node "POST" "/v1/lookup"
                                                {"rows" (lookup-rows)})]
    (case (http/outcome reply)
      :ok      (let [{:keys [balances source]} (read-value body)]
                 (assoc op :type :ok, :value balances, :source source,
                        :op (parse-long (get body "op"))))
      :refused (assoc op :type :fail, :error (keyword (get body "status")))
      :unknown (http/unknown op false :unavailable))))

(defn invoke-transfer
  [node op]
  (let [{:keys [body] :as reply} (http/request! node "POST" "/v1/commit"
                                                {"entries" (transfer-entries (:value op))})]
    (case (http/outcome reply)
      :ok      (assoc op :type :ok
                      :applied (- (parse-long (get-in body ["adds" 0 "applied"])))
                      :op (parse-long (get body "op")))
      :refused (assoc op :type :fail, :error (keyword (get body "status")))
      :unknown (http/unknown op true :unavailable))))

(defn invoke-view
  [node op]
  (let [{:keys [body] :as reply} (http/request! node "GET" (str "/v1/views/" view-name) nil)]
    (case (http/outcome reply)
      :ok      (let [groups (get body "groups")]
                 (assoc op :type :ok
                        :value (reduce + (for [group groups
                                               field ["sum_available" "sum_held"]]
                                           (parse-long (get group field))))
                        :groups (count groups)
                        :op (parse-long (get body "op"))))
      :refused (assoc op :type :fail, :error (keyword (get body "status")))
      :unknown (http/unknown op false :unavailable))))

(defrecord Client [node]
  client/Client
  (open! [this _test node] (assoc this :node node))
  (setup! [_ _test])
  (invoke! [_ _test op]
    (http/with-errors op (= :transfer (:f op))
      (case (:f op)
        :read     (invoke-read node op)
        :transfer (invoke-transfer node op)
        :view     (invoke-view node op))))
  (teardown! [_ _test])
  (close! [_ _test]))

(defn source-checker
  "Every read sees the source at minus the funded total: nothing else moves it."
  []
  (reify checker/Checker
    (check [_ test history _opts]
      (let [expected (- (:total-amount test))
            bad      (->> history
                          (filter #(and (= :ok (:type %)) (= :read (:f %))))
                          (remove #(= expected (:source %))))]
        {:valid?   (empty? bad)
         :expected expected
         :errors   (vec (take 10 bad))}))))

(defn view-checker
  "Every answer of the sum view totals what was funded."
  []
  (reify checker/Checker
    (check [_ test history _opts]
      (let [answers (filter #(and (= :ok (:type %)) (= :view (:f %))) history)
            bad     (remove #(= (:total-amount test) (:value %)) answers)]
        {:valid?  (empty? bad)
         :answers (count answers)
         :errors  (vec (take 10 bad))}))))

(def expected-refusals
  "Why a well-formed transfer may be refused: it would take a field below its floor."
  #{:out_of_bounds})

(defn refusal-checker
  "Transfers are refused only for expected reasons."
  []
  (reify checker/Checker
    (check [_ _test history _opts]
      (let [refused (->> history
                         (filter #(and (= :fail (:type %)) (= :transfer (:f %)))))
            bad     (remove (comp expected-refusals :error) refused)]
        {:valid?      (empty? bad)
         :refusals    (frequencies (map :error refused))
         :unexpected  (vec (take 10 bad))}))))

(defn generator
  "Transfers (half of them clamped), reads and view reads, in equal parts."
  []
  (gen/mix [(gen/map (fn [op] (assoc-in op [:value :clamp?] (< (rand) 0.5)))
                     bank/diff-transfer)
            bank/read
            (repeat {:f :view})]))

(defn final-generator
  "After healing, one read and one view read per worker."
  []
  (gen/each-thread [{:f :read} {:f :view}]))

(defn workload
  [_opts]
  {:client          (map->Client {})
   :bootstrap       bootstrap!
   :test-keys       {:accounts     accounts
                     :total-amount total-amount
                     :max-transfer max-transfer}
   :generator       (generator)
   :final-generator (final-generator)
   :checker         (checker/compose
                      {:bank      (bank/checker {:negative-balances? false})
                       :source    (source-checker)
                       :view      (view-checker)
                       :refusals  (refusal-checker)})})
