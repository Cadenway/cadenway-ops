#!/usr/bin/env bash
# End-to-end test of cadenway-agent against a real Docker daemon, with a throwaway ops repository.
# Covers: first run, no-op run, rolling update, failed health check that keeps the old container,
# failed commit not retried, fix with a secret rotation, `$` kept in a secret, a config content
# change, a missing secret, an unpullable image (retried, the others still deployed), an unhealthy
# first container (removed), a concurrent run that leaves the running one alone, and the migrator
# URL of a database given to the migration container only, never on a command line, with a commit
# that misses it refused. Companion cases cover activation and scaling, failure isolation,
# rollback to a definition with only the owner, validation of process settings, and isolation of
# Notification's mail configuration when its worker runs separately.
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

# data-service connects to a database. Its image stands in for a service image: dist/migrate.js,
# and a `node` that prints the hash of the migrator URL it receives. Written with the
# MIGRATION_DATABASE_URL entry the definitions carry until each service drops it (`carried`), or
# without it.
write_data() {
  cat >$S/data-service.yaml <<'EOF'
services:
  data-service:
    image: busybox:${DATA_SERVICE_VERSION}
    command: ['sleep', 'infinity']
    environment:
      DATABASE_URL: ${DATA_SERVICE_DATABASE_URL}
      MIGRATION_DATABASE_URL: ${DATA_SERVICE_MIGRATION_DATABASE_URL}
    configs:
      - source: migrate
        target: /dist/migrate.js
      - source: node
        target: /usr/local/bin/node
        mode: 0555
    healthcheck: { test: ['CMD', 'true'], interval: 2s, retries: 2, start_period: 1s }
    networks: [internal]
configs:
  migrate:
    content: 'run by the stand-in node'
  node:
    content: |
      #!/bin/sh
      printf 'migrated with %s\n' "$$(printf %s "$$MIGRATION_DATABASE_URL" | sha256sum | cut -c1-64)"
networks:
  internal: {}
EOF
  [[ $1 == carried ]] || sed -i '/^      MIGRATION_DATABASE_URL:/d' $S/data-service.yaml
}
readonly MIGRATOR_URL='postgres://data_migrator:mi$grat0r@db:5432/data'
MIGRATED="migrated with $(printf %s "$MIGRATOR_URL" | sha256sum | cut -c1-64)"
data_secrets() {
  secrets 'SECRET_VALUE=pa$word$HOME' 'DATA_SERVICE_DATABASE_URL=postgres://data_app:app@db:5432/data' "$@"
}
data() { containers data-service; }
data_id() { data | cut -d" " -f1; }

echo '=== 12. migrations while the definition still carries the migrator URL'
echo '  - ${CADENWAY_SERVICES:-../environments/test/services}/data-service.yaml' >>$R/compose/compose.yaml
write_data carried
echo 'DATA_SERVICE_VERSION=1.37.0' >>$R/environments/test/versions.env
data_secrets "DATA_SERVICE_MIGRATION_DATABASE_URL=$MIGRATOR_URL"
commit 'release data-service'
run_agent
check 'applied' 'head_is applied && [[ $(data | wc -l) == 1 ]]'
check 'the migration container gets the migrator URL' '[[ $OUT == *"$MIGRATED"* ]]'
check 'the service gets it from its definition, as before' \
  '[[ $(docker exec "$(data_id)" printenv MIGRATION_DATABASE_URL) == "$MIGRATOR_URL" ]]'

echo '=== 13. migrations once the definition no longer carries it'
# Records every docker command line of the agent, to show that no secret reaches an argument list:
# /usr/local/sbin comes first in the PATH of the image.
REAL_DOCKER=$(command -v docker)
mkdir -p /usr/local/sbin
cat >/usr/local/sbin/docker <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>/tmp/docker-arguments
exec $REAL_DOCKER "\$@"
EOF
chmod +x /usr/local/sbin/docker
BEFORE=$(data_id)
write_data dropped
# web-service rolls out in the same run: it has no database, so its migration gets nothing.
write_web true third
commit 'drop MIGRATION_DATABASE_URL from the definition'
run_agent
rm -f /usr/local/sbin/docker
check 'applied, with a new container' 'head_is applied && [[ $(data | wc -l) == 1 && $(data_id) != "$BEFORE" ]]'
check 'the migration container still gets the migrator URL' '[[ $OUT == *"$MIGRATED"* ]]'
check 'the service container does not' \
  '! docker exec "$(data_id)" printenv MIGRATION_DATABASE_URL >/dev/null'
check 'and keeps its own database URL' \
  '[[ $(docker exec "$(data_id)" printenv DATABASE_URL) == postgres://data_app:* ]]'
