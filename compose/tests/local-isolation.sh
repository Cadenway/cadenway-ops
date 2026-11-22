#!/usr/bin/env bash
# Test of two local stacks on one Docker host, which must never route to each other. Covers, for two
# project names and the default one: an edge network named after the project and created by the
# stack, no network shared by the two stacks, a local Traefik that serves the containers of its own
# project only and reaches them on its edge network, every service it serves joined to that network;
# and, on a server, the external edge network of the environment left as it was.
#
#   bash compose/tests/local-isolation.sh
#
# It renders the configuration of compose.yaml and compose.local.yaml with the local values of
# compose/.env.example: nothing is started, compose/.env is never read. The only container is a
# short-lived Node process that reads the rendered configurations.
#
# The assertions are strings evaluated by `check`, so they expand late on purpose, and the helpers
# they call look unused.
# shellcheck disable=SC2016,SC2329
set -euo pipefail
# Git Bash would rewrite the container paths given to `docker run`.
export MSYS_NO_PATHCONV=1
# The default project is the `name` of compose.yaml, whatever the shell says.
unset COMPOSE_PROJECT_NAME

cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# The path Docker mounts: the Windows form under Git Bash, the path itself elsewhere.
host_path() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }
MOUNT=$(host_path "$WORK")
readonly WORK MOUNT
IMAGE=$(sed -n '/^  internal-token-keys:/,/^$/s/^ *image: //p' compose.local.yaml)
readonly IMAGE
readonly FIRST=cadenway-test-isolation-a SECOND=cadenway-test-isolation-b

# Renders a configuration as JSON into the temporary folder. Arguments: the file name, then the
# options of `docker compose` before `config`. Exits on an invalid configuration.
render() {
  local file=$1
  shift
  if ! docker compose "$@" config --format json >"$WORK/$file.json" 2>"$WORK/$file.err"; then
    echo "FAIL the configuration $file does not render"
    tail -5 "$WORK/$file.err"
    exit 1
  fi
}
# The local stack, with every profile. Arguments: the file name, then the project options.
local_stack() {
  render "$1" "${@:2}" --env-file .env.example -f compose.yaml -f compose.local.yaml --profile full
}
local_stack first -p "$FIRST"
local_stack second -p "$SECOND"
local_stack default
ENVIRONMENT=staging CADENWAY_SERVICES=../environments/staging/services \
  render staging -p cadenway-staging --env-file .env.example \
  --env-file ../environments/staging/versions.env -f compose.yaml

# Prints, for each configuration, `<file>.<fact>=<value>` lines: its project, its edge network,
# every network name, the Docker provider options of its Traefik and the networks Traefik joins,
# the services Traefik serves, and those it would reach on another network than the edge (a label
# pointing elsewhere, or a service not joined to it). An error goes to the same file, and every
# check below then fails.
docker run --rm -i --network none -v "$MOUNT:/work" "$IMAGE" node --input-type=module - \
  >"$WORK/facts" 2>&1 <<'JS' || true
import { readFileSync } from 'node:fs';

for (const file of ['first', 'second', 'default', 'staging']) {
  const config = JSON.parse(readFileSync(`/work/${file}.json`, 'utf8'));
  const print = (fact, value) => console.log(`${file}.${fact}=${value}`);
  const command = config.services.traefik?.command ?? [];
  const option = (name) =>
    command
      .filter((argument) => argument.startsWith(`--providers.docker.${name}=`))
      .map((argument) => argument.slice(argument.indexOf('=') + 1))
      .join(' ');
  const edge = config.networks.edge;
  const served = Object.entries(config.services).filter(
    ([, service]) => service.labels?.['traefik.enable'] === 'true',
  );
  const astray = served.filter(([, service]) => {
    const network = service.labels['traefik.docker.network'] ?? option('network');
    const joined = Object.keys(service.networks ?? {}).map((key) => config.networks[key].name);
    return network !== edge.name || !joined.includes(edge.name);
  });
  print('project', config.name);
  print('edge', edge.name);
  print('external', edge.external === true);
  print('networks', Object.values(config.networks).map((network) => network.name).sort().join(' '));
  print('constraints', option('constraints'));
  print('network', option('network'));
  const joins = Object.keys(config.services.traefik?.networks ?? {});
  print('joins', joins.map((key) => config.networks[key].name).sort().join(' '));
  print('served', served.map(([name]) => name).sort().join(' '));
  print('astray', astray.map(([name]) => name).sort().join(' '));
  if (file !== 'staging') {
    const membersOf = (network) =>
      Object.entries(config.services)
        .filter(([, service]) => Object.hasOwn(service.networks ?? {}, network))
        .map(([name]) => name)
        .sort()
        .join(' ');
    const socket = '/var/run/docker.sock';
    print('discovery.isolated',
      option('endpoint') === 'tcp://docker-api-proxy:8080' &&
      config.networks['docker-api']?.internal === true &&
      membersOf('docker-api') === 'docker-api-proxy traefik' &&
      !config.services.traefik.volumes?.some((volume) => volume.target === socket) &&
      config.services['docker-api-proxy'].volumes?.some((volume) => volume.target === socket),
    );
    const storage = config.services['storage-service'];
    print('upload-transfer.isolated',
      config.networks['upload-transfer']?.internal === true &&
      membersOf('upload-transfer') === 'storage-service traefik' &&
      Object.keys(storage.networks).sort().join(' ') === 'internal upload-transfer' &&
      !storage.ports?.length,
    );
    print('redis-legacy.enabled', Object.hasOwn(config.services, 'redis'));
    for (const [network, gateway] of [
      ['redis-api', 'api-gateway'],
      ['redis-realtime', 'realtime-gateway'],
    ]) {
      print(`${network}.members`, membersOf(network));
      print(`${network}.internal`, config.networks[network]?.internal === true);
      print(`${network}.url`, config.services[gateway]?.environment?.REDIS_URL);
    }
  }
}
JS
fact() { sed -n "s/^$1=//p" "$WORK/facts"; }
# Prints the network names of a configuration, one per line, sorted.
networks() { fact "$1.networks" | tr ' ' '\n' | sort; }

