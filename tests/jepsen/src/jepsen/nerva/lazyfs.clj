(ns jepsen.nerva.lazyfs
  "The `lose-unfsynced-writes` fault (R1 slice 9): each node's data directory is a LazyFS mount
  (`jepsen.lazyfs`), whose page cache holds every write until it is fsynced. Stock LazyFS does
  not count a write to a file opened O_DSYNC (Nerva's data file) as synced (#246); the image's
  LazyFS carries `node/lazyfs-osync.patch`, which does (P242d). Killing
  a replica and then clearing that cache is a crash that loses every write the replica never
  made durable: the fault a power cut makes, which `kill` (SIGKILL, the page cache survives)
  cannot.

  LazyFS is built into the node image (`node/Dockerfile`, at a pinned commit plus that patch), not by
  `jepsen.lazyfs/install!`. The data file is `<mount>/replica.nerva` when the test runs the
  fault (`data-file`), else `<dir>/replica.nerva` as before. It is formatted on the backing path
  before the mount (`format-file`), so LazyFS's cache starts empty (P242h).

  The fault's op value is `{:scope :minority|:all, :nodes [...]}`; for `:all` also `:crash`, a
  majority killed first. The completion adds `:killed` (the nodes killed) and `:unsynced-bytes`
  (`{node bytes}`: what LazyFS held unsynced, and so lost), `:remaining`, `:cache-usage`
  (`{node percent}`, LazyFS's cache before the clear: 100 means it wrote through, P242h) and
  `:sentinel` (`{node :gone|:truncated|:survived|:unwritten|:unchecked}`, P242e). Its undo, `:lazyfs-recover`, starts
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
  "LazyFS's page cache, in LazyFS's MB, which is 2^20 bytes (a MiB). Eviction is off, so every
  page written through the mount stays until a clear, but the cache is keyed by file offset: it
  can never hold more than the files on the mount, and the only large one is the replica's data
  file (1,141,374,976 bytes = 1,088.5 MiB, `nerva format --development`). The cache is sized just
  above that file plus `sentinel-slack-bytes` (`cache-bytes`: 1,105 MiB), so it cannot fill
  whatever the run's length (P242i). The memory is not allocated as it is used: LazyFS
  pre-allocates and zero-fills every cache page when it mounts (custom_cache.cpp:33-48,
  page.cpp:33-34), so each node holds the whole 1,105 MiB (about 1.08 GiB a node: 2.2 GiB for the 2 a hosted run mounts, 5.4 GiB for 5 on the host; RSS measured 0.9 to 1.26 GiB)
  from mount to unmount, touched or not. `check-cache-bound!` asserts the bound after the format.
  A full cache would make LazyFS write through, which `lose!` records (`:cache-usage`) and the
  checker judges (`:cache-full`)."
  "1105MB")

(def cache-bytes
  "`cache-size` in bytes: 1,105 MiB."
  (* 1105 1024 1024))

(def sentinel-slack-bytes
  "What the mount may hold beyond the data file: the sentinel (4 KiB) and room for a stray file.
  16 MiB: `cache-bytes` (1,105 MiB) is 0.5 MiB over the file plus this, the cache being sized to
  the MiB because every MiB is resident on every node for the whole run."
  (* 16 1024 1024))

(defn cache-covers?
  "Can the cache hold a data file of `file-bytes` and the slack on top?"
  [file-bytes]
  (boolean (and (integer? file-bytes)
                (<= (+ file-bytes sentinel-slack-bytes) cache-bytes))))

(defn enabled?
  "Does the test run the fault?"
  [test]
  (boolean (:lazyfs test)))

(defn minority-size-max
  "The most nodes of `n` that are a minority: 2 of 5."
  [n]
  (max 1 (dec (util/majority n))))

(defn lazyfs-nodes
  "The nodes whose data directory is a LazyFS mount: every node with `:lazyfs-all-nodes` (the
  R1 host, `check-host-memory!`), else the first minority of the test's nodes, 2 of 5. Each
  mount holds 1,105 MiB from mount to unmount, so a hosted runner (16 GB) puts it on 2 nodes,
  not 5 (P242j). The fault only ever takes these nodes."
  [test]
  (let [nodes (vec (:nodes test))]
    (if (:lazyfs-all-nodes test)
      nodes
      (vec (take (minority-size-max (count nodes)) nodes)))))

(defn mounted?
  "Is `node`'s data directory a LazyFS mount in this test? Never without the fault."
  [test node]
  (boolean (and (enabled? test) (some #{node} (lazyfs-nodes test)))))

(defn mounted-here?
  "`mounted?` for the node `c/*host*` is bound to (inside `c/on-nodes` or a DB setup)."
  [test]
  (mounted? test c/*host*))

(def all-nodes-memory-min-kib
  "The host memory `--lazyfs-all-nodes` needs: 32 GiB, in KiB. Five replicas at about 1.8 GiB, five
  LazyFS mounts at about 0.9 to 1.2 GiB resident (1,105 MiB each, from mount to unmount), the JVM and
  the gateways leave about 0.4 GiB free on a 16 GB runner (measured, P242j), which a longer run
  or a larger heap turns into an OOM kill. The R1 host has 64 GB."
  (* 32 1024 1024))

(def all-nodes-available-min-kib
  "The `MemAvailable` `--lazyfs-all-nodes` also needs: 16 GiB, in KiB. `MemTotal` alone passes a
  64 GB host whose memory another service (the simulation fleet, if its stop failed) holds."
  (* 16 1024 1024))

(defn meminfo-kib
  "The KiB of the /proc/meminfo field `field` (`\"MemTotal\"`) in `meminfo`'s text, or nil."
  [meminfo field]
  (some->> (str meminfo)
           (re-find (re-pattern (str "(?m)^" field ":\\s+(\\d+)\\s+kB")))
           second
           parse-long))

(defn mem-total-kib
  "`MemTotal` in KiB from the text of /proc/meminfo, or nil."
  [meminfo]
  (meminfo-kib meminfo "MemTotal"))

(defn check-host-memory!
  "Refuses `--lazyfs-all-nodes` on a host with less than `all-nodes-memory-min-kib` in total or
  `all-nodes-available-min-kib` available (or whose memory cannot be read): throws NRV-E0607 before
  anything starts, a harness refusal that says nothing about Nerva (its ex-data has `:refusal
  true`, which `core/-main` prints as one line). `meminfo` is the text of the harness host's
  /proc/meminfo; that is the machine the replicas run on only because run.sh starts the nodes as
  Docker containers on it. Nothing without the option."
  [test meminfo]
  (when (:lazyfs-all-nodes test)
    (let [total (mem-total-kib meminfo)
          avail (meminfo-kib meminfo "MemAvailable")]
      (when-not (and total avail
                     (>= total all-nodes-memory-min-kib)
                     (>= avail all-nodes-available-min-kib))
        (throw (ex-info (str "NRV-E0607: --lazyfs-all-nodes needs a host with at least 32 GiB of "
                             "memory and 16 GiB of it available (this one has "
                             (if (and total avail)
                               (str (quot total 1024) " MiB, " (quot avail 1024) " MiB available")
                               "an unreadable /proc/meminfo")
                             "): LazyFS on all 5 nodes leaves a 16 GB runner about 0.4 GiB free. "
                             "Run it on the R1 host (ops/jepsen) with nothing else running (stop "
                             "sim-fleet); a hosted run puts LazyFS on a minority of nodes (P242j)")
                        {:refusal true, :total-kib total, :available-kib avail
                         :min-kib all-nodes-memory-min-kib}))))))

(defn lazyfs-map
  "The `jepsen.lazyfs` map for the node directory `dir`: mounted at `dir/data`, backed by
  `dir/data.lazyfs/data`, its log in `dir/data.lazyfs/log` (`log-files`)."
  [dir]
  (assoc (lazyfs/lazyfs {:dir (str dir "/" mount-name)}) :cache-size cache-size))

(defn data-file
  "Where the replica's data file is: in the mount when this node has one (`mounted-here?`), else `plain`."
  [test dir plain]
  (if (mounted-here? test) (str dir "/" mount-name "/replica.nerva") plain))

(defn backing-dir
  "Where LazyFS keeps the files behind the mount at `dir/data`: `dir/data.lazyfs/data`."
  [dir]
  (:data-dir (lazyfs-map dir)))

(defn format-file
  "Where `nerva format` writes the data file: on the backing path when this node has a mount,
  not through the mount, so the format's writes do not fill LazyFS's cache (P242h); else `plain`.
  The replica opens `data-file` and finds the same file."
  [test dir plain]
  (if (mounted-here? test) (str (backing-dir dir) "/replica.nerva") plain))

(defn check-cache-bound!
  "Throws, a harness failure, when the data file just formatted at `format-file` does not fit the
  cache (`cache-covers?`), so a change to the format's size cannot silently bring back a cache
  that fills (P242i). Run on the node, after the format and before the mount. Nothing with the
  fault off."
  [test dir plain]
  (when (mounted-here? test)
    (let [path (format-file test dir plain)
          size (parse-long (str/trim (c/exec :stat :-c "%s" path)))]
      (when-not (cache-covers? size)
        (throw (ex-info (str "NRV-E0607: the data file (" size " bytes) does not fit LazyFS's "
                             "cache (" cache-size "); raise cache-bytes and cache-size (P242i)")
                        {:size size, :cache cache-bytes}))))))

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

(defn fault-value
  "A fresh op value against `test`: `:minority` loses writes on 1 to a minority of the
  `lazyfs-nodes` (all of them with `--lazyfs-all-nodes`, else the 2 that have a mount);
  `:all` (opt in) crashes a majority first, then the rest, and loses writes on every node.
  `forced`, when given, is the scope instead of a draw (the generator's first fault, P242i)."
  [test & [forced]]
  (let [nodes (vec (:nodes test))
        mounts (lazyfs-nodes test)
        scope  (or forced (rand/nth (scopes test)))]
    (case scope
      :minority {:scope :minority
                 :nodes (vec (take (rand/nth (vec (range 1 (inc (minority-size-max (count nodes))))))
                                   (rand/shuffle mounts)))}
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
  "How many times (200 ms apart) `await-line` looks for LazyFS's answer in its log."
  10)

(def report-pattern
  "The two lines LazyFS ends a report with: the byte total, or, when nothing is unsynced, that
  every block is synced (no total is printed then: hosted run 42202316064)."
  "total number of bytes un-fsynced\\|all data blocks are synced")

(def usage-pattern
  "The line `lazyfs::display-cache-usage` logs: `cache usage (%pages) is 29.3%`."
  "cache usage (")

(defn- count-lines
  "How many lines of LazyFS's log match `pattern`."
  [lz pattern]
  (parse-long (str/trim (c/exec :sh :-c (str "grep -c '" pattern "' " (:log-file lz)
                                              " || true")))))

(defn parse-report
  "The bytes a report-ending line says are unsynced: the total, 0 for \"all data blocks are
  synced\", nil for anything else."
  [line]
  (cond (str/includes? line "all data blocks are synced") 0
        :else (some->> (re-find #"un-fsynced: (\d+)" line) second parse-long)))

(defn parse-usage
  "The percent of its cache LazyFS says it uses, from a `display-cache-usage` line; nil for
  anything else."
  [line]
  (some->> (re-find #"is ([0-9.]+)%" line) second parse-double))

(defn cache-full?
  "Is `usage` (percent) a full cache? LazyFS writes through exactly at 100 (`cache_full`)."
  [usage]
  (boolean (and usage (<= 100.0 usage))))

(defn- await-line
  "Sends `command` to LazyFS and returns the last log line matching `pattern` that it wrote in
  answer; nil if none appears within `report-wait-polls` polls (about 2 s plus the fifo's 1 s)."
  [lz command pattern]
  (let [before (count-lines lz pattern)]
    (lazyfs/fifo! lz command)
    (loop [polls report-wait-polls]
      (if (< before (count-lines lz pattern))
        (c/exec :sh :-c (str "grep '" pattern "' " (:log-file lz) " | tail -1"))
        (when (pos? polls)
          (Thread/sleep 200)
          (recur (dec polls)))))))

(defn unsynced-bytes
  "Asks LazyFS to report the bytes written and not fsynced, and reads the report from its log;
  nil if it does not appear. The evidence that the fault took something: a replica that is quiet
  has none to lose."
  [lz]
  (some-> (await-line lz "lazyfs::unsynced-data-report" report-pattern) parse-report))

(defn cache-usage
  "Asks LazyFS how full its cache is, in percent; nil if it does not answer. A full cache writes
  through, and then a clear loses nothing."
  [lz]
  (some-> (await-line lz "lazyfs::display-cache-usage" usage-pattern) parse-usage))

(def clear-wait-polls
  "How many times `clear!` asks LazyFS for its unsynced bytes after a clear, hoping for 0."
  5)

(def sentinel-name
  "The file `lose!` writes on the mount, without syncing it, before the clear (P242e, P242h)."
  "lazyfs-sentinel")

(def sentinel-bytes
  "The sentinel's size: one 4 KiB block."
  4096)

(def fs-timeout-s
  "A command on the mount (`dd`, `stat`, `rm`) is killed after this long: a wedged LazyFS does
  not fail them, it blocks them, and the single nemesis worker must not wait forever."
  10)

(defn classify-sentinel
  "What became of the sentinel: `written` is its size before the clear, `after` its size after
  (nil when the file is gone, `:timeout` when the mount did not answer). `:gone` and `:truncated`
  mean the clear lost the unsynced bytes; `:survived` means it did not (the fault did not bite:
  a full cache wrote the sentinel through); `:unwritten` means the sentinel never reached
  `written` bytes before the clear, and `:unchecked` that its size after was not read (a timeout,
  or `:error`: `stat` failed for a reason other than the file not existing, such as a dead
  mount): nothing was proved."
  [written after]
  (cond (not= sentinel-bytes written) :unwritten
        (keyword? after)              :unchecked
        (nil? after)                  :gone
        (< after written)             :truncated
        :else                         :survived))

(defn- on-mount
  "Runs `cmd` on this node under `timeout`; returns `[exit-code output]`, 124 or 137 when it was
  killed. The output is stdout, and stdout and stderr together when `both?`."
  [cmd & [both?]]
  (let [out (str/trim (c/exec :sh :-c (str "out=$(timeout -k 2 " fs-timeout-s " " cmd
                                           (if both? " 2>&1" " 2>/dev/null")
                                           "); echo \"$?\"; echo \"$out\"")))
        [rc & more] (str/split-lines out)]
    [(parse-long rc) (str/join "\n" more)]))

(defn- size-of
  "The size in bytes of `path` on this node; nil only when it does not exist (ENOENT), `:timeout`
  when the mount did not answer within `fs-timeout-s`, `:error` for any other failure of `stat`
  (a dead FUSE mount says \"Transport endpoint is not connected\"): that is not proof that a clear
  dropped the file."
  [path]
  (let [[rc out] (on-mount (str "stat -c %s " path) true)]
    (cond (zero? rc)                          (or (parse-long out) :error)
          (#{124 137} rc)                     :timeout
          (str/includes? out "No such file")  nil
          :else                               :error)))

(defn clear!
  "Clears LazyFS's cache, then reads its unsynced bytes again until they are 0
  (`clear-wait-polls`); returns the last reading (not 0 when the clear was not seen to take)."
  [lz]
  (lazyfs/lose-unfsynced-writes! lz)
  (loop [polls clear-wait-polls]
    (let [after (unsynced-bytes lz)]
      (if (or (= 0 after) (zero? polls))
        after
        (recur (dec polls))))))

(defn lose!
  "On `nodes` (the replica must be dead there): reads the cache usage and the unsynced bytes,
  writes the sentinel on the mount without syncing it, clears LazyFS's cache, then reads until
  the unsynced bytes are 0 (`clear!`), so the op ends only once the clear has been applied and a
  fast restart's open-time fsync cannot make the lost bytes durable. Returns
  `{node {:before bytes, :after bytes, :sentinel kw, :cache-usage percent}}`: `:before` is what
  the replica left unsynced; `:after` is not 0 when the clear was not seen to take; `:sentinel`
  is `classify-sentinel`'s verdict, which proves the clear bit even when the replica, writing
  O_DSYNC, left nothing unsynced (P242e); `:cache-usage` is how full the cache was, 100 when
  LazyFS was writing through and the clear lost nothing (P242h). The sentinel comes before the
  first clear, so the first fault on a node is checked too; the cache starts empty because the
  data file is formatted outside the mount (`format-file`). The sentinel is removed afterwards.
  Each command on the mount is bounded (`fs-timeout-s`); the longest a node takes is about 75 s
  (two reads of 3 s, the fifo's 1 s and up to 6 reports of 3 s, and five mount commands of 10
  s), and nodes go in parallel."
  [test lz nodes]
  (c/on-nodes test nodes
              (fn [_ _]
                (let [path    (str (:dir lz) "/" sentinel-name)
                      usage   (cache-usage lz)
                      before  (unsynced-bytes lz)
                      _       (on-mount (str "rm -f " path))
                      _       (on-mount (str "dd if=/dev/zero of=" path " bs=" sentinel-bytes
                                             " count=1 status=none"))
                      written (size-of path)
                      after   (clear! lz)
                      status  (classify-sentinel written (size-of path))]
                  (on-mount (str "rm -f " path))
                  {:before      before
                   :after       after
                   :sentinel    status
                   :cache-usage usage}))))

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
  `(probe test)`, returns `{:up :down :pending :replica}`). `watch` are nodes settled and judged
  without starting anything (the final recovery watches every node the fault has hit, P242d).
  Returns `{:nodes nodes, :judged [node...], :down [[node index]...], :pending [...],
  :replica-down [node...], :unsettled [node...], :waited-ms {node ms}}`. `db/start!` reports no
  outcome, so without this a gateway or replica the recovery left down would never be judged
  (P242b, P242c)."
  [test nodes env final? watch]
  (let [probe    (:probe env)
        watch    (vec (remove (set nodes) watch))
        settle   (fn [test]
                   (settle-recovery (when probe #(probe test))
                                    {:wait-ms   (recover-wait-ms (if final? :final :mid))
                                     :stable-ms stable-ms}))
        outcomes (merge (c/on-nodes test nodes
                                    (fn [test _]
                                      (start-node! test env final?)
                                      (settle test)))
                        (when (seq watch)
                          (c/on-nodes test watch (fn [test _] (settle test)))))
        pairs    (fn [k] (vec (for [n (sort (keys outcomes)), i (get-in outcomes [n k])]
                                [n i])))]
    {:nodes        (vec nodes)
     :judged       (vec (sort (keys outcomes)))
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
  `:unknown`, with NRV-E0607 (the harness, not Nerva, is at fault; the run proved nothing), when
  the fault was asked for and:
  a fault op threw; no final recovery ran; the final recovery judged no node (it settles every
  node the fault hit, P242d); no fault took (`:faults` 0); a clear was not seen to take
  (`:remaining` not 0); or the sentinel `lose!` writes unsynced before each clear (P242e) was not
  proved lost: it `:survived` (`:sentinel-survived`, with a `:reason`: the fault did not bite) or
  was not checked; or a fault met a full cache (`:cache-full`: LazyFS wrote through, so the
  clear lost nothing, P242h). The bytes LazyFS lost (`:lost-bytes`) are reported, not judged, unless the
  test sets `:lazyfs-strict-sync` (the hosted canary, P242j), when any is `:valid? false`: with the
  image's O_DSYNC patch (P242d) Nerva leaves none unsynced, so only the sentinel shows the
  clear bit; a run that loses some carries `:warnings [:unsynced-bytes-lost]` (not judged: a Nerva
  that stopped syncing, or an unpatched LazyFS, shows here, P242i). `:cache-usage-unread` counts the
  faults whose cache usage LazyFS did not answer, so `:cache-usage-max` is not mistaken for a
  complete measurement. A fault op skipped because an earlier victim had not caught up (`:skipped`) is
  counted, not judged.
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
            sentinel (for [o took, n (keys (:unsynced-bytes (:value o)))]
                       (get-in (:value o) [:sentinel n]))
            survived (count (filter #{:survived} sentinel))
            unproved (count (remove #{:gone :truncated :survived} sentinel))
            ;; Asked for: the test runs the fault, or the history holds one of its ops. A run
            ;; with only kill, partition or gateway ops (the nightly) never asked (P242h).
            asked?   (boolean (or (:lazyfs test) (seq done) (seq recovers)))
            scopes   (frequencies (map #(:scope (:value %)) took))
            usage    (for [o took, [n u] (:cache-usage (:value o)) :when u] [n u])
            unread   (count (for [o took, [_ u] (:cache-usage (:value o)) :when (nil? u)] 1))
            full     (vec (distinct (for [[n u] usage :when (cache-full? u)] n)))
            problems (cond-> []
                       (some :exception done)               (conj :fault-threw)
                       (and asked? (empty? finals))         (conj :no-final-recover)
                       (and (seq took) (seq finals)
                            (every? (comp empty? :judged :value) finals))
                                                            (conj :final-judged-nothing)
                       (and asked? (empty? took))           (conj :no-fault-took)
                       (seq full)                           (conj :cache-full)
                       (pos? survived)                      (conj :sentinel-survived)
                       (pos? unproved)                      (conj :sentinel-unchecked)
                       (seq unclear)                        (conj :clear-unconfirmed))
            strict?  (boolean (and (:lazyfs-strict-sync test) (pos? lost)))]
        (cond-> {:valid?     (cond (seq judged)   false
                                   strict?        false
                                   (seq problems) :unknown
                                   :else          true)
                 :faults     (count took)
                 :scopes     scopes
                 :skipped    (count skipped)
                 :lost-bytes lost
                 :cache-usage-max (reduce max 0 (map second usage))
                 :cache-usage-unread unread
                 :sentinel   (frequencies sentinel)
                 :recovers   (count recovers)
                 :final      (count finals)}
          (seq problems) (assoc :problems problems)
          (pos? lost)    (assoc :warnings [:unsynced-bytes-lost])
          strict?        (assoc :reason (str "LazyFS held " lost " unsynced bytes after the kill: "
                                             "with `--lazyfs-strict-sync` that is a failure (an "
                                             "unpatched LazyFS, or a Nerva that stopped syncing)"))
          strict?        (assoc :code "NRV-E0608")
          (and (seq problems) (not (seq judged)) (not strict?)) (assoc :code "NRV-E0607")
          (seq full)     (assoc :cache-full full)
          (pos? survived) (assoc (if strict? :harness-reason :reason)
                                 (str "the fault did not bite: an unsynced sentinel file "
                                      "survived a LazyFS clear on " survived " node(s)"))
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
        unsettled (atom #{})
        hit       (atom #{})]
    (reify
      n/Reflection
      (fs [_] #{fault :lazyfs-recover})

      n/Nemesis
      (setup! [this _] this)

      (invoke! [_ test o]
        (case (:f o)
          :lose-unfsynced-writes
          (let [late   (vec (remove @pending @unsettled))
                behind (if (seq late) (catch-up! test late env) [])
                _      (reset! unsettled (set behind))
                still  (into (vec @pending) behind)]
            (if (seq still)
              (assoc o :value (assoc (:value o) :killed [], :skipped :not-caught-up
                                     :behind (vec (sort still))))
              (let [queue!        #(do (swap! pending into %) (swap! hit into %))
                    [killed lost] (invoke-fault test lz (:value o) queue!)]
                (assoc o :value (assoc (:value o)
                                       :killed         killed
                                       :unsynced-bytes (update-vals lost :before)
                                       :remaining      (update-vals lost :after)
                                       :sentinel       (update-vals lost :sentinel)
                                       :cache-usage    (update-vals lost :cache-usage))))))

          :lazyfs-recover
          (let [final? (boolean (:final? (:value o)))
                nodes  (vec (sort @pending))
                watch  (when final? (into @hit @unsettled))
                r      (recover! test nodes env final? watch)]
            (swap! pending #(reduce disj % nodes))
            ;; Only the nodes this recovery settled leave `unsettled`: a recover with no nodes
            ;; (after a skipped fault) settled nothing (P242d).
            (swap! unsettled #(into (reduce disj % (:judged r)) (:unsettled r)))
            (assoc o :value {:started      nodes
                             :judged       (:judged r)
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
  (let [on?    (contains? (:faults opts) fault)
        first? (atom true)]
    {:generator       (when on?
                       (gen/stagger (:interval opts 10)
                                    (gen/flip-flop
                                      (fn [test _]
                                        {:type :info, :f fault
                                         :value (fault-value
                                                  test
                                                  ;; The first fault is `:all` when the test
                                                  ;; allows it: a canary draws one (P242i).
                                                  (when (and (:lazyfs-all-nodes test)
                                                             (compare-and-set! first? true false))
                                                    :all))})
                                      (fn [_ _] {:type :info, :f :lazyfs-recover}))))
     :final-generator (when on? [{:type :info, :f :lazyfs-recover, :value {:final? true}}])
     :nemesis         (nemesis (:dir opts) {:probe      (:node-probe opts)
                                            :start-mid! (:start-mid! opts)})
     :perf            (if on? perf #{})}))
