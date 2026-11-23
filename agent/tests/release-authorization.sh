#!/usr/bin/env bash
# Verify the production and staging release boundaries without invoking Docker.
set -euo pipefail

agent=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/cadenway-agent.sh
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
source_repo=$test_root/source
state=$test_root/state
trace=$test_root/trace
export CADENWAY_AGENT_CONFIG=/dev/null CADENWAY_REPO_URL=$source_repo
export CADENWAY_ENVIRONMENTS=staging
export CADENWAY_SETTINGS_DIR=$test_root
mkdir -p "$state"/{edge,prod}

git init --quiet --initial-branch=main "$source_repo"
git -C "$source_repo" config user.name 'GitOps fixture'
git -C "$source_repo" config user.email 'gitops-fixture@example.test'
git -C "$source_repo" -c commit.gpgsign=false commit --quiet --allow-empty -m 'baseline'
baseline=$(git -C "$source_repo" rev-parse HEAD)
printf '%s\n' "$baseline" >"$state/edge/applied"
printf '%s\n' "$baseline" >"$state/prod/applied"

# Keys belong only to this disposable fixture.
for role in release production; do
  ssh-keygen -q -t ed25519 -N '' -f "$test_root/$role"
  { printf '%s ' "$role"; cat "$test_root/$role.pub"; } >"$test_root/$role-signers"
done
signed_commit() {
  git -C "$source_repo" -c gpg.format=ssh -c user.signingkey="$test_root/$1" \
    commit --quiet -S --allow-empty -m "$2"
}
mkdir -p "$source_repo/environments/staging/services"
printf 'service fixture\n' >"$source_repo/environments/staging/services/app.yaml"
printf 'APP_VERSION=1.2.3\n' >"$source_repo/environments/staging/versions.env"
git -C "$source_repo" add environments/staging
signed_commit release 'signed staging'
staging=$(git -C "$source_repo" rev-parse HEAD)
git -C "$source_repo" switch --quiet --create production "$baseline"
mkdir -p "$source_repo/environments/prod"
printf 'WEBAPP_VERSION=1.2.3\n' >"$source_repo/environments/prod/versions.env"
git -C "$source_repo" add environments/prod/versions.env
signed_commit production 'signed production'
production=$(git -C "$source_repo" rev-parse HEAD)

configure_paths() {
  local prefix=$1 journal_path=$2
  export CADENWAY_ROOT=$test_root/$prefix CADENWAY_STATE_DIR=$journal_path
  export CADENWAY_LOCK_FILE=$test_root/$prefix.lock CADENWAY_SECRETS_DIR=$test_root/$prefix.run
}

run_agent() (
  export CADENWAY_ENVIRONMENTS="${2:-prod}"
  configure_paths mirror "$state"
  export CADENWAY_BRANCH=main CADENWAY_PRODUCTION_BRANCH=${1:-production}
  # shellcheck source=/dev/null
  source "$agent"
  # These test doubles are invoked by the sourced release loop.
  # shellcheck disable=SC2329
  confirm_host_assignment() { return 0; }
  # shellcheck disable=SC2329
  apply_edge() { printf 'edge %s\n' "$1" >>"$trace"; }
  # shellcheck disable=SC2329
  apply_environment() { printf '%s %s\n' "$1" "$2" >>"$trace"; }
  # shellcheck disable=SC2329
  timeout() {
    [[ $1 == -k && $2 == 5s && $3 == 30s && $4 == git ]] || return 1
    if [[ ${*: -1} == +refs/heads/main:refs/heads/main ]]; then
      [[ ${fixture_staging_timeout:-false} == false ]] || return 124
    fi
    command timeout "$@"
  }
  main
)

check_refusal() {
  local message=$1
  shift
  : >"$trace"
  if output=$(run_agent "$@" 2>&1) || [[ $output != *"$message"* || -s $trace ]]; then
    printf 'unexpected authorization result: %s\n' "$output" >&2
    exit 1
  fi
}

run_agent
run_agent production staging
printf 'edge %s\nprod %s\nedge %s\nstaging %s\n' "$production" "$production" "$staging" "$staging" | diff - "$trace"
echo 'PASS dedicated hosts apply the expected environment and edge ref'

check_refusal 'one environment per host with independent storage' production 'staging prod'
echo 'PASS a shared host assignment is refused before reconciliation'

git -C "$source_repo" update-ref -d refs/heads/main
: >"$trace"
if output=$(run_agent production staging 2>&1) || [[ $output != *'non-production: cannot fetch its release ref'* ]]; then
  printf 'unexpected missing staging ref result: %s\n' "$output" >&2
  exit 1
fi
[[ ! -s $trace ]]
echo 'PASS an unavailable staging ref never applies its cached tip'

