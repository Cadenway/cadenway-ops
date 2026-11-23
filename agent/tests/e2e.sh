#!/usr/bin/env bash
# End-to-end test of cadenway-agent against a real Docker daemon, with a throwaway ops repository.
# Covers: first run, no-op run, same-commit repair, rolling update, failed health check that keeps the old container,
# failed commit not retried, fix with a secret rotation, `$` kept in a secret, a config content
# change, a missing secret, an unpullable image (retried, the others still deployed), an unhealthy
# first container (removed), a concurrent run that leaves the running one alone, and the migrator
# URL of a database given to the migration container only, never on a command line, with a commit
# that misses it refused. Companion cases cover activation and scaling, failure isolation,
# rollback to a definition with only the owner, and validation of process settings. Batch
# cases cover readiness before discovery, failure after another candidate passed, and recovery
# of a candidate left running by an interrupted agent.
#
#   docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$PWD/agent:/agent:ro" \
#     docker:28.5.2-cli sh -c "apk add --no-cache bash >/dev/null && bash /agent/tests/e2e.sh"
#
# CADENWAY_E2E_PREPARED=1 reuses runner dependencies and the pinned SOPS binary.
#
# It requires empty cadenway-test and cadenway-edge projects and refuses existing resources.
#
# The assertions are strings evaluated by `check`, so they expand late on purpose.
# shellcheck disable=SC2016,SC2034,SC2329
set -euo pipefail
if [[ ${CADENWAY_E2E_PREPARED:-0} != 1 ]]; then
  apk add --quiet --no-cache bash git jq curl age util-linux coreutils py3-yaml openssh-keygen >/dev/null
  curl -fsSL -o /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64
  chmod +x /usr/local/bin/sops
fi
echo "e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b  /usr/local/bin/sops" | sha256sum -c - >/dev/null
export SOPS_DISABLE_VERSION_CHECK=1
python3 /agent/tests/compose-policy.py
bash /agent/tests/release-authorization.sh

# The agent uses fixed project names for its edge and the configured environment. Refuse any
# collision on a shared daemon before the fixture creates or later removes those resources.
for project in cadenway-test cadenway-edge; do
  label="label=com.docker.compose.project=$project"
  containers=$(docker ps --all --quiet --filter "$label")
  networks=$(docker network ls --quiet --filter "$label")
  volumes=$(docker volume ls --quiet --filter "$label")
  if [[ -n $containers || -n $networks || -n $volumes ]]; then
    echo "The fixture requires an unused Docker Compose project: $project." >&2
    exit 1
  fi
done
if docker network inspect cadenway-edge-test >/dev/null 2>&1; then
  echo 'The fixture network cadenway-edge-test already exists.' >&2
  exit 1
fi

cleanup() {
  local project label containers networks
  local -a ids=()
  for project in cadenway-test cadenway-edge; do
    label="label=com.docker.compose.project=$project"
    containers=$(docker ps --all --quiet --filter "$label")
    if [[ -n $containers ]]; then
      mapfile -t ids <<<"$containers"
      docker rm --force "${ids[@]}" >/dev/null || true
    fi
  done
  for project in cadenway-test cadenway-edge; do
    label="label=com.docker.compose.project=$project"
    networks=$(docker network ls --quiet --filter "$label")
    if [[ -n $networks ]]; then
      mapfile -t ids <<<"$networks"
      docker network rm "${ids[@]}" >/dev/null || true
    fi
  done
}
trap cleanup EXIT

mkdir -p /run/lock /etc/cadenway/env /src
cp /agent/cadenway-agent.sh /usr/local/bin/cadenway-agent && chmod +x /usr/local/bin/cadenway-agent
cp /agent/compose-policy.py /usr/local/bin/compose-policy.py

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
  - ${CADENWAY_SERVICES:-../environments/test/services}/webapp.yaml
  - ${CADENWAY_SERVICES:-../environments/test/services}/other-service.yaml
