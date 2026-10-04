# Probe image: the nerva binary plus the tools the nightly needs (fio, perf).
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends fio linux-perf procps iproute2 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY nerva /usr/local/bin/nerva
COPY probe.sh /usr/local/bin/probe.sh
CMD ["/usr/local/bin/probe.sh"]
