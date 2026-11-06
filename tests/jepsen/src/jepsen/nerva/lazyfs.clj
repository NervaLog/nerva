(ns jepsen.nerva.lazyfs
  "The `lose-unfsynced-writes` fault (R1 slice 9): each node's data directory is a LazyFS mount
  (`jepsen.lazyfs`), whose page cache holds every write until it is fsynced (or, as Nerva
  writes, until a write with O_DSYNC returns, which the kernel turns into a FUSE fsync). Killing
  a replica and then clearing that cache is a crash that loses every write the replica never
  made durable: the fault a power cut makes, which `kill` (SIGKILL, the page cache survives)
  cannot.

  LazyFS is built into the node image (`node/Dockerfile`, at a pinned commit), not by
  `jepsen.lazyfs/install!`. The data file is `<mount>/replica.nerva` when the test runs the
  fault (`data-file`), else `<dir>/replica.nerva` as before.

  The fault's op value is `{:scope :minority|:all, :nodes [...]}`; for `:all` also `:crash`, a
  majority killed first. The completion adds `:killed` (the nodes killed) and `:unsynced-bytes`
  (`{node bytes}`: what LazyFS held unsynced, and so lost). Its undo, `:lazyfs-recover`, starts
  the replica and the gateways again on the nodes the fault killed.
  The nemesis kills through `db/kill!` and starts through `db/start!`, so it needs nothing from
  `jepsen.nerva.db`."
  (:require [clojure.string :as str]
            [clojure.tools.logging :refer [info]]
            [jepsen [checker :as checker]
                    [control :as c]
                    [db :as db]
                    [generator :as gen]
                    [nemesis :as n]
                    [util :as util]]
            [jepsen.lazyfs :as lazyfs]
            [jepsen.random :as rand]))

(def fault
  "The name `--nemesis` knows the fault by."
  :lose-unfsynced-writes)

(def mount-name
  "The mount's directory, inside the node's Nerva directory."
  "data")

