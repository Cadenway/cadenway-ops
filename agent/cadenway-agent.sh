#!/usr/bin/env bash
# GitOps agent of a Cadenway host: applies approved Ops releases, one run per timer tick.
#
# Pull-only: the host fetches the repository with a read-only deploy key; nothing reaches the VPS from
# outside. One host runs one or several environments (CADENWAY_ENVIRONMENTS), each as the Compose
# project cadenway-<env> with its own definitions (environments/<env>/services/), behind the single
# Traefik of the cadenway-edge project.
#
# For each environment, on a new commit:
#   1. check out the commit, validate its service definitions, decrypt its secrets into /run (tmpfs);
#   2. check for missing settings, pull and bring infrastructure services up (idempotent);
#   3. for every deployable whose version is set and whose fingerprint changed or whose container is
#      not healthy: run its migrations in a one-off container, to which the agent gives the migrator
#      URL of its database, start the new container without serving aliases, wait for `healthy`;
#      prepare companion replicas, then promote the healthy batch and retire obsolete containers.
#      An interrupted batch is recovered from its local journal before applying another commit;
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
readonly PRODUCTION_BRANCH=${CADENWAY_PRODUCTION_BRANCH:-production}
readonly ENVIRONMENTS=${CADENWAY_ENVIRONMENTS:?CADENWAY_ENVIRONMENTS is required}
readonly ROOT=${CADENWAY_ROOT:-/opt/cadenway}
readonly SETTINGS_DIR=${CADENWAY_SETTINGS_DIR:-/etc/cadenway}
readonly RELEASE_SIGNERS=${CADENWAY_RELEASE_SIGNERS:-$SETTINGS_DIR/release-signers}
readonly PRODUCTION_SIGNERS=${CADENWAY_PRODUCTION_SIGNERS:-$SETTINGS_DIR/production-signers}
readonly STATE_DIR=${CADENWAY_STATE_DIR:-/var/lib/cadenway-agent}
readonly SECRETS_DIR=${CADENWAY_SECRETS_DIR:-/run/cadenway}
readonly HEALTH_TIMEOUT=${CADENWAY_HEALTH_TIMEOUT:-60}
readonly LOCK_FILE=${CADENWAY_LOCK_FILE:-/run/lock/cadenway-agent.lock}
readonly MIRROR=$ROOT/ops.git
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
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

# Keeps a bare mirror of only the configured release refs.
fetch() {
  local branch
  local -a refspecs=()
  for branch in "$@"; do
    git check-ref-format "refs/heads/$branch" || return 1
    refspecs+=("+refs/heads/$branch:refs/heads/$branch")
  done
  if [[ ! -d $MIRROR ]]; then
    git init --quiet --bare "$MIRROR" &&
      git -C "$MIRROR" remote add origin "$CADENWAY_REPO_URL" || return 1
  fi
  git -C "$MIRROR" fetch --quiet --no-tags --prune origin "${refspecs[@]}"
}

