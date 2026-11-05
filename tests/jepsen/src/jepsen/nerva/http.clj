(ns jepsen.nerva.http
  "JSON over HTTP to `nerva api`, and what a reply means for a Jepsen operation.

  A reply is definite or not. `200` applied the request at the op it names; `409` applied
  nothing (a conflict, `out_of_bounds`, `unpaired`, ...: README, JSON API). A connection that
  was never made (refused, or timed out connecting) sent nothing, so its request failed too.
  Anything else that does not reach a reply (a reset connection, our timeout) and a `503` (the
  gateway lost its cluster session, maybe after the commit went out) leave a write's outcome
  unknown: Jepsen's `:info`. A read changes nothing, so a read without a reply simply failed.
  A `400` means the test sent something malformed: that is a bug in the test, and throws."
  (:require [clojure.data.json :as json]
            [clojure.string :as str])
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
  Throws an IOException when no reply arrives. With a port, sends it to that gateway."
  ([node method path body]
   (request! node api-port method path body))
  ([node port method path body]
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
  "What a reply means: :ok (applied), :refused (nothing applied), or :unknown (the gateway
  could not say). Throws on any other status: the test sent something it should not have."
  [{:keys [status body] :as reply}]
  (case (long status)
    200     :ok
    409     :refused
    (503 504) :unknown
    (throw (ex-info (str "unexpected reply " status) {:reply reply}))))

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
