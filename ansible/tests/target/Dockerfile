# A throwaway Ubuntu 24.04 host with systemd and a socket-activated SSH server, the shape of an OVH
# VPS image, for ansible/tests/run.sh. Never a production image.
FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3
RUN apt-get update -qq \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    systemd systemd-sysv python3 python3-apt sudo openssh-server iptables ca-certificates \
    tzdata util-linux-extra >/dev/null \
  && systemctl enable ssh.socket \
  && install -d -m 0700 /root/.ssh
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
