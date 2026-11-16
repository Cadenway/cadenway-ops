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
#      not healthy: run its migrations in a one-off container, to which the agent gives the migrator
#      URL of its database, start the new container beside the old one, wait for `healthy`, then
#      remove the old one. A failure keeps the old container;
#      reconcile allowlisted companion replicas after their owners, with migrations on owners only;
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
# Companions are defined in their owner's Compose file and share its release and database.
declare -Ar COMPANION_OWNERS=(
  [task-service-relay]=task-service
  [notification-service-worker]=notification-service
)
# Positive replica counts require the owner's inline background process to be disabled.
declare -Ar COMPANION_OWNER_MODES=(
  [task-service-relay]=TASK_SERVICE_OUTBOX_MODE=dedicated
  [notification-service-worker]=NOTIFICATION_SERVICE_PROCESS_ROLE=api
)
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
  local process_file=$worktree/environments/$env/processes.env
  local -a process_settings=()
  [[ ! -f $process_file ]] || process_settings=(--env-file "$process_file")
  CADENWAY_SERVICES=../environments/$env/services \
    docker compose -p "cadenway-$env" --project-directory "$worktree/compose" \
    -f "$worktree/compose/compose.yaml" \
    --env-file "$SETTINGS_DIR/env/$env.env" \
    --env-file "$worktree/environments/$env/versions.env" \
    --env-file "$SECRETS_DIR/$env/secrets.env" \
    "${process_settings[@]}" \
    "$@"
}

# Replica counts and owner modes are desired Git state, independent of image releases. Keep the
# optional file limited to these literal, non-secret settings before Compose interpolates it.
valid_process_settings() {
  local file=$ROOT/envs/$1/environments/$1/processes.env line key
  local -A seen=()
  [[ ! -L $file ]] || return 1
  [[ -e $file ]] || return 0
  [[ -f $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    case $line in
      '' | \#*) continue ;;
      TASK_SERVICE_RELAY_REPLICAS=[012] | NOTIFICATION_SERVICE_WORKER_REPLICAS=[012] | \
        TASK_SERVICE_OUTBOX_MODE=legacy | TASK_SERVICE_OUTBOX_MODE=dedicated | \
        NOTIFICATION_SERVICE_PROCESS_ROLE=combined | NOTIFICATION_SERVICE_PROCESS_ROLE=api) ;;
      *) return 1 ;;
    esac
    key=${line%%=*}
    [[ ! -v seen[$key] ]] || return 1
    seen[$key]=1
  done <"$file"
}

# Deployables are the files of environments/<env>/services/; their version is <NAME>_VERSION.
version_variable() { printf '%s_VERSION' "$(tr '[:lower:]-' '[:upper:]_' <<<"$1")"; }
# The secret that holds the URL of a deployable's database migrator, as the definitions named it
# when they referenced it: TASK_SERVICE_MIGRATION_DATABASE_URL for task-service.
migration_variable() {
  printf '%s_MIGRATION_DATABASE_URL' "$(tr '[:lower:]-' '[:upper:]_' <<<"$1")"
}

