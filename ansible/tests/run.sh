#!/usr/bin/env bash
# Runs ansible/playbooks/setup.yml against a throwaway Ubuntu 24.04 container with systemd:
#   1. a `--check` preview of the fresh host;
#   2. the first apply, as the image user (root);
#   3. a second apply as the admin user, which must change nothing (idempotence);
#   4. a `--check` preview of the set-up host, which must change nothing;
# then checks the result: admin login over IPv4, root refused, services active.
#
#   bash ansible/tests/run.sh            (from the repository root, with Docker)
#
# It needs privileged containers (systemd, ufw, Docker inside) and creates and removes the
# container cw-ansible-target and the network cw-ansible-net. Never point it at a real host.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
readonly ROOT WORK
# Paths as the Docker daemon sees them (Git Bash on Windows needs them converted).
host_path() { cygpath -w "$1" 2>/dev/null || printf '%s
' "$1"; }
trap 'docker rm -f cw-ansible-target >/dev/null 2>&1 || true; docker network rm cw-ansible-net >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

docker build -q -t cw-ansible-target "$(host_path "$ROOT/ansible/tests/target")" >/dev/null
docker network create cw-ansible-net >/dev/null
docker run -d --name cw-ansible-target --hostname cw-ansible-target --network cw-ansible-net \
  --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw cw-ansible-target >/dev/null
ssh-keygen -q -t ed25519 -N '' -C controller -f "$WORK/id_ed25519"
until docker exec cw-ansible-target systemctl is-system-running --quiet 2>/dev/null ||
  [[ $(docker exec cw-ansible-target systemctl is-system-running 2>/dev/null) == degraded ]]; do
  sleep 1
done
docker cp "$(host_path "$WORK/id_ed25519.pub")" cw-ansible-target:/root/.ssh/authorized_keys
docker exec cw-ansible-target sh -c 'chown root:root /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'

cat >"$WORK/controller.sh" <<'EOF'
set -eu
export DEBIAN_FRONTEND=noninteractive ANSIBLE_COLLECTIONS_PATH=/root/.ansible/collections
apt-get update -qq >/dev/null && apt-get install -y -qq openssh-client >/dev/null
pip install -q --root-user-action=ignore ansible-core==2.19.4 >/dev/null 2>&1
cp -r /src /repo && cd /repo
ansible-galaxy collection install -r ansible/requirements.yml >/dev/null
install -d -m 0700 /root/.ssh && cp /keys/id_ed25519 /keys/id_ed25519.pub /root/.ssh/
chmod 600 /root/.ssh/id_ed25519
cat >ansible/inventory/hosts.yml <<HOSTS
cadenway:
  hosts:
    cw-ansible-target:
      ansible_host: cw-ansible-target
      cadenway_environments: [staging, prod]
HOSTS
cat >/tmp/vars.yml <<VARS
cadenway_admin_ssh_keys: ['$(cat /root/.ssh/id_ed25519.pub)']
cadenway_repo_url: git@github.com:example/cadenway-ops.git
cadenway_ghcr_owner: example
cadenway_acme_email: ops@example.com
cadenway_backup_age_recipient: age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq
ansible_ssh_common_args: -o StrictHostKeyChecking=accept-new
VARS
phase() {
  name=$1
  shift
  ansible-playbook ansible/playbooks/setup.yml -e @/tmp/vars.yml "$@" >/tmp/out 2>&1 || true
  recap=$(grep -E '^cw-ansible-target +:' /tmp/out | tail -1)
  echo "$name: $recap"
  echo "$recap" | grep -q 'failed=0' && echo "$recap" | grep -q 'unreachable=0' || {
    grep -E 'fatal|FAILED' /tmp/out | tail -5
    exit 1
  }
  if [ "${expect_unchanged:-}" = yes ]; then
    echo "$recap" | grep -q 'changed=0' || { grep -E '^changed:' /tmp/out | head; exit 1; }
  fi
}
expect_unchanged=no phase 'preview of a fresh host' --check -e ansible_user=root
expect_unchanged=no phase 'first apply' -e ansible_user=root
expect_unchanged=yes phase 'second apply' --diff
expect_unchanged=yes phase 'preview of a set-up host' --check
ssh -o BatchMode=yes cadenway@cw-ansible-target 'sudo -n true' && echo 'admin logs in over IPv4'
if ssh -o BatchMode=yes root@cw-ansible-target true 2>/dev/null; then
  echo 'root login still allowed'
  exit 1
fi
echo 'root login refused'
EOF

docker run --rm --network cw-ansible-net -v "$(host_path "$ROOT"):/src:ro" -v "$(host_path "$WORK"):/keys:ro" \
  python:3.13-slim sh /keys/controller.sh

for unit in ssh.socket docker fail2ban cadenway-agent.timer cadenway-backup.timer; do
  state=$(docker exec cw-ansible-target systemctl is-active "$unit")
  echo "$unit: $state"
  [[ $state == active ]]
done
docker exec cw-ansible-target ufw status | grep -q 'Status: active' && echo 'ufw: active'
