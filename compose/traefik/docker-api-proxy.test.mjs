import assert from 'node:assert/strict';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import { randomBytes } from 'node:crypto';
import { after, before, test } from 'node:test';

const suffix = randomBytes(12).toString('hex');
const socket =
  process.platform === 'win32'
    ? `\\\\.\\pipe\\cadenway-docker-proxy-${suffix}`
    : path.join(os.tmpdir(), `cadenway-docker-proxy-${suffix}.sock`);
const proxySocket = socket + '-client';
process.env.DOCKER_SOCKET_PATH = socket;
process.env.TRAEFIK_ALLOWED_NETWORKS = 'cadenway-edge-staging,cadenway-edge-prod';
const { createProxy } = await import('./docker-api-proxy.mjs');

const exposedId = 'a'.repeat(64);
const privateId = 'b'.repeat(64);
const exposedLabels = {
  'traefik.enable': 'true',
  'traefik.http.routers.app.rule': 'Host(`app.example.com`)',
  'com.docker.compose.project': 'cadenway-staging',
  'private.label': 'private-label-value',
};
const exposedNetworks = {
  'cadenway-edge-staging': { NetworkID: 'edge', IPAddress: '172.20.0.3' },
  'cadenway-staging-internal': { NetworkID: 'internal', IPAddress: '172.21.0.3' },
};

const fakeDocker = http.createServer((request, response) => {
  const url = request.url ?? '';
  if (url === '/_ping') {
    response.writeHead(200, { 'API-Version': '1.53' }).end();
  } else if (url === '/v1.53/version') {
    response.end(JSON.stringify({ Version: '28', ApiVersion: '1.53', secret: 'server-secret' }));
  } else if (url.startsWith('/v1.53/containers/json?')) {
    response.end(
      JSON.stringify([
        { Id: exposedId, Labels: exposedLabels, NetworkSettings: { Networks: exposedNetworks } },
        {
          Id: privateId,
          Labels: { 'traefik.enable': 'true' },
          NetworkSettings: { Networks: { internal: {} } },
        },
      ]),
    );
  } else if (url === `/v1.53/containers/${exposedId}/json`) {
    response.end(
      JSON.stringify({
        Id: exposedId,
        Name: '/app',
        Config: { Labels: exposedLabels, Env: ['PRIVATE=environment-secret'] },
        State: { Status: 'running', Health: { Status: 'healthy', Log: ['health-secret'] } },
        HostConfig: { NetworkMode: 'default', Binds: ['host-secret'] },
        NetworkSettings: {
          Networks: exposedNetworks,
          Ports: { '8080/tcp': [{ HostIp: '192.0.2.1', HostPort: '1234' }] },
        },
      }),
    );
  } else if (url === `/v1.53/containers/${privateId}/json`) {
    response.end(
      JSON.stringify({
        Id: privateId,
        Config: { Labels: { 'traefik.enable': 'true' }, Env: ['PRIVATE=other-secret'] },
        NetworkSettings: { Networks: { internal: {} } },
      }),
    );
  } else if (url.startsWith('/v1.53/events?')) {
    response.writeHead(200, { 'Content-Type': 'application/json' });
    response.write(
      JSON.stringify({
        Type: 'container',
        Action: 'start',
        Actor: { ID: privateId, Attributes: { secret: 'event-secret' } },
      }) + '\n',
    );
  } else {
    response.writeHead(404).end();
  }
});

const proxy = createProxy();

before(async () => {
  fakeDocker.listen(socket);
  await once(fakeDocker, 'listening');
  proxy.listen(proxySocket);
  await once(proxy, 'listening');
});

after(async () => {
  proxy.closeAllConnections();
  await new Promise((resolve) => proxy.close(resolve));
  fakeDocker.closeAllConnections();
  await new Promise((resolve) => fakeDocker.close(resolve));
});

function request(method, target) {
  return new Promise((resolve, reject) => {
    const outgoing = http.request({ socketPath: proxySocket, method, path: target }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () =>
        resolve({
          status: response.statusCode,
          headers: response.headers,
          body: Buffer.concat(chunks).toString(),
        }),
      );
      response.on('error', reject);
    });
    outgoing.on('error', reject);
    outgoing.end();
  });
}

test('only exposed edge containers and required discovery fields are returned', async () => {
  const listed = await request('GET', '/v1.53/containers/json?all=1');
  assert.equal(listed.status, 200);
  assert.deepEqual(JSON.parse(listed.body), [{ Id: exposedId }]);

  const inspected = await request('GET', `/v1.53/containers/${exposedId}/json`);
  assert.equal(inspected.status, 200);
  const value = JSON.parse(inspected.body);
  assert.deepEqual(value.Config.Labels, {
    'traefik.enable': 'true',
    'traefik.http.routers.app.rule': 'Host(`app.example.com`)',
    'com.docker.compose.project': 'cadenway-staging',
  });
  assert.deepEqual(Object.keys(value.NetworkSettings.Networks), ['cadenway-edge-staging']);
  assert.deepEqual(value.NetworkSettings.Ports, { '8080/tcp': null });
  assert.equal(value.State.Health.Status, 'healthy');
  assert.doesNotMatch(inspected.body, /secret|private-label-value|192\.0\.2\.1/);
  assert.equal((await request('GET', `/v1.53/containers/${privateId}/json`)).status, 404);
});

test('Docker mutation and unneeded endpoints are denied', async () => {
  for (const [method, target] of [
    ['POST', '/v1.53/containers/create'],
    ['DELETE', `/v1.53/containers/${exposedId}`],
    ['GET', '/v1.53/info'],
    ['GET', '/v1.53/containers/json/../create'],
    ['GET', `/v1.53/containers/${exposedId}/json?leak=1`],
  ]) {
    assert.equal((await request(method, target)).status, 403);
  }
  const version = JSON.parse((await request('GET', '/v1.53/version')).body);
  assert.deepEqual(version, { Version: '28', ApiVersion: '1.53' });
  assert.equal((await request('HEAD', '/_ping')).headers['api-version'], '1.53');
});

test('events trigger refresh without disclosing actor metadata', async () => {
  const body = await new Promise((resolve, reject) => {
    const outgoing = http.get({ socketPath: proxySocket, path: '/v1.53/events' }, (response) => {
      response.once('data', (chunk) => {
        resolve(chunk.toString());
        response.destroy();
      });
      response.once('error', reject);
    });
    outgoing.once('error', reject);
  });
  assert.deepEqual(JSON.parse(body), { Type: 'container', Action: 'start' });
  assert.doesNotMatch(body, /secret|bbbb/);
});
