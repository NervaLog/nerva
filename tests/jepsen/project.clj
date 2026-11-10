(defproject jepsen.nerva "0.1.0-SNAPSHOT"
  :description "Jepsen tests for Nerva, through nerva api"
  :dependencies [[org.clojure/clojure "1.12.0"]
                 [jepsen "0.3.14"]
                 [org.clojure/data.json "2.5.1"]]
  :main jepsen.nerva.core
  :jvm-opts ["-Xmx3g" "-Djava.awt.headless=true"])
