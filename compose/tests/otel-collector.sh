#!/usr/bin/env bash
# Exercises the local collector with isolated OTLP/HTTP trace and metric payloads.
# Run from any directory with Docker available: bash compose/tests/otel-collector.sh
# The temporary Compose project and its network are removed on exit.
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
project="cadenway-otel-test-$$"
compose() {
  docker compose --project-name "$project" -f compose/otel-collector/compose.yaml "$@"
}
cleanup() { compose down --remove-orphans >/dev/null 2>&1; }
trap cleanup EXIT
compose up --build --detach --wait --wait-timeout 120 --no-deps otel-collector
collector=$(compose ps -q otel-collector)
node_image=$(sed -n '/^  internal-token-keys:/,/^$/s/^ *image: //p' compose/compose.local.yaml)
# The isolated client shares the collector network namespace and never publishes a host port.
docker run --rm -i --network "container:$collector" "$node_image" node --input-type=module - <<'JS'
const now = String(BigInt(Date.now()) * 1_000_000n);
const traces = { resourceSpans: [{ scopeSpans: [{ spans: [{
  traceId: '0123456789abcdef0123456789abcdef', spanId: '0123456789abcdef',
  name: 'local-recipe', startTimeUnixNano: now, endTimeUnixNano: now,
}]}]}] };
const metrics = { resourceMetrics: [{ scopeMetrics: [{ metrics: [{
  name: 'local_recipe', gauge: { dataPoints: [{ timeUnixNano: now, asDouble: 1 }] },
}]}]}] };
for (const [signal, body] of [['traces', traces], ['metrics', metrics]]) {
  const response = await fetch(`http://127.0.0.1:4318/v1/${signal}`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${signal}: HTTP ${response.status} ${await response.text()}`);
  const result = await response.json();
  const rejected = result.partialSuccess?.rejectedSpans ?? result.partialSuccess?.rejectedDataPoints;
  if (Number(rejected ?? 0) > 0) throw new Error(`${signal}: rejected ${rejected} records`);
}
JS
# Debug export is asynchronous. The project contains only this test's collector.
for _ in {1..30}; do
  logs=$(docker logs "$collector" 2>&1)
  if [[ $logs == *'"otelcol.signal": "traces"'*'"spans": 1'* && \
        $logs == *'"otelcol.signal": "metrics"'*'"data points": 1'* ]]; then
    echo 'PASS collector received and exported traces and metrics'
    exit 0
  fi
  sleep 1
done
echo 'FAIL collector did not export both signals' >&2
docker logs "$collector" >&2
exit 1
