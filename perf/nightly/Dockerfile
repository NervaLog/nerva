# The nightly perf Machine (docs/DECISIONS.md N56): both builds, the runner, fio, python3.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends fio python3 procps ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY baseline /opt/perf/baseline
COPY candidate /opt/perf/candidate
COPY run.sh /opt/perf/run.sh
CMD ["/opt/perf/run.sh"]
