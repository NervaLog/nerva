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
            [jepsen [control :as c]
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
  "LazyFS's page cache. Eviction is off, so it holds every unsynced write: a replica's unsynced
  writes are a few MiB at most, and 128 MiB bounds a stuck fsync."
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

(defn lose!
  "On `nodes` (the replica must be dead there): reads the unsynced bytes, then clears LazyFS's
  cache. Returns `{node bytes}`."
  [test lz nodes]
  (c/on-nodes test nodes (fn [_ _]
                           (let [bytes (unsynced-bytes lz)]
                             (lazyfs/lose-unfsynced-writes! lz)
                             bytes))))

(defn recover!
  "Starts the replica and gateways on `nodes` through the test's DB; returns `nodes`."
  [test nodes]
  (c/on-nodes test nodes (fn [test node] (db/start! (:db test) test node)))
  (vec nodes))

(defn invoke-fault
  "Applies a fault op's value: kill, then lose. A `:crash` majority dies before the rest."
  [test lz v]
  (let [crash  (vec (:crash v))
        rest-n (vec (remove (set crash) (:nodes v)))
        killed (into (kill! test crash) (kill! test rest-n))
        lost   (lose! test lz (:nodes v))]
    (info "Lost unfsynced writes (bytes by node):" lost "after killing" killed)
    [killed lost]))

(defn nemesis
  "Applies `fault` and `:lazyfs-recover`. `dir` is the node's Nerva directory. The nodes the
  fault killed and nothing has started yet are `pending` (at most the test's nodes); a recover
  starts those."
  [dir]
  (let [lz      (lazyfs-map dir)
        pending (atom #{})]
    (reify
      n/Reflection
      (fs [_] #{fault :lazyfs-recover})

      n/Nemesis
      (setup! [this _] this)

      (invoke! [_ test o]
        (case (:f o)
          :lose-unfsynced-writes
          (let [[killed lost] (invoke-fault test lz (:value o))]
            (swap! pending into killed)
            (assoc o :value (assoc (:value o) :killed killed :unsynced-bytes lost)))

          :lazyfs-recover
          (let [nodes (vec (sort @pending))]
            (recover! test nodes)
            (swap! pending #(reduce disj % nodes))
            (assoc o :value {:started nodes}))))

      (teardown! [_ _]))))

(def perf
  #{{:name "lose-unfsynced-writes", :start #{fault}, :stop #{:lazyfs-recover}, :color "#D0A0E9"}})

(defn package
  "A nemesis package for `fault`; its generator is empty unless `(:faults opts)` has it. `opts`
  also holds `:dir` (the node's Nerva directory). Its final generator starts every node the
  fault killed."
  [opts]
  (let [on? (contains? (:faults opts) fault)]
    {:generator       (when on?
                       (gen/stagger (:interval opts 10)
                                    (gen/flip-flop
                                      (fn [test _]
                                        {:type :info, :f fault, :value (fault-value test)})
                                      (fn [_ _] {:type :info, :f :lazyfs-recover}))))
     :final-generator (when on? [{:type :info, :f :lazyfs-recover}])
     :nemesis         (nemesis (:dir opts))
     :perf            (if on? perf #{})}))
