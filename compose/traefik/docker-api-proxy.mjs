import http from 'node:http';
import { pathToFileURL } from 'node:url';

const socketPath = process.env.DOCKER_SOCKET_PATH ?? '/var/run/docker.sock';
const allowedNetworks = new Set(
  (process.env.TRAEFIK_ALLOWED_NETWORKS ?? 'cadenway-edge-staging,cadenway-edge-prod')
    .split(',')
    .filter(Boolean),
);
const maxResponseBytes = 16 * 1024 * 1024;

/** Return only labels Traefik uses for routing and Compose service naming. */
function routingLabels(labels = {}) {
  return Object.fromEntries(
    Object.entries(labels).filter(
      ([name]) =>
        name.startsWith('traefik.') ||
        name === 'com.docker.compose.project' ||
        name === 'com.docker.compose.service',
    ),
  );
}

function exposed(labels, networks) {
  return (
    labels?.['traefik.enable'] === 'true' &&
    Object.keys(networks ?? {}).some((name) => allowedNetworks.has(name))
  );
}

function safeNetworks(networks = {}) {
  return Object.fromEntries(
    Object.entries(networks)
      .filter(([name]) => allowedNetworks.has(name))
      .map(([name, network]) => [
        name,
        {
          NetworkID: network.NetworkID,
          IPAddress: network.IPAddress,
          GlobalIPv6Address: network.GlobalIPv6Address,
        },
      ]),
  );
}

function safeContainer(container) {
  const labels = container.Config?.Labels;
  const networks = container.NetworkSettings?.Networks;
  if (!exposed(labels, networks)) return null;

  return {
    Id: container.Id,
    Name: container.Name,
    Config: { Labels: routingLabels(labels) },
    State: {
      Status: container.State?.Status,
      Health: container.State?.Health ? { Status: container.State.Health.Status } : undefined,
    },
    HostConfig: { NetworkMode: container.HostConfig?.NetworkMode },
    NetworkSettings: {
      Networks: safeNetworks(networks),
      Ports: Object.fromEntries(
        Object.keys(container.NetworkSettings?.Ports ?? {}).map((port) => [port, null]),
      ),
    },
  };
}

function sendJson(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json' });
  response.end(JSON.stringify(body));
}

function dockerRequest(path, method = 'GET') {
  return http.request({ socketPath, path, method });
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    request.once('error', reject);
    request.once('response', (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error('Docker API request failed'));
        return;
      }
      const chunks = [];
      let size = 0;
      response.on('data', (chunk) => {
        size += chunk.length;
        if (size > maxResponseBytes) {
          response.destroy(new Error('Docker API response exceeds the size limit'));
          return;
        }
        chunks.push(chunk);
      });
      response.once('error', reject);
      response.once('end', () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch (error) {
          reject(error);
        }
      });
    });
    request.end();
  });
}

function streamEvents(request, response, path) {
  const filters = encodeURIComponent(
    JSON.stringify({ type: ['container'], label: ['traefik.enable=true'] }),
  );
  const upstream = dockerRequest(path + '?filters=' + filters);
  upstream.once('error', () => response.destroy());
  upstream.once('response', (events) => {
    if (events.statusCode !== 200) {
      events.resume();
      response.writeHead(502).end();
      return;
    }
    response.writeHead(200, { 'Content-Type': 'application/json' });
    let pending = '';
    events.setEncoding('utf8');
    events.on('data', (chunk) => {
      pending += chunk;
      if (pending.length > maxResponseBytes) {
        events.destroy();
        response.destroy();
        return;
      }
      let newline = pending.indexOf('\n');
      while (newline !== -1) {
        const line = pending.slice(0, newline);
        pending = pending.slice(newline + 1);
        try {
          const event = JSON.parse(line);
          if (
            event.Type === 'container' &&
            (event.Action === 'start' ||
              event.Action === 'die' ||
              event.Action?.startsWith('health_status'))
          ) {
            // The provider refreshes its complete filtered list on each of these events.
            if (
              !response.write(JSON.stringify({ Type: 'container', Action: event.Action }) + '\n')
            ) {
              events.pause();
            }
          }
        } catch {
          events.destroy();
          response.destroy();
          return;
        }
        newline = pending.indexOf('\n');
      }
    });
    events.once('error', () => response.destroy());
    events.once('end', () => response.end());
    response.on('drain', () => events.resume());
  });
  response.once('close', () => upstream.destroy());
  upstream.end();
}

export function createProxy() {
  return http.createServer(async (request, response) => {
    const target = request.url ?? '';
    if (request.method === 'GET' && target === '/healthz') {
      response.writeHead(200).end();
      return;
    }
    if (request.method === 'HEAD' && target === '/_ping') {
      const upstream = dockerRequest('/_ping', 'HEAD');
      upstream.once('response', (result) => {
        response.writeHead(result.statusCode ?? 502, {
          'API-Version': result.headers['api-version'] ?? '',
        });
        result.resume();
        response.end();
      });
      upstream.once('error', () => response.writeHead(502).end());
      upstream.end();
      return;
    }
    if (request.method !== 'GET') {
      response.writeHead(403).end();
      return;
    }
    const match =
      /^\/(v[0-9]+\.[0-9]+)\/(version|containers\/json|containers\/[0-9a-f]{64}\/json|events)(?:\?[^#]*)?$/.exec(
        target,
      );
    if (
      !match ||
      (match[2].startsWith('containers/') && match[2] !== 'containers/json' && target.includes('?'))
    ) {
      response.writeHead(403).end();
      return;
    }

    const path = '/' + match[1] + '/' + match[2];
    if (match[2] === 'events') {
      streamEvents(request, response, path);
      return;
    }
    try {
      if (match[2] === 'version') {
        const version = await readJson(dockerRequest(path));
        sendJson(response, 200, {
          Version: version.Version,
          ApiVersion: version.ApiVersion,
          MinAPIVersion: version.MinAPIVersion,
        });
      } else if (match[2] === 'containers/json') {
        const filters = encodeURIComponent(JSON.stringify({ label: ['traefik.enable=true'] }));
        const containers = await readJson(dockerRequest(path + '?all=1&filters=' + filters));
        sendJson(
          response,
          200,
          containers
            .filter((container) => exposed(container.Labels, container.NetworkSettings?.Networks))
            .map((container) => ({ Id: container.Id })),
        );
      } else {
        const container = safeContainer(await readJson(dockerRequest(path)));
        if (container === null) {
          response.writeHead(404).end();
        } else {
          sendJson(response, 200, container);
        }
      }
    } catch {
      if (!response.headersSent) response.writeHead(502).end();
      else response.destroy();
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  createProxy().listen(8080, '0.0.0.0');
}
