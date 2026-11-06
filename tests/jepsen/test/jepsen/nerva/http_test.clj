(ns jepsen.nerva.http-test
  "Each row of README's \"What a reply means\" maps to the outcome R4's contract gives it
  (P215d)."
  (:require [clojure.test :refer [deftest is testing]]
            [jepsen.nerva.http :as http]))

(defn reply
  [status body]
  {:status status, :body body})

(defn thrown-reply?
  [r]
  (try (http/outcome r) false
       (catch clojure.lang.ExceptionInfo _ true)))

(deftest a-2xx-is-applied
  (is (= :ok (http/outcome (reply 200 {"op" "7"}))))
  (is (= :ok (http/outcome (reply 200 nil))) "a body is not needed for a success"))

(deftest applied-false-is-a-definite-refusal-on-any-status
  (doseq [[status code] [[409 "NRV-E0201"] [503 "NRV-E0605"] [503 "NRV-E0602"]
                         [413 "NRV-E0403"] [504 "NRV-E0603"] [400 "NRV-E0101"]
                         [500 "NRV-B0001"]]]
    (testing (str status " " code)
      (is (= :refused (http/outcome (reply status {"applied" false, "code" code})))))))

(deftest applied-unknown-leaves-a-write-unknown
  (doseq [[status code] [[503 "NRV-E0601"] [500 "NRV-B0002"] [500 "NRV-B0001"]]]
    (testing (str status " " code)
      (is (= :unknown (http/outcome (reply status {"applied" "unknown", "code" code})))))))

(deftest the-status-alone-decides-nothing
  (is (= :refused (http/outcome (reply 503 {"applied" false, "code" "NRV-E0605"})))
      "a 503 that says nothing was applied is a definite refusal, not unknown")
  (is (= :unknown (http/outcome (reply 500 {"applied" "unknown", "code" "NRV-B0002"})))
      "a 5xx other than 503 can be unknown too"))

(deftest a-reply-that-breaks-r4s-promise-fails-the-test
  (testing "no applied and no code"
    (is (thrown-reply? (reply 503 {"error" "cluster unavailable"})))
    (is (thrown-reply? (reply 500 nil))))
  (testing "applied without a code"
    (is (thrown-reply? (reply 409 {"applied" false}))))
  (testing "a code without applied"
    (is (thrown-reply? (reply 409 {"code" "NRV-E0201"}))))
  (testing "an applied that is neither false nor \"unknown\""
    (is (thrown-reply? (reply 409 {"applied" true, "code" "NRV-E0201"})))
    (is (thrown-reply? (reply 409 {"applied" "maybe", "code" "NRV-E0201"})))))

(deftest a-replay-is-a-success-that-names-the-original-op
  (let [r (reply 200 {"op" "42", "replayed" true, "code" "NRV-W0201"})]
    (is (= :ok (http/outcome r)))
    (is (http/replayed? r))
    (is (= {:op 42, :replayed? true} (http/ok-fields r))))
  (let [r (reply 200 {"op" "43"})]
    (is (not (http/replayed? r)))
    (is (= {:op 43} (http/ok-fields r)))))

(deftest a-refusal-is-nervas-only-for-a-409
  (is (= :out_of_bounds
         (http/refusal-error (reply 409 {"status" "out_of_bounds", "applied" false,
                                         "code" "NRV-E0201"}))))
  (is (= {:code "NRV-E0602", :http 503}
         (http/refusal-error (reply 503 {"error" "busy", "applied" false,
                                         "code" "NRV-E0602"})))
      "busy is a definite failure, not a refusal the checker judges")
  (is (thrown? clojure.lang.ExceptionInfo
               (http/refusal-error (reply 400 {"applied" false, "code" "NRV-E0101"})))
      "a 400 is a malformed request: a bug in the test"))

(deftest no-reply-is-failed-or-unknown
  (is (= :fail (:type (http/no-reply {:f :transfer} true (java.net.ConnectException. "x")))))
  (is (= :info (:type (http/no-reply {:f :transfer} true (java.io.IOException. "reset")))))
  (is (= :fail (:type (http/no-reply {:f :read} false (java.io.IOException. "reset"))))
      "a read without a reply changed nothing")
  (is (= :info (:type (http/unknown {:f :transfer} true :x))))
  (is (= :fail (:type (http/unknown {:f :read} false :x)))))
