(ns jepsen.nerva.nemesis
  "Faults on the `nerva api` gateways alone, the replica left running: the gateway is killed,
  cut off from every replica, or paused. A gateway is a client's way into the cluster, so these
  are the faults `retry` exists for: a client resends to another gateway.

  An op's value is `{:nodes <node spec> :gateway 0|1|:all}`; a node without that gateway does
  nothing. `package` is a nemesis package beside `combined/db-package`, with its own heal."
  (:require [jepsen [control :as c]
                    [generator :as gen]
                    [nemesis :as n]]
            [jepsen.nemesis.combined :as combined]
            [jepsen.nerva.db :as db]
            [jepsen.random :as rand]))

(def faults
  "The faults that name a gateway fault; `:gateway` is all three."
  #{:gateway-kill :gateway-partition :gateway-pause})

(def targets
  "Node specs a gateway fault may pick (as `combined/db-nodes` reads them)."
  [:one :minority :majority])

(def gateway-choices
  "Which gateway of a node: the first, the second or both."
  [0 1 :all])

(defn enabled
  "The gateway faults `fault-set` asks for: `:gateway` asks for all."
  [fault-set]
  (if (contains? fault-set :gateway)
    faults
    (into #{} (filter faults) fault-set)))

(defn target
  "A fresh op value: some nodes, some gateway."
  []
  {:nodes (rand/nth targets), :gateway (rand/nth gateway-choices)})

(defn op
  "An info op for the nemesis."
  [f value]
  {:type :info, :f f, :value value})

(def opposite
  "What undoes each fault."
  {:gateway-kill      :gateway-start
   :gateway-partition :gateway-heal
   :gateway-pause     :gateway-resume})

(defn fault-generator
  "Alternates `fault` on a fresh target and its undo on every node and gateway."
  [fault]
  (gen/flip-flop (fn [_ _] (op fault (target)))
                 (gen/repeat (op (opposite fault) {:nodes :all, :gateway :all}))))

(defn nemesis
  "Applies the gateway faults. Every f here is distinct from `combined/db-nemesis`'s and
  `partition-nemesis`'s, so the three compose."
  [db]
  (reify
    n/Reflection
    (fs [_] (into (set (keys opposite)) (vals opposite)))

    n/Nemesis
    (setup! [this _] this)

    (invoke! [_ test o]
      (let [{:keys [nodes gateway]} (:value o)
            targets (combined/db-nodes test db nodes)
            act     (case (:f o)
                      :gateway-kill      #(db/kill-gateways! test gateway)
                      :gateway-start     #(db/start-gateways! test gateway)
                      :gateway-partition #(db/partition-gateways! test gateway)
                      :gateway-heal      #(db/heal-gateways!)
                      :gateway-pause     #(db/signal-gateways! test gateway "-STOP")
                      :gateway-resume    #(db/signal-gateways! test gateway "-CONT"))]
        (c/on-nodes test targets (fn [_ _] (c/su (act)) :done))
        (assoc o :value {:nodes targets, :gateway gateway})))

    (teardown! [_ _])))

(def perf
  #{{:name "gateway-kill",      :start #{:gateway-kill},      :stop #{:gateway-start},  :color "#E9A4D0"}
    {:name "gateway-partition", :start #{:gateway-partition}, :stop #{:gateway-heal},   :color "#E9C4A0"}
    {:name "gateway-pause",     :start #{:gateway-pause},     :stop #{:gateway-resume}, :color "#A0E9C4"}})

(defn package
  "A nemesis package for the gateway faults in `(:faults opts)` (`:gateway`, or any of
  `faults`). The final generator undoes all of them: resume, heal, start."
  [opts]
  (let [want  (enabled (:faults opts))
        order [:gateway-pause :gateway-partition :gateway-kill]
        used  (filterv want order)]
    {:generator       (when (seq used)
                       (gen/stagger (:interval opts combined/default-interval)
                                    (gen/mix (mapv fault-generator used))))
     :final-generator (when (seq used)
                        (mapv #(op (opposite %) {:nodes :all, :gateway :all}) used))
     :nemesis         (nemesis (:db opts))
     :perf            (into #{} (filter #(contains? want (first (:start %)))) perf)}))