EOF
# webapp: health command, served config content.
write_web() {
  cat >$S/webapp.yaml <<EOF
services:
  webapp:
    image: busybox:\${WEBAPP_VERSION}
    command: ['sh', '-c', 'httpd -f -p 8080 -h /srv']
    environment:
      SECRET_VALUE: \${WEBAPP_DATABASE_URL}
    labels:
      - traefik.enable=true
      - traefik.docker.network=cadenway-edge-\${ENVIRONMENT:-local}
      - traefik.http.routers.webapp-\${ENVIRONMENT:-local}.rule=Host(\`app.\${DOMAIN}\`)
      - traefik.http.services.webapp-\${ENVIRONMENT:-local}.loadbalancer.server.port=8080
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
    name: cadenway-edge-\${ENVIRONMENT:-local}
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
versions() { printf 'WEBAPP_VERSION=%s\nOTHER_SERVICE_VERSION=%s\n' "$1" "$2" >$R/environments/test/versions.env; }
secrets() {
  printf '%s\n' "$@" 'ALERT_WEBHOOK_URL=' >/tmp/plain.env
  sops --encrypt --age "$RECIPIENT" --input-type dotenv --output-type dotenv /tmp/plain.env \
    >$R/environments/test/secrets.sops.env
  rm /tmp/plain.env
}
versions 1.36.1 ''
secrets 'WEBAPP_DATABASE_URL=first'
git -C $R init -q -b main && git -C $R add -A && git -C $R -c user.name=t -c user.email=t@t commit -qm init

cat >/etc/cadenway/agent.env <<EOF
CADENWAY_REPO_URL=$R
CADENWAY_ENVIRONMENTS=test
CADENWAY_HEALTH_TIMEOUT=60
EOF
echo 'ACME_EMAIL=unused@example.com' >/etc/cadenway/edge.env
printf '%s\n' 'ENVIRONMENT=test' 'DOMAIN=example.test' >/etc/cadenway/env/test.env

commit() { git -C $R add -A && git -C $R -c user.name=t -c user.email=t@t commit -qm "$1"; }
containers() {
  docker ps --filter label=com.docker.compose.project=cadenway-test \
    --filter label=com.docker.compose.oneoff=False --filter "label=com.docker.compose.service=$1" \
    --format '{{.ID}} {{.Image}}'
}
web() { containers webapp; }
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

echo '=== 2a. repair a missing workload under the same commit'
DATABASE=$(containers db)
docker rm --force "$FIRST" >/dev/null
run_agent
check 'the missing workload is restored under the previous applied commit' \
  '[[ $RESULT == 0 && $(web | wc -l) == 1 && $(web | cut -d" " -f1) != "$FIRST" ]] && head_is applied'
check 'healthy infrastructure is kept' '[[ $(containers db) == "$DATABASE" ]]'
FIRST=$(web | cut -d" " -f1)

echo '=== 3. new version: rolling update'
versions 1.37.0 ''
commit 'deploy 1.37.0'
run_agent
check 'one container at 1.37.0' '[[ $(web | wc -l) == 1 && $(web) == *busybox:1.37.0* ]]'
check 'old container replaced' '[[ $(web | cut -d" " -f1) != "$FIRST" ]]'
SECOND=$(web | cut -d" " -f1)

echo '=== 4. broken definition: the old container keeps serving'
OLD_PLATFORM=$(containers db)
write_web false first
sed -i '/^    command: .*sleep.*infinity/a\    environment: [FIXTURE_INFRA_REVISION=new]' "$R/compose/infra.yaml"
commit 'break the healthcheck'
run_agent
check 'run reports a failure' '[[ $RESULT != 0 ]]'
check 'old container still the only one' '[[ $(web | wc -l) == 1 && $(web | cut -d" " -f1) == "$SECOND" ]]'
check 'commit recorded as failed' 'head_is failed'
check 'worktree back on the applied commit' '[[ $(git -C /opt/cadenway/envs/test rev-parse HEAD) == $(cat /var/lib/cadenway-agent/test/applied) ]]'
NEW_PLATFORM=$(containers db)
check 'the infrastructure update remains after the application failure' '[[ -n $NEW_PLATFORM && $NEW_PLATFORM != "$OLD_PLATFORM" ]]'

echo '=== 5. failed commit is not retried'
run_agent
check 'skipped' '[[ $OUT == *"failed before"* ]]'
check 'the platform change alone does not trigger an application repair' \
  '[[ $RESULT == 0 && $(containers db) == "$NEW_PLATFORM" && $OUT != *"reconciled workloads"* ]]'

echo '=== 5a. repair the applied application and preserve the newer infrastructure'
APPLIED_RELEASE=$(cat /var/lib/cadenway-agent/test/applied)
docker rm --force "$SECOND" >/dev/null
run_agent
check 'only the application is repaired, with the rejection still recorded' \
  '[[ $RESULT == 0 && $(web | wc -l) == 1 && $(web) == *busybox:1.37.0* && $(web | cut -d" " -f1) != "$SECOND" ]] && head_is failed'
check 'the applied SHA and newer platform stay in place' \
  '[[ $(cat /var/lib/cadenway-agent/test/applied) == "$APPLIED_RELEASE" && $(containers db) == "$NEW_PLATFORM" ]]'

echo '=== 6. fix, and a rotated secret with a dollar sign'
write_web true first
secrets 'WEBAPP_DATABASE_URL=pa$word$HOME'
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
commit 'drop WEBAPP_DATABASE_URL'
run_agent
check 'commit failed' 'head_is failed'
check 'names the variable' '[[ $OUT == *"misses WEBAPP_DATABASE_URL"* ]]'
check 'web untouched' '[[ $(web | cut -d" " -f1) == "$BEFORE" ]]'
secrets 'WEBAPP_DATABASE_URL=pa$word$HOME'
commit 'restore WEBAPP_DATABASE_URL'
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

echo '=== 9a. a pending release does not prevent repairing the applied application'
PREVIOUS_WEB=$(web | cut -d" " -f1)
PREVIOUS_PLATFORM=$(containers db)
APPLIED_RELEASE=$(cat /var/lib/cadenway-agent/test/applied)
docker rm --force "$PREVIOUS_WEB" >/dev/null
run_agent
check 'the pending release keeps its retry without recording a failure' \
  '[[ $RESULT != 0 && $OUT != *"retrying every minute"* ]] && head_is retrying && ! head_is failed'
check 'the same applied commit recovers the application without replacing the platform' \
  '[[ $(web | wc -l) == 1 && $(web) == *busybox:1.37.0* && $(web | cut -d" " -f1) != "$PREVIOUS_WEB" &&
    $(cat /var/lib/cadenway-agent/test/applied) == "$APPLIED_RELEASE" && $(containers db) == "$PREVIOUS_PLATFORM" ]]'

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
  secrets 'WEBAPP_DATABASE_URL=pa$word$HOME' 'DATA_SERVICE_DATABASE_URL=postgres://data_app:app@db:5432/data' "$@"
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
# webapp rolls out in the same run: it has no database, so its migration gets nothing.
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
  'grep -qE -- "run --rm --no-deps --pull never -T --label io[.]cadenway[.]agent[.]migration=data-service[.][[:alnum:]]+ -e MIGRATION_DATABASE_URL data-service" /tmp/docker-arguments'
check 'a deployable without a database is migrated without it' \
  'grep -qE -- "run --rm --no-deps --pull never -T --label io[.]cadenway[.]agent[.]migration=webapp[.][[:alnum:]]+ webapp sh" /tmp/docker-arguments'
check 'never in a docker argument list' '! grep -qF grat0r /tmp/docker-arguments'
check 'nor in the logs' '[[ $OUT != *grat0r* ]]'

echo '=== 13a. same-commit data service recovery does not repeat migrations'
PREVIOUS_DATA=$(data_id)
PREVIOUS_WEB=$(web | cut -d" " -f1)
docker stop "$PREVIOUS_DATA" >/dev/null
run_agent
check 'the stopped service is repaired without migrating or replacing healthy peers' \
  '[[ $RESULT == 0 && -n $(data_id) && $(web | cut -d" " -f1) == "$PREVIOUS_WEB" && $OUT != *"$MIGRATED"* ]] && head_is applied'

echo '=== 13b. an interrupted same-commit repair is rolled back before fetching'
ROLLOUT=/var/lib/cadenway-agent/test/rollout
mkdir -p "$ROLLOUT"/{baseline,migrations,networks,obsolete,records}
PREVIOUS_DATA=$(docker inspect --format '{{.Id}}' "$(data_id)")
printf '%s' "$PREVIOUS_DATA" >"$ROLLOUT/baseline/data-service"
printf '%s' "$PREVIOUS_DATA" >"$ROLLOUT/obsolete/data-service"
cat /var/lib/cadenway-agent/test/applied >"$ROLLOUT/commit"
touch "$ROLLOUT/repair"
INTERRUPTED=$(docker create --pull never --network none \
  --label com.docker.compose.project=cadenway-test --label com.docker.compose.oneoff=False \
  --label com.docker.compose.service=data-service busybox:1.37.0 sleep 120)
mv -- "$R" "$R.offline"
run_agent
mv -- "$R.offline" "$R"
check 'the uncommitted repair candidate is removed and the running release is kept' \
  '[[ $RESULT != 0 && $OUT == *"cannot fetch its release ref"* && ! -d $ROLLOUT ]] && \
    ! docker inspect "$INTERRUPTED" >/dev/null 2>&1 && \
    [[ $(docker inspect --format "{{.State.Running}}" "$PREVIOUS_DATA") == true ]] && head_is applied'

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

echo '=== 16a. repair a missing replica under the same commit'
MISSING_RELAY=$(relay_ids | grep -vxF "$RELAY")
docker rm --force "$MISSING_RELAY" >/dev/null
run_agent
check 'only the missing replica is replaced' \
  '[[ $RESULT == 0 && $(task_id) == "$TASK" && $(relay_ids | wc -l) == 2 ]] && head_is applied && relay_ids | grep -Fxq "$RELAY"'
check 'same-commit replica repair runs no migration' '[[ $OUT != *"task fixture migration ran"* ]]'
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

web_id() { web | cut -d' ' -f1; }
other_id() { containers other-service | cut -d' ' -f1; }

write_slow_web() {
  write_web true "$1"
  sed -i "s/test: \\['CMD', 'true'\\].*}/test: ['CMD', 'test', '-f', '\\/tmp\\/rollout-ready'], interval: 2s, retries: 2, start_period: 2m }/" \
    "$S/webapp.yaml"
}

wait_for_web_candidate() {
  local previous=$1 attempt candidate
  for ((attempt = 0; attempt < 120; attempt++)); do
    candidate=$(web_id | grep -vxF "$previous" || true)
    if [[ -n $candidate ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    sleep 0.25
  done
  return 1
}

finish_background_agent() {
  RESULT=0
  wait "$AGENT_PID" || RESULT=$?
  OUT=$(</tmp/cadenway-rollout-log)
}

echo '=== 23. an unready public candidate keeps its edge endpoint and withholds internal aliases'
task_settings legacy 0
write_slow_web fourth
commit 'stage a candidate that waits for a readiness marker'
PREVIOUS=$(web_id)
PREVIOUS_IP=$(docker inspect --format '{{(index .NetworkSettings.Networks "cadenway-test_internal").IPAddress}}' "$PREVIOUS")
cadenway-agent >/tmp/cadenway-rollout-log 2>&1 &
AGENT_PID=$!
CANDIDATE=$(wait_for_web_candidate "$PREVIOUS")
check 'unready candidate keeps its edge endpoint and has no internal serving alias' \
  'docker inspect --format "{{json .NetworkSettings.Networks}}" "$CANDIDATE" \
    | jq -e '"'"'has("cadenway-edge-test") and (.["cadenway-test_internal"].Aliases // [] | length == 0)'"'"' >/dev/null'
DB=$(containers db | cut -d' ' -f1)
# Use the absolute service name so BusyBox ignores the host's DNS search suffix. Compare the
# distinct answers and retain the response for diagnostics if they differ from the previous address.
DNS_IPS=''
if DNS_RESPONSE=$(docker exec "$DB" nslookup -type=a webapp. 2>&1); then
  DNS_IPS=$(awk '
    /^Name:[[:space:]]/ { answer = 1; next }
    answer && /^Address([[:space:]]+[0-9]+)?:[[:space:]]/ { print $NF }
  ' <<<"$DNS_RESPONSE" | sort -u)
fi
OUT=$(printf '%s\nExpected DNS address: %s\nObserved DNS addresses: %s\n' \
  "$DNS_RESPONSE" "$PREVIOUS_IP" "$DNS_IPS")
check 'internal DNS still returns only the previous address' \
  '[[ -n $PREVIOUS_IP && $DNS_IPS == "$PREVIOUS_IP" ]]'
check 'the previous configuration is still served' \
  '[[ $(docker exec "$DB" wget -qO- http://webapp:8080/config.txt) == third ]]'
docker exec "$CANDIDATE" touch /tmp/rollout-ready
finish_background_agent
check 'ready candidate now serves through both networks' \
  'head_is applied && [[ $(web_id) == "$CANDIDATE" ]] && \
    docker inspect --format "{{json .NetworkSettings.Networks}}" "$CANDIDATE" \
      | jq -e '"'"'length == 2 and all(.[]; .Aliases | index("webapp") != null)'"'"' >/dev/null'
check 'the candidate serves the new configuration with the declared permissions' \
  '[[ $(docker exec "$DB" wget -qO- http://webapp:8080/config.txt) == fourth ]] && \
    [[ $(docker exec "$CANDIDATE" stat -c "%a %u %g" /srv/config.txt) == "444 0 0" ]]'

echo '=== 24. a later failure rolls back the full application batch'
PREVIOUS_WEB=$(web_id)
PREVIOUS_OTHER=$(other_id)
sed -i 's/^OTHER_SERVICE_VERSION=.*/OTHER_SERVICE_VERSION=1.36.1/' "$R/environments/test/versions.env"
write_web false broken
commit 'prepare other-service then fail webapp'
run_agent
check 'the earlier candidate was prepared before web failed' \
  '[[ $OUT == *"Container cadenway-test-other-service-"*"Created"* && $OUT == *"webapp: the new container could not be prepared"* ]]'
check 'both previous containers and the applied commit are retained' \
  'head_is failed && [[ $(web_id) == "$PREVIOUS_WEB" && $(other_id) == "$PREVIOUS_OTHER" ]] && \
    [[ $(git -C /opt/cadenway/envs/test rev-parse HEAD) == $(cat /var/lib/cadenway-agent/test/applied) ]]'
check 'the earlier candidate was removed, including from stopped containers' \
  '[[ $(docker ps -aq --filter label=com.docker.compose.project=cadenway-test \
      --filter label=com.docker.compose.service=other-service) == "$PREVIOUS_OTHER" ]]'

echo '=== 25. an interrupted readiness wait is recovered on the next tick'
sed -i 's/^OTHER_SERVICE_VERSION=.*/OTHER_SERVICE_VERSION=1.37.0/' "$R/environments/test/versions.env"
write_slow_web fifth
commit 'prepare an interrupted rollout'
cadenway-agent >/tmp/cadenway-rollout-log 2>&1 &
AGENT_PID=$!
CANDIDATE=$(wait_for_web_candidate "$PREVIOUS_WEB")
kill -KILL "$AGENT_PID"
finish_background_agent
check 'the uncommitted candidate was left running' \
  '[[ $RESULT == 137 && $(docker inspect --format "{{.State.Running}}" "$CANDIDATE") == true ]]'
# The readiness sleep inherits the lock descriptor and lasts at most two seconds.
flock /run/lock/cadenway-agent.lock true
mv -- "$R" "$R.offline"
run_agent
mv -- "$R.offline" "$R"
check 'offline recovery removes the candidate and keeps the last applied release serving' \
  '[[ $RESULT != 0 && $OUT == *"cannot fetch its release ref"* && $(web_id) == "$PREVIOUS_WEB" ]] && \
    ! docker inspect "$CANDIDATE" >/dev/null 2>&1 && [[ ! -d /var/lib/cadenway-agent/test/rollout ]]'
write_web true sixth
commit 'resume from a healthy release'
run_agent
check 'the interrupted candidate and its journal are gone' \
  'head_is applied && ! docker inspect "$CANDIDATE" >/dev/null 2>&1 && \
    [[ $(web | wc -l) == 1 && ! -d /var/lib/cadenway-agent/test/rollout ]]'

echo '=== 26. a failed dedicated companion brings the previous inline owner back'
PREVIOUS_TASK=$(task_id)
write_task "$TASK_REPLICAS" true false
task_settings dedicated 1
commit 'fail the first dedicated task relay'
run_agent
check 'the previous inline owner is restarted with the same container identity' \
  'head_is failed && [[ $(task_id) == "$PREVIOUS_TASK" && -z $(relay_ids) ]] && \
    [[ $(docker exec "$PREVIOUS_TASK" printenv TASK_SERVICE_OUTBOX_MODE) == legacy ]]'

echo '=== 27. a failure after the applied marker only postpones cleanup'
PREVIOUS_WEB=$(docker inspect --format '{{.Id}}' "$(web_id)")
write_web true seventh
write_task absent true true
task_settings legacy 0
commit 'apply a release and interrupt its cleanup'
cat >/usr/local/sbin/docker <<EOF
#!/bin/sh
if [ "\$1" = rm ] && [ "\${2:-}" = "$PREVIOUS_WEB" ]; then exit 75; fi
exec $REAL_DOCKER "\$@"
EOF
chmod +x /usr/local/sbin/docker
run_agent
rm -f /usr/local/sbin/docker
APPLIED_WEB=$(web_id)
check 'the new release serves while the retired original stays stopped' \
  '[[ $RESULT != 0 && -n $APPLIED_WEB ]] && head_is applied && \
    [[ $(docker inspect --format "{{.State.Running}}" "$PREVIOUS_WEB") == false ]]'
mv -- "$R" "$R.offline"
run_agent
mv -- "$R.offline" "$R"
check 'offline recovery removes only the stopped original and clears the committed journal' \
  '[[ $RESULT != 0 && $OUT == *"cannot fetch its release ref"* && $(web_id) == "$APPLIED_WEB" ]] && \
    ! docker inspect "$PREVIOUS_WEB" >/dev/null 2>&1 && \
    [[ ! -d /var/lib/cadenway-agent/test/rollout && ! -f /var/lib/cadenway-agent/test/retrying ]]'
run_agent
check 'the applied release stays intact when its ref is available again' \
  '[[ $RESULT == 0 && $(web_id) == "$APPLIED_WEB" ]] && head_is applied'

echo '=== 28. a public candidate without readiness keeps the previous release'
write_web true eighth
sed -i '/^    healthcheck:/d' "$S/webapp.yaml"
commit 'omit the healthcheck on a public service'
run_agent
check 'the public candidate is refused before it starts' \
  'head_is failed && [[ $(web_id) == "$APPLIED_WEB" && $OUT == *"an exposed candidate needs its edge network and a healthcheck"* ]]'

echo '=== 29. another service variable in a config is refused before rollout'
PREVIOUS=$(web | cut -d' ' -f1)
write_web true '${DATA_SERVICE_DATABASE_URL}'
commit 'request a disallowed config reference'
run_agent
check 'service scope violation failed the commit without replacing the previous container' \
  'head_is failed && [[ $(web | cut -d" " -f1) == "$PREVIOUS" && $OUT == *"outside the service grant"* ]]'

echo '=== 30. offline recovery removes only the one-off migration recorded by the agent'
write_web true seventh
write_data dropped
sed -i '/printf .*migrated with/i\      sleep 120' "$S/data-service.yaml"
commit 'hold an agent managed migration open while the agent stops'
PREVIOUS_DATA=$(data_id)
MANUAL_MIGRATION=$(docker run --detach --rm --pull never --network none \
  --label com.docker.compose.project=cadenway-test --label com.docker.compose.oneoff=True \
  --label com.docker.compose.service=data-service --label io.cadenway.agent.migration=data-service.manual \
  busybox:1.37.0 sleep 120)
setsid cadenway-agent >/tmp/cadenway-rollout-log 2>&1 &
AGENT_PID=$!
for ((attempt = 0; attempt < 120; attempt++)); do
  MIGRATOR=$(docker ps -q --no-trunc --filter label=com.docker.compose.project=cadenway-test \
    --filter label=com.docker.compose.oneoff=True --filter label=com.docker.compose.service=data-service \
    --filter label=io.cadenway.agent.migration | grep -vxF "$MANUAL_MIGRATION" || true)
  [[ -z $MIGRATOR ]] || break
  sleep 0.25
done
kill -KILL -- "-$AGENT_PID"
finish_background_agent
check 'the agent-owned migration is still running after the process group was stopped' \
  '[[ $RESULT == 137 && -n $MIGRATOR && $(docker inspect --format "{{.State.Running}}" "$MIGRATOR") == true ]]'
flock -w 10 /run/lock/cadenway-agent.lock true
mv -- "$R" "$R.offline"
run_agent
mv -- "$R.offline" "$R"
check 'the interrupted migration is removed before fetching and the unrelated one-off remains' \
  '[[ $RESULT != 0 && $OUT == *"cannot fetch its release ref"* && $(data_id) == "$PREVIOUS_DATA" ]] && \
    ! docker inspect "$MIGRATOR" >/dev/null 2>&1 && [[ ! -d /var/lib/cadenway-agent/test/rollout ]] && \
    [[ $(docker inspect --format "{{.State.Running}}" "$MANUAL_MIGRATION") == true ]]'
docker rm -f "$MANUAL_MIGRATION" >/dev/null

exit $FAILED
