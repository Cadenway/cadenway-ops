#!/usr/bin/env bash
# GitOps agent of a Cadenway host: applies what cadenway-ops `main` describes, one run per timer tick.
#
# Pull-only: the host fetches the repository with a read-only deploy key; nothing reaches the VPS from
# outside. One host runs one or several environments (CADENWAY_ENVIRONMENTS), each as the Compose
# project cadenway-<env> with its own definitions (environments/<env>/services/), behind the single
# Traefik of the cadenway-edge project.
#
# For each environment, on a new commit:
#   1. check out the commit in the environment's worktree and decrypt its secrets into /run (tmpfs);
#   2. validate (no missing variable), pull, bring the infrastructure services up (idempotent);
#   3. for every deployable whose version is set and whose fingerprint changed or whose container is
#      not healthy: run its migrations in a one-off container, start the new container beside the old
#      one, wait for `healthy`, then remove the old one. A failure keeps the old container;
#   4. record the commit as applied; or as failed when the desired state itself is wrong (never
#      retried); or retry on the next tick when the failure is transient (registry, network), and
#      notify once per commit.
#
# Configuration: /etc/cadenway/agent.env (written by Ansible). Decrypted values are never logged.
set -euo pipefail

readonly CONFIG_FILE=${CADENWAY_AGENT_CONFIG:-/etc/cadenway/agent.env}
# Plain KEY=value lines, exported so git sees GIT_SSH_COMMAND.
if [[ -r $CONFIG_FILE ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  set +a
fi

: "${CADENWAY_REPO_URL:?CADENWAY_REPO_URL is required}"
readonly BRANCH=${CADENWAY_BRANCH:-main}
readonly ENVIRONMENTS=${CADENWAY_ENVIRONMENTS:?CADENWAY_ENVIRONMENTS is required}
readonly ROOT=${CADENWAY_ROOT:-/opt/cadenway}
readonly SETTINGS_DIR=${CADENWAY_SETTINGS_DIR:-/etc/cadenway}
readonly STATE_DIR=${CADENWAY_STATE_DIR:-/var/lib/cadenway-agent}
readonly SECRETS_DIR=${CADENWAY_SECRETS_DIR:-/run/cadenway}
readonly HEALTH_TIMEOUT=${CADENWAY_HEALTH_TIMEOUT:-60}
readonly LOCK_FILE=${CADENWAY_LOCK_FILE:-/run/lock/cadenway-agent.lock}
readonly MIRROR=$ROOT/ops.git
# Exit status of a failure worth retrying on the next tick (sysexits EX_TEMPFAIL).
readonly TRANSIENT=75
export SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-/etc/cadenway/age.key}

ALERT_WEBHOOK_URL=''

log() { printf '%s\n' "$*" >&2; }

# Posts a one-line message to the environment's webhook (Slack-compatible `text`); logs it always.
# The URL is a secret: it reaches curl through a config file descriptor, never through its arguments.
notify() {
  local message=$1
  log "$message"
  [[ -n $ALERT_WEBHOOK_URL ]] || return 0
  jq -cn --arg text "$message" '{text: $text}' |
    curl -fsS --max-time 10 -H 'Content-Type: application/json' --data @- \
      --config <(printf 'url = "%s"\n' "$ALERT_WEBHOOK_URL") >/dev/null ||
    log "notify: the webhook did not accept the message"
}

# Keeps a bare mirror of the repository up to date with the branch.
fetch() {
  if [[ ! -d $MIRROR ]]; then
    git clone --quiet --bare "$CADENWAY_REPO_URL" "$MIRROR" || return 1
  fi
  git -C "$MIRROR" fetch --quiet --prune origin "+refs/heads/$BRANCH:refs/heads/$BRANCH"
}

# Checks out a commit, detached, in a stable worktree: Compose sees the same paths on every run.
# A worktree whose link to the mirror broke (mirror recreated) is created again.
checkout() {
  local worktree=$1 commit=$2
  if [[ -e $worktree/.git ]] && git -C "$worktree" checkout --quiet --detach --force "$commit"; then
    return 0
  fi
  rm -rf "$worktree"
  git -C "$MIRROR" worktree prune
  git -C "$MIRROR" worktree add --quiet --detach --force "$worktree" "$commit"
}

read_state() { cat "$1" 2>/dev/null || true; }

# Reads one variable from a dotenv file without sourcing it.
dotenv_value() {
  local file=$1 name=$2
  sed -n "s/^${name}=//p" "$file" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# The single Traefik of the host; Compose recreates it only when its definition changed.
apply_edge() {
  local commit=$1 worktree=$ROOT/edge applied
  applied=$(read_state "$STATE_DIR/edge/applied")
  [[ $applied == "$commit" ]] && return 0
  checkout "$worktree" "$commit" || return 1
  docker compose -p cadenway-edge --project-directory "$worktree/compose" \
    -f "$worktree/compose/edge.yaml" --env-file "$SETTINGS_DIR/edge.env" \
    up -d --wait --wait-timeout 120 --remove-orphans || return 1
  mkdir -p "$STATE_DIR/edge"
  printf '%s\n' "$commit" >"$STATE_DIR/edge/applied"
}

# Runs docker compose for one environment with its definitions, settings, versions and secrets.
env_compose() {
  local env=$1
  shift
  local worktree=$ROOT/envs/$env
  CADENWAY_SERVICES=../environments/$env/services \
    docker compose -p "cadenway-$env" --project-directory "$worktree/compose" \
    -f "$worktree/compose/compose.yaml" \
    --env-file "$SETTINGS_DIR/env/$env.env" \
    --env-file "$worktree/environments/$env/versions.env" \
    --env-file "$SECRETS_DIR/$env/secrets.env" \
    "$@"
}

# Deployables are the files of environments/<env>/services/; their version is <NAME>_VERSION.
version_variable() { printf '%s_VERSION' "$(tr '[:lower:]-' '[:upper:]_' <<<"$1")"; }

# Container ids of one service of the environment, oldest first.
service_containers() {
  docker ps --filter "label=com.docker.compose.project=cadenway-$1" \
    --filter "label=com.docker.compose.service=$2" --format '{{.CreatedAt}}|{{.ID}}' |
    sort | cut -d'|' -f2
}

container_health() {
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1"
}

# Waits until every given container reports `healthy`; fails on `unhealthy`, an exit or the timeout.
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) id status
  for id in "$@"; do
    while :; do
      status=$(container_health "$id")
      case $status in
        healthy | running) break ;;
        unhealthy | exited | dead) return 1 ;;
      esac
      ((SECONDS < deadline)) || return 1
      sleep 2
    done
  done
}