check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi; }
FAILED=0

echo '=== 1. each local stack has an edge network of its own'
check 'the first one is <project>-edge-local, created by the stack' \
  '[[ $(fact first.edge) == "$FIRST-edge-local" && $(fact first.external) == false ]]'
check 'the second one too' \
  '[[ $(fact second.edge) == "$SECOND-edge-local" && $(fact second.external) == false ]]'
check 'the default project keeps cadenway-edge-local' \
  '[[ $(fact default.project) == cadenway && $(fact default.edge) == cadenway-edge-local ]]'
check 'the two stacks share no network' \
  '[[ -n $(networks first) && -z $(comm -12 <(networks first) <(networks second)) ]]'

echo '=== 2. each local Traefik serves its own project, on its edge network'
check 'the first one reads the containers of its project only' \
  '[[ $(fact first.constraints) == "Label(\`com.docker.compose.project\`,\`$FIRST\`)" ]]'
check 'the second one too' \
  '[[ $(fact second.constraints) == "Label(\`com.docker.compose.project\`,\`$SECOND\`)" ]]'
check 'the default one too' \
  '[[ $(fact default.constraints) == "Label(\`com.docker.compose.project\`,\`cadenway\`)" ]]'
check 'each one reaches the containers on the edge network of its project' \
  '[[ $(fact first.network) == "$FIRST-edge-local" &&
    $(fact second.network) == "$SECOND-edge-local" ]]'
check 'and joins only edge, the private Docker API network, and the upload relay network' \
  '[[ $(fact first.joins) == "$FIRST-edge-local ${FIRST}_docker-api ${FIRST}_upload-transfer" &&
    $(fact second.joins) == "$SECOND-edge-local ${SECOND}_docker-api ${SECOND}_upload-transfer" &&
    $(fact default.joins) == "cadenway-edge-local cadenway_docker-api cadenway_upload-transfer" ]]'
check 'only the isolated discovery proxy mounts the Docker socket' \
  '[[ $(fact first.discovery.isolated) == true && $(fact second.discovery.isolated) == true &&
    $(fact default.discovery.isolated) == true ]]'
check 'only Traefik and Storage join the private upload relay network, with no Storage port published' \
  '[[ $(fact first.upload-transfer.isolated) == true && $(fact second.upload-transfer.isolated) == true &&
    $(fact default.upload-transfer.isolated) == true ]]'

echo '=== 3. every service Traefik serves is on that network'
check 'a definition of staging and a local service are served' \
  '[[ " $(fact first.served) " == *" api-gateway "* && " $(fact first.served) " == *" mailpit "* ]]'
check 'none is reached on another network' \
  '[[ -z $(fact first.astray) && -z $(fact second.astray) && -z $(fact default.astray) ]]'

echo '=== 4. a server keeps the edge network of its environment'
check 'staging joins the external cadenway-edge-staging' \
  '[[ $(fact staging.edge) == cadenway-edge-staging && $(fact staging.external) == true ]]'
check 'and its services point the shared Traefik at it' \
  '[[ -n $(fact staging.served) && -z $(fact staging.astray) ]]'

echo '=== 5. local gateways have private Redis networks'
for stack in first second default; do
  check "$stack leaves the legacy shared store stopped" \
    '[[ $(fact "$stack.redis-legacy.enabled") == false ]]'
  check "$stack confines the API store to the API gateway" \
    '[[ $(fact "$stack.redis-api.members") == "api-gateway redis-api" &&
       $(fact "$stack.redis-api.internal") == true &&
       $(fact "$stack.redis-api.url") == redis://redis-api:6379 ]]'
  check "$stack confines the realtime store to the realtime gateway" \
    '[[ $(fact "$stack.redis-realtime.members") == "realtime-gateway redis-realtime" &&
       $(fact "$stack.redis-realtime.internal") == true &&
       $(fact "$stack.redis-realtime.url") == redis://redis-realtime:6379 ]]'
done

if ((FAILED)); then
  echo '--- what the configurations render'
  cat "$WORK/facts"
fi
exit "$FAILED"