# The public trust store lives on the host. Verify before worktree checkout or any Compose apply.
# OpenPGP/X.509 signatures cannot substitute for the separately authorized Ops SSH signer.
authorized_commit() {
  local commit=$1 signers=$2 applied=$3
  [[ $signers == /* && -s $signers && -f $signers && ! -L $signers ]] || return 1
  git -C "$MIRROR" \
    -c gpg.minTrustLevel=fully \
    -c gpg.ssh.allowedSignersFile="$signers" \
    -c gpg.openpgp.program=/bin/false \
    -c gpg.x509.program=/bin/false \
    verify-commit "$commit" >/dev/null 2>&1 || return 1
  descends_from "$commit" "$applied"
}

descends_from() {
  local commit=$1 applied=$2
  [[ -z $applied ]] || git -C "$MIRROR" merge-base --is-ancestor "$applied" "$commit"
}

# An approval for staging alone may change its app manifests and versions. Infrastructure, SOPS
# sources and process settings on a shared daemon also need the production approval.
has_approved_host_inputs() {
  local release=$1 production=$2 env=$3
  git -C "$MIRROR" diff --quiet --no-ext-diff --no-textconv "$production" "$release" -- \
    compose "environments/$env" ":(exclude)environments/$env/services" \
    ":(exclude)environments/$env/versions.env"
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

# Runs Compose for one environment using only the service documents staged by the installed policy.
env_compose() {
  local env=$1
  shift
  local worktree=$ROOT/envs/$env
  local process_file=$worktree/environments/$env/processes.env
  local -a process_settings=()
  [[ ! -f $process_file ]] || process_settings=(--env-file "$process_file")
  CADENWAY_SERVICES=$SECRETS_DIR/$env/definitions \
    docker compose -p "cadenway-$env" --project-directory "$worktree/compose" \
    -f "$worktree/compose/compose.yaml" \
    --env-file "$SETTINGS_DIR/env/$env.env" \
    --env-file "$worktree/environments/$env/versions.env" \
    --env-file "$SECRETS_DIR/$env/secrets.env" \
    "${process_settings[@]}" \
    "$@"
}

# Constrain the service manifests before Compose can load files or use the environment's secrets.
# The canonical copies contain only the same raw literals and authorized references as the source.
stage_service_definitions() {
  local env=$1 base=$ROOT/envs/$1/environments
  local scratch=${SECRETS_DIR:?}/$env
  local -a policy_options=()
  [[ $env != prod ]] || policy_options=(--require-digest)
  [[ $env =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && ! -L $base && ! -L $base/$env ]] || return 1
  # The release lock also covers this scratch directory. A killed process cannot run its
  # exit trap, so the next tick discards the previous candidate's files before staging.
  rm -rf -- "$scratch" && install -d -m 0700 "$scratch" || return 1
  python3 -I "$SCRIPT_DIR/compose-policy.py" "${policy_options[@]}" "$base/$env/services" \
    "$base/$env/versions.env" "$scratch/definitions"
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

# Container ids of one service of the environment, oldest first. Include stopped containers when
# requested, including candidates created before the current run was interrupted.
service_containers() {
  local -a states=()
  [[ ${3:-} != all ]] || states=(--all)
  docker ps "${states[@]}" --no-trunc --filter "label=com.docker.compose.project=cadenway-$1" \
    --filter 'label=com.docker.compose.oneoff=False' \
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
  MIGRATION_DATABASE_URL=$url env_compose "$env" run --rm --no-deps --pull never -T "${forward[@]}" "$service" \
    sh -c 'if [ -f dist/migrate.js ]; then exec node dist/migrate.js; fi'
}

# Public routes belong to the approved Compose definitions. An image must not supply
# additional routing labels, including to a one-off migration container.
require_compose_owned_routing() {
  local env=$1 service=$2 image labels
  image=$(env_compose "$env" config --format json |
    jq -er --arg name "$service" '.services[$name].image | strings | select(length > 0)') || return 1
  labels=$(docker image inspect --format '{{json .Config.Labels}}' "$image") || return 1
  if ! jq -e '(. // {}) | all(keys[]; (ascii_downcase | startswith("traefik.")) | not)' \
    <<<"$labels" >/dev/null; then
    log "$env/$service: routing labels must come from the approved Compose definition"
    return 1
  fi
}

new_since() {
  local env=$1 service=$2 baseline=$3 inventory
  inventory=$(service_containers "$env" "$service" all) || return 1
  comm -13 <(sort "$baseline") <(printf '%s' "$inventory" | sort)
}

# Withhold internal serving aliases while keeping dependency connectivity. A public candidate
# keeps its edge endpoint and relies on Traefik's health filter. Detaching that endpoint could
# send Traefik to an unreachable fallback address once the candidate is healthy.
isolate_candidate() {
  local env=$1 id=$2 file=$3 networks network bindings exposure enabled allow_nonrunning routing_network healthcheck
  local preserved_edge=''
  local edge=cadenway-edge-$env
  bindings=$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$id") || return 1
  jq -e '(. // {} | length) == 0' <<<"$bindings" >/dev/null || return 1
  networks=$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$id") || return 1
  exposure=$(docker inspect --format \
    '{{index .Config.Labels "traefik.enable"}}|{{index .Config.Labels "traefik.docker.allownonrunning"}}|{{index .Config.Labels "traefik.docker.network"}}' \
    "$id") || return 1
  IFS='|' read -r enabled allow_nonrunning routing_network <<<"$exposure"
  if [[ ${enabled,,} =~ ^(true|t|1)$ ]]; then
    healthcheck=$(docker inspect --format '{{json .Config.Healthcheck}}' "$id") || return 1
    if [[ $routing_network != "$edge" || ${allow_nonrunning,,} =~ ^(true|t|1)$ ]] ||
      ! jq -e --arg edge "$edge" 'has($edge)' <<<"$networks" >/dev/null ||
      ! jq -e '(.Test[0] == "CMD" or .Test[0] == "CMD-SHELL") and (.Test | length) > 1' \
        <<<"$healthcheck" >/dev/null; then
      log "$env: an exposed candidate needs its edge network and a healthcheck"
      return 1
    fi
    preserved_edge=$edge
  fi
  # Reconnecting a dynamic bridge endpoint without extra options preserves its configuration.
  jq -cer --arg preserved "$preserved_edge" '
    to_entries
    | map(select(.key != $preserved))
    | if (length == 0 and $preserved == "") or any(.[];
        ((.value.IPAMConfig // {}) | length) != 0 or
        ((.value.Links // []) | length) != 0 or
        ((.value.DriverOpts // {}) | length) != 0 or (.value.MacAddress // "") != "" or
        (.value.GwPriority // 0) != 0)
      then error("unsupported rollout network endpoint") else . end
    | map({name: .key, aliases: (.value.Aliases // [])})' <<<"$networks" >"$file" || return 1
  while IFS= read -r network; do
    docker network disconnect "$network" "$id" || return 1
    if [[ $network != "$edge" ]]; then
      docker network connect "$network" "$id" || return 1
    fi
  done < <(jq -r '.[].name' "$file")
}

promote_candidate() {
  local env=$1 id=$2 file=$3 endpoint network alias
  local -a aliases=()
  [[ -f $file.active ]] && return 0
  while IFS= read -r endpoint; do
    network=$(jq -r '.name' <<<"$endpoint") || return 1
    aliases=()
    while IFS= read -r alias; do
      aliases+=(--alias "$alias")
    done < <(jq -r '.aliases[]' <<<"$endpoint")
    if [[ $network != "cadenway-edge-$env" ]]; then
      docker network disconnect "$network" "$id" || return 1
    fi
    docker network connect "${aliases[@]}" "$network" "$id" || return 1
  done < <(jq -c --arg edge "cadenway-edge-$env" 'sort_by(.name == $edge)[]' "$file")
  touch "$file.active"
}

# Compose copies inline configs at start, rather than at create. Copy them into only the
# candidates so a stopped previous container cannot be started or modified by Compose.
# File-backed configs and secrets were already attached by the create operation.
stage_inline_configs() (
  local env=$1 service=$2 configs config scratch target path uid gid mode id
  shift 2
  configs=$(env_compose "$env" config --format json | jq -ce --arg name "$service" '
    . as $model | .services[$name] as $service |
    if (($service.post_start // []) | length) != 0 or
      any($service.secrets[]?; $model.secrets[.source].environment != null) or
      any($service.configs[]?; $model.configs[.source].environment != null)
    then error("cannot stage Compose hooks or environment-backed files")
    else [
      $service.configs[]? as $mount | $model.configs[$mount.source].content as $content |
      select($content != null and $content != "") |
      {
        target: ($mount.target // ("/" + $mount.source)),
        content: $content,
        uid: (($mount.uid // "0") | tonumber),
        gid: (($mount.gid // "0") | tonumber),
        mode: ($mount.mode // 292)
      }
    ] end') || return 1
  [[ $configs != '[]' ]] || return 0
  scratch=$(mktemp -d "$SECRETS_DIR/$env/rollout-config.XXXXXX") || return 1
  trap 'rm -rf "$scratch"' EXIT
  while IFS= read -r config; do
    target=$(jq -r '.target' <<<"$config") || return 1
    path=${target#/}
    [[ -n $path && /$path/ != */../* && $path != /* ]] || return 1
    uid=$(jq -r '.uid' <<<"$config") || return 1
    gid=$(jq -r '.gid' <<<"$config") || return 1
    mode=$(printf '%o' "$(jq -r '.mode' <<<"$config")") || return 1
    mkdir -p "$scratch/$(dirname "$path")" || return 1
    jq -j '.content' <<<"$config" >"$scratch/$path" || return 1
    chown "$uid:$gid" "$scratch/$path" && chmod "$mode" "$scratch/$path" || return 1
    for id in "$@"; do
      tar -C "$scratch" -cf - -- "$path" | docker cp -a - "$id:/" || return 1
    done
  done < <(jq -c '.[]' <<<"$configs")
)

# Capture the baseline before Compose can create anything. Recovery finds even a stopped
# candidate created before the process was interrupted and before its ID could be written.
prepare_candidates() {
  local env=$1 service=$2 count=$3 required=$4 inventory id pending code=0
  local rollout=$STATE_DIR/$env/rollout
  local -a before=() candidates=()
  inventory=$(service_containers "$env" "$service" all) || return 1
  mapfile -t before < <(printf '%s' "$inventory")
  printf '%s' "$inventory" >"$rollout/baseline/.$service" &&
    mv "$rollout/baseline/.$service" "$rollout/baseline/$service" || return 1
  env_compose "$env" up --no-start --no-deps --no-recreate --pull never \
    --scale "$service=$((${#before[@]} + count))" "$service" || code=$?
  pending=$(new_since "$env" "$service" "$rollout/baseline/$service") || return 1
  mapfile -t candidates < <(printf '%s' "$pending")
  ((code == 0 && ${#candidates[@]} == count)) || return 1
  for id in "${candidates[@]}"; do
    isolate_candidate "$env" "$id" "$rollout/networks/$id" || return 1
  done
  stage_inline_configs "$env" "$service" "${candidates[@]}" || return 1
  docker start "${candidates[@]}" >/dev/null && wait_healthy "$required" "${candidates[@]}"
}

# Brings one deployable to its desired state. A no-op when its fingerprint is the one applied and
# every container runs that configuration and is healthy. Returns 1 when the desired state fails
# (migrations, health), TRANSIENT when its image cannot be pulled.
apply_service() {
  local env=$1 service=$2 record desired hash container inventory
  local rollout=$STATE_DIR/$env/rollout
  local -a running
  record=$STATE_DIR/$env/services/$service
  desired=$(fingerprint "$env" "$service") || return 1
  hash=${desired%% *}
  inventory=$(service_containers "$env" "$service") || return 1
  mapfile -t running < <(printf '%s' "$inventory")
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
  require_compose_owned_routing "$env" "$service" || return 1
  migrate "$env" "$service" || {
    log "$env/$service: the migrations failed"
    return 1
  }
  inventory=$(service_containers "$env" "$service" all) || return 1
  printf '%s' "$inventory" >"$rollout/obsolete/$service" || return 1
  prepare_candidates "$env" "$service" 1 no || {
    log "$env/$service: the new container could not be prepared"
    return 1
  }
  printf '%s\n' "$desired" >"$rollout/records/$service"
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

# Reconciles a companion after its owner applied. Keep healthy matching replicas on scale changes.
# Start replacement candidates together and wait for all of them before touching older instances.
apply_companion() {
  local env=$1 service=$2 replicas=$3 inventory record desired hash id count
  local rollout=$STATE_DIR/$env/rollout
  local -a before=() kept=() obsolete=()
  inventory=$(service_containers "$env" "$service" all) || return 1
  mapfile -t before < <(printf '%s' "$inventory")
  if ((replicas == 0)); then
    printf '%s' "$inventory" >"$rollout/obsolete/$service" || return 1
    # The candidate owner may start inline work. Drain existing dedicated workers first,
    # but retain their containers in case the rest of the application batch fails.
    for id in "${before[@]}"; do
      suspend_container "$rollout" "$id" 60 || return 1
    done
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
  printf '%s\n' "${obsolete[@]}" >"$rollout/obsolete/$service" || return 1
  if ((count > 0)); then
    env_compose "$env" pull --quiet "$service" || return "$TRANSIENT"
    require_compose_owned_routing "$env" "$service" || return 1
    prepare_companion_owner "$env" "$service" || return 1
    prepare_candidates "$env" "$service" "$count" yes || return 1
  fi
  printf '%s\n' "$desired" >"$rollout/records/$service"
}

# Journal only IDs of containers that this batch stops. A failed batch must not restart a
# container that was already stopped before it began.
suspend_container() {
  local rollout=$1 id=$2 grace=$3 running
  running=$(docker inspect --format '{{.State.Running}}' "$id") || return 1
  [[ $running == true ]] || return 0
  printf '%s\n' "$id" >>"$rollout/suspended" || return 1
  docker stop --time "$grace" "$id" >/dev/null
}

promote_service() {
  local env=$1 service=$2 candidates id
  local rollout=$STATE_DIR/$env/rollout
  local -a promoted=()
  candidates=$(new_since "$env" "$service" "$rollout/baseline/$service") || return 1
  mapfile -t promoted < <(printf '%s' "$candidates")
  ((${#promoted[@]} > 0)) || return 1
  for id in "${promoted[@]}"; do
    promote_candidate "$env" "$id" "$rollout/networks/$id" || return 1
  done
  wait_healthy no "${promoted[@]}"
}

# When moving from inline to dedicated processing, stop the old inline owners before the
# companion starts. Promote their healthy replacement first so the API remains available.
# Inspect only the known process-mode flag, without returning any environment values.
prepare_companion_owner() {
  local env=$1 service=$2 owner=${COMPANION_OWNERS[$2]} mode=${COMPANION_OWNER_MODES[$2]}
  local rollout=$STATE_DIR/$env/rollout
  local id ids dedicated
  [[ -f $rollout/obsolete/$owner ]] || return 0
  ids=$(<"$rollout/obsolete/$owner") || return 1
  for id in $ids; do
    dedicated=$(docker inspect --format \
      '{{range .Config.Env}}{{if eq . "'"$mode"'"}}yes{{end}}{{end}}' "$id") || return 1
    if [[ $dedicated != yes ]]; then
      promote_service "$env" "$owner" || return 1
      suspend_container "$rollout" "$id" 30 || return 1
    fi
  done
}

begin_release() {
  local rollout=$STATE_DIR/$1/rollout
  mkdir -p "$rollout"/{baseline,networks,obsolete,records} &&
    printf '%s\n' "$2" >"$rollout/commit"
}

rollback_release() {
  local env=$1 applied=$2 rollout=$STATE_DIR/$1/rollout baseline candidates id
  local -a previous=()
  for baseline in "$rollout"/baseline/*; do
    [[ -f $baseline ]] || continue
    candidates=$(new_since "$env" "${baseline##*/}" "$baseline") || return 1
    for id in $candidates; do
      docker rm -f "$id" >/dev/null || return 1
    done
  done
  if [[ -n $applied ]]; then
    # Restore checked-in bind-mount sources before a previous container restarts.
    checkout "$ROOT/envs/$env" "$applied" || return 1
  fi
  if [[ -f $rollout/suspended ]]; then
    mapfile -t previous <"$rollout/suspended"
    for id in "${previous[@]}"; do
      docker start "$id" >/dev/null || return 1
    done
    if ! wait_healthy no "${previous[@]}"; then
      log "$env: a restored container is not ready; retaining the rollback journal"
      return 1
    fi
  fi
}

finish_release() {
  local env=$1 state=$STATE_DIR/$1 rollout=$STATE_DIR/$1/rollout file id inventory
  mkdir -p "$state/services" || return 1
  for file in "$rollout"/records/*; do
    [[ -f $file ]] || continue
    cp "$file" "$state/services/${file##*/}" || return 1
  done
  for file in "$rollout"/obsolete/*; do
    [[ -s $file ]] || continue
    inventory=$(service_containers "$env" "${file##*/}" all) || return 1
    for id in $inventory; do
      if grep -Fxq "$id" "$file"; then
        docker rm "$id" >/dev/null || return 1
      fi
    done
  done
  rm -f "$state/failed" "$state/retrying"
}

