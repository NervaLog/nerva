(ns jepsen.nerva.http
  "JSON over HTTP to `nerva api`, and what a reply means for a Jepsen operation.

  A reply is definite or not, and its body says which (R4, P215d). A `2xx` applied the request
  at the op it names (`\"replayed\": true` when a resent key had already committed). Any other
  reply carries `applied`: `false` means nothing was applied (a conflict, `out_of_bounds`, a
  gateway without a session, ...), `\"unknown\"` means a write went out and no reply came back.
  A connection that was never made (refused, or timed out connecting) sent nothing, so its
  request failed too. Anything else that does not reach a reply (a reset connection, our
  timeout) leaves a write's outcome unknown: Jepsen's `:info`. A read changes nothing, so a
  read without a reply simply failed. A non-2xx reply without `applied` and `code` is a bug in
  the gateway's promise, and a `400` means the test sent something malformed: both complete
  the op as a protocol violation (`violation`), which `protocol-checker` turns into an invalid
  run. They do not throw: Jepsen records a thrown op as :info, and nothing would fail."
  (:require [clojure.data.json :as json]
            [clojure.string :as str]
            [jepsen.checker :as checker])
  (:import (java.io IOException)
           (java.net ConnectException URI)
           (java.net.http HttpClient HttpClient$Version HttpConnectTimeoutException HttpRequest
                          HttpRequest$BodyPublishers HttpResponse$BodyHandlers)
           (java.time Duration)))

(def api-port
  "Where every node's `nerva api` listens."
  8080)

(def api-key
  "The shared key (`NERVA_KEY`) the gateways are started with."
  "jepsen")

(def timeout-ms
  "How long a request may take. Longer than the gateway's own 30 s cluster timeout, so a
  request the cluster does not answer comes back as the gateway's `503`, not as ours."
  35000)

(def ^:private client
  ;; HTTP/1.1 only: the gateway takes one request per connection and does not upgrade.
  (delay (-> (HttpClient/newBuilder)
             (.version HttpClient$Version/HTTP_1_1)
             (.connectTimeout (Duration/ofSeconds 5))
             (.build))))

(defn request!
  "Sends one request to node's gateway. Returns {:status int, :body parsed JSON or nil}.
  Throws an IOException when no reply arrives. With a port, sends it to that gateway; with a
  timeout (milliseconds), gives up on the reply after that long instead of `timeout-ms`."
  ([node method path body]
   (request! node api-port method path body))
  ([node port method path body]
   (request! node port method path body timeout-ms))
  ([node port method path body timeout-ms]
   (let [publisher (if (nil? body)
                     (HttpRequest$BodyPublishers/noBody)
                     (HttpRequest$BodyPublishers/ofString (json/write-str body)))
         request   (-> (HttpRequest/newBuilder (URI. (str "http://" node ":" port path)))
                       (.timeout (Duration/ofMillis timeout-ms))
                       (.header "X-Nerva-Key" api-key)
                       (.header "Content-Type" "application/json")
                       (.method method publisher)
                       (.build))
         response  (.send ^HttpClient @client request (HttpResponse$BodyHandlers/ofString))
         text      (.body response)]
     {:status (.statusCode response)
      :body   (when-not (str/blank? text) (json/read-str text))})))

(defn ok!
  "Like request!, for setup: returns the body of a `200`, and throws on anything else."
  [node method path body]
  (let [{:keys [status] :as reply} (request! node method path body)]
    (when-not (= 200 status)
      (throw (ex-info (str method " " path " answered " status)
                      {:node node, :reply reply})))
    (:body reply)))

(defn outcome
  "What a reply means, read from its body as R4 defines it (README, \"What a reply means\";
  P215d): :ok (any 2xx, a replay included), :refused (`applied: false`, on any status: nothing
  reached the cluster, or the cluster refused it), :unknown (`applied: \"unknown\"`: a write
  went out and no reply came back) or :violation (a `400`, or a non-2xx reply that does not
  carry both `applied` and `code`: it breaks R4's promise, or the test is wrong)."
  [{:keys [status body]}]
  (let [applied (get body "applied")]
    (cond
      (<= 200 (long status) 299)      :ok
      (= 400 (long status))           :violation
      (not (string? (get body "code"))) :violation
      (false? applied)                :refused
      (= "unknown" applied)           :unknown
      :else                           :violation)))

