(ns jepsen.nerva.http-test
  "Each row of README's \"What a reply means\" maps to the outcome R4's contract gives it
  (P215d)."
  (:require [clojure.test :refer [deftest is testing]]
            [jepsen.nerva.http :as http]))

(defn reply
  [status body]
  {:status status, :body body})

(defn violation?
  "Whether the reply breaks R4's promise (or is a 400): it must invalidate the run, never throw."
  [r]
  (= :violation (http/outcome r)))

(deftest a-2xx-is-applied
  (is (= :ok (http/outcome (reply 200 {"op" "7"}))))
  (is (= :ok (http/outcome (reply 200 nil))) "a body is not needed for a success"))

(deftest applied-false-is-a-definite-refusal-on-any-status
  (doseq [[status code] [[409 "NRV-E0201"] [503 "NRV-E0605"] [503 "NRV-E0602"]
                         [413 "NRV-E0403"] [504 "NRV-E0603"] [500 "NRV-B0001"]]]
    (testing (str status " " code)
      (is (= :refused (http/outcome (reply status {"applied" false, "code" code})))))))

(deftest a-400-is-a-violation-whatever-it-says
  (is (violation? (reply 400 {"applied" false, "code" "NRV-E0101"}))
      "a 400 means the test sent something malformed"))

(deftest applied-unknown-leaves-a-write-unknown
  (doseq [[status code] [[503 "NRV-E0601"] [500 "NRV-B0002"] [500 "NRV-B0001"]]]
    (testing (str status " " code)
      (is (= :unknown (http/outcome (reply status {"applied" "unknown", "code" code})))))))

(deftest the-status-alone-decides-nothing
  (is (= :refused (http/outcome (reply 503 {"applied" false, "code" "NRV-E0605"})))
      "a 503 that says nothing was applied is a definite refusal, not unknown")
  (is (= :unknown (http/outcome (reply 500 {"applied" "unknown", "code" "NRV-B0002"})))
      "a 5xx other than 503 can be unknown too"))

(deftest a-reply-that-breaks-r4s-promise-invalidates-the-run
  (testing "no applied and no code"
    (is (violation? (reply 503 {"error" "cluster unavailable"})))
    (is (violation? (reply 500 nil))))
  (testing "applied without a code"
    (is (violation? (reply 409 {"applied" false}))))
  (testing "a code without applied"
    (is (violation? (reply 409 {"code" "NRV-E0201"}))))
  (testing "an applied that is neither false nor \"unknown\""
    (is (violation? (reply 409 {"applied" true, "code" "NRV-E0201"})))
    (is (violation? (reply 409 {"applied" "maybe", "code" "NRV-E0201"})))))

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
      "busy is a definite failure, not a refusal the checker judges"))

(deftest a-violation-completes-as-info-with-the-mark
  (let [op (http/violation {:f :transfer} (reply 503 nil))]
    (is (= :info (:type op)) "whether the write applied is not known")
    (is (:protocol-violation op))))

(deftest no-reply-is-failed-or-unknown
  (is (= :fail (:type (http/no-reply {:f :transfer} true (java.net.ConnectException. "x")))))
  (is (= :info (:type (http/no-reply {:f :transfer} true (java.io.IOException. "reset")))))
  (is (= :fail (:type (http/no-reply {:f :read} false (java.io.IOException. "reset"))))
      "a read without a reply changed nothing")
  (is (= :info (:type (http/unknown {:f :transfer} true :x))))
  (is (= :fail (:type (http/unknown {:f :read} false :x)))))
