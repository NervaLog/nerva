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
    `conserved_write`, `conflict`) means Nerva refused a move it should have taken.

  With `--keys` (the default), each transfer is sent as Botpike sends one (R1 brief \"Workload
  `bank` with keys and records\"): under a fresh commit key, resent as `retry` resends (shared
  code in `jepsen.nerva.keyed`), and in the same transaction it writes a record in the
  `transfers` record table: id the key, value `from`, `to` (each an index into `accounts`) and
  the requested `amount`. An index by `from` and a `count` view over the table are declared
  with it. A transfer is answered by a 2xx or by Nerva's own refusal (a 409 with a status),
  unless an earlier attempt of its key got no answer (the original may commit later: the op
  ends :info); keys that were not are resent after healing, then every record is read through
  the index.
  Also checked:
  - `:refused-after-commit`  no key is refused after an attempt of it committed, `conflict`
                  apart (keys are kept forever, so a resend replays);
  - `:duplicate`  every 2xx for a key, a discarded one included, names the same op, and no key
                  that committed is then refused `conflict` (the record read caught a second
                  application);
  - `:records`    every key that committed has exactly one record, with its `from`, `to` and
                  `amount`, and every record is of a key that committed or may have (an
                  attempt got no answer); the count view equals the records the index lists,
                  and lies between the committed keys and the keys that may have committed.
  A refusal in the final phase is judged as one in an operation. `--no-keys` keeps the unkeyed
  run, with no record."
  (:require [jepsen [checker :as checker]
                    [client :as client]
                    [generator :as gen]]
            [jepsen.tests.bank :as bank]
            [jepsen.nerva.http :as http]
            [jepsen.nerva.keyed :as keyed])
  (:import (java.io IOException)))

(def accounts-table 20)
(def sources-table 21)
(def ledger-id 1)
(def view-name "bank_totals")
(def rows [1 2 3 4])
(def source-row 1)
(def transfers-table
  "The record table of transfers (0x80000014): record tables start at 0x80000000."
  0x80000014)
(def transfers-index "transfers_by_from")
(def transfers-view "transfers_count")
(def page-limit 500)
(def scan-pages-max
  "Pages one index key's scan may take: 100 x 500 records, far above a run's transfers."
  100)
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

(defn declare-transfers!
  "The record table of transfers, an index by `from` and a count view over it, declared before
  the funding so that every record is in all three from its commit."
  [node]
  (http/ok! node "PUT" (str "/v1/tables/" transfers-table)
            {"name"   "transfers"
             "fields" [{"name" "from", "type" "u8"}
                       {"name" "to", "type" "u8"}
                       {"name" "amount", "type" "u64"}]})
  (http/ok! node "PUT" (str "/v1/indexes/" transfers-index)
            {"table" transfers-table, "eq" ["from"]})
  (http/ok! node "PUT" (str "/v1/views/" transfers-view)
            {"table" transfers-table, "aggregates" [{"fn" "count"}]}))

(defn bootstrap!
  "Layouts, the ledger and the view, then the funding: once, before the test. With `keyed?`,
  also the transfers' record table, index and view."
  [keyed? _test node]
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
  (when keyed? (declare-transfers! node))
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
      :refused (assoc op :type :fail, :error (http/refusal-error reply))
      :unknown (http/unknown op false :unavailable)
      :violation (http/violation op reply))))

(defn invoke-transfer
  [node op]
  (let [{:keys [body] :as reply} (http/request! node "POST" "/v1/commit"
                                                {"entries" (transfer-entries (:value op))})]
    (case (http/outcome reply)
      :ok      (assoc op :type :ok
                      :applied (- (parse-long (get-in body ["adds" 0 "applied"])))
                      :op (parse-long (get body "op")))
      :refused (assoc op :type :fail, :error (http/refusal-error reply))
      :unknown (http/unknown op true :unavailable)
      :violation (http/violation op reply))))

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
      :refused (assoc op :type :fail, :error (http/refusal-error reply))
      :unknown (http/unknown op false :unavailable)
      :violation (http/violation op reply))))


;; ---------------------------------------------------------------------------------------
;; Keyed transfers and their records