(defn violation
  "op, completed for a reply that breaks R4's promise or shows the test is wrong (see
  `outcome`). :info, because whether a write applied is not known; it carries
  :protocol-violation, which `protocol-checker` invalidates the run for."
  [op {:keys [status body]}]
  (assoc op :type :info
         :error [:protocol-violation status]
         :protocol-violation {:http status, :body body}))

(defn protocol-checker
  "Invalid when any operation in the history carries :protocol-violation. Composed into every
  test by core, so no workload wires it by hand."
  []
  (reify checker/Checker
    (check [_ _test history _opts]
      (let [bad (filter :protocol-violation history)]
        {:valid?     (empty? bad)
         :violations (count bad)
         :examples   (vec (take 10 bad))}))))

(defn replayed?
  "Whether a 2xx reply says the request had already committed: `\"replayed\": true`
  (NRV-W0201). Its `op` is the original commit's."
  [{:keys [body]}]
  (true? (get body "replayed")))

(defn ok-fields
  "The fields an :ok completion takes from its 2xx reply: the `:op` it names, and
  `:replayed? true` when it was a replay."
  [{:keys [body] :as reply}]
  (cond-> {:op (parse-long (str (get body "op")))}
    (replayed? reply) (assoc :replayed? true)))

(defn refusal-error
  "The :error of a :fail completion for a :refused reply. Nerva's own refusal of a well-formed
  request (a `409`) is its status as a keyword, which a workload's checker may judge. Any other
  `applied: false` reply (busy, no session, too large, ...) is a definite failure that is no
  refusal of the request: {:code \"NRV-...\", :http 503}. A `400` means the test sent something
  malformed: `outcome` calls it a violation, so it never gets here."
  [{:keys [status body]}]
  (case (long status)
    409 (keyword (or (get body "status") (get body "error") (get body "code")))
    {:code (get body "code"), :http status}))

(defn unknown
  "op, completed for a request whose outcome is unknown: :info for a write, :fail for a read."
  [op write? error]
  (assoc op :type (if write? :info :fail), :error error))

(defn not-sent?
  "Whether an exception from request! means the request never left: no connection was made."
  [e]
  (or (instance? ConnectException e) (instance? HttpConnectTimeoutException e)))

(defn no-reply
  "op, completed for a request that threw e instead of returning a reply."
  [op write? ^Exception e]
  (let [error [(.getName (class e)) (.getMessage e)]]
    (if (not-sent? e)
      (assoc op :type :fail, :error (into [:not-sent] error))
      (unknown op write? (into [:no-reply] error)))))

(defmacro with-errors
  "Evaluates body, which completes op. A request that gets no reply completes op as failed if
  it was never sent, and as unknown otherwise."
  [op write? & body]
  `(try ~@body
        (catch IOException e#
          (no-reply ~op ~write? e#))))

(defn healthy?
  "Whether the gateway at node (and port, `api-port` when omitted) has a cluster session
  (`/healthz` answers 200)."
  ([node]
   (healthy? node api-port))
  ([node port]
   (try (= 200 (:status (request! node port "GET" "/healthz" nil)))
        (catch IOException _ false))))

(defn await-healthy!
  "Waits until the gateway at node (and port, `api-port` when omitted) is healthy, at most
  timeout-s seconds; throws past that."
  ([node timeout-s]
   (await-healthy! node api-port timeout-s))
  ([node port timeout-s]
   (let [deadline (+ (System/nanoTime) (* timeout-s 1000000000))]
     (loop []
       (cond (healthy? node port) :healthy
             (< deadline (System/nanoTime))
             (throw (ex-info (str node ":" port " gateway not healthy after " timeout-s " s")
                             {:node node :port port}))
             :else (do (Thread/sleep 500) (recur)))))))
