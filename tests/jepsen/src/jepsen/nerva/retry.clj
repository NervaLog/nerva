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
            [jepsen.nerva.db :as db]
            [jepsen.nerva.http :as http])
  (:import (java.io IOException)
           (java.util.concurrent ThreadLocalRandom)))

(def accounts-table 30)
(def sources-table 31)
(def ledger-id 1)
(def source-row 1)
(def account-rows (vec (range 1 9)))
(def max-amount 30)

(def request-timeout-ms
  "The gateways' `--request-timeout`: an unanswered request is answered by the gateway within
  about 5 s, and a short client timeout (below) is shorter than that."
  3000)

(def short-timeout-probability 0.25)
(def resolve-deadline-ms
  "How long the final phase tries to get one key answered."
  180000)

(defn rnd
  "A uniform double in [0, 1) from the worker's own source: client choices are not seeded."
  []
  (.nextDouble (ThreadLocalRandom/current)))

(defn rnd-long
  "A uniform long in [lo, hi)."
  [lo hi]
  (.nextLong (ThreadLocalRandom/current) lo hi))

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
  "A fresh pay-in. The key is 128 bits from Jepsen's random source, never zero."
  []
  (let [key (format "%016x%016x" (rand/long) (rand/long))]
    (if (= key (apply str (repeat 32 \0)))
      (recur)
      {:key     key
       :account (nth account-rows (rand/long (count account-rows)))
       :amount  (inc (rand/long max-amount))})))

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

;; ---------------------------------------------------------------------------------------
;; One attempt