# The applied marker is the application's commit point. Before it, recover by removing
# candidates and restoring suspended originals. After it, finish retirement idempotently.
recover_release() {
  local env=$1 state=$STATE_DIR/$1 rollout=$STATE_DIR/$1/rollout pending applied
  rm -rf "$state/rollout-completed" || return 1
  [[ -d $rollout ]] || return 0
  pending=$(read_state "$rollout/commit")
  applied=$(read_state "$state/applied")
  if [[ -n $pending && $pending == "$applied" ]]; then
    finish_release "$env" || return 1
  else
    rollback_release "$env" "$applied" || return 1
  fi
  # A crash during deletion must not leave a partial journal to interpret on the next tick.
  mv "$rollout" "$state/rollout-completed" && rm -rf "$state/rollout-completed"
}

commit_release() {
  local env=$1 commit=$2 state=$STATE_DIR/$1 rollout=$STATE_DIR/$1/rollout file id grace
  for file in "$rollout"/baseline/*; do
    [[ -f $file ]] || continue
    promote_service "$env" "${file##*/}" || return 1
  done
  for file in "$rollout"/obsolete/*; do
    [[ -s $file ]] || continue
    grace=30
    [[ ! -v COMPANION_OWNERS[${file##*/}] ]] || grace=60
    for id in $(<"$file"); do
      suspend_container "$rollout" "$id" "$grace" || return 1
    done
  done
  printf '%s\n' "$commit" >"$state/applied.next" &&
    mv -f "$state/applied.next" "$state/applied"
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
  if ! recover_release "$env"; then
    log "$env: cannot recover the previous release; trying again on the next tick"
    return "$TRANSIENT"
  fi
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
  if ! stage_service_definitions "$env"; then
    result=1
    log "$env: service definitions refused by the installed Compose policy"
  elif ! valid_process_settings "$env"; then
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
    elif ! env_compose "$env" config -q >/dev/null 2>&1; then
      result=1
      log "$env: the Compose configuration is invalid"
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
    begin_release "$env" "$commit" || result=$TRANSIENT
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
        result=$TRANSIENT
        break
      else
        result=1
        notify "cadenway $env: $service could not be prepared at ${commit:0:12}"
        break
      fi
    done
  fi

  if ((result == 0)); then
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
        result=$TRANSIENT
        break
      else
        result=1
        notify "cadenway $env: $service could not be prepared at ${commit:0:12}"
        break
      fi
    done
  fi

  if ((result == 0)) && ! commit_release "$env" "$commit"; then
    result=$TRANSIENT
    log "$env: cannot promote the release; trying again on the next tick"
  fi
  if ((result == 1)); then
    printf '%s\n' "$commit" >"$state/failed" || result=$TRANSIENT
  fi
  if ! recover_release "$env"; then
    log "$env: cannot finish release recovery; trying again on the next tick"
    result=$TRANSIENT
  fi

  rm -rf "${SECRETS_DIR:?}/$env"
  unset DOCKER_CONFIG
  case $result in
    0)
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
      rm -f "$state/retrying"
      # Validation can fail before there was a release journal to restore the checkout.
      [[ -n $applied ]] && checkout "$worktree" "$applied"
      notify "cadenway $env: ${commit:0:12} FAILED after $((SECONDS - start)) s; not retried until a new commit"
      ;;
  esac
  return "$result"
}

