// Generates the Ed25519 key pairs of the internal token, one per backend that signs it.
//
// A backend that calls another one signs a short-lived token with its private key; the called
// service checks it with the public key of that issuer (@cadenway/nest-common, "Internal token").
// No key is committed: a workstation generates its own, an operator generates those of staging and
// production. The file mode also appends missing workstation cursor and upload receipt secrets.
//
//   node generate-keys.mjs <env file>   appends the missing pairs to the file (compose/.env),
//                                       single-quoted so Compose takes the JSON literally;
//   node generate-keys.mjs --print      prints fresh pairs, unquoted, for `sops edit`.
//
// For each issuer <NAME> it writes two variables:
//   <NAME>_INTERNAL_TOKEN_PRIVATE_JWK   the private key, a secret, given to that backend only;
//   <NAME>_INTERNAL_TOKEN_PUBLIC_JWKS   its public key, given to the services that trust it. More
//                                       than one key, separated by commas, during a rotation.
//
// An issuer whose private key is already in the file is left alone, so a second run changes
// nothing; delete its two lines to replace its pair. Exits with 1 when the file does not exist.
// The local stack runs it in a container: `docker compose run --rm internal-token-keys`.
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';

// Backends that sign calls to other services.
const ISSUERS = [
  'API_GATEWAY',
  'REALTIME_GATEWAY',
  'IDENTITY_SERVICE',
  'ORGANIZATION_SERVICE',
  'AUTOMATION_SERVICE',
  'INTEGRATION_SERVICE',
  'TASK_SERVICE',
  'DOCUMENT_SERVICE',
  'SEARCH_SERVICE',
  'NOTIFICATION_SERVICE',
  'BILLING_SERVICE',
];

// Independent workstation keys; these remain stable across subsequent runs.
const CURSOR_SECRETS = [
  'ORGANIZATION_SEARCH_PROJECTION_CURSOR_SECRET',
  'ORGANIZATION_BILLING_AUTHORITY_CURSOR_SECRET',
  'TASK_SEARCH_PROJECTION_CURSOR_SECRET',
  'DOCUMENT_SEARCH_PROJECTION_CURSOR_SECRET',
  'STORAGE_SEARCH_PROJECTION_CURSOR_SECRET',
  'STORAGE_BILLING_PROJECTION_CURSOR_SECRET',
  'SEARCH_SERVICE_PALETTE_CURSOR_SECRET',
];
const LOCAL_SECRETS = [
  ...CURSOR_SECRETS,
  'AUTOMATION_CURSOR_SIGNING_KEY',
  'STORAGE_UPLOAD_RECEIPT_KEYS',
];

function renderSecrets(names) {
  return names
    .map((name) => {
      const bytes = randomBytes(32);
      const value =
        name === 'AUTOMATION_CURSOR_SIGNING_KEY'
          ? bytes.toString('hex')
          : name === 'STORAGE_UPLOAD_RECEIPT_KEYS'
            ? JSON.stringify({
                activeKeyId: 'local',
                keys: [{ id: 'local', key: bytes.toString('base64url') }],
              })
            : bytes.toString('base64url');
      return `${name}='${value}'\n`;
    })
    .join('');
}

/**
 * Creates one key pair as two JSON Web Keys that share a key id.
 *
 * @returns {{ privateJwk: string, publicJwk: string }} Each key as one line of JSON.
 */
function generatePair() {
  const { privateKey } = generateKeyPairSync('ed25519');
  const { x, d } = privateKey.export({ format: 'jwk' });
  const kid = randomBytes(8).toString('hex');
  return {
    privateJwk: JSON.stringify({ kty: 'OKP', crv: 'Ed25519', x, d, kid }),
    publicJwk: JSON.stringify({ kty: 'OKP', crv: 'Ed25519', x, kid }),
  };
}

/**
 * Renders the two variables of the issuers that still need a pair.
 *
 * @param {string[]} issuers Issuer names, in capitals.
 * @param {string} quote Character written around each value, or an empty string.
 * @returns {string} The dotenv lines, each ended by a line feed.
 */
function render(issuers, quote) {
  return issuers
    .map((issuer) => {
      const { privateJwk, publicJwk } = generatePair();
      return (
        `${issuer}_INTERNAL_TOKEN_PRIVATE_JWK=${quote}${privateJwk}${quote}\n` +
        `${issuer}_INTERNAL_TOKEN_PUBLIC_JWKS=${quote}${publicJwk}${quote}\n`
      );
    })
    .join('');
}

const target = process.argv[2];

if (target === undefined) {
  console.error('usage: generate-keys.mjs <env file> | --print');
  process.exit(2);
}

if (target === '--print') {
  process.stdout.write(render(ISSUERS, ''));
} else if (!existsSync(target)) {
  console.error(`internal-token-keys: ${target} does not exist; copy .env.example to .env first.`);
  process.exit(1);
} else {
  const current = readFileSync(target, 'utf8');
  const missing = ISSUERS.filter(
    (issuer) => !new RegExp(`^${issuer}_INTERNAL_TOKEN_PRIVATE_JWK=.`, 'm').test(current),
  );
  const missingSecrets = LOCAL_SECRETS.filter(
    (name) => !new RegExp(`^${name}=.`, 'm').test(current),
  );
  if (missing.length === 0 && missingSecrets.length === 0) {
    console.log('internal-token-keys: all local keys and secrets already exist; nothing written.');
  } else {
    const separator = current === '' || current.endsWith('\n') ? '' : '\n';
    appendFileSync(
      target,
      `${separator}\n# Local keys and secrets (internal-token/generate-keys.mjs).\n` +
        render(missing, "'") +
        renderSecrets(missingSecrets),
    );
    console.log(
      `internal-token-keys: wrote the key pairs of ${missing.join(', ')} and ${missingSecrets.length} local secrets.`,
    );
  }
}
