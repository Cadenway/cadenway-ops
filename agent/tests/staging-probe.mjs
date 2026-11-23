import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { setTimeout as sleep } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

const routes = ['list', 'groups', 'detail'];
const rates = [5, 15, 30];
const workers = 2;
const warmupSeconds = 60;
const sampleSeconds = 300;
const timeoutMs = 5_000;

function origin(value) {
  const url = URL.parse(value);
  if (!url || !['https:', 'http:'].includes(url.protocol) || url.href !== `${url.origin}/`) {
    throw new Error('Provide an HTTP origin without credentials, a path, or a query.');
  }
  return url.origin;
}

function credentials(input, minimum) {
  const values = JSON.parse(input ?? '[]');
  if (
    !Array.isArray(values) ||
    values.some((value) => typeof value !== 'string' || !/^[^\s]+$/.test(value)) ||
    new Set(values).size !== values.length ||
    values.length < minimum
  ) {
    throw new Error(
      `Provide at least ${minimum} distinct bearer values in CW_PROBE_PUBLIC_TOKENS.`,
    );
  }
  return values;
}

export function configure(env, benchmark = false) {
  const listId = env.CW_PROBE_LIST_ID;
  const taskKey = env.CW_PROBE_TASK_KEY;
  if (!listId || !taskKey) throw new Error('Set CW_PROBE_LIST_ID and CW_PROBE_TASK_KEY.');

  const targets = [];
  if (env.CW_PROBE_PUBLIC_ORIGIN) {
    const tokens = credentials(env.CW_PROBE_PUBLIC_TOKENS, benchmark ? 2 : 1);
    targets.push({ base: origin(env.CW_PROBE_PUBLIC_ORIGIN), tokens, layer: 'public' });
  }
  if (!benchmark && env.CW_PROBE_INTERNAL_ORIGIN) {
    if (!env.CW_PROBE_INTERNAL_TOKEN_FILE) throw new Error('Set CW_PROBE_INTERNAL_TOKEN_FILE.');
    targets.push({
      base: origin(env.CW_PROBE_INTERNAL_ORIGIN),
      tokenFile: env.CW_PROBE_INTERNAL_TOKEN_FILE,
      layer: 'internal',
    });
  }
  if (targets.length === 0) throw new Error('Set an origin for the chosen mode.');

  const organizationId = env.CW_PROBE_ORGANIZATION_ID;
  const filters = new URLSearchParams({ status: 'progress,review', limit: '50' });
  const list = `/lists/${encodeURIComponent(listId)}`;
  const task = `/tasks/${encodeURIComponent(taskKey)}`;
  const paths = {
    list: `${list}/tasks?${filters}`,
    groups: `${list}/task-groups?groupBy=status&${filters}`,
    detail: `${task}/detail`,
  };
  const scenario = createHash('sha256')
    .update(JSON.stringify([targets[0].base, paths, organizationId]))
    .digest('hex');
  return { targets, paths, organizationId, scenario };
}

export async function request(target, path, route, organizationId, slot, send = fetch) {
  const started = performance.now();
  const signal = AbortSignal.timeout(timeoutMs);
  const sample = (status, outcome) => [
    Math.round((performance.now() - started) * 100) / 100,
    status,
    outcome,
  ];

  let token;
  try {
    token = target.tokens
      ? target.tokens[slot % target.tokens.length]
      : (await readFile(target.tokenFile, { encoding: 'utf8', signal })).trim();
    if (!token) return sample(null, 'credential');
  } catch {
    return sample(null, 'credential');
  }

  let status = null;
  try {
    const headers = { authorization: `Bearer ${token}`, accept: 'application/json' };
    // A fresh connection checks Docker DNS during the transition even if the old socket still works.
    if (target.layer === 'internal') headers.connection = 'close';
    if (target.layer === 'public' && organizationId)
      headers['if-organization-match'] = organizationId;
    const prefix = target.layer === 'internal' ? '/internal/v1' : '/v1';
    const response = await send(`${target.base}${prefix}${path}`, {
      headers,
      redirect: 'manual',
      signal,
    });
    status = response.status;
    if (status !== 200) {
      await response.body?.cancel();
      return sample(status, 'http');
    }
    const body = await response.json();
    if (route === 'detail') {
      if (!body?.task) return sample(status, 'invalid-response');
      if (target.layer === 'public') {
        if (!Array.isArray(body.partial)) return sample(status, 'invalid-response');
        if (body.partial.length > 0) return sample(status, 'partial');
      }
    } else if (!Array.isArray(body?.items) || (route === 'groups' && body.groupBy !== 'status')) {
      return sample(status, 'invalid-response');
    }
    return sample(status, 'ok');
  } catch {
    const outcome = signal.aborted ? 'timeout' : status === null ? 'network' : 'invalid-response';
    return sample(status, outcome);
  }
}

