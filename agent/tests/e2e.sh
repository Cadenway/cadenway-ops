#!/usr/bin/env bash
# End-to-end test of cadenway-agent against a real Docker daemon, with a throwaway ops repository.
# Covers: first run, no-op run, rolling update, failed health check that keeps the old container,
# failed commit not retried, fix with a secret rotation, `$` kept in a secret, a config content
# change, a missing secret, an unpullable image (retried, the others still deployed), an unhealthy
# first container (removed), and a concurrent run that leaves the running one alone.
#
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD/agent:/agent:ro" \
#     docker:28.5.2-cli sh -c "apk add --no-cache bash >/dev/null && bash /agent/tests/e2e.sh"
#
# It creates and removes the Compose projects cadenway-test and cadenway-edge: never run it on a
# Cadenway host.
#
# The assertions are strings evaluated by `check`, so they expand late on purpose.
# shellcheck disable=SC2016,SC2034,SC2329
set -euo pipefail
apk add --quiet --no-cache bash git jq curl age util-linux coreutils >/dev/null
curl -fsSL -o /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64
echo "e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b  /usr/local/bin/sops" | sha256sum -c - >/dev/null
chmod +x /usr/local/bin/sops
mkdir -p /run/lock /etc/cadenway/env /src
cp /agent/cadenway-agent.sh /usr/local/bin/cadenway-agent && chmod +x /usr/local/bin/cadenway-agent

age-keygen -o /etc/cadenway/age.key 2>/dev/null
RECIPIENT=$(age-keygen -y /etc/cadenway/age.key)

# A minimal ops repository with the same layout: edge, infra, deployables, one environment.
R=/src/ops
S=$R/environments/test/services
mkdir -p $R/compose $S
cat >$R/compose/edge.yaml <<'EOF'
name: cadenway-edge
services:
  edge:
    image: busybox:1.37.0
    command: ['sleep', 'infinity']
    healthcheck: { test: ['CMD', 'true'], interval: 2s, retries: 3 }
    networks: [edge-test]
networks:
  edge-test:
    name: cadenway-edge-test
EOF
cat >$R/compose/infra.yaml <<'EOF'
services:
  db:
    image: busybox:1.37.0
    command: ['sleep', 'infinity']
    healthcheck: { test: ['CMD', 'true'], interval: 2s, retries: 3 }
    networks: [internal]
networks:
  internal: {}
EOF
cat >$R/compose/compose.yaml <<'EOF'
name: cadenway
include:
  - infra.yaml
  - ${CADENWAY_SERVICES:-../environments/test/services}/web-service.yaml
  - ${CADENWAY_SERVICES:-../environments/test/services}/other-service.yaml
EOF
# web-service: health command, served config content.
write_web() {
  cat >$S/web-service.yaml <<EOF
services:
  web-service:
    image: busybox:\${WEB_SERVICE_VERSION}
    command: ['sh', '-c', 'httpd -f -p 8080 -h /srv']
    environment:
      SECRET_VALUE: \${SECRET_VALUE}
    configs:
      - source: web-config
        target: /srv/config.txt
    healthcheck: { test: ['CMD', '$1'], interval: 2s, retries: 2, start_period: 1s }
    networks: [edge, internal]
configs:
  web-config:
    content: '$2'
networks:
  edge:
    name: cadenway-edge-\${ENVIRONMENT}
    external: true
  internal: {}
EOF
}
write_other() {
  cat >$S/other-service.yaml <<EOF
services:
  other-service:
    image: busybox:\${OTHER_SERVICE_VERSION}
    command: ['sleep', 'infinity']
    healthcheck: { test: ['CMD', '$1'], interval: 2s, retries: 2, start_period: 1s }
    networks: [internal]
networks:
  internal: {}
EOF
}
write_web true first
write_other true
versions() { printf 'WEB_SERVICE_VERSION=%s\nOTHER_SERVICE_VERSION=%s\n' "$1" "$2" >$R/environments/test/versions.env; }
secrets() {
  printf '%s\n' "$@" 'ALERT_WEBHOOK_URL=' >/tmp/plain.env
  sops --encrypt --age "$RECIPIENT" --input-type dotenv --output-type dotenv /tmp/plain.env \
    >$R/environments/test/secrets.sops.env
  rm /tmp/plain.env
}
versions 1.36.1 ''
secrets 'SECRET_VALUE=first'
git -C $R init -q -b main && git -C $R add -A && git -C $R -c user.name=t -c user.email=t@t commit -qm init

cat >/etc/cadenway/agent.env <<EOF
CADENWAY_REPO_URL=$R
CADENWAY_ENVIRONMENTS=test
CADENWAY_HEALTH_TIMEOUT=20
EOF
echo 'ACME_EMAIL=unused@example.com' >/etc/cadenway/edge.env
echo 'ENVIRONMENT=test' >/etc/cadenway/env/test.env

commit() { git -C $R add -A && git -C $R -c user.name=t -c user.email=t@t commit -qm "$1"; }
containers() { docker ps --filter label=com.docker.compose.project=cadenway-test --filter "label=com.docker.compose.service=$1" --format '{{.ID}} {{.Image}}'; }
web() { containers web-service; }
head_is() { [[ $(cat "/var/lib/cadenway-agent/test/$1" 2>/dev/null) == $(git -C "$R" rev-parse HEAD) ]]; }
run_agent() {
  set +e
  OUT=$(cadenway-agent 2>&1)
  RESULT=$?
  set -e
}
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; echo "$OUT" | tail -5; FAILED=1; fi; }
FAILED=0
OUT=''