(def cache-size
  "LazyFS's page cache. Eviction is off, so it holds every write not yet synced. If LazyFS does
  not count O_DSYNC writes as synced (#246), that is everything a replica wrote since its last
  open (the report showed 0.8 to 1.6 MB after a few minutes), so a long run can fill it: size it
  from the run length if a run longer than about an hour needs the fault."
  "128MB")

(defn enabled?
  "Does the test run the fault (so mount LazyFS)?"
  [test]
  (boolean (:lazyfs test)))

(defn lazyfs-map
  "The `jepsen.lazyfs` map for the node directory `dir`: mounted at `dir/data`, backed by
  `dir/data.lazyfs/data`, its log in `dir/data.lazyfs/log` (`log-files`)."
  [dir]
  (assoc (lazyfs/lazyfs {:dir (str dir "/" mount-name)}) :cache-size cache-size))

(defn data-file
  "Where the replica's data file is: in the mount when the test runs the fault, else `plain`."
  [test dir plain]
  (if (enabled? test) (str dir "/" mount-name "/replica.nerva") plain))

(defn mount!
  "Mounts LazyFS on this node and waits for it (bounded by `jepsen.lazyfs`'s own await)."
  [dir]
  (lazyfs/mount! (lazyfs-map dir)))

(defn umount!
  "Unmounts LazyFS on this node; quiet when it is not mounted."
  [dir]
  (lazyfs/umount! (lazyfs-map dir)))

(defn log-files
  "The LazyFS log, copied to `store/` as `lazyfs.log`."
  [dir]
  {(:log-file (lazyfs-map dir)) "lazyfs.log"})

(defn scopes
  "`:minority` always; `:all` (the whole cluster after a quorum crash) only when the test sets
  `:lazyfs-all-nodes`."
  [test]
  (if (:lazyfs-all-nodes test) [:minority :all] [:minority]))

(defn minority-size-max
  "The most nodes of `n` that are a minority: 2 of 5."
  [n]
  (max 1 (dec (util/majority n))))

(defn fault-value
  "A fresh op value against `test`: `:minority` loses writes on 1 to a minority of nodes;
  `:all` (opt in) crashes a majority first, then the rest, and loses writes on every node."
  [test]
  (let [nodes (vec (:nodes test))
        scope (rand/nth (scopes test))]
    (case scope
      :minority {:scope :minority
                 :nodes (vec (take (rand/nth (vec (range 1 (inc (minority-size-max (count nodes))))))
                                   (rand/shuffle nodes)))}
      :all      (let [shuffled (vec (rand/shuffle nodes))]
                  {:scope :all
                   :crash (vec (take (util/majority (count nodes)) shuffled))
                   :nodes (vec (sort nodes))}))))

(defn kill!
  "Kills the replica and gateways on `nodes` through the test's DB; returns `nodes`."
  [test nodes]
  (when (seq nodes)
    (c/on-nodes test nodes (fn [test node] (db/kill! (:db test) test node))))
  (vec nodes))

(def report-wait-polls
  "How many times (200 ms apart) `unsynced-bytes` looks for LazyFS's report in its log."
  10)

(defn report-count
  "How many `un-fsynced` report lines LazyFS's log holds."
  [lz]
  (parse-long (str/trim (c/exec :sh :-c (str "grep -c 'total number of bytes un-fsynced' "
                                              (:log-file lz) " || true")))))

(defn unsynced-bytes
  "Asks LazyFS to report the bytes written and not fsynced, and reads the report from its log;
  nil if it does not appear within `report-wait-polls` polls. The evidence that the fault took
  something: a replica that is quiet has none to lose."
  [lz]
  (let [before (report-count lz)]
    (lazyfs/fifo! lz "lazyfs::unsynced-data-report")
    (loop [polls report-wait-polls]
      (if (< before (report-count lz))
        (some-> (c/exec :sh :-c (str "grep -o 'total number of bytes un-fsynced: [0-9]*' "
                                     (:log-file lz) " | tail -1 | grep -o '[0-9]*$'"))
                str/trim
                parse-long)
        (when (pos? polls)
          (Thread/sleep 200)
          (recur (dec polls)))))))

(def clear-wait-polls
  "How many times `lose!` asks LazyFS for its unsynced bytes after the clear, hoping for 0."
  5)

(defn lose!
  "On `nodes` (the replica must be dead there): reads the unsynced bytes, clears LazyFS's cache,
  then reads them again until they are 0 (`clear-wait-polls`), so the op ends only once the clear
  has been applied and a fast restart's open-time fsync cannot make the lost bytes durable.
  Returns `{node {:before bytes, :after bytes}}`; `:after` is not 0 when the clear was not seen
  to take."
  [test lz nodes]
  (c/on-nodes test nodes
              (fn [_ _]
                (let [before (unsynced-bytes lz)]
                  (lazyfs/lose-unfsynced-writes! lz)
                  {:before before
                   :after  (loop [polls clear-wait-polls]
                             (let [after (unsynced-bytes lz)]
                               (if (or (= 0 after) (zero? polls))
                                 after
                                 (recur (dec polls)))))}))))

(def recover-wait-ms
  "How long a recovery waits for a restarted node to serve (`settle-recovery`). The mid-run wait
  is short: a `kill` or `partition` running beside the fault can keep the node from serving,
  and that is not the fault's doing."
  {:mid 30000, :final 180000})

(def stable-ms
  "How long a restarted node must have been serving, replica alive and every gateway up, before
  the recovery calls it caught up. An approximation: no probe reads the replica's commit_max."
  5000)

(defn settled?
  "Does the probe's outcome show a serving node: the replica alive (or not probed) and no
  gateway down or pending?"
  [o]
  (boolean (and (#{nil :up} (:replica o))
                (empty? (:down o))
                (empty? (:pending o)))))

(defn settle-recovery
  "Calls `probe` (no arguments; returns `{:up :down :pending :replica}`) until the node has been
  `settled?` for `stable-ms` or `wait-ms` have passed; `now` (ms) and `sleep!` are injectable.
  Returns the last outcome with `:waited-ms` and `:settled?`. With no probe: settled at once."
  [probe {:keys [wait-ms stable-ms now sleep!]
          :or   {now #(System/currentTimeMillis), sleep! #(Thread/sleep 500)}}]
  (if-not probe
    {:waited-ms 0, :settled? true}
    (let [start (now)]
      (loop [since nil]
        (let [o     (probe)
              t     (now)
              ok    (settled? o)
              since (when ok (or since t))
              out   (fn [s] (assoc o :waited-ms (- t start), :settled? s))]
          (cond (and ok (<= stable-ms (- t since))) (out true)
                (<= wait-ms (- t start))            (out false)
                :else                               (do (sleep!) (recur since))))))))

(defn start-node!
  "Starts the replica and gateways on this node. A final recovery goes through the DB; a
  mid-run one through `(:start-mid! env)` when there is one, which waits for gateways only
  boundedly (`db/start-node-bounded!`), as a concurrent `kill` or `partition` can keep them from
  ever coming up."
  [test env final?]
  (if-let [start (and (not final?) (:start-mid! env))]
    (start test)
    (db/start! (:db test) test c/*host*)))

(defn recover!
  "Starts the replica and gateways on `nodes`, then settles each (`settle-recovery`, waiting at
  most `recover-wait-ms` for the final or mid-run kind) with `(:probe env)` (called on the node,
  `(probe test)`, returns `{:up :down :pending :replica}`). Returns `{:nodes nodes, :down
  [[node index]...], :pending [...], :replica-down [node...], :unsettled [node...], :waited-ms
  {node ms}}`. `db/start!` reports no outcome, so without this a gateway or replica the
  recovery left down would never be judged (P242b, P242c)."
  [test nodes env final?]
  (let [probe    (:probe env)
        outcomes (c/on-nodes test nodes
                             (fn [test _]
                               (start-node! test env final?)
                               (settle-recovery (when probe #(probe test))
                                                {:wait-ms   (recover-wait-ms (if final? :final :mid))
                                                 :stable-ms stable-ms})))
        pairs    (fn [k] (vec (for [n (sort (keys outcomes)), i (get-in outcomes [n k])]
                                [n i])))]
    {:nodes        (vec nodes)
     :down         (pairs :down)
     :pending      (pairs :pending)
     :replica-down (vec (sort (for [[n o] outcomes :when (= :dead (:replica o))] n)))
     :unsettled    (vec (sort (for [[n o] outcomes :when (not (:settled? o))] n)))
     :waited-ms    (into {} (for [[n o] outcomes] [n (:waited-ms o)]))}))

(defn catch-up!
  "Settles `nodes` again without starting anything: the nodes an earlier recovery left
  unsettled, waited for (at most `(:mid recover-wait-ms)`) before the fault hits more nodes.
  Returns the nodes still not settled."
  [test nodes env]
  (let [probe (:probe env)]
    (vec (sort (for [[n o] (c/on-nodes test nodes
                                       (fn [test _]
                                         (settle-recovery (when probe #(probe test))
                                                          {:wait-ms   (:mid recover-wait-ms)
                                                           :stable-ms stable-ms})))
                     :when (not (:settled? o))]
                 n)))))

(defn nemesis-ops
  "The nemesis ops of `history` as `[invocation completion]` pairs: the one nemesis process
  alternates an invocation and its completion, and Jepsen records both with `:type :info`. An
  invocation left without a completion (an aborted run) is `[inv nil]`."
  [history]
  (loop [ops (filter #(= :nemesis (:process %)) history), open nil, out []]
    (cond (empty? ops) (cond-> out open (conj [open nil]))
          open         (recur (rest ops) nil (conj out [open (first ops)]))
          :else        (recur (rest ops) (first ops) out))))

(defn recover-checker
  "Judges the fault. Invalid, with NRV-E0604, when the final `:lazyfs-recover` left a gateway
  `:down` or `:pending`, the replica dead, or did not finish (an `:exception`): a node that
  cannot serve after the restart is an availability finding. Only the final recovery is judged
  for that (`:final? true`): mid-run, a `kill` or `partition` may have removed quorum.
  Invalid without a code (the harness, not Nerva, is at fault) when the fault was asked for and:
  a fault op threw; no final recovery ran; no fault took (`:faults` 0) or none lost a byte
  (`:lost-bytes` 0, so the run proved nothing); or a clear was not seen to take. A fault op
  skipped because an earlier victim had not caught up (`:skipped`) is counted, not judged.
  Valid with nothing to judge when the run did not ask for the fault."
  []
  (reify checker/Checker
    (check [_ test history _opts]
      (let [pairs    (nemesis-ops history)
            of       (fn [f] (remove nil? (for [[i c] pairs :when (= f (:f i))] c)))
            done     (of fault)
            recovers (of :lazyfs-recover)
            took     (filter #(seq (:killed (:value %))) done)
            skipped  (filter #(:skipped (:value %)) done)
            threw    (filter :exception (concat done recovers))
            finals   (filter #(:final? (:value %)) recovers)
            judged   (filter #(or (:exception %)
                                  (seq (:down (:value %)))
                                  (seq (:pending (:value %)))
                                  (seq (:replica-down (:value %))))
                             finals)
            lost     (reduce + 0 (for [o took, [_ b] (:unsynced-bytes (:value o))] (or b 0)))
            unclear  (for [o took, [n a] (:remaining (:value o)) :when (not= 0 a)] n)
            asked?   (boolean (or (:lazyfs test) (seq pairs)))
            problems (cond-> []
                       (some :exception done)               (conj :fault-threw)
                       (and asked? (empty? finals))         (conj :no-final-recover)
                       (and asked? (empty? took))           (conj :no-fault-took)
                       (and (seq took) (zero? lost))        (conj :no-bytes-lost)
                       (seq unclear)                        (conj :clear-unconfirmed))]
        (cond-> {:valid?     (and (empty? judged) (empty? problems))
                 :faults     (count took)
                 :skipped    (count skipped)
                 :lost-bytes lost
                 :recovers   (count recovers)
                 :final      (count finals)}
          (seq problems) (assoc :problems problems)
          (seq judged)   (assoc :code         "NRV-E0604"
                                :gateways     (vec (distinct (mapcat #(concat (:down (:value %))
                                                                              (:pending (:value %)))
                                                                     judged)))
                                :replica-down (vec (distinct (mapcat #(:replica-down (:value %))
                                                                     judged))))
          (seq threw)    (assoc :exceptions (vec (keep #(let [e (:exception %)]
                                                          (and e (or (:cause e) (str e))))
                                                        threw))))))))

(defn invoke-fault
  "Applies a fault op's value: kill, then lose. A `:crash` majority dies before the rest. Returns
  `[killed lost]`; `lost` is `lose!`'s `{node {:before :after}}`. `queue!` is called with the
  nodes about to be killed before anything runs, so a throw after the kill still leaves them for
  the final recovery."
  [test lz v queue!]
  (let [crash  (vec (:crash v))
        rest-n (vec (remove (set crash) (:nodes v)))
        _      (queue! (into crash rest-n))
        killed (into (kill! test crash) (kill! test rest-n))
        lost   (lose! test lz (:nodes v))]
    (info "Lost unfsynced writes (bytes by node):" lost "after killing" killed)
    [killed lost]))

(defn nemesis
  "Applies `fault` and `:lazyfs-recover`. `dir` is the node's Nerva directory; `env` is
  `{:probe (fn [test]) :start-mid! (fn [test])}` (`package`). The nodes the fault is about to
  kill or has killed and nothing has started yet are `pending`; a recover starts those. The
  nodes a recovery left unsettled are `unsettled`. The fault does not act while either set is
  non-empty after one `catch-up!`: at most a minority of nodes is ever behind (P242c)."
  [dir env]
  (let [lz        (lazyfs-map dir)
        pending   (atom #{})
        unsettled (atom #{})]
    (reify
      n/Reflection
      (fs [_] #{fault :lazyfs-recover})

      n/Nemesis
      (setup! [this _] this)

      (invoke! [_ test o]
        (case (:f o)
          :lose-unfsynced-writes
          (let [late  (vec (remove @pending @unsettled))
                still (when (or (seq @pending) (seq late))
                        (into (vec @pending) (catch-up! test late env)))]
            (if (seq still)
              (assoc o :value (assoc (:value o) :killed [], :skipped :not-caught-up
                                     :behind (vec (sort still))))
              (let [_             (reset! unsettled #{})
                    [killed lost] (invoke-fault test lz (:value o) #(swap! pending into %))]
                (assoc o :value (assoc (:value o)
                                       :killed         killed
                                       :unsynced-bytes (update-vals lost :before)
                                       :remaining      (update-vals lost :after))))))

          :lazyfs-recover
          (let [final? (boolean (:final? (:value o)))
                nodes  (vec (sort @pending))
                r      (recover! test nodes env final?)]
            (swap! pending #(reduce disj % nodes))
            (reset! unsettled (set (:unsettled r)))
            (assoc o :value {:started      nodes
                             :final?       final?
                             :down         (:down r)
                             :pending      (:pending r)
                             :replica-down (:replica-down r)
                             :unsettled    (:unsettled r)
                             :waited-ms    (:waited-ms r)}))))

      (teardown! [_ _]))))

(def perf
  #{{:name "lose-unfsynced-writes", :start #{fault}, :stop #{:lazyfs-recover}, :color "#D0A0E9"}})

(defn package
  "A nemesis package for `fault`; its generator is empty unless `(:faults opts)` has it. `opts`
  also holds `:dir` (the node's Nerva directory), `:node-probe` (`db/node-health`) and
  `:start-mid!` (`db/start-node-bounded!`); core wires them, as `lazyfs` cannot require `db`.
  Its final generator is the one judged recovery: it starts every node the fault killed."
  [opts]
  (let [on? (contains? (:faults opts) fault)]
    {:generator       (when on?
                       (gen/stagger (:interval opts 10)
                                    (gen/flip-flop
                                      (fn [test _]
                                        {:type :info, :f fault, :value (fault-value test)})
                                      (fn [_ _] {:type :info, :f :lazyfs-recover}))))
     :final-generator (when on? [{:type :info, :f :lazyfs-recover, :value {:final? true}}])
     :nemesis         (nemesis (:dir opts) {:probe      (:node-probe opts)
                                            :start-mid! (:start-mid! opts)})
     :perf            (if on? perf #{})}))