: >"$trace"
run_agent production prod
printf 'edge %s\nprod %s\n' "$production" "$production" | diff - "$trace"
git -C "$source_repo" update-ref refs/heads/main "$staging"
echo 'PASS a production-only host needs only the production ref'

: >"$trace"
if output=$(fixture_staging_timeout=true run_agent production staging 2>&1) ||
  [[ $output != *'non-production: cannot fetch its release ref'* ]]; then
  printf 'unexpected staging fetch timeout result: %s\n' "$output" >&2
  exit 1
fi
[[ ! -s $trace ]]
echo 'PASS a staging fetch timeout prevents staging reconciliation'

check_refusal 'separate protected Ops ref' main
git -C "$source_repo" update-ref refs/heads/production "$staging"
check_refusal 'unsigned by Ops or would rewind'
git -C "$source_repo" update-ref refs/heads/production "$production"
cp "$test_root/production-signers" "$test_root/release-signers"
check_refusal 'also authorizes non-production releases'
{ printf 'release '; cat "$test_root/release.pub"; } >"$test_root/release-signers"

git -C "$source_repo" -c commit.gpgsign=false commit --quiet --allow-empty -m 'unsigned desired state'
check_refusal 'unsigned by Ops or would rewind'
git -C "$source_repo" update-ref refs/heads/production "$production"
printf 'WEBAPP_VERSION=2.0.0\n' >"$source_repo/environments/prod/versions.env"
git -C "$source_repo" add environments/prod/versions.env
signed_commit production 'later approved production'
later=$(git -C "$source_repo" rev-parse HEAD)
printf '%s\n' "$later" >"$state/prod/applied"
git -C "$source_repo" update-ref refs/heads/production "$production"
check_refusal 'unsigned by Ops or would rewind'
echo 'PASS shared refs, wrong or overlapping signers, unsigned commits and rewinds are refused'

printf '%s\n' "$later" >"$state/edge/applied"
printf '%s\n' "$baseline" >"$state/prod/applied"
check_refusal 'unsigned by Ops or would rewind'
echo 'PASS a rewind of the shared edge is refused even when the application can fast-forward'

git -C "$source_repo" update-ref refs/heads/production "$later"
git -C "$source_repo" restore --source "$production" --staged --worktree environments/prod/versions.env
signed_commit production 'approved rollback to the previous version'
rollback=$(git -C "$source_repo" rev-parse HEAD)
printf '%s\n' "$later" >"$state/prod/applied"
: >"$trace"
run_agent production prod
printf 'edge %s\nprod %s\n' "$rollback" "$rollback" | diff - "$trace"
git -C "$source_repo" diff --quiet "$production" "$rollback" -- environments/prod/versions.env
echo 'PASS a signed descendant may restore an earlier application version'

(
  configure_paths first-release "$test_root/first-state"
  # shellcheck source=/dev/null
  source "$agent"
  # shellcheck disable=SC2329
  confirm_host_assignment() { return 0; }
  mkdir -p "$STATE_DIR/staging/rollout/baseline"
  printf '%s\n' "$staging" >"$STATE_DIR/staging/rollout/commit"
  : >"$STATE_DIR/staging/rollout/baseline/gateway"
  # shellcheck disable=SC2329
  new_since() {
    [[ $1 == staging && $2 == gateway ]] || return 1
    printf '%s\n' first-candidate
  }
  # shellcheck disable=SC2329
  docker() {
    [[ $* == 'rm -f first-candidate' ]] || return 1
    printf '%s\n' removed >"$test_root/first-candidate"
  }
  # shellcheck disable=SC2329
  fetch_release() {
    [[ ! -d $STATE_DIR/staging/rollout && -f $test_root/first-candidate ]] ||
      printf '%s\n' too-early >"$test_root/first-fetch-order"
    return 1
  }
  if main; then
    echo 'the first release should fail to fetch its unavailable ref' >&2
    exit 1
  fi
  [[ ! -e $test_root/first-fetch-order && ! -d $MIRROR && ! -d $STATE_DIR/staging/rollout && -f $test_root/first-candidate ]]
)
echo 'PASS recovery removes an interrupted first candidate without an applied state or mirror'

(
  configure_paths interrupted-release "$test_root/interrupted-state"
  # shellcheck source=/dev/null
  source "$agent"
  # shellcheck disable=SC2329
  confirm_host_assignment() { return 0; }
  mkdir -p "$STATE_DIR/staging/rollout" "$ROOT/envs/staging"
  printf '%s\n' "$baseline" >"$STATE_DIR/staging/applied"
  printf '%s\n' "$staging" >"$STATE_DIR/staging/rollout/commit"
  printf '%s\n' 'local checkout fixture' >"$ROOT/envs/staging/fixture"
  # shellcheck disable=SC2329
  fetch_release() {
    printf '%s\n' 'unexpected remote fetch' >"$test_root/interrupted-fetch"
    return 1
  }
  if main; then
    echo 'recovery should require the last applied commit' >&2
    exit 1
  fi
  [[ -f $ROOT/envs/staging/fixture && -d $STATE_DIR/staging/rollout && ! -e $test_root/interrupted-fetch ]]
)
echo 'PASS recovery preserves the checkout and journal when the last applied commit is unavailable locally'

