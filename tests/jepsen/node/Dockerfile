# A Jepsen node: sshd for the control node, iptables and iproute2 for partitions, sudo for
# Jepsen's `su`. nerva itself is uploaded by the test (db.clj), so the image does not change
# with it.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server iptables iproute2 procps psmisc sudo ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd /root/.ssh \
 && chmod 700 /root/.ssh \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
CMD ["/usr/sbin/sshd", "-D", "-e"]
