(ns jepsen.nerva.keyed
  "What Botpike does after a lost reply, shared by the workloads that send keyed commits
  (`retry`, and `bank` with `--keys`; R1 brief \"Workload `retry`\"): an operation draws a fresh
  128-bit key from Jepsen's random source, and every attempt resends the same entries under it,
  to another gateway after a backoff, until an answer is definite. After healing, every key
  whose operation did not end definite is resent until a 2xx (or the workload's own definite
  refusal) answers it.

  A workload gives this namespace what differs, as a map (`ops`):
  - `:attempt!`   (fn [target value timeout-ms drop?]) sending one attempt: `attempt!` below,
                  given the workload's commit body;
  - `:definite?`  whether an attempt answers its key (default `definite?`: a 2xx the client
                  kept);
  - `:complete`   (fn [op done]) the :ok or :fail completion for an operation whose attempt
                  `done` was definite;
  - `:entry-keys` the keys of an operation's value that the final phase records beside the
                  attempts.

  And the checks every keyed workload makes of what the attempts show: `duplicates` (one op per
  key), and for `retry` `applied-lies` and `refused-keys`."
  (:require [jepsen [random :as rand]]
            [jepsen.nerva.db :as db]
            [jepsen.nerva.http :as http])
  (:import (java.io IOException)
           (java.util.concurrent ThreadLocalRandom)))

(def request-timeout-ms
  "The gateways' `--request-timeout`, in milliseconds: a gateway answers a request the cluster
  leaves unanswered after this long (3 s), and a short client timeout (below, under 2 s) is
  shorter than that."
  3000)

(def short-timeout-probability 0.25)
(def resolve-deadline-ms
  "How long the whole final phase (all workers, all keys) tries to get pending keys answered.
  Keys left when it passes are reported unresolved, so a run with no healthy gateway ends in
  :unknown within the job's time."
  180000)

(defn rnd
  "A uniform double in [0, 1) from the worker's own source: client choices are not seeded."
  []
  (.nextDouble (ThreadLocalRandom/current)))

(defn rnd-long
  "A uniform long in [lo, hi)."
  [lo hi]
  (.nextLong (ThreadLocalRandom/current) lo hi))

(defn fresh-key
  "A commit key: 128 bits from Jepsen's random source as 32 hex digits, never zero."
  []
  (let [key (format "%016x%016x" (rand/long) (rand/long))]
    (if (= key (apply str (repeat 32 \0)))
      (recur)
      key)))

;; ---------------------------------------------------------------------------------------
;; One attempt

(defn attempt!
  "Sends `value` once, as `body` (a commit request), to gateway [node port] and says what came
  of it, as a map with a :kind: :committed (a 2xx; :op, and :replayed? for a replay;
  :applied, the first add's applied amount, when the reply has it; :dropped? when the client
  discarded the reply on purpose), :refused (`applied: false`; :http, :code, :status),
  :unknown (`applied: \"unknown\"`, or no reply to a request that went out), :not-sent (no
  connection) or :violation (a reply that breaks R4's promise; :reply)."
  [body [node port] timeout-ms drop?]
  (let [base {:gateway (str node ":" port), :timeout-ms timeout-ms}]
    (try
      (let [reply (http/request! node port "POST" "/v1/commit" body timeout-ms)
            rbody (:body reply)]
        (merge base
               (case (http/outcome reply)
                 :ok        (merge {:kind :committed} (http/ok-fields reply)
                                   (when-let [applied (some-> (get-in rbody ["adds" 0 "applied"])
                                                              parse-long)]
                                     {:applied (- applied)})
                                   (when drop? {:dropped? true}))
                 :refused   {:kind :refused, :http (:status reply), :code (get rbody "code"),
                             :status (get rbody "status")}
                 :unknown   {:kind :unknown, :http (:status reply), :code (get rbody "code")}
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
  discarded (:drop-reply is the probability). With :deadline-ns (a System/nanoTime value, one
  for the whole final phase), the client waits for a healthy gateway, keeps the long timeout
  and sends nothing after the deadline passes. With :sink (a volatile), it always holds the
  attempts so far, even if this throws. `ops` is the workload's (see the namespace). Returns
  the attempts."
  [test value ops {:keys [max-attempts deadline-ns drop-reply sink]}]
  (let [targets   (targets test)
        deadline  deadline-ns
        attempt!  (:attempt! ops)
        definite? (:definite? ops definite?)]
    (loop [attempts [], previous nil]
      (let [n      (count attempts)
            target (pick targets previous)]
        (cond
          (and deadline (<= deadline (System/nanoTime))) attempts
          (and deadline (not (apply http/healthy? target)))
          (do (backoff! (min n 5)) (recur attempts target))
          :else
          (let [timeout-ms (if (and max-attempts (< (rnd) short-timeout-probability))
                             (rnd-long 50 2000)
                             http/timeout-ms)
                drop?      (and max-attempts (< (rnd) drop-reply))
                attempts   (conj attempts (attempt! target value timeout-ms drop?))
                _          (when sink (vreset! sink attempts))
                last       (peek attempts)]
            (cond (or (definite? last) (= :violation (:kind last))) attempts
                  (if max-attempts (<= max-attempts (count attempts))
                      (<= deadline (System/nanoTime)))             attempts
                  :else (do (backoff! (count attempts)) (recur attempts target)))))))))

;; ---------------------------------------------------------------------------------------
;; The operation and the final phase

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

(defn attempts-or-crash
  "Runs the attempts for `value`. Returns [attempts crashed?]: if they throw (an interrupt, a
  reply the code did not expect), the attempts made so far are kept, so a 2xx among them still
  counts in the duplicate check, and the interrupt is passed on."
  [test value ops opts]
  (let [sink (volatile! [])]
    (try [(run-attempts! test value ops (assoc opts :sink sink)) false]
         (catch Throwable t
           (when (instance? InterruptedException t)
             (.interrupt (Thread/currentThread)))
           [@sink true]))))

(defn invoke-keyed
  "An operation for `value` (a key and what it commits): :ok or :fail by `:complete` if an
  attempt was definite (a refusal only if no earlier attempt got no answer); :fail :refused if
  every attempt was refused or never sent (the key stays pending, for the final phase); else
  :info. A violation is the protocol checker's."
  [{:keys [pending drop-reply attempts]} test op ops]
  (let [value (:value op)
        definite? (:definite? ops definite?)
        [tries crashed?] (attempts-or-crash test value ops
                                            {:max-attempts attempts, :drop-reply drop-reply})
        done  (first (filter definite? tries))
        ;; A refusal after an attempt that got no answer is no answer: the original may still
        ;; commit (a paused gateway), and Nerva records no key for a refusal.
        doubtful? (and done (= :refused (:kind done)) (some (comp #{:unknown} :kind) tries))
        base  (assoc op :attempts tries)]
    (cond
      (violation-of tries)
      (do (push-pending! pending value)
          (http/violation base (:reply (violation-of tries))))

      (and done (not doubtful?))
      ((:complete ops) base done)

      (and (not crashed?) (every? (comp #{:refused :not-sent} :kind) tries))
      (do (push-pending! pending value)
          (assoc base :type :fail, :error :refused))

      :else
      (do (push-pending! pending value)
          (assoc base :type :info, :error (if crashed? :crashed :unresolved))))))

(defn phase-deadline!
  "The final phase's one deadline (a System/nanoTime value): set by whichever worker asks first,
  `ms` after that moment, then the same for every worker and key."
  [phase ms]
  (or @phase
      (let [fresh (+ (System/nanoTime) (* ms 1000000))]
        (swap! phase #(or % fresh)))))

(defn resolve-pending
  "The final phase: sends every key still pending until it is answered, or the phase's deadline
  passes; keys left then are reported with the attempts made (none), unresolved."
  [{:keys [pending phase]} test op ops]
  (let [definite? (:definite? ops definite?)]
    (loop [entries []]
      (if-let [value (pop-pending! pending)]
        (let [tries (run-attempts! test value ops
                                   {:deadline-ns (phase-deadline! phase resolve-deadline-ms)})
              entry (assoc (select-keys value (:entry-keys ops)) :attempts tries)]
          (if-let [bad (violation-of tries)]
            (http/violation (assoc op :resolved (conj entries entry)) (:reply bad))
            (recur (conj entries entry))))
        (assoc op :type (if (every? #(some definite? (:attempts %)) entries) :ok :info)
               :resolved entries)))))

;; ---------------------------------------------------------------------------------------
;; What the attempts show

(defn key-records
  "Everything the history says about each key: {key {<its value without :key> :attempts}},
  attempts in the order they were sent (the operation's, then the final phase's, which carry
  :final? true), and :info? true when its operation ended :info. `f` names the operations
  that send keys."
  [history f]
  (reduce
    (fn [records {op-f :f, :keys [type value resolved attempts]}]
      (let [add (fn [records {:keys [key attempts] :as value}]
                  (-> records
                      (update key (fnil identity (dissoc value :key :attempts)))
                      (update-in [key :attempts] (fnil into []) attempts)))]
        (cond
          (and (= f op-f) (#{:ok :fail :info} type))
          (cond-> (add records (assoc value :attempts attempts))
            (= :info type) (assoc-in [(:key value) :info?] true))
          (and (= :resolve op-f) (#{:ok :info} type))
          (reduce (fn [records entry]
                    (add records
                         (update entry :attempts (partial mapv #(assoc % :final? true)))))
                  records resolved)
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
