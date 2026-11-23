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

check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; echo "${OUT:-}" | tail -5; FAILED=1; fi; }
FAILED=0
OUT=''

echo '=== 1. the generator'
OUT=$(generate /work/.env) && OUT="succeeded: $OUT"
check 'refuses a file that does not exist' '[[ $OUT == *"copy .env.example to .env first"* && $OUT != succeeded:* ]]'
cp .env.example "$WORK/.env"
OUT=$(generate /work/.env) || OUT="failed: $OUT"
check 'writes the pairs' '[[ $OUT == *"wrote the key pairs of API_GATEWAY, REALTIME_GATEWAY, AUTOMATION_SERVICE, INTEGRATION_SERVICE, NOTIFICATION_SERVICE, DOCUMENT_SERVICE, BILLING_SERVICE, IDENTITY_SERVICE, ORGANIZATION_SERVICE, TASK_SERVICE"* ]]'
OUT=$(grep -c '_INTERNAL_TOKEN_\(PRIVATE_JWK\|PUBLIC_JWKS\)=' "$WORK/.env")
check 'two variables per issuer' '[[ $OUT == 20 ]]'
BEFORE=$(sha256sum "$WORK/.env")
OUT=$(generate /work/.env) || OUT="failed: $OUT"
check 'a second run writes nothing' '[[ $OUT == *"nothing written"* && $(sha256sum "$WORK/.env") == "$BEFORE" ]]'
OUT=$(generate --print) || OUT="failed: $OUT"
OUT=$(grep -c '^[A-Z_]*_INTERNAL_TOKEN_[A-Z_]*={"kty":"OKP"' <<<"$OUT") || true
check '--print prints twenty unquoted assignments' '[[ $OUT == 20 ]]'
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
for (const issuer of ['API_GATEWAY', 'REALTIME_GATEWAY', 'AUTOMATION_SERVICE', 'INTEGRATION_SERVICE', 'NOTIFICATION_SERVICE', 'DOCUMENT_SERVICE', 'BILLING_SERVICE', 'IDENTITY_SERVICE', 'ORGANIZATION_SERVICE', 'TASK_SERVICE']) {
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
  'identity-service': ['api-gateway', 'realtime-gateway', 'notification-service'],
  'organization-service': gateway,
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
  'task-service': ['organization-service'],
  'automation-service': ['task-service', 'notification-service'],
  'integration-service': ['task-service'],
  'notification-service': ['identity-service'],
  'document-service': ['task-service'],
};
const scopedSigners = {
  'identity-service': 'IDENTITY_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK',
  'organization-service': 'ORGANIZATION_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK',
  'task-service': 'TASK_SERVICE_INTERNAL_TOKEN_PRIVATE_JWK',
};
const signerVariable = (name) => scopedSigners[name] ?? 'INTERNAL_TOKEN_PRIVATE_JWK';
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
  // These backends fix the issuer in the application.
  if (name !== 'document-service' && !(name in scopedSigners) &&
      environment.INTERNAL_TOKEN_ISSUER !== name) fail(`${name} issuer`);
  if (JSON.parse(environment[signerVariable(name)]).d === undefined) fail(`${name} private key`);
  for (const target of targets) {
    const variable = `${target.toUpperCase().replaceAll('-', '_')}_URL`;
    const expected = `http://${target}:${services[target].environment.PORT}`;
    if (!port(target) || environment[variable] !== expected) fail(`${name} ${variable}`);
  }
  const extra = Object.keys(environment).filter(
    (key) => key.endsWith('_SERVICE_URL') && !targets.includes(key.slice(0, -4).toLowerCase().replaceAll('_', '-')),
  );
  if (name === 'notification-service') {
    for (const variable of ['ORGANIZATION_SERVICE_URL', 'TASK_SERVICE_URL']) {
      const index = extra.indexOf(variable);
      if (index >= 0 && !environment[variable]) extra.splice(index, 1);
    }
  }
  if (extra.length > 0) fail(`${name} also has ${extra}`);
}
for (const [receiver, senders] of Object.entries({
  'identity-service': ['organization-service'],
  'organization-service': ['identity-service', 'task-service', 'realtime-gateway'],
})) {
  for (const sender of senders) {
    const publicVariable = `${sender.toUpperCase().replaceAll('-', '_')}_INTERNAL_TOKEN_PUBLIC_JWKS`;
    const key = JSON.parse(services[receiver].environment[publicVariable]);
    const signer = JSON.parse(services[sender].environment[signerVariable(sender)]);
    if (key.kty !== 'OKP' || key.d !== undefined || key.x !== signer.x || key.kid !== signer.kid) {
      fail(`${receiver} ${sender} public key`);
    }
  }
}
const taskDocumentKey = JSON.parse(services['task-service'].environment.DOCUMENT_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS);
const documentPrivateKey = JSON.parse(services['document-service'].environment.INTERNAL_TOKEN_PRIVATE_JWK);
if (services['task-service'].environment.TASK_MEMBERSHIP_AUTHORITY_MODE !== 'required' ||
    services['document-service'].environment.DOCUMENT_ACCESS_MODE !== 'task-authorized') {
  fail('Task and Document authority modes');
}
if (taskDocumentKey.kty !== 'OKP' || taskDocumentKey.d !== undefined ||
    taskDocumentKey.x !== documentPrivateKey.x || taskDocumentKey.kid !== documentPrivateKey.kid) {
  fail('task Document public key');
}
const taskNotificationKey = JSON.parse(services['task-service'].environment.NOTIFICATION_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS);
const notificationPrivateKey = JSON.parse(services['notification-service'].environment.INTERNAL_TOKEN_PRIVATE_JWK);
if (taskNotificationKey.kty !== 'OKP' || taskNotificationKey.d !== undefined ||
    taskNotificationKey.x !== notificationPrivateKey.x || taskNotificationKey.kid !== notificationPrivateKey.kid) {
  fail('task Notification public key');
}
const automation = services['automation-service'].environment;
const integration = services['integration-service'].environment;
if (automation.AUTOMATION_TASK_TRIGGERS_ENABLED !== 'false' ||
    automation.AUTOMATION_COMMENT_AND_NOTIFICATION_ACTIONS_ENABLED !== 'false' ||
    automation.AUTOMATION_CURSOR_SIGNING_KEY ||
    services['notification-service'].environment.TASK_SERVICE_URL ||
    services['realtime-gateway'].environment.REALTIME_GIT_RELAYS_ENABLED !== 'false' ||
    integration.GIT_LINK_EVENTS_ENABLED !== 'false' || integration.GIT_LINK_PURGE_ENABLED !== 'false' ||
    integration.GIT_WEBHOOK_RECEIVERS !== '[]') {
  fail('P6 actions and Git links are inactive by default');
}
for (const name of Object.keys(services)) {
  const environment = services[name].environment ?? {};
  const keys = Object.keys(environment).filter((key) => key.endsWith('INTERNAL_TOKEN_PRIVATE_JWK'));
  const expected = name in called || name === 'billing-service' ? signerVariable(name) : undefined;
  if (keys.length !== (expected === undefined ? 0 : 1) || keys.some((key) => key !== expected)) {
    fail(`${name} signing key scope`);
  }
}
const billing = services['billing-service'].environment;
const billingPrivateKey = JSON.parse(billing.INTERNAL_TOKEN_PRIVATE_JWK);
for (const name of ['organization-service', 'storage-service']) {
  const key = JSON.parse(services[name].environment.BILLING_SERVICE_INTERNAL_TOKEN_PUBLIC_JWKS);
  if (key.kty !== 'OKP' || key.d !== undefined || key.x !== billingPrivateKey.x ||
      key.kid !== billingPrivateKey.kid) fail(`${name} Billing public key`);
}
if (billing.BILLING_USAGE_ENABLED !== 'false' || billing.ORGANIZATION_SERVICE_URL ||
    billing.STORAGE_SERVICE_URL || services['notification-service'].environment.ORGANIZATION_SERVICE_URL) {
  fail('Billing is inactive by default');
}
const storage = services['storage-service'].environment;
if (storage.STORAGE_UPLOAD_TRANSFER_MODE !== 'presigned-post' ||
    storage.STORAGE_UPLOAD_TRANSFER_URL) fail('default Storage upload mode');
