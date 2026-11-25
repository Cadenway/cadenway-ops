#!/usr/bin/env bash
# Test of the internal token keys and of what the local stack gives each backend. Covers: the key
# generator (refuses a missing file, writes one pair per issuer, changes nothing on a second run,
# prints without writing), keys that really sign and verify, and the environment Compose builds
# from them: each service trusts exactly the backends allowed to call it, each caller has its
# private key and the addresses of the services it calls.
#
#   bash compose/tests/service-wiring.sh
#
# It works on a copy of compose/.env.example in a temporary folder: compose/.env is never read or
# written. Nothing is started; the only containers are short-lived Node processes.
#
# The assertions are strings evaluated by `check`, so they expand late on purpose.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# Git Bash would rewrite the container paths given to `docker run`.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# The path Docker mounts: the Windows form under Git Bash, the path itself elsewhere.
host_path() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }
MOUNT=$(host_path "$WORK")
STACK=$(host_path .)
readonly WORK MOUNT STACK
IMAGE=$(sed -n '/^  internal-token-keys:/,/^$/s/^ *image: //p' compose.local.yaml)
readonly IMAGE

# Runs Node in the image of the `internal-token-keys` service, without network, with the temporary
# folder as /work and the generator as /keys. Arguments: those of `node`. A script may come on stdin.
node_run() {
  docker run --rm -i --network none -v "$MOUNT:/work" -v "$STACK/internal-token:/keys:ro" \
    "$IMAGE" node "$@" 2>&1
}
generate() { node_run /keys/generate-keys.mjs "$@"; }

check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi; }
FAILED=0
OUT=''

echo '=== 1. the generator'
OUT=$(generate /work/.env) && OUT="succeeded: $OUT"
check 'refuses a file that does not exist' '[[ $OUT == *"copy .env.example to .env first"* && $OUT != succeeded:* ]]'
cp .env.example "$WORK/.env"
OUT=$(generate /work/.env) || OUT="failed: $OUT"
check 'writes the pairs' '[[ $OUT == *"wrote the key pairs of API_GATEWAY, REALTIME_GATEWAY, IDENTITY_SERVICE, ORGANIZATION_SERVICE, AUTOMATION_SERVICE, INTEGRATION_SERVICE, TASK_SERVICE, DOCUMENT_SERVICE, SEARCH_SERVICE, NOTIFICATION_SERVICE, BILLING_SERVICE"* ]]'
OUT=$(grep -c '_INTERNAL_TOKEN_\(PRIVATE_JWK\|PUBLIC_JWKS\)=' "$WORK/.env")
check 'two variables per issuer' '[[ $OUT == 22 ]]'
BEFORE=$(sha256sum "$WORK/.env")
OUT=$(generate /work/.env) || OUT="failed: $OUT"
check 'a second run writes nothing' '[[ $OUT == *"nothing written"* && $(sha256sum "$WORK/.env") == "$BEFORE" ]]'
OUT=$(generate --print) || OUT="failed: $OUT"
check '--print prints twenty-two unquoted lines' \
  '[[ $(grep -c "^[A-Z_]*_INTERNAL_TOKEN_[A-Z_]*={\"kty\":\"OKP\"" <<<"$OUT") == 22 ]]'
check 'and leaves the file alone' '[[ $(sha256sum "$WORK/.env") == "$BEFORE" ]]'