check 'passed by name to docker compose run' \
  'grep -qF -- "run --rm --no-deps -T -e MIGRATION_DATABASE_URL data-service" /tmp/docker-arguments'
check 'a deployable without a database is migrated without it' \
  'grep -qF -- "run --rm --no-deps -T web-service sh" /tmp/docker-arguments'
check 'never in a docker argument list' '! grep -qF grat0r /tmp/docker-arguments'
check 'nor in the logs' '[[ $OUT != *grat0r* ]]'

echo '=== 14. a missing migrator URL: refused before anything changes'
BEFORE=$(data_id)
data_secrets
commit 'drop DATA_SERVICE_MIGRATION_DATABASE_URL'
run_agent
check 'commit failed' 'head_is failed'
check 'names the variable' '[[ $OUT == *"misses DATA_SERVICE_MIGRATION_DATABASE_URL"* ]]'
check 'data-service untouched' '[[ $(data_id) == "$BEFORE" ]]'
data_secrets "DATA_SERVICE_MIGRATION_DATABASE_URL=$MIGRATOR_URL"
commit 'restore DATA_SERVICE_MIGRATION_DATABASE_URL'
run_agent
check 'restored' 'head_is applied && [[ $(data_id) == "$BEFORE" ]]'

# Both Task processes intentionally share the owner's version and application database. The
# fixture's executable records every migration, even if mistakenly run with the companion.
write_task() {
  local replicas=$1 owner_health=$2 relay_health=$3 relay_image=${4:-'busybox:${TASK_SERVICE_VERSION}'}
  cat >"$S/task-service.yaml" <<EOF
services:
  task-service:
    image: busybox:\${TASK_SERVICE_VERSION}
    command: ['sh', '-c', 'trap "exit 0" TERM; while :; do sleep 1 & wait; done']
    environment:
      DATABASE_URL: \${TASK_SERVICE_DATABASE_URL}
      TASK_SERVICE_OUTBOX_MODE: \${TASK_SERVICE_OUTBOX_MODE:-legacy}
    configs:
      - { source: task-migrate, target: /dist/migrate.js }
      - { source: task-node, target: /usr/local/bin/node, mode: 0555 }
    networks: [internal]
    healthcheck: { test: ['CMD', '$owner_health'], interval: 2s, retries: 2 }
EOF
  if [[ $replicas != absent ]]; then
    cat >>"$S/task-service.yaml" <<EOF
  task-service-relay:
    image: $relay_image
    command: ['sh', '-c', 'trap "exit 0" TERM; while :; do sleep 1 & wait; done']
    environment:
      DATABASE_URL: \${TASK_SERVICE_DATABASE_URL}
    configs:
      - { source: task-migrate, target: /dist/migrate.js }
      - { source: task-node, target: /usr/local/bin/node, mode: 0555 }
    deploy:
      replicas: $replicas
    networks: [internal]
    healthcheck: { test: ['CMD', '$relay_health'], interval: 2s, retries: 2 }
EOF
  fi
  cat >>"$S/task-service.yaml" <<'EOF'
configs:
  task-migrate:
    content: 'run by the stand-in node'
  task-node:
    content: |
      #!/bin/sh
      printf 'task fixture migration ran\n'
networks:
  internal: {}
EOF
}
task_id() { containers task-service | cut -d' ' -f1; }
relay_ids() { containers task-service-relay | cut -d' ' -f1 | sort; }
task_settings() {
  printf 'TASK_SERVICE_OUTBOX_MODE=%s\nTASK_SERVICE_RELAY_REPLICAS=%s\n' "$1" "$2" \
    >"$R/environments/test/processes.env"
}
readonly TASK_REPLICAS='${TASK_SERVICE_RELAY_REPLICAS:-0}'

echo '=== 15. stage the owner with its companion disabled'
echo '  - ${CADENWAY_SERVICES:-../environments/test/services}/task-service.yaml' >>"$R/compose/compose.yaml"
echo 'TASK_SERVICE_VERSION=1.37.0' >>"$R/environments/test/versions.env"
data_secrets "DATA_SERVICE_MIGRATION_DATABASE_URL=$MIGRATOR_URL" \
  'TASK_SERVICE_DATABASE_URL=postgres://fixture@db/task' \
  'TASK_SERVICE_MIGRATION_DATABASE_URL=postgres://fixture-owner@db/task'
write_task "$TASK_REPLICAS" true true
task_settings dedicated 0
commit 'stage task without companion'
run_agent
check 'task is healthy and relay is absent' 'head_is applied && [[ -n $(task_id) && -z $(relay_ids) ]]'
check 'only the task owner migrated' '[[ $(grep -cF "task fixture migration ran" <<<"$OUT") == 1 ]]'
check 'task reads the owner role from Git' '[[ $(docker exec "$(task_id)" printenv TASK_SERVICE_OUTBOX_MODE) == dedicated ]]'
TASK=$(task_id)

