import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, randomBytes } from 'node:crypto';

import { InternalTokenSigner } from '@cadenway/nest-common';
import sharp from 'sharp';

const keyId = 'p8-storage-fixture';
const organization = '018b6300-0000-7000-8000-000000000001';
const actor = '018b6300-0000-7000-8000-000000000002';
const otherOrganization = '018b6300-0000-7000-8000-000000000003';
const avatarId = '018b6300-0000-7000-8000-000000000004';
const taskPath = '/internal/v1/tasks/CAD-482/attachments';
const avatarPath = `/internal/v1/avatars/${avatarId}?ownerUserId=${actor}`;
const objectOrigin = 'http://127.0.0.1:8333';
const original = Buffer.from('P8 Cadenway real Storage verification\nUTF-8 test: éclair.\n');
const later = Buffer.from(
  'P8 later upload, left in object storage by the earlier database restore.\n',
);

function fixtureKeys(mode) {
  if (mode === 'keypair') {
    const privateJwk = generateKeyPairSync('ed25519').privateKey.export({ format: 'jwk' });
    return { ...privateJwk, kid: keyId };
  }
  if (mode === 'public-key') {
    const { kty, crv, x, kid } = JSON.parse(process.env.CW_FIXTURE_SIGNER);
    return { 'api-gateway': [{ kty, crv, x, kid }] };
  }
  return {
    activeKeyId: keyId,
    keys: [{ id: keyId, key: randomBytes(32).toString('base64url') }],
  };
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

async function bytes(response) {
  return Buffer.from(await response.arrayBuffer());
}

async function expect(response, status, operation) {
  if (response.status === status) return response;
  const error = await response.json().catch(() => ({}));
  const code =
    typeof error.code === 'string' && /^[a-z0-9.-]+$/u.test(error.code) ? ` (${error.code})` : '';
  throw new Error(`${operation}: expected HTTP ${status}, got ${response.status}${code}`);
}

async function objectRequest(url, options = {}) {
  assert.equal(new URL(url).origin, objectOrigin, 'Storage returned an unexpected object endpoint');
  try {
    return await fetch(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(25_000) });
  } catch {
    throw new Error('The loopback object storage request failed');
  }
}

async function upload(capability, payload, name, contentType) {
  assert.equal(capability.method, 'POST');
  const form = new FormData();
  for (const [key, value] of Object.entries(capability.fields)) form.append(key, value);
  form.append('file', new Blob([payload], { type: contentType }), name);
  const result = await objectRequest(capability.url, { method: 'POST', body: form });
  assert.ok(result.ok, `S3 multipart upload HTTP ${result.status}`);
}