# Fingerprint of what a service should run: Compose's own hash (image, environment, definition)
# plus the contents of the configs it mounts, which that hash leaves out.
fingerprint() {
  local env=$1 service=$2 hash configs
  hash=$(env_compose "$env" config --hash "$service" | awk '{print $2}') || return 1
  [[ -n $hash ]] || return 1
  configs=$(env_compose "$env" config --format json | jq -r --arg s "$service" '
    [.services[$s].configs // [] | .[] | .source] as $used
    | [.configs // {} | to_entries[] | select(.key as $k | $used | index($k)) | .value.content // ""]
    | tostring' | sha256sum | cut -d' ' -f1) || return 1
  printf '%s %s\n' "$hash" "$configs"
}

# Applies the service's migrations in a one-off container; images without dist/migrate.js have none.
migrate() {
  env_compose "$1" run --rm --no-deps -T "$2" \
    sh -c 'if [ -f dist/migrate.js ]; then exec node dist/migrate.js; fi'
}

# Starts the new container beside the old ones, then removes the old ones once it is healthy.
# Compose keeps the old containers (`--no-recreate`) and adds one with the desired configuration;
# Traefik only routes to healthy containers, the Docker DNS of the internal network to both.
roll_out() {
  local env=$1 service=$2 old new id
  mapfile -t old < <(service_containers "$env" "$service")
  env_compose "$env" up -d --no-deps --no-recreate \
    --scale "$service=$((${#old[@]} + 1))" "$service" || return 1
  mapfile -t new < <(comm -13 <(printf '%s\n' "${old[@]}" | sort) \
    <(service_containers "$env" "$service" | sort))
  if ((${#new[@]} == 0)) || ! wait_healthy "${new[@]}"; then
    log "$env/$service: the new container is not healthy; the old one keeps serving"
    for id in "${new[@]}"; do docker rm -f "$id" >/dev/null || true; done
    return 1
  fi
  for id in "${old[@]}"; do
    docker stop --time 30 "$id" >/dev/null && docker rm "$id" >/dev/null || return 1
  done
}

# Brings one deployable to its desired state. A no-op when its fingerprint is the one applied and
# every container runs that configuration and is healthy. Returns 1 when the desired state fails
# (migrations, health), TRANSIENT when its image cannot be pulled.
apply_service() {
  local env=$1 service=$2 record desired hash container
  local -a running
  record=$STATE_DIR/$env/services/$service
  desired=$(fingerprint "$env" "$service") || return 1
  hash=${desired%% *}
  mapfile -t running < <(service_containers "$env" "$service")
  if ((${#running[@]})) && [[ $(read_state "$record") == "$desired" ]]; then
    local unchanged=true
    for container in "${running[@]}"; do
      [[ $(docker inspect --format '{{index .Config.Labels "com.docker.compose.config-hash"}}' \
        "$container") == "$hash" ]] || unchanged=false
      [[ $(container_health "$container") =~ ^(healthy|running)$ ]] || unchanged=false
    done
    [[ $unchanged == true ]] && return 0
  fi

  env_compose "$env" pull --quiet "$service" || {
    log "$env/$service: the image cannot be pulled"
    return "$TRANSIENT"
  }
  migrate "$env" "$service" || {
    log "$env/$service: the migrations failed"
    return 1
  }
  if ((${#running[@]} == 0)); then
    if ! env_compose "$env" up -d --no-deps --wait --wait-timeout "$HEALTH_TIMEOUT" "$service"; then
      # An unhealthy first container would later look applied: it goes.
      env_compose "$env" rm --stop --force "$service" >/dev/null || true
      log "$env/$service: the first container is not healthy"
      return 1
    fi
  else
    roll_out "$env" "$service" || return 1
  fi
  mkdir -p "${record%/*}"
  printf '%s\n' "$desired" >"$record"
}

# Decrypts the environment's secrets into tmpfs, readable by root only. Values are written
# single-quoted so Compose takes them literally: a `$` in a password is neither expanded nor logged.
decrypt_secrets() {
  local env=$1 worktree=$ROOT/envs/$1 plain line key value
  install -d -m 0700 "$SECRETS_DIR/$env" || return 1
  plain=$(sops --decrypt --input-type dotenv --output-type dotenv \
    "$worktree/environments/$env/secrets.sops.env") || return 1
  (
    umask 077
    while IFS= read -r line; do
      [[ -z $line || $line == \#* ]] && continue
      key=${line%%=*}
      value=${line#*=}
      if [[ $value == *"'"* ]]; then
        log "$env: the secret $key contains a single quote, which an env file cannot carry"
        exit 1
      fi
      printf "%s='%s'\n" "$key" "$value"
    done <<<"$plain" >"$SECRETS_DIR/$env/secrets.env"
  )
}

# Logs in to GHCR when the environment has a pull token (private images). The credentials live in a
# per-run Docker configuration under /run, never in /root/.docker.
login_registry() {
  local env=$1 secrets=$SECRETS_DIR/$1/secrets.env user token
  token=$(dotenv_value "$secrets" GHCR_PULL_TOKEN)
  [[ -n $token ]] || return 0
  user=$(dotenv_value "$secrets" GHCR_PULL_USER)
  export DOCKER_CONFIG=$SECRETS_DIR/$env/docker
  install -d -m 0700 "$DOCKER_CONFIG"
  docker login ghcr.io --username "${user:-cadenway}" --password-stdin <<<"$token" >/dev/null
}

# Names of the variables the stack uses but nobody set (versions excepted: unreleased is allowed).
missing_variables() {
  env_compose "$1" config -q 2>&1 >/dev/null |
    grep -o 'The [^ ]* variable is not set' | tr -d '\\"' | awk '{print $2}' |
    grep -v '_VERSION$' | sort -u || true
}

# Applies one environment at a commit. Returns 0 when applied, 1 when the commit failed (recorded,
# not retried), TRANSIENT when it will be tried again on the next tick.
apply_environment() {
  local env=$1 commit=$2
  local worktree=$ROOT/envs/$env state=$STATE_DIR/$env
  local applied failed start=$SECONDS file service version missing code result=0
  local -a deployables=() infrastructure=() changed=()
  mkdir -p "$state"
  applied=$(read_state "$state/applied")
  failed=$(read_state "$state/failed")
  [[ $commit == "$applied" ]] && return 0
  if [[ $commit == "$failed" ]]; then
    log "$env: ${commit:0:12} failed before; waiting for a new commit"
    return 0
  fi
  if ! docker network inspect "cadenway-edge-$env" >/dev/null 2>&1; then
    log "$env: the edge network cadenway-edge-$env does not exist yet; waiting for the edge"
    return "$TRANSIENT"
  fi

  ALERT_WEBHOOK_URL=''
  if ! checkout "$worktree" "$commit"; then
    log "$env: ${commit:0:12} cannot be checked out; trying again on the next tick"
    return "$TRANSIENT"
  fi
  if ! decrypt_secrets "$env"; then
    result=1
    log "$env: the secrets of ${commit:0:12} cannot be decrypted by this host"
  else
    ALERT_WEBHOOK_URL=$(dotenv_value "$SECRETS_DIR/$env/secrets.env" ALERT_WEBHOOK_URL)
    missing=$(missing_variables "$env")
    if [[ -n $missing ]]; then
      result=1
      notify "cadenway $env: ${commit:0:12} misses $(tr '\n' ' ' <<<"$missing")"
    elif ! env_compose "$env" config -q; then
      result=1
    elif ! login_registry "$env"; then
      result=$TRANSIENT
      log "$env: the GHCR login failed"
    fi
  fi

  if ((result == 0)); then
    # A deployable without a version (never released) is not started.
    for file in "$worktree/environments/$env/services"/*.yaml; do
      service=$(basename "$file" .yaml)
      version=$(dotenv_value "$worktree/environments/$env/versions.env" "$(version_variable "$service")")
      [[ -n $version ]] && deployables+=("$service")
    done
    mapfile -t infrastructure < <(env_compose "$env" config --services |
      grep -vxF -f <(basename -s .yaml "$worktree/environments/$env/services"/*.yaml))
    if ((${#infrastructure[@]} == 0)); then
      result=1
    elif ! env_compose "$env" pull --quiet "${infrastructure[@]}" ||
      ! env_compose "$env" up -d --wait --wait-timeout 120 "${infrastructure[@]}"; then
      result=$TRANSIENT
      log "$env: the infrastructure services did not come up"
    fi
  fi

  if ((result == 0)); then
    for service in "${deployables[@]}"; do
      code=0
      apply_service "$env" "$service" || code=$?
      if ((code == 0)); then
        changed+=("$service")
      elif ((code == TRANSIENT)); then
        ((result == 1)) || result=$TRANSIENT
      else
        result=1
        notify "cadenway $env: $service failed at ${commit:0:12}; the previous container keeps serving"
      fi
    done
  fi

  rm -rf "${SECRETS_DIR:?}/$env"
  unset DOCKER_CONFIG
  case $result in
    0)
      printf '%s\n' "$commit" >"$state/applied"
      rm -f "$state/failed" "$state/retrying"
      notify "cadenway $env: ${commit:0:12} applied in $((SECONDS - start)) s; checked ${changed[*]:-no deployable} ($(git -C "$worktree" log -1 --format=%s))"
      ;;
    "$TRANSIENT")
      # Tried again every tick; said once per commit.
      if [[ $(read_state "$state/retrying") != "$commit" ]]; then
        printf '%s\n' "$commit" >"$state/retrying"
        notify "cadenway $env: ${commit:0:12} not fully applied (registry, network or start-up); retrying every minute"
      fi
      ;;
    *)
      printf '%s\n' "$commit" >"$state/failed"
      rm -f "$state/retrying"
      # The worktree goes back to what runs, so a manual `docker compose` sees the applied state.
      [[ -n $applied ]] && checkout "$worktree" "$applied"
      notify "cadenway $env: ${commit:0:12} FAILED after $((SECONDS - start)) s; not retried until a new commit"
      ;;
  esac
  return "$result"
}

main() {
  local commit env status=0
  exec 9>"$LOCK_FILE"
  flock -n 9 || {
    log 'another run is in progress'
    exit 0
  }
  # Only the run holding the lock cleans up: decrypted secrets never outlive it.
  trap 'rm -rf "${SECRETS_DIR:?}"/*' EXIT
  mkdir -p "$ROOT/envs" "$STATE_DIR"
  if ! fetch; then
    log "cannot fetch $BRANCH from $CADENWAY_REPO_URL: check the deploy key and the network"
    exit 1
  fi
  commit=$(git -C "$MIRROR" rev-parse "refs/heads/$BRANCH")
  apply_edge "$commit" || {
    log "edge: ${commit:0:12} failed; environments without their edge network wait"
    status=1
  }
  for env in $ENVIRONMENTS; do
    apply_environment "$env" "$commit" || status=1
  done
  return "$status"
}

main "$@"
