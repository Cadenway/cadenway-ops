import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';

// All Docker API replies and the Unix socket in this test are synthetic.
const docker = (...args) =>
  execFileSync('docker', ['--context', 'desktop-linux', ...args], { encoding: 'utf8' }).trim();
const suffix = randomBytes(8).toString('hex');
const network = 'traefik-proxy-test-' + suffix;
const volume = 'traefik-proxy-socket-' + suffix;
const fixture = 'docker-api-fixture-' + suffix;
const proxy = 'docker-api-proxy-' + suffix;
const traefik = 'traefik-proxy-test-' + suffix;
const proxyScript = fileURLToPath(new URL('../traefik/docker-api-proxy.mjs', import.meta.url));
const node =
  'node:24.22.3-alpine3.24@sha256:98e4e60b35fd50143e1838da2957488c25aa3a3efbd48bb679923f77d6d3d873';
const traefikImage =
  'traefik:v3.7.18@sha256:9c437ac4f09ce6f4980a8544902d3475fdf70a1a7c578729581d2535dfa7d635';

const fakeDocker = [
  "const http = require('http');",
  "const os = require('os');",
  "const id = 'a'.repeat(64);",
  "const ip = Object.values(os.networkInterfaces()).flat().find(e => e.family === 'IPv4' && !e.internal).address;",
  "let path = '/one';",
  'const listeners = [];',
  "const labels = () => ({ 'traefik.enable': 'true', 'traefik.http.routers.fixture.rule': 'Path(' + String.fromCharCode(96) + path + String.fromCharCode(96) + ')', 'traefik.http.services.fixture.loadbalancer.server.port': '8081' });",
  'const networks = () => ({ [' + JSON.stringify(network) + ']: { IPAddress: ip } });',
  "const respond = (response, body) => { response.setHeader('Content-Type', 'application/json'); response.end(JSON.stringify(body)); };",
  'http.createServer((request, response) => {',
  " if (request.url.startsWith('/_ping')) { response.setHeader('API-Version', '1.53'); response.end('OK'); }",
  " else if (request.url.endsWith('/version')) respond(response, { ApiVersion: '1.53', MinAPIVersion: '1.24', Version: '28.0.0' });",
  " else if (request.url.includes('/containers/json')) respond(response, [{ Id: id, Labels: labels(), State: 'running', NetworkSettings: { Networks: networks() } }]);",
  " else if (request.url.includes('/containers/') && request.url.endsWith('/json')) respond(response, { Id: id, Name: '/fixture', Config: { Labels: labels(), ExposedPorts: { '8081/tcp': {} } }, State: { Running: true, Status: 'running' }, NetworkSettings: { Networks: networks(), Ports: {} } });",
  " else if (request.url.includes('/events')) { response.writeHead(200, { 'Content-Type': 'application/json' }); listeners.push(response); }",
  ' else response.writeHead(404).end();',
  "}).listen('/run/fixture/docker.sock');",
  'http.createServer((request, response) => {',
  " if (request.url === '/flip') { path = '/two'; for (const listener of listeners) listener.write(JSON.stringify({ Type: 'container', Action: 'start', Actor: { ID: id }, time: Math.floor(Date.now() / 1000) }) + '\\n'); }",
  " response.end('fixture');",
  '}).listen(8081);',
].join('\n');

async function eventually(check, label) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      if (await check()) return;
    } catch {
      // Wait for the synthetic stack to become ready.
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(label);
}

try {
  docker('network', 'create', '--internal', network);
  docker('volume', 'create', volume);
  docker(
    'run',
    '-d',
    '--pull',
    'never',
    '--name',
    fixture,
    '--network',
    network,
    '-v',
    volume + ':/run/fixture',
    '--entrypoint',
    'node',
    node,
    '-e',
    fakeDocker,
  );
  docker(
    'run',
    '-d',
    '--pull',
    'never',
    '--name',
    proxy,
    '--network',
    network,
    '--network-alias',
    'docker-api-proxy',
    '--read-only',
    '--tmpfs',
    '/tmp',
    '--cap-drop',
    'ALL',
    '--security-opt',
    'no-new-privileges:true',
    '-v',
    volume + ':/var/run',
    '-v',
    proxyScript + ':/app/docker-api-proxy.mjs:ro',
    '-e',
    'TRAEFIK_ALLOWED_NETWORKS=' + network,
    '--entrypoint',
    'node',
    node,
    '/app/docker-api-proxy.mjs',
  );
  docker(
    'run',
    '-d',
    '--pull',
    'never',
    '--name',
    traefik,
    '--network',
    network,
    traefikImage,
    '--providers.docker=true',
    '--providers.docker.endpoint=tcp://docker-api-proxy:8080',
    '--providers.docker.exposedbydefault=false',
    '--entrypoints.web.address=:80',
  );

  const request = (path) => {
    const code =
      "require('http').get({host:process.argv[1],port:80,path:process.argv[2]},r=>{let body='';r.on('data',chunk=>body+=chunk);r.on('end',()=>console.log(r.statusCode+' '+body))}).on('error',()=>process.exit(1))";
    return docker('exec', fixture, 'node', '-e', code, traefik, path);
  };
  await eventually(() => request('/one') === '200 fixture', 'Initial Traefik route');

  const probe = (method, path) => {
    const code =
      "const http=require('http'); const r=http.request({host:'docker-api-proxy',port:8080,method:process.argv[1],path:process.argv[2]},s=>{console.log(s.statusCode);s.resume()});r.on('error',()=>process.exit(1));r.end()";
    return docker('exec', fixture, 'node', '-e', code, method, path);
  };
  for (const [method, path] of [
    ['POST', '/v1.53/containers/create'],
    ['DELETE', '/v1.53/containers/' + 'a'.repeat(64)],
    ['POST', '/v1.53/containers/json'],
    ['HEAD', '/v1.53/containers/json'],
    ['GET', '/v1.53/containers/json/../create'],
    ['GET', '/v1.53/containers/a/json'],
    ['GET', '/v1.53/containers/aaaaaaaaaaaa/json'],
    ['GET', '/v1.53/info'],
  ])
    assert.equal(probe(method, path), '403', method + ' ' + path);
  assert.equal(probe('GET', '/v1.53/containers/json?all=1'), '200');
  assert.equal(probe('GET', '/v1.53/containers/' + 'a'.repeat(64) + '/json'), '200');
  docker(
    'exec',
    fixture,
    'node',
    '-e',
    "require('http').get('http://127.0.0.1:8081/flip',r=>r.resume())",
  );
  await eventually(() => request('/two') === '200 fixture', 'Updated Traefik route');
  await eventually(() => request('/one').startsWith('404 '), 'Old Traefik route removal');
  console.log('PASS Docker API restrictions and live Traefik route refresh');
} catch (error) {
  for (const name of [traefik, proxy, fixture]) {
    try {
      console.error(docker('logs', name));
    } catch {
      /* Resource was not created. */
    }
  }
  throw error;
} finally {
  for (const name of [traefik, proxy, fixture]) {
    try {
      docker('rm', '-f', name);
    } catch {
      /* Resource was not created. */
    }
  }
  try {
    docker('network', 'rm', network);
  } catch {
    /* Resource was not created. */
  }
  try {
    docker('volume', 'rm', volume);
  } catch {
    /* Resource was not created. */
  }
}