(defn account-index
  "An account's index in `accounts`: what a record's `from` and `to` hold."
  [account]
  (.indexOf ^java.util.List accounts account))

(defn record-fields
  "The fields of a transfer's record: both ends as indexes into `accounts`, and the amount
  requested (a clamped transfer may move less)."
  [{:keys [from to amount]}]
  {"from" (account-index from), "to" (account-index to), "amount" (str amount)})

(defn keyed-entries
  "A transfer's pair of adds and, after them, its record under the commit key. The record is
  read as absent (`op_seen` \"0\") before it is put, so a second application of the transfer,
  which finds the record, is refused `conflict` instead of upserting it unseen (P239d)."
  [{:keys [key] :as value}]
  (conj (transfer-entries value)
        {"kind" "read", "table" transfers-table, "id" key, "op_seen" "0"}
        {"kind" "put", "table" transfers-table, "id" key, "fields" (record-fields value)}))

(defn attempt!
  "Sends the keyed transfer once to gateway [node port] (`keyed/attempt!`)."
  [target value timeout-ms drop?]
  (keyed/attempt! {"key" (:key value), "entries" (keyed-entries value)}
                  target timeout-ms drop?))

(defn refused?
  "Whether an attempt was refused by Nerva itself (a 409 with its status), which is as definite
  as a commit (`keyed/invoke-keyed` makes it so only if no earlier attempt of the key got no
  answer). Not a gateway's own refusal (busy, no session: no status), and not a 503
  `views_busy` or 413 `views_too_large`, which carry a status but say nothing was applied and a
  resend is safe (R4's contract; `http/refusal-error` keeps the same line)."
  [attempt]
  (and (= :refused (:kind attempt)) (= 409 (:http attempt)) (string? (:status attempt))))

(defn definite?
  "A transfer is answered by a 2xx the client kept, or by Nerva's refusal of it."
  [attempt]
  (or (keyed/definite? attempt) (refused? attempt)))

(def ops
  "What `keyed` takes of this workload."
  {:attempt!   (fn [target value timeout-ms drop?] (attempt! target value timeout-ms drop?))
   :definite?  definite?
   :entry-keys [:key :from :to :amount :clamp?]
   :complete   (fn [base done]
                 (if (refused? done)
                   (assoc base :type :fail, :error (keyword (:status done)))
                   (cond-> (assoc base :type :ok, :op (:op done))
                     (:applied done)   (assoc :applied (:applied done))
                     (:replayed? done) (assoc :replayed? true))))})

(defn parse-record
  "A scan's record as {:id :from :to :amount}."
  [record]
  (let [fields (get record "fields")]
    {:id     (get record "id")
     :from   (parse-long (str (get fields "from")))
     :to     (parse-long (str (get fields "to")))
     :amount (parse-long (str (get fields "amount")))}))

(defn request-timeout-ms
  "How long the next request of the records read may take: `http/timeout-ms`, or the time left
  before `deadline` (System/nanoTime) if that is less. Throws once none is left (P239f)."
  [deadline]
  (let [left (quot (- deadline (System/nanoTime)) 1000000)]
    (when (<= left 0)
      (throw (ex-info "records deadline" {})))
    (min http/timeout-ms left)))

(defn scan-from!
  "Every record of the index with `from` = i, in pages. Throws unless every page is a 200, if a
  cursor does not advance, after `scan-pages-max` pages, or once `deadline` has passed; each
  page's request is bounded by the time left (P239f)."
  [node port i deadline]
  (loop [after nil, found [], pages 0]
    (when (<= scan-pages-max pages)
      (throw (ex-info "a scan has too many pages" {:pages pages})))
    (let [reply (http/request! node port "POST" (str "/v1/indexes/" transfers-index "/scan")
                               (cond-> {"eq" {"from" i}, "limit" page-limit}
                                 after (assoc "after" after))
                               (request-timeout-ms deadline))]
      (when-not (= 200 (:status reply))
        (throw (ex-info "a scan was not answered" {:reply (select-keys reply [:status :body])})))
      (let [found (into found (map parse-record) (get-in reply [:body "records"]))]
        (if-let [next-page (get-in reply [:body "next"])]
          (do (when (= next-page after)
                (throw (ex-info "a scan's cursor did not advance" {:cursor next-page})))
              (recur next-page found (inc pages)))
          found)))))

(defn count-view!
  "The count view's answer: the number of records, 0 before there is a group."
  [node port deadline]
  (let [reply (http/request! node port "GET" (str "/v1/views/" transfers-view) nil
                             (request-timeout-ms deadline))]
    (when-not (= 200 (:status reply))
      (throw (ex-info "the count view was not answered"
                      {:reply (select-keys reply [:status :body])})))
    (reduce + (for [group (get-in reply [:body "groups"])] (parse-long (get group "count"))))))

(def records-deadline-ms
  "How long the final records read tries: 180 s in all (P239e). Every page and the count view
  is bounded by the time left, so the read ends within it plus one health probe (P239f)."
  180000)

(defn invoke-records
  "The final read of the records, after every pending key is resolved: all eight index keys
  and the count view, through a healthy gateway that answers all of them. It tries for
  `records-deadline-ms` (180 s, plus the request in flight), checked before every try and
  every page of every scan and before the count view, each request bounded by the time left, so
  the total is `records-deadline-ms` plus one health probe. Past it, or with no healthy
  gateway, the op ends :fail :no-answer, which leaves the keys' verdict :unknown with the
  harness's code, never a finding against Nerva (P239f)."
  [test op]
  (let [targets  (keyed/targets test)
        deadline (+ (System/nanoTime) (* records-deadline-ms 1000000))
        expired? #(<= deadline (System/nanoTime))]
    (loop [n 0, previous nil]
      (let [[node port :as target] (keyed/pick targets previous)
            answer (when (and (not (expired?)) (http/healthy? node port))
                     (try {:records (vec (mapcat #(scan-from! node port % deadline)
                                                 (range (count accounts))))
                           :count   (count-view! node port deadline)}
                          (catch IOException _ nil)
                          (catch clojure.lang.ExceptionInfo _ nil)))]
        (cond answer (assoc op :type :ok, :value (:records answer), :count (:count answer),
                            :gateway (str node ":" port))
              (and (< n 20) (not (expired?))) (do (keyed/backoff! (min n 5)) (recur (inc n) target))
              :else (assoc op :type :fail, :error :no-answer))))))

(defrecord Client [node keyed? pending phase drop-reply attempts]
  client/Client
  (open! [this _test node] (assoc this :node node))
  (setup! [_ _test])
  (invoke! [this test op]
    (http/with-errors op (= :transfer (:f op))
      (case (:f op)
        :read     (invoke-read node op)
        :transfer (if keyed?
                    (keyed/invoke-keyed this test op ops)
                    (invoke-transfer node op))
        :view     (invoke-view node op)
        :resolve  (keyed/resolve-pending this test op ops)
        :records  (invoke-records test op))))
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

(def gateway-refusal
  "The :error of a keyed transfer every attempt of which a gateway refused (`keyed`): no
  refusal by Nerva."
  :refused)

(defn final-refusals
  "Nerva's refusals that decided no operation: in the final phase (a :resolve op's attempts) and
  among the attempts of an operation that ended :info (a doubtful key's). As {:error :key}."
  [history]
  (for [op history
        :let [tries (case (:f op)
                      :resolve  (when (#{:ok :info} (:type op)) (mapcat :attempts (:resolved op)))
                      :transfer (when (= :info (:type op)) (:attempts op))
                      nil)]
        attempt tries
        :when (refused? attempt)]
    {:error (keyword (:status attempt)), :gateway (:gateway attempt)}))

(defn refusal-checker
  "Nerva refuses transfers only for expected reasons. A refusal is a failed transfer whose
  error is Nerva's status (a keyword); one that was never sent is not a refusal. A refusal in
  the final phase counts as one in an operation."
  []
  (reify checker/Checker
    (check [_ _test history _opts]
      (let [refused (concat (->> history
                                 (filter #(and (= :fail (:type %)) (= :transfer (:f %))
                                               (keyword? (:error %))
                                               (not= gateway-refusal (:error %)))))
                            (final-refusals history))
            bad     (remove (comp expected-refusals :error) refused)]
        {:valid?      (empty? bad)
         :refusals    (frequencies (map :error refused))
         :unexpected  (vec (take 10 bad))}))))

(defn maybe-committed?
  "Whether a key with no 2xx may have committed all the same: an attempt got no answer, or its
  operation ended :info. A key every attempt of which was refused, or never sent, did not."
  [record]
  (boolean (or (:info? record)
               (some (comp #{:unknown :violation} :kind) (:attempts record)))))

(defn answered-by-refusal?
  "Whether a refusal by Nerva answers a key: one with no attempt that got no answer before it,
  or one of the final phase (`keyed/invoke-keyed` makes the same cut in an operation)."
  [attempts]
  (loop [[attempt & more] attempts, doubt? false]
    (cond (nil? attempt) false
          (and (refused? attempt) (or (:final? attempt) (not doubt?))) true
          :else (recur more (or doubt? (= :unknown (:kind attempt)))))))

(defn record-errors
  "What one final read of the records (`read`, an :ok :records op) gets wrong about `records`,
  the history's {key record}: {:missing :extra :duplicated :wrong :refused-with-record :count},
  each a vector. :refused-with-record: a record of a key that no 2xx answered although a refusal
  did; keys are kept forever, so the key's transaction cannot have committed (P239d)."
  [records read]
  (let [found      (:value read)
        by-id      (group-by :id found)
        committed  (set (for [[k r] records :when (seq (keyed/answers r))] k))
        possible   (set (for [[k r] records
                              :when (and (not (committed k)) (maybe-committed? r))]
                          k))
        wanted     (fn [k] (let [r (records k)]
                             {:id k, :from (account-index (:from r)), :to (account-index (:to r)),
                              :amount (:amount r)}))]
    {:missing    (vec (for [k (sort committed) :when (empty? (by-id k))] {:key k}))
     :extra      (vec (for [id (sort (keys by-id))
                            :when (not (or (committed id) (possible id)))]
                        {:id id}))
     :refused-with-record
     (vec (for [id (sort (keys by-id))
                :when (and (possible id) (answered-by-refusal? (:attempts (records id))))]
            {:id id, :statuses (vec (map :status (filter refused? (:attempts (records id)))))}))
     :duplicated (vec (for [[id rs] by-id :when (< 1 (count rs))] {:id id, :records (count rs)}))
     :wrong      (vec (for [r found
                            :when (and (records (:id r)) (not= (wanted (:id r)) r))]
                        {:found r, :wanted (wanted (:id r))}))
     :count      (let [lo (count committed), hi (+ lo (count possible))]
                   (vec (when-not (and (= (:count read) (count found))
                                       (<= lo (:count read) hi))
                          [{:view (:count read), :listed (count found), :committed lo,
                            :at-most hi}])))}))

(defn refused-after-commit
  "Keys refused after an attempt of them committed: keys are kept forever, so a resend must
  replay, and a cluster that refuses it has lost the key. `conflict` is the exception, which
  `duplicates-by-conflict` takes: the record read caught a second application (P239e)."
  [records]
  (for [[key record] records
        :let [after (rest (drop-while #(not= :committed (:kind %)) (:attempts record)))
              refusals (remove #(= "conflict" (:status %)) (filter refused? after))]
        :when (seq refusals)]
    {:key key, :statuses (vec (map :status refusals))}))

(defn duplicates-by-conflict
  "Keys that committed and were then refused `conflict`: the transfer ran a second time and
  the record read (`op_seen` 0) refused it. This is the duplicate of a re-execution, as the
  retry workload and the canary (which needs a finding named `duplicate`) see it (P239e).
  A resend after an `:unknown` original is not named here but as a refusal: the canary's
  `duplicate` comes from the dropped replies (`drop-reply`), so tuning those can blind it."
  [records]
  (for [[key record] records
        :let [after (rest (drop-while #(not= :committed (:kind %)) (:attempts record)))]
        :when (some #(and (refused? %) (= "conflict" (:status %))) after)]
    {:key key, :conflict true}))

(defn analyze-keys
  "The keyed checks of a history: one op per key (:duplicate) and the records (:records), as
  the namespace doc says. Invalid on any error; :unknown when a key was never answered, or
  nothing read the records (then with the code NRV-E0607: the harness could not read, which says
  nothing about Nerva, P239f); else valid."
  [history]
  (let [records    (keyed/key-records history :transfer)
        reads      (filter #(and (= :records (:f %)) (= :ok (:type %))) history)
        duplicate  (vec (concat (keyed/duplicates records) (duplicates-by-conflict records)))
        errors     (map (partial record-errors records) reads)
        gather     (fn [k] (vec (mapcat k errors)))
        unresolved (vec (for [[k r] records
                              :when (not (or (seq (keyed/answers r))
                                             (answered-by-refusal? (:attempts r))))]
                          {:key k}))
        refused-late (vec (refused-after-commit records))
        broken?    (or (seq duplicate) (seq refused-late)
                       (some #(some seq (vals %)) errors))]
    (cond->
     {:valid?     (cond broken? false
                       (or (seq unresolved) (empty? reads)) :unknown
                       :else true)
     :keys       (count records)
     :committed  (count (filter (comp seq keyed/answers) (vals records)))
     :replayed   (count (filter (comp (partial some :replayed?) keyed/answers) (vals records)))
     :reads      (count reads)
     :records    (:count (last reads))
     :duplicate  {:count (count duplicate), :examples (vec (take 10 duplicate))}
     :refused-after-commit {:count (count refused-late), :examples (vec (take 10 refused-late))}
     :missing    {:count (count (gather :missing)), :examples (vec (take 10 (gather :missing)))}
     :extra      {:count (count (gather :extra)), :examples (vec (take 10 (gather :extra)))}
     :duplicated {:count (count (gather :duplicated)),
                  :examples (vec (take 10 (gather :duplicated)))}
     :refused-with-record {:count (count (gather :refused-with-record)),
                           :examples (vec (take 10 (gather :refused-with-record)))}
     :wrong      {:count (count (gather :wrong)), :examples (vec (take 10 (gather :wrong)))}
     :count-view {:count (count (gather :count)), :examples (vec (take 10 (gather :count)))}
     :unresolved {:count (count unresolved), :examples (vec (take 10 unresolved))}}
      (and (not broken?) (empty? reads)) (assoc :code "NRV-E0607"))))

(defn keys-checker
  []
  (reify checker/Checker
    (check [_ _test history _opts]
      (analyze-keys history))))

(defn generator
  "Transfers (half of them clamped, each under a fresh commit key if `keyed?`), reads and view
  reads, in equal parts."
  [keyed?]
  (gen/mix [(gen/map (fn [op] (cond-> (assoc-in op [:value :clamp?] (< (rand) 0.5))
                                keyed? (assoc-in [:value :key] (keyed/fresh-key))))
                     bank/diff-transfer)
            bank/read
            (repeat {:f :view})]))

(defn final-generator
  "After healing, one read and one view read per worker; with keys, first every pending key
  resent until answered, and one read of the records per worker."
  [keyed?]
  (if keyed?
    (gen/phases (gen/each-thread {:f :resolve})
                (gen/each-thread [{:f :read} {:f :view} {:f :records}]))
    (gen/each-thread [{:f :read} {:f :view}])))

(defn workload
  [opts]
  (let [keyed? (:keyed opts true)]
    {:client          (map->Client {:keyed?     keyed?
                                    :pending    (atom [])
                                    :phase      (atom nil)
                                    :drop-reply (:drop-reply opts 0.1)
                                    :attempts   (:attempts opts 8)})
     :bootstrap       (partial bootstrap! keyed?)
     :test-keys       {:accounts     accounts
                       :total-amount total-amount
                       :max-transfer max-transfer}
     :generator       (generator keyed?)
     :final-generator (final-generator keyed?)
     :checker         (checker/compose
                        (cond-> {:bank      (bank/checker {:negative-balances? false})
                                 :source    (source-checker)
                                 :view      (view-checker)
                                 :refusals  (refusal-checker)}
                          keyed? (assoc :keys (keys-checker))))}))