(defn attempt!
  "Sends the pay-in once to gateway [node port] and says what came of it, as a map with a
  :kind: :committed (a 2xx; :op, and :replayed? for a replay; :dropped? when the client
  discarded the reply on purpose), :refused (`applied: false`; :http, :code, :status),
  :unknown (`applied: \"unknown\"`, or no reply to a request that went out), :not-sent (no
  connection) or :violation (a reply that breaks R4's promise; :reply)."
  [[node port] value timeout-ms drop?]
  (let [base {:gateway (str node ":" port), :timeout-ms timeout-ms}]
    (try
      (let [reply (http/request! node port "POST" "/v1/commit" (commit-body value) timeout-ms)
            body  (:body reply)]
        (merge base
               (case (http/outcome reply)
                 :ok        (merge {:kind :committed} (http/ok-fields reply)
                                   (when drop? {:dropped? true}))
                 :refused   {:kind :refused, :http (:status reply), :code (get body "code"),
                             :status (get body "status")}
                 :unknown   {:kind :unknown, :http (:status reply), :code (get body "code")}
                 :violation {:kind :violation, :reply (select-keys reply [:status :body])})))
      (catch IOException e
        (merge base (if (http/not-sent? e)
                      {:kind :not-sent}
                      {:kind :unknown, :error (.getName (class e))}))))))

(defn definite?
  "Whether an attempt answered its key as far as the client knows: a 2xx it kept."
  [attempt]
  (and (= :committed (:kind attempt)) (not (:dropped? attempt))))

(defn targets
  "Every node's gateways, as [node port]."
  [test]
  (vec (for [node (:nodes test), index (range (db/gateways test node))]
         [node (db/gateway-port index)])))

(defn pick
  "A gateway other than `previous` when there is another."
  [targets previous]
  (let [others (vec (or (seq (remove #{previous} targets)) targets))]
    (nth others (rnd-long 0 (count others)))))

(defn backoff!
  "Sleeps before attempt number n + 1: 100 ms doubling to 2 s, jittered."
  [n]
  (Thread/sleep (long (* (min 2000 (* 100 (bit-shift-left 1 (min n 10)))) (+ 0.5 (* 0.5 (rnd)))))))

(defn run-attempts!
  "Sends `value` until an attempt is definite, a reply is a violation, or the budget is spent.
  With :max-attempts, each attempt may be given a short client timeout and its 200 may be
  discarded (:drop-reply is the probability). With :deadline-ms (the final phase), the client
  waits for a healthy gateway and keeps the long timeout. Returns the attempts."
  [test value {:keys [max-attempts deadline-ms drop-reply]}]
  (let [targets  (targets test)
        deadline (when deadline-ms (+ (System/nanoTime) (* deadline-ms 1000000)))]
    (loop [attempts [], previous nil]
      (let [n      (count attempts)
            target (pick targets previous)]
        (if (and deadline (not (apply http/healthy? target)))
          (if (< (System/nanoTime) deadline)
            (do (backoff! (min n 5)) (recur attempts target))
            attempts)
          (let [timeout-ms (if (and max-attempts (< (rnd) short-timeout-probability))
                             (rnd-long 50 2000)
                             http/timeout-ms)
                drop?      (and max-attempts (< (rnd) drop-reply))
                attempts   (conj attempts (attempt! target value timeout-ms drop?))
                last       (peek attempts)]
            (cond (or (definite? last) (= :violation (:kind last))) attempts
                  (if max-attempts (<= max-attempts (count attempts))
                      (<= deadline (System/nanoTime)))             attempts
                  :else (do (backoff! (count attempts)) (recur attempts target)))))))))

;; ---------------------------------------------------------------------------------------
;; The client

(defn push-pending!
  [pending value]
  (swap! pending conj value))

(defn pop-pending!
  "Takes one key to resolve, atomically; nil when none is left."
  [pending]
  (let [[old _] (swap-vals! pending #(if (seq %) (pop %) %))]
    (peek old)))

(defn violation-of
  [attempts]
  (first (filter #(= :violation (:kind %)) attempts)))

(defn invoke-pay
  [{:keys [pending drop-reply attempts]} test op]
  (let [value (:value op)
        tries (run-attempts! test value {:max-attempts attempts, :drop-reply drop-reply})
        done  (first (filter definite? tries))
        base  (assoc op :attempts tries)]
    (cond
      (violation-of tries)
      (do (push-pending! pending value)
          (http/violation base (:reply (violation-of tries))))

      done
      (cond-> (assoc base :type :ok, :op (:op done))
        (:replayed? done) (assoc :replayed? true))

      (every? (comp #{:refused :not-sent} :kind) tries)
      (do (push-pending! pending value)
          (assoc base :type :fail, :error :refused))

      :else
      (do (push-pending! pending value)
          (assoc base :type :info, :error :unresolved)))))

(defn invoke-resolve
  "The final phase: sends every key still pending until a 2xx answers it."
  [{:keys [pending]} test op]
  (loop [entries []]
    (if-let [value (pop-pending! pending)]
      (let [tries (run-attempts! test value {:deadline-ms resolve-deadline-ms})
            entry (assoc (select-keys value [:key :account :amount]) :attempts tries)]
        (if-let [bad (violation-of tries)]
          (http/violation (assoc op :resolved (conj entries entry)) (:reply bad))
          (recur (conj entries entry))))
      (assoc op :type (if (every? #(some definite? (:attempts %)) entries) :ok :info)
             :resolved entries))))

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
  (let [targets (targets test)]
    (loop [n 0, previous nil]
      (let [[node port :as target] (pick targets previous)
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
              (< n 20) (do (backoff! (min n 5)) (recur (inc n) target))
              :else (assoc op :type :fail, :error :no-answer))))))

(defrecord Client [pending drop-reply attempts]
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
  "Everything the history says about each key: {key {:account :amount :attempts}}, attempts in
  the order they were sent (the operation's, then the final phase's)."
  [history]
  (reduce
    (fn [records {:keys [f type value resolved attempts]}]
      (let [add (fn [records {:keys [key account amount attempts]}]
                  (-> records
                      (update key (fnil identity {:account account, :amount amount}))
                      (update-in [key :attempts] (fnil into []) attempts)))]
        (cond
          (and (= :pay f) (#{:ok :fail :info} type)) (add records (assoc value :attempts attempts))
          (and (= :resolve f) (#{:ok :info} type))   (reduce add records resolved)
          :else records)))
    {}
    history))

(defn answers
  "A key's 2xx replies, a discarded one included."
  [record]
  (filter #(= :committed (:kind %)) (:attempts record)))

(defn duplicates
  "Keys answered at more than one op."
  [records]
  (for [[key record] records
        :let [ops (distinct (map :op (answers record)))]
        :when (< 1 (count ops))]
    {:key key, :ops (vec (sort ops))}))

(defn applied-lies
  "Keys whose first 2xx is a replay although every attempt before it was `applied: false` (or
  never connected): the gateways said nothing was applied, and something had been."
  [records]
  (for [[key record] records
        :let [attempts (:attempts record)
              [before from] (split-with #(not= :committed (:kind %)) attempts)
              first-answer  (first from)]
        :when (and first-answer
                   (:replayed? first-answer)
                   (every? (comp #{:refused :not-sent} :kind) before))]
    {:key key, :refused-before (count before), :op (:op first-answer)}))

(defn refused-keys
  "Attempts answered `key_reused` or `key_collision`, by that status."
  [records status]
  (for [[key record] records
        attempt (:attempts record)
        :when (= status (:status attempt))]
    {:key key, :gateway (:gateway attempt)}))

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
                                  :drop-reply (:drop-reply opts 0.1)
                                  :attempts   (:attempts opts 8)})
   :bootstrap       bootstrap!
   :test-keys       {:request-timeout request-timeout-ms}
   :generator       (fn [] {:f :pay, :value (pay-value)})
   :final-generator (gen/phases (gen/each-thread {:f :resolve})
                                (gen/each-thread {:f :read}))
   :checker         (checker)})
