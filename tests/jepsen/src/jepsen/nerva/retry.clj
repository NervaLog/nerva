(ns jepsen.nerva.retry
  "What Botpike does after a lost reply: it resends a keyed commit, under the same key, until
  the answer is definite (P123, R1 brief \"Workload `retry`\"). Is the commit applied once?

  Eight account rows each hold an i64 `balance` (floored at 0) in a declared ledger, and an
  unfloored `source` funds them. An operation is a pay-in: a fixed amount (1 to 30) from the
  source to one account, as a pair of adds with no `clamp`, so its effect does not depend on
  state and every commit of it moves exactly its amount. A pay-in never fails for funds. Rows
  are created by their first pay-in.

  Each operation draws a fresh 128-bit key from Jepsen's random source, so `--seed` steers it,
  and its entries never change. Replies are lost on purpose: an attempt's client timeout is
  35 s, or with probability 1/4 a short 50 to 1,999 ms (below the gateways' 3 s
  `--request-timeout`), and with probability `--drop-reply` the client discards a 200 and
  resends as if it were lost. An attempt that is not definite is resent to another gateway of
  the cluster's nodes, after a backoff, up to `--attempts`. The operation completes :ok with
  the op of its first definite 200, :fail if every attempt was refused with `applied: false`
  (or never connected), else :info.

  After healing, every key whose operation did not complete :ok is resent through a healthy
  gateway until a 2xx answers it (a pay-in has no other definite answer), then every account
  is read in one lookup.

  Checked (`checker`):
  1. :duplicate    every 200 for a key, first-time or `replayed`, a discarded one included, names
                   the same op;
  2. :balance      each account holds the sum of the amounts of the keys that committed for it,
                   each counted once, and the source holds minus their total;
  3. :applied-lie  a key whose attempts before its first 200 were all `applied: false` is
                   answered first-time, never `replayed`;
  4. :key-reused / :key-collision  no reply refuses the client's own keys;
  and :unresolved, a key no 2xx answered even in the final phase (unknown, not invalid)."
  (:require [jepsen [checker :as checker]
                    [client :as client]
                    [generator :as gen]
                    [random :as rand]]
            [jepsen.nerva.http :as http]
            [jepsen.nerva.keyed :as keyed])
  (:import (java.io IOException)))

(def accounts-table 30)
(def sources-table 31)
(def ledger-id 1)
(def source-row 1)
(def account-rows (vec (range 1 9)))
(def max-amount 30)

(def request-timeout-ms keyed/request-timeout-ms)

;; ---------------------------------------------------------------------------------------
;; The transaction

(defn pay-entries
  "A pay-in as the pair of adds a ledger allows. Both create their row, so no row is seeded."
  [{:keys [account amount]}]
  [{"kind" "add", "table" sources-table, "id" (str source-row), "field" "balance",
    "delta" (str (- amount)), "pair" true, "create" true}
   {"kind" "add", "table" accounts-table, "id" (str account), "field" "balance",
    "delta_from" 0, "create" true}])

(defn commit-body
  [{:keys [key] :as value}]
  {"key" key, "entries" (pay-entries value)})

(defn pay-value
  "A fresh pay-in, under a fresh key."
  []
  {:key     (keyed/fresh-key)
   :account (nth account-rows (rand/long (count account-rows)))
   :amount  (inc (rand/long max-amount))})

(defn bootstrap!
  "Layouts and the ledger, once, before the test."
  [_test node]
  (http/ok! node "PUT" (str "/v1/tables/" accounts-table)
            {"name" "accounts", "fields" [{"name" "balance", "type" "i64"}]})
  (http/ok! node "PUT" (str "/v1/tables/" sources-table)
            {"name" "sources", "fields" [{"name" "balance", "type" "i64"}]})
  (http/ok! node "PUT" (str "/v1/ledgers/" ledger-id)
            {"fields" [{"table" accounts-table, "field" "balance", "floor" "0"}
                       {"table" sources-table, "field" "balance", "floor" nil}]}))

(defn attempt!
  "Sends the pay-in once to gateway [node port] (`keyed/attempt!`)."
  [target value timeout-ms drop?]
  (keyed/attempt! (commit-body value) target timeout-ms drop?))

(def ops
  "What `keyed` takes of this workload: a pay-in is answered by a 2xx it kept."
  {:attempt!   (fn [target value timeout-ms drop?] (attempt! target value timeout-ms drop?))
   :entry-keys [:key :account :amount]
   :complete   (fn [base done]
                 (cond-> (assoc base :type :ok, :op (:op done))
                   (:replayed? done) (assoc :replayed? true)))})

(def phase-deadline! keyed/phase-deadline!)

(defn invoke-pay
  [client test op]
  (keyed/invoke-keyed client test op ops))

(defn invoke-resolve
  "The final phase: sends every key still pending until a 2xx answers it, or the phase's
  deadline passes (`keyed/resolve-pending`)."
  [client test op]
  (keyed/resolve-pending client test op ops))

(defn lookup-rows
  [accounts]
  (conj (mapv (fn [row] {"table" accounts-table, "id" (str row)}) accounts)
        {"table" sources-table, "id" (str source-row)}))

(defn balance-of
  "A row's balance in a lookup, 0 for a row no pay-in has created."
  [row]
  (or (some-> (get-in row ["fields" "balance"]) parse-long) 0))

(defn read-value
  [lookup]
  (let [rows (get lookup "rows")]
    {:balances (zipmap account-rows (map balance-of rows))
     :source   (balance-of (last rows))}))

(defn invoke-read
  "Every account and the source, in one lookup, through any gateway that answers."
  [test op]
  (let [targets (keyed/targets test)]
    (loop [n 0, previous nil]
      (let [[node port :as target] (keyed/pick targets previous)
            reply (try (http/request! node port "POST" "/v1/lookup"
                                      {"rows" (lookup-rows account-rows)})
                       (catch IOException _ nil))
            outcome (when reply (http/outcome reply))]
        (cond (= :ok outcome)
              (assoc op :type :ok, :op (parse-long (str (get-in reply [:body "op"])))
                     :gateway (str node ":" port)
                     :value (:balances (read-value (:body reply)))
                     :source (:source (read-value (:body reply))))
              (= :violation outcome) (http/violation op reply)
              (< n 20) (do (keyed/backoff! (min n 5)) (recur (inc n) target))
              :else (assoc op :type :fail, :error :no-answer))))))

(defrecord Client [pending phase drop-reply attempts]
  client/Client
  (open! [this _test _node] this)
  (setup! [_ _test])
  (invoke! [this test op]
    (case (:f op)
      :pay     (invoke-pay this test op)
      :resolve (invoke-resolve this test op)
      :read    (invoke-read test op)))
  (teardown! [_ _test])
  (close! [_ _test]))

;; ---------------------------------------------------------------------------------------
;; The checker

(defn key-records
  [history]
  (keyed/key-records history :pay))

(def answers keyed/answers)
(def duplicates keyed/duplicates)
(def applied-lies keyed/applied-lies)
(def refused-keys keyed/refused-keys)

(defn expected
  "What the final reads must show: [lo hi] per account, and for the source (as :source). lo
  counts the keys that committed once each; hi adds the keys no one answered, which may or may
  not have."
  [records]
  (let [committed  (filter (comp seq answers val) records)
        unresolved (remove (comp seq answers val) records)
        total      (fn [rs account]
                     (reduce + (for [[_ r] rs :when (or (nil? account) (= account (:account r)))]
                                 (:amount r))))]
    (merge (into {} (for [a account-rows]
                      (let [lo (total committed a)]
                        [a [lo (+ lo (total unresolved a))]])))
           {:source (let [lo (total committed nil)]
                      [(- (+ lo (total unresolved nil))) (- lo)])})))

(defn balance-errors
  [records history]
  (let [want  (expected records)
        reads (filter #(and (= :read (:f %)) (= :ok (:type %))) history)]
    (for [read reads
          [account actual] (cons [:source (:source read)] (:value read))
          :let [[lo hi] (want account)]
          :when (not (<= lo actual hi))]
      {:account account, :actual actual, :expected lo, :at-most hi, :op (:op read)})))

(defn analyze
  "The checker's verdict on a history."
  [history]
  (let [records    (key-records history)
        reads      (filter #(and (= :read (:f %)) (= :ok (:type %))) history)
        duplicate  (vec (duplicates records))
        balance    (vec (balance-errors records history))
        lies       (vec (applied-lies records))
        reused     (vec (refused-keys records "key_reused"))
        collisions (vec (refused-keys records "key_collision"))
        unresolved (vec (for [[key r] records :when (empty? (answers r))] {:key key}))
        broken?    (some seq [duplicate balance lies reused collisions])]
    {:valid?       (cond broken? false
                         (or (seq unresolved) (empty? reads)) :unknown
                         :else true)
     :keys         (count records)
     :committed    (count (filter (comp seq answers) (vals records)))
     :replayed     (count (filter (comp (partial some :replayed?) answers) (vals records)))
     :dropped      (count (filter #(some :dropped? (:attempts %)) (vals records)))
     :reads        (count reads)
     :duplicate    {:count (count duplicate), :examples (vec (take 10 duplicate))}
     :balance      {:count (count balance), :examples (vec (take 10 balance))}
     :applied-lie  {:count (count lies), :examples (vec (take 10 lies))}
     :key-reused   {:count (count reused), :examples (vec (take 10 reused))}
     :key-collision {:count (count collisions), :examples (vec (take 10 collisions))}
     :unresolved   {:count (count unresolved), :examples (vec (take 10 unresolved))}}))

(defn checker
  []
  (reify checker/Checker
    (check [_ _test history _opts]
      (analyze history))))

;; ---------------------------------------------------------------------------------------

(defn workload
  [opts]
  {:client          (map->Client {:pending    (atom [])
                                  :phase      (atom nil)
                                  :drop-reply (:drop-reply opts 0.1)
                                  :attempts   (:attempts opts 8)})
   :bootstrap       bootstrap!
   :test-keys       {:request-timeout request-timeout-ms}
   :generator       (fn [] {:f :pay, :value (pay-value)})
   :final-generator (gen/phases (gen/each-thread {:f :resolve})
                                (gen/each-thread {:f :read}))
   :checker         (checker)})