echo '=== 2. the keys sign and verify'
OUT=$(node_run --input-type=module - <<'JS'
import { createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';

const variables = Object.fromEntries(
  readFileSync('/work/.env', 'utf8')
    .split('\n')
    .filter((line) => line.includes('_INTERNAL_TOKEN_'))
    .map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]),
);
const message = Buffer.from('cadenway');
for (const issuer of ['API_GATEWAY', 'REALTIME_GATEWAY', 'IDENTITY_SERVICE', 'ORGANIZATION_SERVICE', 'AUTOMATION_SERVICE', 'INTEGRATION_SERVICE', 'TASK_SERVICE', 'DOCUMENT_SERVICE', 'SEARCH_SERVICE', 'NOTIFICATION_SERVICE', 'BILLING_SERVICE']) {
  const quotedPrivate = variables[`${issuer}_INTERNAL_TOKEN_PRIVATE_JWK`];
  const quotedPublic = variables[`${issuer}_INTERNAL_TOKEN_PUBLIC_JWKS`];
  if (!/^'.*'$/.test(quotedPrivate) || !/^'.*'$/.test(quotedPublic)) throw new Error('not quoted');
  const privateJwk = JSON.parse(quotedPrivate.slice(1, -1));
  const publicJwk = JSON.parse(quotedPublic.slice(1, -1));
  if (publicJwk.d !== undefined) throw new Error('a public key carries the private part');
  if (privateJwk.kid !== publicJwk.kid || privateJwk.kid.length < 8) throw new Error('key ids');
  if (privateJwk.kty !== 'OKP' || privateJwk.crv !== 'Ed25519') throw new Error('not Ed25519');
  const signature = sign(null, message, createPrivateKey({ key: privateJwk, format: 'jwk' }));
  if (!verify(null, message, createPublicKey({ key: publicJwk, format: 'jwk' }), signature)) {
    throw new Error('the public key does not verify the private one');
  }
}
console.log('verified');
JS
) || true
check 'each public key verifies a signature of its private key' '[[ $OUT == verified ]]'

echo '=== 3. what Compose gives each backend'
docker compose --env-file "$MOUNT/.env" -f compose.yaml -f compose.local.yaml --profile full \
  config --format json >"$WORK/config.json" 2>"$WORK/warnings"