echo '=== 16. activate the companion, then scale it up to two instances'
task_settings dedicated 1
commit 'activate task relay'
run_agent
check 'relay starts without rolling its owner' 'head_is applied && [[ $(task_id) == "$TASK" && $(relay_ids | wc -l) == 1 ]]'
check 'a companion never runs a migration' '[[ $OUT != *"task fixture migration ran"* ]]'
RELAY=$(relay_ids)
task_settings dedicated 2
commit 'scale task relay to two'
run_agent
check 'scale-up keeps the healthy replica' 'head_is applied && [[ $(relay_ids | wc -l) == 2 ]] && relay_ids | grep -Fxq "$RELAY"'
check 'scale-up keeps the owner and runs no migration' '[[ $(task_id) == "$TASK" && $OUT != *"task fixture migration ran"* ]]'
RELAYS=$(relay_ids)

echo '=== 17. a failed owner keeps its companions untouched'
write_task "$TASK_REPLICAS" false true
task_settings dedicated 1
commit 'deploy an unhealthy task owner'
run_agent
check 'failed owner and healthy companions keep serving' 'head_is failed && [[ $(task_id) == "$TASK" && $(relay_ids) == "$RELAYS" ]]'

echo '=== 18. a failed companion rollout keeps both earlier replicas'
write_task "$TASK_REPLICAS" true false
task_settings dedicated 2
commit 'deploy unhealthy task relays'
run_agent
check 'failed candidates removed, the earlier replicas kept' 'head_is failed && [[ $(relay_ids) == "$RELAYS" ]]'
check 'replacement never restarted the owner' '[[ $(task_id) == "$TASK" ]]'

echo '=== 19. scale down, and roll back to the owner-only definition'
write_task "$TASK_REPLICAS" true true
task_settings dedicated 1
commit 'scale down task relay'
run_agent
check 'scale-down keeps the oldest healthy replica without migrating' 'head_is applied && [[ $(relay_ids) == "$RELAY" && $OUT != *"task fixture migration ran"* ]]'
write_task absent true true
task_settings legacy 0
sed -i 's/^TASK_SERVICE_VERSION=.*/TASK_SERVICE_VERSION=1.36.1/' "$R/environments/test/versions.env"
commit 'roll back the task deployment'
run_agent
check 'roll back the owner and remove the absent companion' 'head_is applied && [[ -z $(relay_ids) && $(containers task-service) == *busybox:1.36.1* ]]'

echo '=== 20. refuse a companion with a different image'
TASK=$(task_id)
write_task "$TASK_REPLICAS" true true busybox:1.37.0
task_settings dedicated 1
commit 'misconfigure the task relay image'
run_agent
check 'invalid companion rejected without touching owner' 'head_is failed && [[ $(task_id) == "$TASK" && -z $(relay_ids) && $OUT == *"invalid companion declaration"* ]]'

echo '=== 21. refuse overlap with inline processing'
write_task "$TASK_REPLICAS" true true
task_settings legacy 1
commit 'attempt to run the legacy and dedicated relays together'
run_agent
check 'overlapping owner mode rejected' 'head_is failed && [[ $(task_id) == "$TASK" && -z $(relay_ids) && $OUT == *"invalid companion declaration"* ]]'

echo '=== 22. reject unknown settings before configuring the deployment'
task_settings dedicated 1
echo 'UNRECOGNIZED_SETTING=1' >>"$R/environments/test/processes.env"
commit 'add an unsupported process setting'
run_agent
check 'unsupported setting refused before any replacement' 'head_is failed && [[ $(task_id) == "$TASK" && -z $(relay_ids) && $OUT == *"invalid process settings"* ]]'

notification_settings() {
  task_settings legacy 0
  printf 'NOTIFICATION_SERVICE_PROCESS_ROLE=%s\nNOTIFICATION_SERVICE_WORKER_REPLICAS=%s\n' "$1" "$2" \
    >>"$R/environments/test/processes.env"
}
notification_smtp_environment() {
  local id
  id=$(containers "$1" | cut -d' ' -f1)
  docker inspect --format '{{json .Config.Env}}' "$id" |
    jq -r 'map(select(test("^(SMTP_|MAIL_FROM=|WEB_APP_URL=)"))) | sort | .[]'
}

