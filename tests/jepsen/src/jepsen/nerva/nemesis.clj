(ns jepsen.nerva.nemesis
  "Faults on the `nerva api` gateways alone, the replica left running: the gateway is killed,
  cut off from every replica, or paused. A gateway is a client's way into the cluster, so these
  are the faults `retry` exists for: a client resends to another gateway.

  The generator draws concrete targets from the gateways the test runs (`db/all-gateways`), so
  no fault names a gateway that does not exist. An op's value is `{:gateways [[node index] ...]}`
  (a partition: `{:scope :own|:majority|:all, :cut [[node index [replica-node ...]] ...]}`;
  an undo: `{:gateways :all}`); the completion adds `:hit`, the `[node index]` pairs acted on.
  `package` is a nemesis package beside `combined/db-package`, with its own heal."
  (:require [jepsen [control :as c]
                    [generator :as gen]
                    [nemesis :as n]]
            [jepsen.nemesis.combined :as combined]
            [jepsen.nerva.db :as db]
            [jepsen.random :as rand]
            [jepsen.util :as util]))

(def faults
  "The faults that name a gateway fault; `:gateway` is all three."
  #{:gateway-kill :gateway-partition :gateway-pause})

(def kill-targets
  "The brief's targets for a kill: one gateway, one node's gateways, a minority of nodes'."
  [:one :node :minority])

(def pause-targets
  "The brief's targets for a pause: one gateway, one node's gateways."
  [:one :node])

(def partition-scopes
  "The replicas a cut gateway loses: its own node's, a majority of the replicas, all."
  [:own :majority :all])

(defn enabled
  "The gateway faults `fault-set` asks for: `:gateway` asks for all."
  [fault-set]
  (if (contains? fault-set :gateway)
    faults
    (into #{} (filter faults) fault-set)))

(defn draw-gateways
  "The `[node index]` pairs of the gateways `kind` names, drawn from those `test` runs: `:one`
  gateway, `:node` (all of one node's), `:minority` (all of a minority of nodes'). Never empty,
  never a gateway that does not exist."
  [test kind]
  (let [nodes (vec (:nodes test))]
    (case kind
      :one      [(rand/nth (db/all-gateways test))]
      :node     (db/node-gateways test (rand/nth nodes))
      :minority (into [] (mapcat #(db/node-gateways test %))
                      (take (max 1 (dec (util/majority (count nodes)))) (rand/shuffle nodes))))))

(defn draw-cuts
  "`[[node index [replica-node ...]] ...]` for `gateways` and a `scope`: `:own` cuts each from
  its own node's replica, `:majority` from one drawn majority of replicas, `:all` from all."
  [test gateways scope]
  (let [nodes (vec (:nodes test))
        maj   (vec (take (util/majority (count nodes)) (rand/shuffle nodes)))]
    (mapv (fn [[node index]]
            [node index (case scope :own [node], :majority maj, :all nodes)])
          gateways)))

(defn fault-value
  "A fresh op value for `fault` against `test`."
  [test fault]
  (case fault
    :gateway-kill      {:gateways (draw-gateways test (rand/nth kill-targets))}
    :gateway-pause     {:gateways (draw-gateways test (rand/nth pause-targets))}
    :gateway-partition (let [scope (rand/nth partition-scopes)]
                         {:scope scope
                          :cut   (draw-cuts test (draw-gateways test (rand/nth kill-targets))
                                            scope)})))

(defn op
  "An info op for the nemesis."
  [f value]
  {:type :info, :f f, :value value})

(def opposite
  "What undoes each fault."
  {:gateway-kill      :gateway-start
   :gateway-partition :gateway-heal
   :gateway-pause     :gateway-resume})

(def undo-value
  "The value of an undo: every gateway on every node."
  {:gateways :all})

(defn fault-generator
  "Alternates `fault` on a fresh target and its undo on every node and gateway."
  [fault]
  (gen/flip-flop (fn [test _] (op fault (fault-value test fault)))
                 (gen/repeat (op (opposite fault) undo-value))))

(defn plan
  "Op value `v` as `{node [arg ...]}`: for a partition the `[index replicas]` pairs, else the
  gateway indices (`:all` is every gateway the test runs)."
  [test v]
  (cond (:cut v)              (reduce (fn [m [node index dests]]
                                        (update m node (fnil conj []) [index dests]))
                                      {} (:cut v))
        (= :all (:gateways v)) (into {} (map (fn [n] [n (range (db/gateways test n))]))
                                     (:nodes test))
        :else                 (reduce (fn [m [node index]] (update m node (fnil conj []) index))
                                      {} (:gateways v))))

(defn act!
  "Does `f` on this node for `arg`; returns the gateway indices it acted on."
  [test f arg]
  (case f
    :gateway-kill      (db/kill-gateways! arg)
    :gateway-start     (db/start-gateways! test)
    :gateway-partition (db/partition-gateways! arg)
    :gateway-heal      (db/heal-gateways! test)
    :gateway-pause     (db/signal-gateways! arg "-STOP")
    :gateway-resume    (db/signal-gateways! arg "-CONT")))

(defn nemesis
  "Applies the gateway faults. Every f here is distinct from `combined/db-nemesis`'s and
  `partition-nemesis`'s, so the three compose."
  []
  (reify
    n/Reflection
    (fs [_] (into (set (keys opposite)) (vals opposite)))

    n/Nemesis
    (setup! [this _] this)

    (invoke! [_ test o]
      (let [plan (plan test (:value o))
            hit  (if (empty? plan)
                   {}
                   (c/on-nodes test (keys plan)
                               (fn [_ node] (c/su (act! test (:f o) (get plan node))))))]
        (assoc o :value (assoc (:value o) :hit (vec (for [[node indices] (sort-by key hit)
                                                          index indices]
                                                      [node index]))))))

    (teardown! [_ _])))

(def perf
  #{{:name "gateway-kill",      :start #{:gateway-kill},      :stop #{:gateway-start},  :color "#E9A4D0"}
    {:name "gateway-partition", :start #{:gateway-partition}, :stop #{:gateway-heal},   :color "#E9C4A0"}
    {:name "gateway-pause",     :start #{:gateway-pause},     :stop #{:gateway-resume}, :color "#A0E9C4"}})

(def order
  "The faults in the order their undos run: resume, heal, then start."
  [:gateway-pause :gateway-partition :gateway-kill])

(defn used
  "The gateway faults `opts` asks for, in `order`."
  [opts]
  (filterv (enabled (:faults opts)) order))

(defn undo-ops
  "Undo ops for `faults`, each on every gateway."
  [faults]
  (let [ops (mapv #(op (opposite %) undo-value) faults)]
    (when (seq ops) ops)))

(defn heal-package
  "Only a final generator: resume and heal. It is listed before `combined/db-package`, whose
  final `:start` waits on every gateway: a paused or cut-off one would hold it up."
  [opts]
  {:final-generator (undo-ops (filterv #{:gateway-pause :gateway-partition} (used opts)))
   :perf            #{}})

(defn package
  "A nemesis package for the gateway faults in `(:faults opts)` (`:gateway`, or any of
  `faults`). Its final generator starts killed gateways; `heal-package` resumes and heals
  first, and it is listed after the replica packages, so gateways start once replicas do."
  [opts]
  (let [used (used opts)]
    {:generator       (when (seq used)
                       (gen/stagger (:interval opts combined/default-interval)
                                    (gen/mix (mapv fault-generator used))))
     :final-generator (undo-ops (filterv #{:gateway-kill} used))
     :nemesis         (nemesis)
     :perf            (into #{} (filter #(contains? (set used) (first (:start %)))) perf)}))