echo '=== 1. first run'
run_agent
check 'run succeeds' '[[ $RESULT == 0 ]]'
check 'web starts at 1.36.1' '[[ $(web | wc -l) == 1 && $(web) == *busybox:1.36.1* ]]'
check 'unreleased other-service not started' '[[ -z $(containers other-service) ]]'
check 'commit recorded' 'head_is applied'
check 'no decrypted secret left' '[[ -z $(ls -A /run/cadenway 2>/dev/null) ]]'
FIRST=$(web | cut -d" " -f1)

echo '=== 2. same commit again: no-op'
run_agent
check 'container untouched' '[[ $(web | cut -d" " -f1) == "$FIRST" ]]'

echo '=== 3. new version: rolling update'
versions 1.37.0 ''
commit 'deploy 1.37.0'
run_agent
check 'one container at 1.37.0' '[[ $(web | wc -l) == 1 && $(web) == *busybox:1.37.0* ]]'
check 'old container replaced' '[[ $(web | cut -d" " -f1) != "$FIRST" ]]'
SECOND=$(web | cut -d" " -f1)

echo '=== 4. broken definition: the old container keeps serving'
write_web false first
commit 'break the healthcheck'
run_agent
check 'run reports a failure' '[[ $RESULT != 0 ]]'
check 'old container still the only one' '[[ $(web | wc -l) == 1 && $(web | cut -d" " -f1) == "$SECOND" ]]'
check 'commit recorded as failed' 'head_is failed'
check 'worktree back on the applied commit' '[[ $(git -C /opt/cadenway/envs/test rev-parse HEAD) == $(cat /var/lib/cadenway-agent/test/applied) ]]'

echo '=== 5. failed commit is not retried'
run_agent
check 'skipped' '[[ $OUT == *"failed before"* ]]'

echo '=== 6. fix, and a rotated secret with a dollar sign'
write_web true first
secrets 'SECRET_VALUE=pa$word$HOME'
commit 'fix and rotate'
run_agent
check 'secret kept literally' '[[ $(docker exec "$(web | cut -d" " -f1)" printenv SECRET_VALUE) == "pa\$word\$HOME" ]]'
check 'secret not leaked to the logs' '[[ $OUT != *word* ]]'
check 'failed marker cleared' '[[ ! -e /var/lib/cadenway-agent/test/failed ]]'

echo '=== 7. config content change: rolled out'
BEFORE=$(web | cut -d" " -f1)
write_web true second
commit 'change the config content'
run_agent
check 'new container' '[[ $(web | wc -l) == 1 && $(web | cut -d" " -f1) != "$BEFORE" ]]'
check 'new content served' '[[ $(docker exec "$(web | cut -d" " -f1)" cat /srv/config.txt) == second ]]'

echo '=== 8. missing secret: refused before anything changes'
BEFORE=$(web | cut -d" " -f1)
secrets 'OTHER=1'
commit 'drop SECRET_VALUE'
run_agent
check 'commit failed' 'head_is failed'
check 'names the variable' '[[ $OUT == *"misses SECRET_VALUE"* ]]'
check 'web untouched' '[[ $(web | cut -d" " -f1) == "$BEFORE" ]]'
secrets 'SECRET_VALUE=pa$word$HOME'
commit 'restore SECRET_VALUE'
run_agent
check 'restored' 'head_is applied'

echo '=== 9. unpullable image: retried, the others still deployed'
versions 1.37.0 0.0.0-does-not-exist
commit 'release other-service with a missing image'
run_agent
check 'not applied' '! head_is applied'
check 'not recorded as failed' '! head_is failed'
check 'retrying noted once' 'head_is retrying && [[ $OUT == *"retrying every minute"* ]]'
run_agent
check 'said once' '[[ $OUT != *"retrying every minute"* ]]'
check 'web still serving' '[[ $(web | wc -l) == 1 ]]'

echo '=== 10. unhealthy first container: removed, not left looking applied'
write_other false
versions 1.37.0 1.37.0
commit 'release a broken other-service'
run_agent
check 'commit failed' 'head_is failed'
check 'no container left' '[[ -z $(containers other-service) ]]'
write_other true
commit 'fix other-service'
run_agent
check 'deployed once fixed' 'head_is applied && [[ $(containers other-service | wc -l) == 1 ]]'

echo '=== 11. a run while another holds the lock'
mkdir -p /run/cadenway/sentinel && touch /run/cadenway/sentinel/secrets.env
flock /run/lock/cadenway-agent.lock sleep 3 &
sleep 1
run_agent
wait
check 'second run steps aside' '[[ $RESULT == 0 && $OUT == *"another run is in progress"* ]]'
check 'the running one keeps its secrets' '[[ -e /run/cadenway/sentinel/secrets.env ]]'
rm -rf /run/cadenway/sentinel

echo '=== cleanup'
docker compose -p cadenway-test down -v --remove-orphans >/dev/null 2>&1 || true
docker compose -p cadenway-edge -f /opt/cadenway/edge/compose/edge.yaml down -v >/dev/null 2>&1 || true
exit $FAILED