echo '=== 23. give SMTP settings only to the dedicated Notification worker'
write_task absent true true
echo '  - ${CADENWAY_SERVICES:-../environments/test/services}/notification-service.yaml' >>"$R/compose/compose.yaml"
echo 'NOTIFICATION_SERVICE_VERSION=1.37.0' >>"$R/environments/test/versions.env"
data_secrets "DATA_SERVICE_MIGRATION_DATABASE_URL=$MIGRATOR_URL" \
  'TASK_SERVICE_DATABASE_URL=postgres://fixture@db/task' \
  'TASK_SERVICE_MIGRATION_DATABASE_URL=postgres://fixture-owner@db/task' \
  'NOTIFICATION_SERVICE_DATABASE_URL=postgres://fixture@db/notification' \
  'NOTIFICATION_SERVICE_MIGRATION_DATABASE_URL=postgres://fixture-owner@db/notification' \
  'SMTP_HOST=mail.example.test' 'SMTP_PORT=2525' 'SMTP_USER=fixture' 'SMTP_PASSWORD=fixture' \
  'MAIL_FROM=notification@example.test'
cat >"$S/notification-service.yaml" <<'EOF'
services:
  notification-service:
    image: busybox:${NOTIFICATION_SERVICE_VERSION}
    command: ['sleep', 'infinity']
    environment:
      DATABASE_URL: ${NOTIFICATION_SERVICE_DATABASE_URL}
      NOTIFICATION_PROCESS_ROLE: ${NOTIFICATION_SERVICE_PROCESS_ROLE:-combined}
      SMTP_HOST: ${NOTIFICATION_OWNER_SMTP_HOST-${SMTP_HOST}}
      SMTP_PORT: ${NOTIFICATION_OWNER_SMTP_PORT-${SMTP_PORT}}
      SMTP_USER: ${NOTIFICATION_OWNER_SMTP_USER-${SMTP_USER}}
      SMTP_PASSWORD: ${NOTIFICATION_OWNER_SMTP_PASSWORD-${SMTP_PASSWORD}}
      MAIL_FROM: ${NOTIFICATION_OWNER_MAIL_FROM-${MAIL_FROM}}
      WEB_APP_URL: ${NOTIFICATION_OWNER_WEB_APP_URL-http://app.example.test}
    networks: [internal]
    healthcheck: { test: ['CMD', 'true'], interval: 2s, retries: 2 }
  notification-service-worker:
    image: busybox:${NOTIFICATION_SERVICE_VERSION}
    command: ['sh', '-c', 'trap "exit 0" TERM; while :; do sleep 1 & wait; done']
    environment:
      DATABASE_URL: ${NOTIFICATION_SERVICE_DATABASE_URL}
      NOTIFICATION_PROCESS_ROLE: worker
      SMTP_HOST: ${SMTP_HOST}
      SMTP_PORT: ${SMTP_PORT}
      SMTP_USER: ${SMTP_USER}
      SMTP_PASSWORD: ${SMTP_PASSWORD}
      MAIL_FROM: ${MAIL_FROM}
      WEB_APP_URL: http://app.example.test
    deploy:
      replicas: ${NOTIFICATION_SERVICE_WORKER_REPLICAS:-0}
    networks: [internal]
    healthcheck: { test: ['CMD', 'true'], interval: 2s, retries: 2 }
networks:
  internal: {}
EOF
notification_settings api 1
commit 'separate Notification worker and SMTP configuration'
run_agent
check 'Notification applies with one worker' 'head_is applied && [[ $(containers notification-service-worker | wc -l) == 1 ]]'
EMPTY_SMTP_ENVIRONMENT=$'MAIL_FROM=\nSMTP_HOST=\nSMTP_PASSWORD=\nSMTP_PORT=\nSMTP_USER=\nWEB_APP_URL='
WORKER_SMTP_ENVIRONMENT=$'MAIL_FROM=notification@example.test\nSMTP_HOST=mail.example.test\nSMTP_PASSWORD=fixture\nSMTP_PORT=2525\nSMTP_USER=fixture\nWEB_APP_URL=http://app.example.test'
check 'the API owner gets no mail settings' '[[ $(notification_smtp_environment notification-service) == "$EMPTY_SMTP_ENVIRONMENT" ]]'
check 'the worker keeps all mail settings' '[[ $(notification_smtp_environment notification-service-worker) == "$WORKER_SMTP_ENVIRONMENT" ]]'

echo '=== 24. restore the combined owner and drain the worker'
notification_settings combined 0
commit 'restore Notification inline job execution'
run_agent
check 'the companion is gone' 'head_is applied && [[ -z $(containers notification-service-worker) ]]'
check 'the combined owner receives mail settings again' '[[ $(notification_smtp_environment notification-service) == "$WORKER_SMTP_ENVIRONMENT" ]]'

echo '=== cleanup'
docker compose -p cadenway-test down -v --remove-orphans >/dev/null 2>&1 || true
docker compose -p cadenway-edge -f /opt/cadenway/edge/compose/edge.yaml down -v >/dev/null 2>&1 || true
exit $FAILED
