import assert from 'node:assert/strict';
import test from 'node:test';
import { configure, merge, pace, request, summarize } from './staging-probe.mjs';

const environment = {
  CW_PROBE_PUBLIC_ORIGIN: 'https://api.staging.example.invalid',
  CW_PROBE_LIST_ID: 'list-fixture',
  CW_PROBE_TASK_KEY: 'TASK-FIXTURE',
  CW_PROBE_ORGANIZATION_ID: 'organization-fixture',
  CW_PROBE_PUBLIC_TOKENS: JSON.stringify(['fixture-a', 'fixture-b']),
};

test('configures the same filtered reads for both benchmark workers', () => {
  const config = configure(environment, true);
  const [target] = config.targets;
  assert.equal(target.layer, 'public');
  assert.equal(target.tokens.length, 2);
  assert.equal(config.paths.list, '/lists/list-fixture/tasks?status=progress%2Creview&limit=50');
  assert.equal(
    config.paths.groups,
    '/lists/list-fixture/task-groups?groupBy=status&status=progress%2Creview&limit=50',
  );
  assert.equal(config.paths.detail, '/tasks/TASK-FIXTURE/detail');
  assert.throws(() =>
    configure({ ...environment, CW_PROBE_PUBLIC_TOKENS: '["same","same"]' }, true),
  );
  assert.throws(() => configure({ ...environment, CW_PROBE_PUBLIC_ORIGIN: `${target.base}/path` }));
});

test('does not follow redirects and distinguishes partial, invalid and unsuccessful reads', async () => {
  const config = configure(environment);
  const [target] = config.targets;
  const path = config.paths.detail;
  const read = (send) => request(target, path, 'detail', config.organizationId, 1, send);
  const [, partialStatus, partial] = await read(async (url, options) => {
    assert.equal(url, `${target.base}/v1${path}`);
    assert.equal(options.redirect, 'manual');
    assert.equal(options.headers.authorization, 'Bearer fixture-b');
    assert.equal(options.headers['if-organization-match'], 'organization-fixture');
    return Response.json({ task: {}, partial: ['comments'] });
  });
  assert.equal(partialStatus, 200);
  assert.equal(partial, 'partial');

  const [, groupStatus, groupOutcome] = await request(
    target,
    config.paths.groups,
    'groups',
    config.organizationId,
    1,
    async () => Response.json({ groupBy: 'status', items: [] }),
  );
  assert.equal(groupStatus, 200);
  assert.equal(groupOutcome, 'ok');

  const [, invalidStatus, invalid] = await read(async () => new Response('not JSON'));
  assert.equal(invalidStatus, 200);
  assert.equal(invalid, 'invalid-response');
  const [, httpStatus, http] = await read(
    async () => new Response('rate limited', { status: 429 }),
  );
  assert.equal(httpStatus, 429);
  assert.equal(http, 'http');
  const [, transportStatus, transport] = await read(async () => {
    throw new Error('fixture connection failure');
  });
  assert.equal(transportStatus, null);
  assert.equal(transport, 'network');
});

test('checks direct internal reads on a fresh connection with the trusted bearer', async () => {
  const target = { base: 'http://task-service:3013', layer: 'internal', tokens: ['fixture'] };
  const [, status, outcome] = await request(
    target,
    '/tasks/TST-42/detail',
    'detail',
    'not-forwarded',
    0,
    async (url, { headers }) => {
      assert.equal(url, 'http://task-service:3013/internal/v1/tasks/TST-42/detail');
      assert.equal(headers.authorization, 'Bearer fixture');
      assert.equal(headers.connection, 'close');
      assert.equal(headers['if-organization-match'], undefined);
      return Response.json({ task: { key: 'TST-42' } });
    },
  );
  assert.equal(status, 200);
  assert.equal(outcome, 'ok');
});

test('skips elapsed schedule slots without a burst', async () => {
  let current = 0;
  const sent = [];
  const skipped = [];
  await pace(
    1_000,
    4,
    1_000,
    async (slot) => void sent.push({ slot, current }),
    (slot) => skipped.push(slot),
    () => current,
    async (milliseconds) => {
      current += milliseconds;
      if (current === 2_000) current += 1_500;
    },
  );

  assert.deepEqual(sent, [
    { slot: 0, current: 1_000 },
    { slot: 2, current: 3_500 },
    { slot: 3, current: 4_000 },
  ]);
  assert.deepEqual(skipped, [1]);
});

test('computes percentiles from combined observations and reports partial responses', () => {
  const summary = summarize([
    [8, 200, 'partial'],
    [4, 200, 'ok'],
    [2, 503, 'http'],
    [null, null, 'skipped'],
  ]);
  assert.equal(summary.p50Ms, 4);
  assert.equal(summary.p95Ms, 8);
  assert.equal(summary.p99Ms, 8);
  assert.equal(summary.statuses[200], 2);
  assert.equal(summary.statuses[503], 1);
  assert.equal(summary.outcomes.partial, 1);
  assert.equal(summary.outcomes.skipped, 1);
});

test('merges aligned runs and marks rate-limited or dropped passes invalid', () => {
  const fixture = (worker, milliseconds) => ({
    worker,
    start: 1,
    scenario: 'fixture',
    passes: [5, 15, 30].flatMap((rate) =>
      [1, 2, 3].map((repeat) => ({
        rate,
        repeat,
        warmupSkipped: 0,
        warmupRateLimited: 0,
        samples: Array.from({ length: rate * 150 }, (_, index) => [
          ['list', 'groups', 'detail'][index % 3],
          milliseconds,
          200,
          'ok',
        ]),
      })),
    ),
  });

  const first = fixture(0, 10);
  const second = fixture(1, 100);
  assert.throws(() => merge(first, first));
  const complete = merge(first, second);
  assert.equal(complete.valid, true);
  assert.equal(complete.passes[8].achievedRate, 30);
  assert.equal(complete.passes[8].byRoute.detail.p50Ms, 10);
  assert.equal(complete.passes[8].byRoute.detail.p95Ms, 100);

  first.passes[8].samples[0] = ['list', 10, 429, 'http'];
  first.passes[8].samples[1] = ['groups', null, null, 'skipped'];
  const invalid = merge(first, second);
  assert.equal(invalid.valid, false);
  assert.equal(invalid.passes[8].rateLimited, 1);
  assert.equal(invalid.passes[8].skipped, 1);
  assert.equal(invalid.passes[8].byRoute.list.statuses[429], 1);
});