export async function pace(
  start,
  slots,
  spacing,
  launch,
  skipped,
  clock = () => performance.timeOrigin + performance.now(),
  wait = sleep,
) {
  const pending = [];
  for (let slot = 0; slot < slots; slot += 1) {
    const scheduled = start + slot * spacing;
    const remaining = scheduled - clock();
    if (remaining > 0) await wait(Math.ceil(remaining));
    // Discard late slots instead of sending catch-up bursts that invalidate the target rate.
    if (clock() >= scheduled + spacing) {
      skipped(slot);
    } else {
      pending.push(launch(slot));
    }
  }
  await Promise.all(pending);
}

async function probe(config, duration) {
  let passed = true;
  const start = Date.now();
  const launch = async (slot) => {
    const time = new Date().toISOString();
    await Promise.all(
      config.targets.flatMap((target) =>
        ['list', 'detail'].map(async (route) => {
          const [milliseconds, status, outcome] = await request(
            target,
            config.paths[route],
            route,
            config.organizationId,
            slot,
          );
          if (outcome !== 'ok') passed = false;
          console.log(
            JSON.stringify({
              time,
              slot,
              layer: target.layer,
              route,
              milliseconds,
              status,
              outcome,
            }),
          );
        }),
      ),
    );
  };
  await pace(start, duration, 1_000, launch, (slot) => {
    passed = false;
    console.log(JSON.stringify({ slot, outcome: 'skipped' }));
  });
  return passed;
}

async function benchmark(config, start, worker) {
  const [target] = config.targets;
  const passes = [];
  const passSeconds = warmupSeconds + sampleSeconds;
  for (const rate of rates) {
    for (let repeat = 1; repeat <= 3; repeat += 1) {
      const samples = [];
      let warmupSkipped = 0;
      let warmupRateLimited = 0;
      const passStart = start + passes.length * (passSeconds * 1_000 + timeoutMs);
      const routeOf = (slot) => routes[(workers * slot + worker) % routes.length];
      const isSample = (slot) => slot * workers + worker >= rate * warmupSeconds;
      await pace(
        passStart + worker * (1_000 / rate),
        (rate * passSeconds) / workers,
        (1_000 * workers) / rate,
        async (slot) => {
          const route = routeOf(slot);
          const sample = await request(
            target,
            config.paths[route],
            route,
            config.organizationId,
            slot,
          );
          if (isSample(slot)) samples.push([route, ...sample]);
          else if (sample[1] === 429) warmupRateLimited += 1;
        },
        (slot) => {
          if (isSample(slot)) samples.push([routeOf(slot), null, null, 'skipped']);
          else warmupSkipped += 1;
        },
      );
      passes.push({ rate, repeat, warmupSkipped, warmupRateLimited, samples });
    }
  }
  return { worker, start, scenario: config.scenario, passes };
}

export function summarize(samples) {
  const durations = [];
  const statuses = Object.create(null);
  const outcomes = Object.create(null);
  for (const [milliseconds, status, outcome] of samples) {
    if (outcome === 'ok' || outcome === 'partial') durations.push(milliseconds);
    const statusKey = status ?? 'no-response';
    statuses[statusKey] = (statuses[statusKey] ?? 0) + 1;
    outcomes[outcome] = (outcomes[outcome] ?? 0) + 1;
  }
  durations.sort((left, right) => left - right);
  const percentile = (fraction) => durations[Math.ceil(durations.length * fraction) - 1] ?? null;
  return {
    samples: samples.length,
    p50Ms: percentile(0.5),
    p95Ms: percentile(0.95),
    p99Ms: percentile(0.99),
    statuses,
    outcomes,
  };
}

