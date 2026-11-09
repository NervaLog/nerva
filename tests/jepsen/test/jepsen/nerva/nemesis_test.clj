(ns jepsen.nerva.nemesis-test
  "The gateway nemesis's shapes: which faults a spec asks for, what the generator emits and
  what the final generator undoes."
  (:require [clojure.java.shell :as shell]
            [clojure.set :as set]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [jepsen.checker :as checker]
            [jepsen.control :as c]
            [jepsen.generator :as gen]
            [jepsen.generator.context :as ctx]
            [jepsen.nemesis :as n]
            [jepsen.nemesis.combined :as combined]
            [jepsen.nerva.core :as core]
            [jepsen.nerva.db :as db]
            [jepsen.nerva.nemesis :as nemesis]))

(def test-map {:nodes ["n1" "n2" "n3"], :concurrency 1})

(defn emitted
  "The first `limit` ops a generator hands the nemesis thread."
  [generator limit]
  (let [context (ctx/context test-map)]
    (loop [g generator, ops [], context context]
      (if (= limit (count ops))
        ops
        (let [[o g'] (gen/op g test-map context)]
          (cond (nil? o) ops
                (= :pending o) ops
                :else (let [o (assoc o :process :nemesis)]
                        (recur (gen/update g' test-map context o)
                               (conj ops o)
                               (ctx/busy-thread context (:time o) :nemesis)))))))))

(defn package [& fault-keys]
  (nemesis/package {:db nil, :faults (set fault-keys), :interval 0}))

(deftest enabled-faults
  (is (= nemesis/faults (nemesis/enabled #{:gateway})))
  (is (= #{:gateway-pause} (nemesis/enabled #{:gateway-pause :kill})))
  (is (= #{} (nemesis/enabled #{:kill :partition}))))

(deftest no-gateway-fault-no-generator
  (let [p (package :partition)]
    (is (nil? (:generator p)))
    (is (nil? (:final-generator p)))
    (is (empty? (:perf p)))))

(deftest replica-kill-gets-the-final-start
  (testing "the kill nemesis's :start settles briefly, so the final phase judges the gateways"
    (let [p (package :kill :partition)]
      (is (nil? (:generator p)) "no gateway fault in the main phase")
      (is (empty? (:perf p)))
      (is (= [{:f :gateway-start, :value {:gateways :all, :final? true}}]
             (map #(select-keys % [:f :value]) (:final-generator p))))))
  (testing "pause and partition alone never kill a gateway"
    (is (nil? (:final-generator (package :gateway-pause))))))

(deftest replica-start-is-short
  (let [calls (atom [])]
    (with-redefs [db/start-gateways! (fn [_] (swap! calls conj :short)
                                       {:up [0] :down [1] :pending [2]})
                  db/start-gateway-until-up! (fn [& _] (swap! calls conj :long) :up)
                  c/*host* "n1"]
      (is (= {:up [0] :down [1] :pending [2]} (db/restart-api! {})))
      (is (= [:short] @calls) "no 35 s waits and no restart loop in the main phase"))))

(deftest heal-script-confirms-the-rule-is-gone
  (let [script (db/heal-script ["10.0.0.1" "10.0.0.2"] 1)]
    (is (re-find #"seq 8" script) "the delete loop is bounded")
    (is (re-find #"-D OUTPUT .*nerva-gw1" script))
    (is (re-find #"-C OUTPUT .*nerva-gw1" script) "confirms with -C after deleting")
    (is (re-find #"exit 1" script) "a rule that is left fails the heal")
    (is (re-find #"10.0.0.1 10.0.0.2" script))))

(defn- run-heal
  "Runs `heal-script` for gateway 1 under a stub `iptables` that behaves as `mode`:
  `nouser` (no such gateway user), `gone` (-D then -C exit 1), `deletes` (two -D succeed, then exit 1, -C exit 1), `stuck`
  (-D exit 1, -C exit 0), `broken` (everything exit 3). Returns {:exit :out :err}."
  [mode]
  (let [dir  (.toFile (java.nio.file.Files/createTempDirectory
                        "stub" (make-array java.nio.file.attribute.FileAttribute 0)))
        ipt  (java.io.File. dir "iptables")
        cnt  (java.io.File. dir "count")]
    (spit ipt (str "#!/bin/sh\n"
                   "case \"$MODE\" in broken) exit 3;; esac\n"
                   "for a in \"$@\"; do case $a in\n"
                   "  -D) if [ \"$MODE\" = deletes ]; then c=$(cat " cnt " 2>/dev/null || echo 0);"
                   " [ $c -lt 2 ] && { echo $((c+1)) > " cnt "; exit 0; }; fi; exit 1;;\n"
                   "  -C) [ \"$MODE\" = stuck ] && exit 0; exit 1;;\n"
                   "esac; done; exit 9\n"))
    (.setExecutable ipt true)
    (let [id (java.io.File. dir "id")]
      (spit id "#!/bin/sh\n[ \"$MODE\" = nouser ] && exit 1; exit 0\n")
      (.setExecutable id true))
    (let [r (shell/sh "sh" "-c" (db/heal-script ["10.0.0.1"] 1)
                      :env {"PATH" (str dir ":/usr/bin:/bin") "MODE" mode})]
      {:exit (:exit r), :out (str/trim (:out r)), :err (:err r)})))

(deftest heal-script-runs-against-iptables
  (testing "no rule left: healed, nothing deleted"
    (is (= {:exit 0 :out "0"} (select-keys (run-heal "gone") [:exit :out]))))
  (testing "rules deleted, then gone: counts them"
    (is (= {:exit 0 :out "2"} (select-keys (run-heal "deletes") [:exit :out]))))
  (testing "a rule that cannot be deleted fails with NRV-E0607"
    (let [r (run-heal "stuck")]
      (is (= 1 (:exit r)))
      (is (re-find #"NRV-E0607: gateway 1: the rule to 10.0.0.1 is still in place" (:err r)))))
  (testing "a gateway user that does not exist yet has no rule (iptables would exit 2 on its name)"
    (let [r (run-heal "nouser")]
      (is (= 0 (:exit r)))
      (is (= "0" (:out r)))))
  (testing "iptables itself broken is not read as healed"
    (let [r (run-heal "broken")]
      (is (= 1 (:exit r)))
      (is (re-find #"NRV-E0607.*cannot be checked.*exit 3" (:err r))))))

(deftest teardown-heals-and-cleans-up
  (let [calls (atom [])
        boom  (fn [_] (throw (ex-info "iptables broke" {})))]
    (with-redefs [db/heal-gateways! boom
                  db/kill-all!      #(swap! calls conj :kill)
                  jepsen.control/exec* (fn [& _] (swap! calls conj :rm) "")]
      (testing "after a run the failure is logged, never rethrown: analysis must run"
        (is (nil? (db/teardown-node! {} true)))
        (is (= [:kill :rm] @calls) "the node is still cleaned"))
      (reset! calls [])
      (testing "before a run (cycle!) it is rethrown, after the cleanup"
        (is (thrown-with-msg? clojure.lang.ExceptionInfo #"iptables broke"
                              (db/teardown-node! {} false)))
        (is (= [:kill :rm] @calls))))))

(deftest signal-checks-ownership-and-reads-the-pidfile-once
  (let [script (db/signal-script 1 "-STOP")]
    (is (= 1 (count (re-seq #"cat " script))) "one read of the pidfile")
    (is (re-find #"= nerva-gw1 \] && kill -STOP \$p$" script) "the owner is checked before the kill")))

(deftest signal-skips-gateways-that-are-not-owned-or-gone
  (let [sent (atom [])]
    (with-redefs [jepsen.control/exec* (fn [& args]
                                         (swap! sent conj args)
                                         (when (re-find #"nerva-gw0" (str args))
                                           (throw (ex-info "not ours" {})))
                                         "")]
      (is (= [1] (db/signal-gateways! [0 1] "-STOP")))
      (is (= 2 (count @sent)) "one command per gateway, nothing else"))))

(defn heal-package [& fault-keys]
  (nemesis/heal-package {:faults (set fault-keys)}))

(deftest gateway-covers-all-three
  (let [p (package :gateway)]
    (is (= #{"gateway-kill" "gateway-partition" "gateway-pause"} (set (map :name (:perf p)))))
    (is (= [:gateway-resume :gateway-heal] (map :f (:final-generator (heal-package :gateway)))))
    (is (= [nil true] (map #(:final? (:value %)) (:final-generator (heal-package :gateway))))
        "only the heal is judged by the checker")
    (is (= [:gateway-start] (map :f (:final-generator p))))
    (is (every? #(= :all (:gateways (:value %))) (:final-generator (heal-package :gateway))))
    (is (= [{:gateways :all, :final? true}] (map :value (:final-generator p)))
        "the final start retries")))

(deftest one-fault-only
  (let [p (package :gateway-partition)]
    (is (= ["gateway-partition"] (map :name (:perf p))))
    (is (nil? (:final-generator p)))
    (is (= [:gateway-heal] (map :f (:final-generator (heal-package :gateway-partition)))))))

(def five {:nodes ["n1" "n2" "n3" "n4" "n5"], :gateways 2})

(deftest node-gateways-respect-the-topology
  (testing "--gateways 2: only the first three nodes run two"
    (is (= [["n1" 0] ["n1" 1]] (db/node-gateways five "n1")))
    (is (= [["n3" 0] ["n3" 1]] (db/node-gateways five "n3")))
    (is (= [["n4" 0]] (db/node-gateways five "n4")))
    (is (= [["n5" 0]] (db/node-gateways five "n5")))
    (is (= 8 (count (db/all-gateways five)))))
  (testing "--gateways 1: one each"
    (is (= 5 (count (db/all-gateways (assoc five :gateways 1)))))
    (is (= [["n1" 0]] (db/node-gateways (assoc five :gateways 1) "n1")))))

(deftest drawn-targets-exist
  (doseq [gateways [1 2], :let [t (assoc five :gateways gateways)
                                have (set (db/all-gateways t))]
          kind [:one :node :minority]
          _ (range 100)]
    (let [drawn (nemesis/draw-gateways t kind)]
      (is (seq drawn))
      (is (set/subset? (set drawn) have))
      (is (apply distinct? drawn))
      (when (= :minority kind)
        (is (<= (count (distinct (map first drawn))) 2))))))

(deftest cuts-follow-the-scope
  (let [gws (db/all-gateways five)]
    (doseq [[node index dests] (nemesis/draw-cuts five gws :own)]
      (is (= [node] dests)))
    (is (every? #(= (set (:nodes five)) (set (nth % 2))) (nemesis/draw-cuts five gws :all)))
    (let [cuts (nemesis/draw-cuts five gws :majority)]
      (is (= 1 (count (distinct (map #(nth % 2) cuts)))))
      (is (= 3 (count (nth (first cuts) 2)))))))

(deftest fault-values-name-existing-gateways
  (let [t (assoc five :gateways 1)
        have (set (db/all-gateways t))]
    (doseq [f nemesis/faults, _ (range 100)
            :let [v (nemesis/fault-value t f)
                  hit (if (= :gateway-partition f) (map #(vec (take 2 %)) (:cut v)) (:gateways v))]]
      (is (seq hit))
      (is (set/subset? (set hit) have))
      (when (= :gateway-pause f) (is (<= (count hit) 2))))
    (is (= #{:own :majority :all}
           (set (repeatedly 200 #(:scope (nemesis/fault-value t :gateway-partition))))))))

(deftest plan-groups-by-node
  (is (= {"n1" [0 1], "n4" [0]} (nemesis/plan five {:gateways [["n1" 0] ["n1" 1] ["n4" 0]]})))
  (is (= {"n1" [[0 ["n2"]]]} (nemesis/plan five {:cut [["n1" 0 ["n2"]]]})))
  (is (= [0 1] (get (nemesis/plan five {:gateways :all}) "n2")))
  (is (= [0] (get (nemesis/plan five {:gateways :all}) "n4"))))

(deftest combined-final-phase-heals-before-starting
  (let [opts {:nodes (:nodes five), :nemesis [:kill :partition :gateway], :nemesis-interval 0}
        ;; n/compose throws on fs that overlap, so building the package shows they are disjoint.
        pkg  (core/nemesis-package opts (db/db (fn [_ _])))
        fs   (vec (keep :f (flatten (:final-generator pkg))))
        at   #(.indexOf ^java.util.List fs %)]
    (is (every? #(<= 0 (at %)) [:gateway-resume :gateway-heal :start :gateway-start]) (pr-str fs))
    (is (< (at :gateway-resume) (at :start)))
    (is (< (at :gateway-heal) (at :start)))
    (is (< (at :start) (at :gateway-start)))))

(deftest nemesis-fs-are-distinct
  (let [gw (set (n/fs (nemesis/nemesis)))
        others (into #{:start :kill :pause :resume :start-partition :stop-partition} [])]
    (is (= 6 (count gw)))
    (is (empty? (set/intersection gw others)))))

(deftest core-takes-the-faults
  (is (every? core/faults [:gateway :gateway-kill :gateway-partition :gateway-pause]))
  (is (some #{[:gateway]} core/all-nemeses))
  (is (some #{[:kill :partition :gateway]} core/all-nemeses)))

(deftest backoff-is-bounded
  (is (= [500 1000 2000 4000 4000 4000] (map db/gateway-backoff-ms (range 1 7))))
  (is (<= (apply + (map db/gateway-backoff-ms (range 1 db/gateway-start-tries)))
          30000)))

(deftest gateway-rule-names-the-gateway-user
  (is (re-find #"--uid-owner nerva-gw1 .*--dport 3000 -j DROP" (db/gateway-rule 1 "10.0.0.1")))
  (is (not= (db/gateway-rule 0 "10.0.0.1") (db/gateway-rule 1 "10.0.0.1"))))

(deftest gateway-rule-names-the-replica
  (is (re-find #"-d 10.0.0.2 --dport 3000" (db/gateway-rule 0 "10.0.0.2")))
  (is (not= (db/gateway-rule 0 "10.0.0.1") (db/gateway-rule 0 "10.0.0.2"))))

(deftest kill-reaches-only-running-gateways
  (let [killed (atom [])]
    (with-redefs [db/gateway-running? #{0 2}
                  jepsen.control.util/stop-daemon! (fn [pidfile] (swap! killed conj pidfile))]
      (is (= [0 2] (db/kill-gateways! [0 1 2])))
      (is (= 2 (count @killed)))
      (is (= [] (db/kill-gateways! [1]))))))

(deftest partition-cuts-only-running-gateways
  (let [rules (atom [])]
    (with-redefs [db/gateway-running? #{1}
                  jepsen.control/exec (fn [& args] (swap! rules conj args))]
      (is (= [1] (db/partition-gateways! [[0 ["n1"]] [1 ["n1" "n2"]]])))
      (is (= 2 (count @rules)) "no rule for the gateway that is down")
      (is (= [] (db/partition-gateways! [[0 ["n1"]]]))))))

(deftest start-outcome-keeps-dead-and-pending-apart
  (is (= {:up [0] :down [1] :pending [2]} (db/start-outcome {0 :up, 1 :dead, 2 :pending})))
  (is (= {:up [] :down [] :pending []} (db/start-outcome {}))))

(defn fake-loop
  "`settle-states` over a fake clock: each probe advances it by `probe-ms`, each sleep by 500.
  `script` maps an index to its states, one per probe, the last repeating. Returns
  `[states probes-by-index]`."
  [initial script probe-ms deadline-ms]
  (let [clock  (atom 0)
        probes (atom {})
        probe  (fn [i]
                 (swap! clock + probe-ms)
                 (let [n (get @probes i 0)]
                   (swap! probes update i (fnil inc 0))
                   (let [seq (script i)] (nth seq (min n (dec (count seq)))))))]
    [(db/settle-states initial probe {:deadline deadline-ms
                                      :now      (fn [] @clock)
                                      :sleep!   #(swap! clock + 500)})
     @probes]))

(deftest settle-re-probes-a-pending-gateway-until-it-is-up
  (let [[states probes] (fake-loop {0 :pending} {0 [:pending :pending :up]} 100 10000)]
    (is (= {0 :up} states))
    (is (= {0 3} probes))))

(deftest settle-ends-a-pending-gateway-that-dies-as-dead
  (let [[states probes] (fake-loop {0 :pending, 1 :pending}
                                   {0 [:pending :dead], 1 [:up]} 100 10000)]
    (is (= {0 :dead, 1 :up} states))
    (is (= {0 2, 1 1} probes) "a settled gateway is not probed again")))

(deftest settle-leaves-a-gateway-pending-at-the-deadline
  (let [[states probes] (fake-loop {0 :pending} {0 [:pending]} 100 2000)]
    (is (= {0 :pending} states))
    (is (<= 4 (get probes 0) 6) "re-probed until the deadline, then it stops")
    (is (= {:up [] :down [] :pending [0]} (db/start-outcome states)))))

(deftest settle-checks-the-deadline-after-a-whole-round
  (let [[states probes] (fake-loop {0 :pending, 1 :pending} {0 [:pending], 1 [:pending]} 3000 1000)]
    (is (= {0 :pending, 1 :pending} states))
    (is (= {0 1, 1 1} probes) "one round, though the first probe already passed the deadline")))

(deftest start-reports-down-and-pending-apart
  (let [started (atom [])]
    (with-redefs [db/gateway-running? (fn [i] (= 3 i))
                  db/start-gateway!   (fn [_ i] (swap! started conj i))
                  db/start-settle-s   0
                  db/gateway-state    {0 :up, 1 :dead, 2 :pending}
                  c/*host*            "n1"]
      (is (= {:up [0] :down [1] :pending [2]}
             (db/start-gateways! {:nodes ["n1"] :gateways 4})))
      (is (= [0 1 2] @started) "the running gateway 3 is left alone"))))

(defn- fake-gateways
  "Redefs for a node `n1` whose gateway `i` is in `(states i)`; a `:pending` one answers once
  `(up? i)`; `starts` and `kills` count what the code does."
  [states starts kills]
  {#'db/start-gateway!      (fn [_ i] (swap! starts update i (fnil inc 0)))
   #'db/gateway-backoff-ms  (constantly 0)
   #'db/gateway-wait-s      (constantly 0)
   #'db/gateway-state       (fn [i] (first (get @states i)))
   #'jepsen.control.util/stop-daemon! (fn [pidfile] (swap! kills conj pidfile))
   #'jepsen.nerva.http/healthy?
   (fn [_ port] (= :up (first (get @states (- port (db/gateway-port 0))))))
   #'jepsen.control.util/daemon-running?
   (fn [pidfile] (not= :dead (first (get @states (if (= pidfile (db/gateway-pidfile 0)) 0 1)))))})

(deftest final-start-retries-until-every-gateway-is-up
  (let [starts (atom {}), kills (atom [])
        ;; gateway 1 is dead until its third start, then up
        states (atom {})
        fakes  (assoc (fake-gateways states starts kills)
                      #'db/start-gateway!
                      (fn [_ i]
                        (swap! starts update i (fnil inc 0))
                        (swap! states assoc i
                               [(if (<= (if (= 1 i) 3 1) (get @starts i)) :up :dead)])))]
    (reset! states {0 [:dead], 1 [:dead]})
    (with-redefs-fn (assoc fakes #'db/gateway-state (fn [i] (first (get @states i))))
      (fn []
        (binding [c/*host* "n1"]
          (is (= {:up [0 1] :down [] :pending []}
                 (db/start-gateways-final! {:nodes ["n1"] :gateways 2})))
          (is (= {0 1, 1 3} @starts)))))))

(deftest final-start-reports-a-gateway-that-never-comes-up
  (let [starts (atom {}), kills (atom []), states (atom {0 [:dead]})]
    (with-redefs-fn (fake-gateways states starts kills)
      (fn []
        (binding [c/*host* "n1"]
          (is (= {:up [] :down [0] :pending []}
                 (db/start-gateways-final! {:nodes ["n1"] :gateways 1}))
              "returned, not thrown: the checker fails the run")
          (is (= {0 db/gateway-start-tries} @starts)))))))

(deftest a-gateway-whose-probe-threw-does-not-hide-the-others
  (let [starts (atom {}), kills (atom []), states (atom {0 [:dead], 1 [:up]})]
    (with-redefs-fn (assoc (fake-gateways states starts kills)
                           #'db/gateway-state
                           (fn [i] (if (= 1 i)
                                     (throw (ex-info "ssh went away" {}))
                                     (first (get @states i)))))
      (fn []
        (binding [c/*host* "n1"]
          (let [r (db/start-gateways-final! {:nodes ["n1"] :gateways 2})]
            (is (= [0] (:down r)) "gateway 0 stays down, with its own state")
            (is (= [] (:up r)))
            (is (= "gateway 1: ssh went away" (:error r))
                "gateway 1 is its own error entry")))))))

(declare check-final pair final-op)

(deftest a-probe-error-reaches-the-op-beside-the-states
  (with-redefs [db/start-gateways-final! (fn [_] {:up [] :down [0] :pending []
                                                   :error "gateway 1: ssh"})]
    (let [r (nemesis/act! {} :gateway-start :all true)]
      (is (= {:hit [] :down [0] :pending [] :error "gateway 1: ssh"} r))
      (let [c (nemesis/completion {"n1" r})]
        (is (= [["n1" 0]] (:down c)))
        (is (= [["n1" "gateway 1: ssh"]] (:error c)))
        (let [v (check-final (pair (final-op :value (merge {:final? true} c))))]
          (is (false? (:valid? v)) "a gateway left down is a finding, whatever else threw")
          (is (= "NRV-E0604" (:code v))))))))

(deftest final-start-waits-for-a-pending-gateway
  (testing "pending, then up: no restart"
    (let [starts (atom {}), kills (atom []), states (atom {0 [:pending]})
          probes (atom 0)]
      (with-redefs-fn (assoc (fake-gateways states starts kills)
                             #'db/wait-for-gateway
                             (fn [_ _] (swap! probes inc) :up))
        (fn []
          (binding [c/*host* "n1"]
            (is (= {:up [0] :down [] :pending []}
                   (db/start-gateways-final! {:nodes ["n1"] :gateways 1})))
            (is (= {} @starts))
            (is (empty? @kills)))))))
  (testing "pending, then exits: started again"
    (let [starts (atom {}), kills (atom []), states (atom {0 [:pending]})]
      (with-redefs-fn (assoc (fake-gateways states starts kills)
                             #'db/wait-for-gateway (let [n (atom 0)]
                                                     (fn [_ _] (if (= 1 (swap! n inc)) :dead :up)))
                             #'db/start-gateway!
                             (fn [_ i]
                               (swap! starts update i (fnil inc 0))
                               (swap! states assoc i [:up])))
        (fn []
          (binding [c/*host* "n1"]
            (is (= {:up [0] :down [] :pending []}
                   (db/start-gateways-final! {:nodes ["n1"] :gateways 1})))
            (is (= {0 1} @starts))))))))

(deftest start-retry-waits-for-a-pending-gateway-instead-of-restarting-it
  (let [starts (atom 0), waits (atom [:pending :up])]
    (with-redefs [db/start-gateway!   (fn [_ _] (swap! starts inc))
                  db/wait-for-gateway (fn [_ _] (let [s (first @waits)] (swap! waits rest) s))
                  db/gateway-wait-s   (constantly 0)]
      (is (= :up (db/start-gateway-until-up! {} 0)))
      (is (= 1 @starts) "one start: the pending wait was repeated"))
    (reset! waits (repeat :pending))
    (reset! starts 0)
    (with-redefs [db/start-gateway!   (fn [_ _] (swap! starts inc))
                  db/wait-for-gateway (fn [_ _] (let [s (first @waits)] (swap! waits rest) s))
                  db/gateway-wait-s   (constantly 0)]
      (is (= :pending (db/start-gateway-until-up! {} 0)))
      (is (= 1 @starts) "still one start; bounded by gateway-waits-max"))))

(deftest a-wait-is-longer-than-the-registration-window
  (is (= 35 (db/gateway-wait-s {})) "the 30 s default plus the margin")
  (is (= 8 (db/gateway-wait-s {:request-timeout 3000}))))

(deftest final-op-routes-to-the-final-start
  (let [calls (atom [])]
    (with-redefs [db/start-gateways!       (fn [_] (swap! calls conj :plain)
                                             {:up [0] :down [] :pending []})
                  db/start-gateways-final! (fn [_] (swap! calls conj :final)
                                             {:up [0] :down [] :pending []})]
      (is (= {:hit [0] :down [] :pending []} (nemesis/act! {} :gateway-start :all false)))
      (is (= {:hit [0] :down [] :pending []} (nemesis/act! {} :gateway-start :all true)))
      (is (= [:plain :final] @calls)))))

(deftest a-final-start-that-throws-keeps-the-other-nodes
  (with-redefs [nemesis/act! (fn [_ _ arg _] (if (= :bad arg)
                                               (throw (ex-info "boom" {}))
                                               {:hit [0]}))]
    (is (= {:error "boom"} (nemesis/act-on-node! {} :gateway-start :bad true)))
    (is (= {:hit [0]} (nemesis/act-on-node! {} :gateway-start :ok true)))
    (is (= {:hit [["n1" 0]] :error [["n2" "boom"]]}
           (nemesis/completion {"n1" {:hit [0]} "n2" {:error "boom"}})))))

(deftest an-interrupted-final-start-is-not-swallowed
  (with-redefs [nemesis/act! (fn [& _] (throw (InterruptedException. "stop")))]
    (is (thrown? InterruptedException (nemesis/act-on-node! {} :gateway-start :all true)))))

(defn- check-final [history]
  (checker/check (nemesis/final-start-checker) {} history {}))

(defn- final-op [& {:as extra}]
  (merge {:type :info, :f :gateway-start, :process :nemesis
          :value {:gateways :all, :final? true, :hit [["n1" 0]]}}
         extra))

(defn- pair
  "A final start as Jepsen records it: the invocation (an `:info` op with the planned value),
  then the completion `done` (also `:info`, the same process, the value plus `:hit`)."
  [done]
  [(-> done (dissoc :exception) (assoc :value {:gateways :all, :final? true})) done])

(deftest final-start-pairs-invocation-and-completion
  (testing "one start is one completion, not two"
    (let [r (check-final (pair (final-op)))]
      (is (true? (:valid? r)))
      (is (= 1 (:final-starts r)))))
  (testing "an invocation with no completion is a harness failure"
    (let [r (check-final [(first (pair (final-op)))])]
      (is (= :unknown (:valid? r)))
      (is (= 0 (:final-starts r)))
      (is (= 1 (:incomplete r)))
      (is (= "NRV-E0607" (:code r)))))
  (testing "a completed start followed by one that never finished"
    (let [h (concat (pair (final-op)) [(first (pair (final-op)))])]
      (is (= :unknown (:valid? (check-final h))))
      (is (= 1 (:final-starts (check-final h)))))))

(deftest final-start-checker
  (testing "valid: every gateway up, or no final start at all"
    (is (true? (:valid? (check-final (pair (final-op))))))
    (is (true? (:valid? (check-final []))))
    (is (true? (:valid? (check-final [{:type :info :f :gateway-start
                                       :value {:down [["n1" 0]]}}])))
        "a main-phase start may leave a gateway down"))
  (testing "an exception is the harness, not Nerva"
    (let [r (check-final (pair (final-op :exception {:cause "boom"})))]
      (is (= :unknown (:valid? r)))
      (is (= "NRV-E0607" (:code r)))
      (is (= ["boom"] (:exceptions r)))))
  (testing "a gateway down"
    (let [r (check-final (pair (final-op :value {:final? true :hit [] :down [["n2" 1]]})))]
      (is (false? (:valid? r)))
      (is (= [["n2" 1]] (:gateways r)))
      (is (= "NRV-E0604" (:code r)))))
  (testing "a gateway pending"
    (let [r (check-final (pair (final-op :value {:final? true :hit [] :pending [["n3" 0]]})))]
      (is (false? (:valid? r)))
      (is (= [["n3" 0]] (:gateways r)))))
  (testing "a node whose start threw is the harness"
    (let [r (check-final (pair (final-op :value {:final? true :hit [] :error [["n1" "ssh"]]})))]
      (is (= :unknown (:valid? r)))
      (is (= "NRV-E0607" (:code r)))))
  (testing "a gateway down wins over a harness failure"
    (let [r (check-final (concat (pair (final-op :value {:final? true :hit [] :down [["n2" 1]]
                                                         :error [["n1" "ssh"]]}))))]
      (is (false? (:valid? r)))
      (is (= "NRV-E0604" (:code r))))))

(deftest a-failed-heal-fails-the-run
  (let [heal (fn [& {:as extra}] (merge {:type :info :f :gateway-heal :process :nemesis
                                         :value {:gateways :all}} extra))]
    (testing "no heal, or a clean one, no final start expected: valid"
      (is (true? (:valid? (check-final []))))
      (is (true? (:valid? (check-final [(heal) (heal :value {:gateways :all :final? true
                                                             :hit []})])))))
    (testing "the final heal's per-node error is the harness (gateway-partition alone has no final start)"
      (let [r (check-final [(heal :value {:gateways :all :final? true})
                            (heal :value {:gateways :all :final? true :hit []
                                          :error [["n1" "NRV-E0607: gateway 0 ..."]]})])]
        (is (= :unknown (:valid? r)))
        (is (= "NRV-E0607" (:code r)))
        (is (= [[["n1" "NRV-E0607: gateway 0 ..."]]] (:heal-failures r)))))
    (testing "a final heal that threw"
      (let [r (check-final [(heal :value {:gateways :all :final? true} :exception {:cause "boom"})])]
        (is (= :unknown (:valid? r)))
        (is (= ["boom"] (:heal-failures r)))))
    (testing "a mid-run heal that threw is reported, not judged, when the final heal is clean"
      (let [r (check-final [(heal :exception {:cause "boom"})
                            (heal :value {:gateways :all :final? true :hit []})])]
        (is (true? (:valid? r)))
        (is (= ["boom"] (:mid-run-heal-failures r)))
        (is (nil? (:code r)))))))

(deftest an-expected-final-start-that-never-ran-fails-the-run
  (let [check (fn [faults h] (checker/check (nemesis/final-start-checker)
                                            {:nemesis-faults faults} h {}))]
    (doseq [faults [#{:kill} #{:gateway} #{:gateway-kill} #{:kill :partition} #{:lose-unfsynced-writes}]]
      (let [r (check faults [])]
        (is (= :unknown (:valid? r)) (str faults))
        (is (= 0 (:final-starts r)))
        (is (= 1 (:expected r)))
        (is (= "NRV-E0607" (:code r)))))
    (is (true? (:valid? (check #{:kill} (pair (final-op))))) "it ran")
    (is (true? (:valid? (check #{:partition} []))) "nothing to expect without a kill")
    (is (true? (:valid? (check #{:gateway-pause :gateway-partition} []))))))

(deftest replica-restarting-faults-get-the-final-start
  (doseq [f [:kill :lose-unfsynced-writes]]
    (is (true? (nemesis/final-start? {:faults #{f}})) (str f))
    (is (= [:gateway-start] (map :f (:final-generator (package f)))) (str f)))
  (is (false? (nemesis/final-start? {:faults #{:partition}}))))

(deftest the-test-map-carries-the-faults
  (let [t (core/nerva-test {:workload :bank, :nemesis [:kill :partition], :time-limit 1
                            :rate 1, :recovery-time 1})]
    (is (= #{:kill :partition} (:nemesis-faults t)))))

(deftest every-workload-composes-the-final-start-checker
  (doseq [workload [:bank :retry]]
    (let [t   (core/nerva-test {:workload workload, :nemesis [:gateway], :time-limit 1
                                :rate 1, :recovery-time 1})
          gws (:gateways (:checkers (:checker t)))
          ;; the same composition the test's :checker is: its :valid? is the merge of the keys'
          r   (checker/check (checker/compose {:stats (checker/unbridled-optimism)
                                               :gateways gws})
                             {} (pair (final-op :value {:final? true :hit [] :down [["n1" 0]]})) {})
          u   (checker/check (checker/compose {:stats (checker/unbridled-optimism)
                                               :gateways gws})
                             {} (pair (final-op :exception {:cause "boom"})) {})]
      (is (some? gws) "a key of the test's top-level checker")
      (is (false? (:valid? (:gateways r))))
      (is (false? (:valid? r)) "the top-level :valid?, which jepsen_report.py reads")
      (is (= :unknown (:valid? u)) "a harness failure is not a pass at the top level"))))
