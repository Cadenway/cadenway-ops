#!/usr/bin/env bash
# Verify the production and co-hosted staging release boundaries without invoking Docker.
set -euo pipefail

agent=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/cadenway-agent.sh
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
source_repo=$test_root/source
state=$test_root/state
trace=$test_root/trace
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
signed_commit production 'signed production'
production=$(git -C "$source_repo" rev-parse HEAD)

run_agent() (
  export CADENWAY_AGENT_CONFIG=/dev/null
  export CADENWAY_REPO_URL=$source_repo
  export CADENWAY_ENVIRONMENTS='staging prod'
  export CADENWAY_ROOT=$test_root/agent CADENWAY_SETTINGS_DIR=$test_root
  export CADENWAY_STATE_DIR=$state CADENWAY_LOCK_FILE=$test_root/lock CADENWAY_SECRETS_DIR=$test_root/run
  export CADENWAY_BRANCH=main CADENWAY_PRODUCTION_BRANCH=${1:-production}
  # shellcheck source=/dev/null
  source "$agent"
  # These test doubles are invoked by the sourced release loop.
  # shellcheck disable=SC2329
  apply_edge() { printf 'edge %s\n' "$1" >>"$trace"; }
  # shellcheck disable=SC2329
  apply_environment() { printf '%s %s\n' "$1" "$2" >>"$trace"; }
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
printf 'edge %s\nstaging %s\nprod %s\n' "$production" "$staging" "$production" |
  diff - "$trace"
echo 'PASS independently signed refs apply to the expected environment and shared edge'

: >"$trace"
git -C "$source_repo" update-ref refs/heads/main "$production"
if output=$(run_agent 2>&1) || [[ $output != *'release sharing the production daemon needs its own Ops approval'* ]]; then
  printf 'unexpected staging authorization result: %s\n' "$output" >&2
  exit 1
fi
printf 'edge %s\nprod %s\n' "$production" "$production" | diff - "$trace"
git -C "$source_repo" update-ref refs/heads/main "$staging"
echo 'PASS lack of a staging approval leaves production and the shared edge independent'

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
git -C "$source_repo" switch --quiet main
mkdir -p "$source_repo/compose"
printf 'unapproved infrastructure fixture\n' >"$source_repo/compose/infra.yaml"
git -C "$source_repo" add compose/infra.yaml
signed_commit release 'stage signer changes host infrastructure'
: >"$trace"
if output=$(run_agent 2>&1) || [[ $output != *'host and secret configuration also require production approval'* ]]; then
  printf 'unexpected shared daemon authorization result: %s\n' "$output" >&2
  exit 1
fi
printf 'edge %s\nprod %s\n' "$later" "$later" | diff - "$trace"
echo 'PASS the staging signer cannot approve co-hosted infrastructure'

(
  export CADENWAY_AGENT_CONFIG=/dev/null CADENWAY_REPO_URL=$source_repo
  export CADENWAY_ENVIRONMENTS=staging
  # shellcheck source=/dev/null
  source "$agent"
  # shellcheck disable=SC2329
  env_compose() {
    printf '%s\n' '{"services":{"gateway":{"image":"fixture:verified"}}}'
  }
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