main() {
  local commit environment_commit edge_commit env status=0 production_commit=''
  local -a branches=("$BRANCH") environments=()
  exec 9>"$LOCK_FILE"
  flock -n 9 || {
    log 'another run is in progress'
    exit 0
  }
  # Only the run holding the lock cleans up: decrypted secrets never outlive it.
  trap 'rm -rf "${SECRETS_DIR:?}"/*' EXIT
  mkdir -p "$ROOT/envs" "$STATE_DIR"

  read -r -a environments <<<"$ENVIRONMENTS"
  for env in "${environments[@]}"; do
    if [[ $env == prod ]]; then
      if [[ $BRANCH == "$PRODUCTION_BRANCH" ]]; then
        log "production requires a separate protected Ops ref"
        return 1
      fi
      branches+=("$PRODUCTION_BRANCH")
      break
    fi
  done
  if ! fetch "${branches[@]}"; then
    log "cannot fetch the configured release refs: check the deploy key and the network"
    return 1
  fi
  commit=$(git -C "$MIRROR" rev-parse "refs/heads/$BRANCH")
  edge_commit=$commit
  if ((${#branches[@]} > 1)); then
    production_commit=$(git -C "$MIRROR" rev-parse "refs/heads/$PRODUCTION_BRANCH")
    if ! authorized_commit "$production_commit" "$PRODUCTION_SIGNERS" \
      "$(read_state "$STATE_DIR/prod/applied")" ||
      ! descends_from "$production_commit" "$(read_state "$STATE_DIR/edge/applied")"; then
      log "production: the release is unsigned by Ops or would rewind an applied ref"
      return 1
    fi
    if authorized_commit "$production_commit" "$RELEASE_SIGNERS" ''; then
      log "production: its approval key also authorizes non-production releases"
      return 1
    fi
    edge_commit=$production_commit
  fi
  apply_edge "$edge_commit" || {
    log "edge: ${edge_commit:0:12} failed; environments without their edge network wait"
    status=1
  }
  for env in "${environments[@]}"; do
    environment_commit=$commit
    if [[ $env == prod ]]; then
      environment_commit=$production_commit
    elif [[ -n $production_commit ]] &&
      { ! authorized_commit "$commit" "$RELEASE_SIGNERS" "$(read_state "$STATE_DIR/$env/applied")" ||
        authorized_commit "$commit" "$PRODUCTION_SIGNERS" ''; }; then
      log "$env: a release sharing the production daemon needs its own Ops approval"
      status=1
      continue
    elif [[ -n $production_commit ]] &&
      ! has_approved_host_inputs "$commit" "$production_commit" "$env"; then
      log "$env: host and secret configuration also require production approval on a shared daemon"
      status=1
      continue
    fi
    apply_environment "$env" "$environment_commit" || status=1
  done
  return "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