function createStorageClient(signer) {
  return async (
    method,
    route,
    { body, organizationId = organization, authenticated = true } = {},
  ) => {
    const headers = {};
    if (authenticated) {
      const token = await signer.sign('storage-service', {
        actor: { type: 'user', id: actor },
        organizationId,
      });
      headers.Authorization = `Bearer ${token}`;
    }
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    return fetch(`http://127.0.0.1:3015${route}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      redirect: 'error',
      signal: AbortSignal.timeout(25_000),
    });
  };
}

async function attachmentBytes(storage, id) {
  const capability = await expect(
    await storage('GET', `${taskPath}/${id}/download`),
    200,
    'signed attachment download',
  );
  assert.equal(capability.headers.get('cache-control'), 'no-store');
  const file = await expect(await objectRequest((await capability.json()).url), 200, 'read file');
  assert.match(file.headers.get('content-disposition'), /attachment/u);
  return bytes(file);
}

async function completeAttachment(storage, fileName, payload) {
  const contentType = 'text/plain';
  const reservation = await expect(
    await storage('POST', taskPath, { body: { fileName, contentType, sizeBytes: payload.length } }),
    201,
    'reserve attachment',
  );
  const capability = await reservation.json();
  await upload(capability, payload, fileName, contentType);

  const completion = await expect(
    await storage('POST', `${taskPath}/${capability.id}/completion`),
    200,
    'complete attachment through Storage',
  );
  const attached = await completion.json();
  assert.equal(attached.id, capability.id);
  assert.ok(completion.headers.get('etag'));
  assert.deepEqual(await attachmentBytes(storage, attached.id), payload);
  return {
    attachmentId: attached.id,
    attachmentSha256: sha256(payload),
  };
}

async function avatarBytes(storage) {
  const image = await expect(
    await storage('GET', avatarPath, { organizationId: null }),
    200,
    'read avatar',
  );
  assert.equal(image.headers.get('content-type'), 'image/png');
  assert.equal(image.headers.get('cache-control'), 'private, no-store');
  return bytes(image);
}

async function prepareAvatar(storage) {
  const contentType = 'image/png';
  const image = await sharp({
    create: { width: 256, height: 256, channels: 3, background: '#55449b' },
  })
    .png()
    .toBuffer();
  const mediaPath = `/internal/v1/profile-media-uploads/${avatarId}`;
  const expiresAt = new Date(Math.floor(Date.now() / 1_000) * 1_000 + 120_000).toISOString();
  const reservation = await expect(
    await storage('POST', `${mediaPath}/transfer`, {
      organizationId: null,
      body: { kind: 'avatar', contentType, sizeBytes: image.length, expiresAt },
    }),
    200,
    'reserve avatar upload',
  );
  await upload(await reservation.json(), image, 'p8-avatar.png', contentType);
  const preparation = await expect(
    await storage('POST', `${mediaPath}/preparation`, {
      organizationId: null,
      body: { kind: 'avatar' },
    }),
    200,
    'prepare avatar derivative through Storage',
  );
  const { sizeBytes } = await preparation.json();
  const png = await avatarBytes(storage);
  assert.equal(png.length, sizeBytes);
  assert.equal((await sharp(png).metadata()).format, 'png');
  return { avatarId, avatarSha256: sha256(png) };
}

async function verifyDownloads(storage, state) {
  assert.equal(state.avatarId, avatarId);
  const attached = await attachmentBytes(storage, state.attachmentId);
  const png = await avatarBytes(storage);
  assert.equal(sha256(attached), state.attachmentSha256);
  assert.deepEqual(attached, original);
  assert.equal(sha256(png), state.avatarSha256);
  const route = `${taskPath}/${state.attachmentId}/download`;
  await expect(await storage('GET', route, { authenticated: false }), 401, 'missing bearer token');
  await expect(
    await storage('GET', route, { organizationId: otherOrganization }),
    404,
    'another tenant cannot access the attachment',
  );
  console.log(
    `PASS identical attachment (${attached.length} bytes) through Storage and its signed URL`,
  );
  console.log(`PASS identical avatar (${png.length} bytes) directly through Storage`);
  console.log(
    'PASS missing authentication returns HTTP 401 and another organization receives HTTP 404',
  );
}

async function run() {
  const [mode, stateJson] = process.argv.slice(2);
  if (['keypair', 'public-key', 'receipt-keyring'].includes(mode)) {
    console.log(JSON.stringify(fixtureKeys(mode)));
    return;
  }
  const signer = await InternalTokenSigner.create({
    issuer: 'api-gateway',
    privateJwk: JSON.parse(process.env.CW_FIXTURE_SIGNER),
  });
  const storage = createStorageClient(signer);
  if (mode === 'upload') {
    const attachment = await completeAttachment(storage, 'p8-recovery.txt', original);
    const avatar = await prepareAvatar(storage);
    console.log(JSON.stringify({ ...attachment, ...avatar }));
    return;
  }
  if (mode === 'upload-later') {
    console.log(
      JSON.stringify(await completeAttachment(storage, 'p8-added-after-dump.txt', later)),
    );
    return;
  }
  const state = JSON.parse(stateJson);
  if (mode === 'delete-attachment') {
    await expect(
      await storage('DELETE', `${taskPath}/${state.attachmentId}`),
      204,
      'delete attachment',
    );
    await expect(
      await storage('GET', `${taskPath}/${state.attachmentId}/download`),
      404,
      'deleted attachment',
    );
    console.log('PASS attachment deletion returns HTTP 204 and its download returns HTTP 404');
  } else if (mode === 'missing-avatar') {
    await expect(await storage('GET', avatarPath, { organizationId: null }), 503, 'missing avatar');
    console.log('PASS avatar is unavailable while its bytes are hidden by the S3 delete marker');
  } else if (mode === 'verify') {
    await verifyDownloads(storage, state);
  } else if (mode === 'later-metadata-rolled-back') {
    await expect(
      await storage('GET', `${taskPath}/${state.attachmentId}/download`),
      404,
      'post-dump record',
    );
    console.log('PASS Storage reports that the post-dump record is absent');
  } else {
    throw new Error(`Unknown Storage test operation: ${mode}`);
  }
}

await run();