(
  configure_paths separate-storage "$test_root/isolated-state"
  # shellcheck source=/dev/null
  source "$agent"
  # shellcheck disable=SC2329
  docker() {
    [[ $* == 'ps -aq --filter label=com.docker.compose.project=cadenway-prod' ]] || return 1
    printf '%s' "$foreign_container"
  }
  # shellcheck disable=SC2329
  fetch_release() {
    printf '%s\n' fetched >"$test_root/isolated-fetch"
    return 1
  }
  foreign_container=previous-production-container
  if main; then
    echo 'a daemon with containers from another environment was accepted' >&2
    exit 1
  fi
  [[ ! -e $test_root/isolated-fetch ]]
  foreign_container=''
  confirm_host_assignment staging
  printf '%s\n' prod >"$CADENWAY_SETTINGS_DIR/assigned-environment"
  if confirm_host_assignment staging; then
    echo 'a conflicting host assignment was accepted' >&2
    exit 1
  fi
  rm -f "$CADENWAY_SETTINGS_DIR/assigned-environment"
)
echo 'PASS a daemon with containers from another environment and a conflicting host assignment are refused'

(
  configure_paths interrupted-restore "$test_root/restore-state"
  # shellcheck source=/dev/null
  source "$agent"
  # shellcheck disable=SC2329
  confirm_host_assignment() { return 0; }
  # shellcheck disable=SC2329
  recover_database_restore() {
    [[ $1 == staging ]] || return 1
    printf '%s\n' attempted >"$test_root/restore-attempted"
    return 1
  }
  # shellcheck disable=SC2329
  fetch_release() {
    printf '%s\n' fetched >"$test_root/unexpected-restore-fetch"
    return 1
  }
  if main; then
    echo 'GitOps proceeded after failing to recover a database restore' >&2
    exit 1
  fi
  [[ -e $test_root/restore-attempted && ! -e $test_root/unexpected-restore-fetch ]]
)
echo 'PASS a failed database restore recovery prevents reconciliation'

(
  configure_paths pending-release "$test_root/pending-state"
  # shellcheck source=/dev/null
  source "$agent"
  # shellcheck disable=SC2329
  confirm_host_assignment() { return 0; }
  # shellcheck disable=SC2329
  fetch_release() { printf '%s\n' "$staging"; }
  # shellcheck disable=SC2329
  reconcile_edge() { return 0; }
  # shellcheck disable=SC2329
  apply_environment() {
    local env=$1 commit=$2 platform=${3:-true}
    printf '%s %s\n' "$commit" "$platform" >>"$trace"
    if [[ $commit == "$staging" ]]; then
      if [[ $interrupted == true ]]; then
        mkdir -p "$STATE_DIR/$env/rollout"
      fi
      return "$TRANSIENT"
    fi
  }
  mkdir -p "$STATE_DIR/staging"
  printf '%s\n' "$baseline" >"$STATE_DIR/staging/applied"
  for interrupted in false true; do
    : >"$trace"
    if main; then
      echo 'the pending release should still report failure' >&2
      exit 1
    fi
    {
      printf '%s true\n' "$staging"
      if [[ $interrupted == false ]]; then printf '%s false\n' "$baseline"; fi
    } | diff - "$trace"
  done
)
echo 'PASS a pending release repairs the applied applications only after journal recovery'

(
  # shellcheck source=/dev/null
  source "$agent"
  # shellcheck disable=SC2329
  env_compose() {
    printf '%s\n' '{"services":{"gateway":{"image":"fixture:verified"}}}'
  }
  # shellcheck disable=SC2329
  docker() {
    [[ $1 == image && $2 == inspect && $5 == fixture:verified ]] || return 1
    printf '%s\n' "$fixture_image_labels"
  }
  fixture_image_labels='null'
  require_compose_owned_routing staging gateway
  fixture_image_labels='{"org.opencontainers.image.title":"fixture"}'
  require_compose_owned_routing staging gateway
  fixture_image_labels='{"Traefik.enable":"true"}'
  if require_compose_owned_routing staging gateway; then
    echo 'image-owned routing metadata was accepted' >&2
    exit 1
  fi
)
echo 'PASS image-owned routing is refused before release activation'