# Deployables of the environment whose definition connects to a database (declares DATABASE_URL):
# their migrations run as the migrator of that database, so each one needs its migrator URL.
database_deployables() {
  local env=$1
  env_compose "$env" config --format json 2>/dev/null |
    jq -r '.services | to_entries[] | select(.value.environment.DATABASE_URL != null) | .key' |
    grep -xF -f <(basename -s .yaml "$ROOT/envs/$env/environments/$env/services"/*.yaml) || true
}

# Container ids of one service of the environment, oldest first. Only companions reconcile stopped
# containers as well, so abandoned rollout candidates cannot accumulate across commits.
service_containers() {
  local -a states=()
  [[ ${3:-} != all ]] || states=(--all)
  docker ps "${states[@]}" --filter "label=com.docker.compose.project=cadenway-$1" \
    --filter "label=com.docker.compose.service=$2" --format '{{.CreatedAt}}|{{.ID}}' |
    sort | cut -d'|' -f2
}

container_health() {
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1"
}

# Waits until every given container reports `healthy` or, for owners without a healthcheck,
# `running`. Fails on an unhealthy status, an exit or a timeout.
wait_healthy() {
  local required=$1 deadline=$((SECONDS + HEALTH_TIMEOUT)) id status
  shift
  for id in "$@"; do
    while :; do
      status=$(container_health "$id") || return 1
      case $status in
        healthy) break ;;
        running) [[ $required == yes ]] || break ;;
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
# The agent gives that container the migrator URL of the service (migration_variable, from the
# secrets) as MIGRATION_DATABASE_URL, so no definition has to declare it: once a definition drops
# the entry, its long-running container connects as the application role only and never holds the
# owner of its schema (docs/database.md). `-e` without a value makes Compose read it from the
# environment of this one command, so it never appears in an argument list; it overrides the entry
# a definition may still carry. A deployable without a database has no such secret and gets nothing.
migrate() {
  local env=$1 service=$2 url
  local -a forward=()
  url=$(dotenv_value "$SECRETS_DIR/$env/secrets.env" "$(migration_variable "$service")")
  if [[ -n $url ]]; then
    forward=(-e MIGRATION_DATABASE_URL)
  fi
  MIGRATION_DATABASE_URL=$url env_compose "$env" run --rm --no-deps -T "${forward[@]}" "$service" \
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
  if ((${#new[@]} == 0)) || ! wait_healthy no "${new[@]}"; then
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

# A companion is an internal process, using its owner's image and application database. A missing
# definition is equivalent to zero replicas, including when rolling back to an older Compose file.
companion_replicas() {
  local env=$1 service=$2 owner=${COMPANION_OWNERS[$2]}
  local owner_mode=${COMPANION_OWNER_MODES[$service]}
  env_compose "$env" config --format json | jq -er --arg service "$service" --arg owner "$owner" \
    --arg mode_variable "${owner_mode%%=*}" --arg mode "${owner_mode#*=}" '
    .services[$service] as $companion | .services[$owner] as $owner
    | if $companion == null then 0
      elif $owner == null or $companion.image != $owner.image
        or ($companion.networks // {} | keys) != ["internal"]
        or ($companion.labels // {} | length) != 0
        or ($companion.ports // [] | length) != 0
        or $companion.network_mode != null
        or ($companion.healthcheck.test // ["NONE"])[0] == "NONE"
        or $companion.healthcheck.disable == true
        or ($companion.environment.DATABASE_URL // "") == ""
        or $companion.environment.DATABASE_URL != $owner.environment.DATABASE_URL
        or ($companion.environment // {} | has("MIGRATION_DATABASE_URL"))
        or ([0, 1, 2] | index($companion.deploy.replicas)) == null
        or ($companion.deploy.replicas > 0 and (
          $owner.environment[$mode_variable] != $mode
          or ($owner.healthcheck.test // ["NONE"])[0] == "NONE"
          or $owner.healthcheck.disable == true))
      then error("invalid companion definition")
      else $companion.deploy.replicas end'
}

# Stops only containers identified by this environment and companion's Compose labels. A longer
# grace than for HTTP services lets Nest close the worker and settle an in-flight attempt.
stop_companion() {
  local id
  for id in "$@"; do
    docker stop --time 60 "$id" >/dev/null && docker rm "$id" >/dev/null || return 1
  done
}

# Reconciles a companion after its owner applied. Keep healthy matching replicas on scale changes.
# Start replacement candidates together and wait for all of them before touching older instances.
apply_companion() {
  local env=$1 service=$2 replicas=$3 inventory record desired hash id count code=0
  local -a before=() kept=() obsolete=() new=()
  inventory=$(service_containers "$env" "$service" all) || return 1
  mapfile -t before < <(printf '%s' "$inventory")
  if ((replicas == 0)); then
    stop_companion "${before[@]}"
    return
  fi

  record=$STATE_DIR/$env/services/$service
  desired=$(fingerprint "$env" "$service") || return 1
  hash=${desired%% *}
  for id in "${before[@]}"; do
    if ((${#kept[@]} < replicas)) && [[ $(read_state "$record") == "$desired" ]] &&
      [[ $(container_health "$id") == healthy ]] &&
      [[ $(docker inspect --format '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$id") == "$hash" ]]; then
      kept+=("$id")
    else
      obsolete+=("$id")
    fi
  done

  count=$((replicas - ${#kept[@]}))
  if ((count > 0)); then
    env_compose "$env" pull --quiet "$service" || return "$TRANSIENT"
    # Create without starting, so Compose cannot restart a stopped container from an older release.
    env_compose "$env" up --no-start --no-deps --no-recreate \
      --scale "$service=$((${#before[@]} + count))" "$service" || code=$?
    inventory=$(service_containers "$env" "$service" all) || return 1
    mapfile -t new < <(comm -13 <(printf '%s\n' "${before[@]}" | sort) <(printf '%s\n' "$inventory" | sort))
    if ((code != 0 || ${#new[@]} != count)) || ! docker start "${new[@]}" >/dev/null ||
      ! wait_healthy yes "${new[@]}"; then
      log "$env/$service: companion candidates failed; retaining the earlier instances"
      for id in "${new[@]}"; do docker rm -f "$id" >/dev/null || true; done
      return 1
    fi
  fi
  stop_companion "${obsolete[@]}" || return 1
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

# Names of the variables the stack uses but nobody set (versions excepted: unreleased is allowed),
# and of the migrator URLs missing from the secrets. No definition has to reference a migrator URL:
# the agent gives it to the migration container itself, so it checks each one as Compose checks a
# referenced variable, and a commit without it is refused before anything changes.
missing_variables() {
  local env=$1 secrets=$SECRETS_DIR/$1/secrets.env service variable
  {
    env_compose "$env" config -q 2>&1 >/dev/null |
      grep -o 'The [^ ]* variable is not set' | tr -d '\\"' | awk '{print $2}' |
      grep -v '_VERSION$' || true
    for service in $(database_deployables "$env"); do
      variable=$(migration_variable "$service")
      [[ -n $(dotenv_value "$secrets" "$variable") ]] || printf '%s\n' "$variable"
    done
  } | sort -u
}

# Applies one environment at a commit. Returns 0 when applied, 1 when the commit failed (recorded,
# not retried), TRANSIENT when it will be tried again on the next tick.
apply_environment() {
  local env=$1 commit=$2
  local worktree=$ROOT/envs/$env state=$STATE_DIR/$env
  local applied failed start=$SECONDS file service version missing code owner replicas result=0
  local -a deployables=() infrastructure=() changed=()
  local -A companion_targets=() owners_applied=()
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
  if ! valid_process_settings "$env"; then
    result=1
    log "$env: invalid process settings in processes.env"
  elif ! decrypt_secrets "$env"; then
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
    for service in "${!COMPANION_OWNERS[@]}"; do
      owner=${COMPANION_OWNERS[$service]}
      if [[ -e $worktree/environments/$env/services/$service.yaml ]] ||
        ! replicas=$(companion_replicas "$env" "$service"); then
        log "$env/$service: invalid companion declaration for $owner"
        result=1
        break
      fi
      version=$(dotenv_value "$worktree/environments/$env/versions.env" "$(version_variable "$owner")")
      companion_targets[$service]=${replicas:-0}
      [[ -n $version ]] || companion_targets[$service]=0
    done
  fi

  if ((result == 0)); then
    # A deployable without a version (never released) is not started.
    for file in "$worktree/environments/$env/services"/*.yaml; do
      service=$(basename "$file" .yaml)
      version=$(dotenv_value "$worktree/environments/$env/versions.env" "$(version_variable "$service")")
      [[ -n $version ]] && deployables+=("$service")
    done
    mapfile -t infrastructure < <(env_compose "$env" config --services |
      grep -vxF -f <(basename -s .yaml "$worktree/environments/$env/services"/*.yaml) |
      grep -vxF -f <(printf '%s\n' "${!COMPANION_OWNERS[@]}"))
    if ((${#infrastructure[@]} == 0)); then
      result=1
    elif ! env_compose "$env" pull --quiet "${infrastructure[@]}" ||
      ! env_compose "$env" up -d --wait --wait-timeout 120 "${infrastructure[@]}"; then
      result=$TRANSIENT
      log "$env: the infrastructure services did not come up"
    fi
  fi

  if ((result == 0)); then
    # Stop disabled companions first. A rollback may re-enable background processing in the owner.
    for service in "${!companion_targets[@]}"; do
      if [[ ${companion_targets[$service]} == 0 ]] && ! apply_companion "$env" "$service" 0; then
        log "$env/$service: unable to stop the companion before applying its owner"
        result=1
      fi
    done
  fi

  if ((result == 0)); then
    for service in "${deployables[@]}"; do
      code=0
      apply_service "$env" "$service" || code=$?
      if ((code == 0)); then
        owners_applied[$service]=1
        changed+=("$service")
      elif ((code == TRANSIENT)); then
        ((result == 1)) || result=$TRANSIENT
      else
        result=1
        notify "cadenway $env: $service failed at ${commit:0:12}; the previous container keeps serving"
      fi
    done
    for service in "${!companion_targets[@]}"; do
      owner=${COMPANION_OWNERS[$service]}
      replicas=${companion_targets[$service]}
      if ((replicas == 0)) || [[ ! -v owners_applied[$owner] ]]; then
        continue
      fi
      code=0
      apply_companion "$env" "$service" "$replicas" || code=$?
      if ((code == 0)); then
        changed+=("$service")
      elif ((code == TRANSIENT)); then
        ((result == 1)) || result=$TRANSIENT
      else
        result=1
        notify "cadenway $env: $service failed at ${commit:0:12}; the previous containers keep serving"
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