OUT=$(grep -E 'INTERNAL_TOKEN|_SERVICE_URL|SMTP_|MAIL_FROM|STORAGE_S3_|MEILI_' "$WORK/warnings" || true)
check 'no variable of the wiring is left unset' '[[ -z $OUT ]]'
OUT=$(node_run --input-type=module - <<'JS'
import { readFileSync } from 'node:fs';

const { services } = JSON.parse(readFileSync('/work/config.json', 'utf8'));
const gateway = ['api-gateway'];
const trusted = {
  'identity-service': ['api-gateway', 'realtime-gateway', 'organization-service'],
  'organization-service': ['api-gateway', 'realtime-gateway', 'identity-service'],
  'billing-service': gateway,
  'task-service': ['api-gateway', 'realtime-gateway', 'automation-service', 'integration-service'],
  'document-service': gateway,
  'storage-service': gateway,
  'notification-service': ['api-gateway', 'automation-service'],
  'automation-service': gateway,
  'integration-service': gateway,
  'search-service': gateway,
};
const called = {
  'api-gateway': Object.keys(trusted),
  'realtime-gateway': ['identity-service', 'organization-service', 'task-service'],
  'identity-service': ['organization-service'],
  'organization-service': ['identity-service'],
  'automation-service': ['task-service', 'notification-service'],
  'integration-service': ['task-service'],
  'task-service': ['organization-service'],
  'document-service': ['task-service'],
  'search-service': ['task-service', 'organization-service', 'document-service', 'storage-service'],
  'notification-service': ['identity-service', 'organization-service', 'task-service'],
  'billing-service': ['organization-service', 'storage-service'],
};
const port = (name) => /^\d+$/.test(services[name].environment.PORT);
const fail = (message) => {
  console.log(`wrong: ${message}`);
  process.exit(1);
};

for (const [name, issuers] of Object.entries(trusted)) {
  const environment = services[name].environment;
  if (environment.INTERNAL_TOKEN_AUDIENCE !== name) fail(`${name} audience`);
  const value = environment.INTERNAL_TOKEN_TRUSTED_ISSUERS;
  if (value.includes('\n')) fail(`${name} trusted issuers on several lines`);
  const parsed = JSON.parse(value);
  if (Object.keys(parsed).join() !== issuers.join()) fail(`${name} trusts ${Object.keys(parsed)}`);
  for (const keys of Object.values(parsed)) {
    if (keys.length !== 1 || keys[0].kty !== 'OKP' || keys[0].d !== undefined) fail(`${name} keys`);
  }
}
for (const [name, targets] of Object.entries(called)) {
  const environment = services[name].environment;
  const serviceSigner = name === 'identity-service' || name === 'organization-service' || name === 'task-service';
  const keyVariable = serviceSigner
    ? `${name.toUpperCase().replaceAll('-', '_')}_INTERNAL_TOKEN_PRIVATE_JWK`
    : 'INTERNAL_TOKEN_PRIVATE_JWK';
  if (!serviceSigner && ['api-gateway', 'realtime-gateway', 'automation-service', 'integration-service'].includes(name) && environment.INTERNAL_TOKEN_ISSUER !== name) fail(`${name} issuer`);
  const privateKey = JSON.parse(environment[keyVariable]);
  if (privateKey.d === undefined) fail(`${name} private key`);
  for (const target of targets) {
    const targetEnv = services[target].environment;
    const fallback = targetEnv[`${name.toUpperCase().replaceAll('-', '_')}_INTERNAL_TOKEN_PUBLIC_JWKS`];
    const publicKey = JSON.parse(targetEnv.INTERNAL_TOKEN_TRUSTED_ISSUERS)[name]?.[0] ?? (fallback && JSON.parse(fallback));
    if (!publicKey || publicKey.x !== privateKey.x || publicKey.kid !== privateKey.kid) {
      fail(`${target} does not trust ${name}'s signing key`);
    }
  }
  for (const target of targets) {
    const variable = `${target.toUpperCase().replaceAll('-', '_')}_URL`;
    const expected = `http://${target}:${services[target].environment.PORT}`;
    if (!port(target) || environment[variable] !== expected) fail(`${name} ${variable}`);
  }
  const extra = Object.keys(environment).filter(
    (key) => key.endsWith('_SERVICE_URL') && !targets.includes(key.slice(0, -4).toLowerCase().replaceAll('_', '-')),
  );
  if (extra.length > 0) fail(`${name} also has ${extra}`);
}
for (const name of Object.keys(services)) {
  const environment = services[name].environment ?? {};
  if (!(name in called) && 'INTERNAL_TOKEN_PRIVATE_JWK' in environment) fail(`${name} has a private key`);
}
// These variables are required by the current service definitions and local features.
const required = {
  'api-gateway': ['FEDERATED_CONTINUATION_URL'],
  'realtime-gateway': ['REALTIME_PAGED_RECIPIENTS_ENABLED'],
  'identity-service': ['AUTHENTICATION_COUNTER_RETENTION_ENABLED', 'NOTIFICATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS'],
  'organization-service': ['SEARCH_PROJECTION_CURSOR_SECRET', 'BILLING_AUTHORITY_CURSOR_SECRET', 'ORGANIZATION_SEAT_QUOTA_ENABLED', 'ORGANIZATION_SEAT_ENTITLEMENT_EVENTS_ENABLED'],
  'billing-service': ['BILLING_USAGE_ENABLED'],
  'task-service': ['TASK_SERVICE_OUTBOX_MODE', 'TASK_MEMBERSHIP_AUTHORITY_MODE', 'SEARCH_PROJECTION_CURSOR_SECRET'],
  'document-service': ['DOCUMENT_ACCESS_MODE', 'SEARCH_PROJECTION_CURSOR_SECRET'],
  'storage-service': ['SEARCH_PROJECTION_CURSOR_SECRET', 'BILLING_PROJECTION_CURSOR_SECRET', 'STORAGE_BYTE_QUOTA_ENABLED', 'STORAGE_BILLING_ENTITLEMENTS_ENABLED', 'STORAGE_UPLOAD_TRANSFER_MODE', 'STORAGE_UPLOAD_RECEIPT_KEYS'],
  'notification-service': ['SITE_CONTACT_SUPPORT_ADDRESS'],
  'automation-service': ['AUTOMATION_TASK_TRIGGERS_ENABLED', 'AUTOMATION_COMMENT_AND_NOTIFICATION_ACTIONS_ENABLED', 'AUTOMATION_CURSOR_SIGNING_KEY'],
  'integration-service': ['GIT_WEBHOOK_RECEIVERS', 'GIT_LINK_EVENTS_ENABLED', 'GIT_LINK_PURGE_ENABLED'],
  'search-service': ['SEARCH_PALETTE_CURSOR_SECRET'],
};
for (const [name, variables] of Object.entries(required)) {
  const environment = services[name].environment;
  const common = name.endsWith('-service')
    ? ['PORT', 'DATABASE_URL', 'NATS_URL', 'NATS_USER', 'NATS_PASSWORD', 'INTERNAL_TOKEN_AUDIENCE', 'INTERNAL_TOKEN_TRUSTED_ISSUERS']
    : ['PORT', 'REDIS_URL', 'ALLOWED_ORIGINS'];
  for (const variable of [...common, ...variables]) {
    if (!(variable in environment) || environment[variable] == null ||
        (environment[variable] === '' && !['FEDERATED_CONTINUATION_URL', 'SITE_CONTACT_SUPPORT_ADDRESS'].includes(variable))) {
      fail(`${name} missing ${variable}`);
    }
  }
}
for (const [name, variable] of [
  ['organization-service', 'SEARCH_PROJECTION_CURSOR_SECRET'], ['organization-service', 'BILLING_AUTHORITY_CURSOR_SECRET'],
  ['task-service', 'SEARCH_PROJECTION_CURSOR_SECRET'], ['document-service', 'SEARCH_PROJECTION_CURSOR_SECRET'],
  ['storage-service', 'SEARCH_PROJECTION_CURSOR_SECRET'], ['storage-service', 'BILLING_PROJECTION_CURSOR_SECRET'],
  ['search-service', 'SEARCH_PALETTE_CURSOR_SECRET'],
]) {
  const value = services[name].environment[variable];
  if (!value || Buffer.from(value, 'base64url').length !== 32 || Buffer.from(value, 'base64url').toString('base64url') !== value) fail(`${name} ${variable}`);
}
if (!/^[a-f0-9]{64}$/.test(services['automation-service'].environment.AUTOMATION_CURSOR_SIGNING_KEY)) fail('automation cursor key');
const receipt = JSON.parse(services['storage-service'].environment.STORAGE_UPLOAD_RECEIPT_KEYS);
if (receipt.keys.length !== 1 || receipt.activeKeyId !== receipt.keys[0].id || Buffer.from(receipt.keys[0].key, 'base64url').length !== 32 || Buffer.from(receipt.keys[0].key, 'base64url').toString('base64url') !== receipt.keys[0].key) fail('storage receipt keyring');
const storage = services['storage-service'].environment;
if (storage.S3_ENDPOINT !== 'http://garage:3900') fail('storage endpoint');
if (storage.S3_PUBLIC_ENDPOINT !== 'http://s3.cadenway.localhost') fail('storage public endpoint');
if (storage.S3_BUCKET !== 'cadenway-local' || !storage.S3_ACCESS_KEY_ID.startsWith('GK')) fail('bucket');
const notification = services['notification-service'].environment;
if (notification.SMTP_HOST !== 'mailpit' || notification.SMTP_PORT !== '1025') fail('SMTP');
const search = services['search-service'].environment;
if (search.MEILI_URL !== 'http://meilisearch:7700' || !search.MEILI_API_KEY) fail('Meilisearch');
// The relying party is the host of the web application, also its only origin.
const identity = services['identity-service'].environment;
if (identity.WEBAUTHN_RP_ID !== 'app.cadenway.localhost') fail('WebAuthn relying party');
if (identity.WEBAUTHN_ORIGINS !== 'http://app.cadenway.localhost') fail('WebAuthn origins');
console.log('wired');
JS
) || true
check 'trusted issuers, private keys, addresses, SMTP, S3, Meilisearch and WebAuthn' '[[ $OUT == wired ]]'

exit "$FAILED"