if (services['organization-service'].environment.ORGANIZATION_SEAT_ENTITLEMENT_EVENTS_ENABLED !== 'false' ||
    storage.STORAGE_BILLING_ENTITLEMENTS_ENABLED !== 'false') {
  fail('Billing entitlement projections are inactive by default');
}
if (storage.S3_ENDPOINT !== 'http://garage:3900') fail('storage endpoint');
if (storage.S3_PUBLIC_ENDPOINT !== 'http://s3.cadenway.localhost') fail('storage public endpoint');
if (storage.S3_BUCKET !== 'cadenway-local' || !storage.S3_ACCESS_KEY_ID.startsWith('GK')) fail('bucket');
const notification = services['notification-service'].environment;
if (notification.SMTP_HOST !== 'mailpit' || notification.SMTP_PORT !== '1025' ||
    notification.NODE_ENV !== 'development' || notification.SMTP_ALLOW_INSECURE_LOCAL !== 'true') fail('SMTP');
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

echo '=== 4. explicit limited and one-shot modes'
TASK_MEMBERSHIP_AUTHORITY_MODE=limited DOCUMENT_ACCESS_MODE=search-only DOCUMENT_TASK_SERVICE_URL= \
  STORAGE_UPLOAD_TRANSFER_MODE=local-one-shot \
  STORAGE_UPLOAD_TRANSFER_URL=http://upload.cadenway.localhost/internal/v1/upload-transfers \
  docker compose --env-file "$MOUNT/.env" -f compose.yaml -f compose.local.yaml --profile full \
  config --format json >"$WORK/config.json" 2>"$WORK/warnings"
OUT=$(node_run --input-type=module - <<'JS'
import { readFileSync } from 'node:fs';

const { services } = JSON.parse(readFileSync('/work/config.json', 'utf8'));
const task = services['task-service'].environment;
const document = services['document-service'].environment;
const storage = services['storage-service'].environment;
if (task.TASK_MEMBERSHIP_AUTHORITY_MODE !== 'limited' ||
    document.DOCUMENT_ACCESS_MODE !== 'search-only' || document.TASK_SERVICE_URL ||
    storage.STORAGE_UPLOAD_TRANSFER_MODE !== 'local-one-shot' ||
    storage.STORAGE_UPLOAD_TRANSFER_URL !== 'http://upload.cadenway.localhost/internal/v1/upload-transfers') {
  throw new Error('incorrect explicit authority or transfer mode');
}
console.log('wired');
JS
) || true
check 'explicit authority and upload modes' '[[ $OUT == wired ]]'

exit "$FAILED"