export function merge(first, second) {
  if (
    new Set([first.worker, second.worker]).size !== workers ||
    ![first.worker, second.worker].every((worker) => worker === 0 || worker === 1) ||
    first.start !== second.start ||
    first.scenario !== second.scenario ||
    first.passes.length !== rates.length * 3 ||
    second.passes.length !== first.passes.length
  ) {
    throw new Error('Provide both reports from the same benchmark start and scenario.');
  }

  const passes = first.passes.map((left, index) => {
    const right = second.passes[index];
    const rate = rates[Math.floor(index / 3)];
    const repeat = (index % 3) + 1;
    const expected = (rate * sampleSeconds) / workers;
    if (
      [left, right].some(
        (pass) => pass.rate !== rate || pass.repeat !== repeat || pass.samples.length !== expected,
      )
    ) {
      throw new Error('A benchmark pass is incomplete.');
    }
    // Merge observations before computing percentiles so neither worker's slower tail is hidden.
    const samples = [...left.samples, ...right.samples];
    const byRoute = Object.fromEntries(
      routes.map((route) => [
        route,
        summarize(samples.filter(([name]) => name === route).map(([, ...sample]) => sample)),
      ]),
    );
    if (
      Object.values(byRoute).some((route) => route.samples !== (expected * workers) / routes.length)
    ) {
      throw new Error('A benchmark pass has an incomplete route mix.');
    }
    const skipped = samples.filter(([, , , outcome]) => outcome === 'skipped').length;
    const rateLimited = samples.filter(([, , status]) => status === 429).length;
    return {
      rate,
      repeat,
      achievedRate: (samples.length - skipped) / sampleSeconds,
      skipped,
      rateLimited,
      warmupSkipped: left.warmupSkipped + right.warmupSkipped,
      warmupRateLimited: left.warmupRateLimited + right.warmupRateLimited,
      byRoute,
    };
  });
  const valid = passes.every(
    ({ skipped, rateLimited, warmupSkipped, warmupRateLimited }) =>
      skipped === 0 && rateLimited === 0 && warmupSkipped === 0 && warmupRateLimited === 0,
  );
  return { valid, passes };
}

async function main([mode, ...args], env) {
  if (mode === 'merge' && args.length === workers) {
    const [first, second] = await Promise.all(
      args.map(async (file) => JSON.parse(await readFile(file, 'utf8'))),
    );
    const report = merge(first, second);
    console.log(JSON.stringify(report, null, 2));
    return report.valid;
  }
  if (mode === 'probe') {
    const { values } = parseArgs({ args, options: { duration: { type: 'string' } } });
    const duration = Number(values.duration);
    if (!Number.isSafeInteger(duration) || duration < 1)
      throw new Error('Set a positive --duration in seconds.');
    return probe(configure(env), duration);
  }
  if (mode === 'benchmark') {
    const { values } = parseArgs({
      args,
      options: { worker: { type: 'string' }, 'start-at': { type: 'string' } },
    });
    const start = Date.parse(values['start-at']);
    if (!['0', '1'].includes(values.worker) || !(start > Date.now())) {
      throw new Error('Provide --worker 0 or 1 and a shared future --start-at timestamp.');
    }
    console.log(
      JSON.stringify(await benchmark(configure(env, true), start, Number(values.worker))),
    );
    return true;
  }
  throw new Error(
    'Usage: staging-probe.mjs probe --duration SECONDS | benchmark --start-at UTC --worker 0|1 | merge REPORT0 REPORT1',
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    process.exitCode = (await main(process.argv.slice(2), process.env)) ? 0 : 1;
  } catch (error) {
    // JSON parsing and fetch errors can include runtime input containing credentials or IDs.
    const message =
      error?.constructor === Error ? error.message : 'Invalid input or unreadable report.';
    console.error(message);
    process.exitCode = 1;
  }
}
