import test from 'node:test';
import assert from 'node:assert/strict';
import { recoverMessageAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { serviceRequestMessage } from '../../scripts/lib/service-worker-client.mjs';
import { createWorkRewardsApi, createWorkRewardsWorker, validateWorkRewardsConfig, readAssignedRewardSnapshot } from '../../scripts/lib/work-rewards-client.mjs';

const signer = privateKeyToAccount(`0x${'12'.repeat(32)}`);
const serviceId = '43fea98b-efc2-40e6-9690-2bd360f52c8c';
const jobId = '12345678-1234-1234-1234-123456789012';
const leaseToken = 'abcdefab-1234-1234-1234-123456789012';
const now = Date.parse('2026-11-07T02:00:00Z');
const raw = () => ({ wallet: signer.address, keyEnv: 'METRION_SERVICE_WORKER_KEY', stateFile: '/tmp/service-state.json',
  service: { id: serviceId, expectedRevision: 1, name: 'Reserve checks', capability: 'protocol.monitor', priceAtomic: '10000' } });
const makeConfig = () => validateWorkRewardsConfig(raw());
const service = () => ({ id: serviceId, provider: signer.address, revision: 1, active: true, capability: 'protocol.monitor', priceAtomic: '10000' });
const job = () => ({ jobId, serviceId, revision: 1, provider: signer.address, capability: 'protocol.monitor', input: {},
  funding: 'protocol-rewards', rewardAtomic: '100000', leaseToken, leaseUntil: new Date(now + 60_000).toISOString(),
  deadline: new Date(now + 90_000).toISOString(), createdAt: new Date(now).toISOString(), windowId: Math.floor(now / 1_800_000) });
const journal = () => ({ data: {}, saves: [], async save() { this.saves.push(structuredClone(this.data)); } });

test('existing monitor config retains buyer price and gets an isolated rewards journal', () => {
  const config = makeConfig();
  assert.equal(config.service.priceAtomic, '10000');
  assert.equal(config.minimumRewardAtomic, '100000');
  assert.equal(config.rewardsStateFile, '/tmp/service-state.json.rewards');
  const input = raw(); delete input.service.id; delete input.service.expectedRevision;
  assert.equal(validateWorkRewardsConfig(input, { serviceId, revision: 1 }).service.id, serviceId);
  assert.throws(() => validateWorkRewardsConfig({ ...raw(), rewardsStateFile: '/tmp/../tmp/service-state.json' }), /different state/);
  assert.throws(() => validateWorkRewardsConfig({ ...raw(), service: { ...raw().service, capability: 'fetch.url' } }), /protocol.monitor/);
  assert.throws(() => validateWorkRewardsConfig(input), /published monitor/);
});

test('signed requests bind method, dedicated path, body and nonce without exposing the key', async () => {
  const config = makeConfig(); let sent;
  const api = createWorkRewardsApi(config, signer, { nowMs: () => now, request: async (url, options) => {
    sent = { url, ...options }; return new Response(JSON.stringify({ participant: {}, service: service() }));
  } });
  await api('/enroll', { serviceId });
  assert.equal(sent.url, 'https://metrion.network/api/work-rewards/enroll');
  assert.equal(sent.redirect, 'error');
  assert.equal(sent.body, JSON.stringify({ serviceId }));
  const headers = sent.headers;
  assert.equal(await recoverMessageAddress({ message: serviceRequestMessage('/api/work-rewards/enroll', sent.body,
    headers['x-request-timestamp'], headers['x-request-nonce']), signature: headers['x-wallet-signature'] }), signer.address);
  assert.ok(!JSON.stringify(sent).includes('12'.repeat(32)));
  await assert.rejects(api('/prepare', {}), /Unsupported/);
});

test('oversized response is rejected and API failure keeps its exact code', async () => {
  await assert.rejects(createWorkRewardsApi(makeConfig(), signer, { request: async () => new Response('{}', {
    headers: { 'content-length': '300000' },
  }) })('/me', {}), /too large/);
  await assert.rejects(createWorkRewardsApi(makeConfig(), signer, { request: async () => new Response(JSON.stringify({ error: 'lease_expired' }), {
    status: 409,
  }) })('/result', {}), error => error.status === 409 && error.code === 'lease_expired');
});

test('reward work pays its separate quote and saved acknowledgment survives restart without rerunning', async () => {
  const saved = journal(); let executions = 0, leased = 0, attempts = 0; const payloads = [];
  const api = async (action, payload) => {
    if (action === '/enroll') return { participant: {}, service: service() };
    if (action === '/lease') { leased++; return { job: job(), pollAfter: 5 }; }
    if (action === '/result') {
      payloads.push(structuredClone(payload)); attempts++;
      if (attempts === 1) throw new TypeError('Connection lost after report accepted');
      return { jobId, state: 'paid', paymentState: 'paid' };
    }
    throw Error('Unexpected action');
  };
  const options = { config: makeConfig(), api, journal: saved, nowMs: () => now,
    execute: async (capability, input) => { executions++; assert.equal(capability, 'protocol.monitor'); assert.deepEqual(input, {}); return { report: 'canonical' }; } };
  let worker = createWorkRewardsWorker(options); await worker.start();
  await assert.rejects(worker.cycle(), /Connection lost/);
  assert.ok(saved.data.pending); assert.equal(saved.data.pending.rewardAtomic, '100000');
  worker = createWorkRewardsWorker(options); await worker.start();
  const recovered = await worker.cycle();
  assert.equal(recovered.state, 'paid'); assert.equal(recovered.recovered, true);
  assert.equal(executions, 1); assert.equal(leased, 1); assert.deepEqual(payloads[0], payloads[1]);
  assert.equal(saved.data.pending, undefined); assert.equal(saved.data.lastResult.paymentState, 'paid');
});

test('foreign identities, wrong capability, arbitrary input, stale lease and low rewards never execute', async () => {
  for (const mutate of [
    value => { value.provider = `0x${'ab'.repeat(20)}`; }, value => { value.revision = 2; },
    value => { value.capability = 'fetch.url'; }, value => { value.input = { url: 'https://example.com' }; },
    value => { value.funding = 'buyer'; }, value => { value.rewardAtomic = '10000'; },
    value => { value.leaseUntil = new Date(now - 1).toISOString(); },
    value => { value.deadline = new Date(now - 1).toISOString(); }, value => { value.windowId = -1; },
    value => { delete value.createdAt; }, value => { value.createdAt = new Date(now + 999_999).toISOString(); },
  ]) {
    const next = job(); mutate(next); let executions = 0;
    const worker = createWorkRewardsWorker({ config: makeConfig(), journal: journal(), nowMs: () => now,
      api: async action => action === '/enroll' ? { service: service() } : { job: next },
      execute: async () => { executions++; return {}; } });
    await worker.start(); await assert.rejects(worker.cycle()); assert.equal(executions, 0);
  }
});

test('default monitor waits for a block at the assignment time instead of failing ordinary chain lag', async () => {
  let clock = now, heads = 0, reports = 0;
  const report = await readAssignedRewardSnapshot(makeConfig(), job(), { nowMs: () => clock,
    sleep: async milliseconds => { clock += milliseconds; },
    chain: { getBlock: async () => ({ timestamp: BigInt(Math.floor(now / 1000) - (heads++ === 0 ? 1 : 0)) }) },
    read: async () => { reports++; return { timestamp: Math.floor(now / 1000), targets: [] }; },
  });
  assert.equal(report.timestamp, Math.floor(now / 1000)); assert.equal(heads, 2); assert.equal(reports, 1);
  assert.equal(clock, now + 1000);
});

test('assignment wait stops at its lease deadline without producing an old report', async () => {
  let clock = now, reports = 0;
  await assert.rejects(readAssignedRewardSnapshot(makeConfig(), { ...job(), leaseUntil: new Date(now + 1500).toISOString() }, {
    nowMs: () => clock, sleep: async milliseconds => { clock += milliseconds; },
    chain: { getBlock: async () => ({ timestamp: BigInt(Math.floor(now / 1000) - 1) }) },
    read: async () => { reports++; return { timestamp: 1 }; },
  }), /expired/);
  assert.equal(clock, now + 1500); assert.equal(reports, 0);
});

test('unconfigured recurring policy waits for 60 seconds and never claims work or earnings', async () => {
  let executions = 0; const saved = journal();
  const worker = createWorkRewardsWorker({ config: makeConfig(), journal: saved, nowMs: () => now,
    execute: async () => { executions++; return {}; }, api: async action => {
      if (action === '/enroll') return { service: service() };
      assert.equal(action, '/lease');
      throw Object.assign(Error('Policy not configured'), { status: 409, code: 'recurring_rewards_policy_not_configured' });
    } });
  await worker.start();
  assert.deepEqual(await worker.cycle(), { state: 'idle', reason: 'recurring_rewards_policy_not_configured', pollAfter: 60 });
  assert.equal(executions, 0); assert.equal(saved.data.pending, undefined); assert.equal(saved.data.lastResult, undefined);
});

test('canonical verifier outage keeps the exact report; definite rejection closes it unpaid', async () => {
  for (const rejection of [{ status: 422, code: 'monitor_report_mismatch' }, { status: 422, code: 'monitor_report_precedes_purchase' },
    { status: 409, code: 'report_already_submitted' }]) {
    const saved = journal(); let attempts = 0, executions = 0; const payloads = [];
    const worker = createWorkRewardsWorker({ config: makeConfig(), journal: saved, nowMs: () => now,
      execute: async () => { executions++; return { report: true }; }, api: async (action, payload) => {
        if (action === '/enroll') return { service: service() };
        if (action === '/lease') return { job: job() };
        payloads.push(structuredClone(payload)); attempts++;
        if (attempts === 1) throw Object.assign(Error('RPC unavailable'), { status: 503, code: 'monitor_rpc_or_canonical_data_unavailable' });
        if (attempts === 2) throw Object.assign(Error('Report rejected'), rejection);
        return { jobId, state: 'failed', paymentState: 'unpaid' };
      } });
    await worker.start(); await assert.rejects(worker.cycle(), /RPC unavailable/);
    assert.deepEqual(saved.data.pending.payload.result, { report: true });
    const result = await worker.cycle(); assert.equal(result.state, 'failed'); assert.equal(executions, 1);
    assert.deepEqual(payloads[0], payloads[1]); assert.deepEqual(payloads[2], { jobId, leaseToken, error: 'execution_failed' });
    assert.equal(saved.data.pending, undefined);
  }
});

test('expired leases stop retrying while unknown acknowledgments retain saved work', async () => {
  for (const expired of [true, false]) {
    const saved = journal(); const worker = createWorkRewardsWorker({ config: makeConfig(), journal: saved, nowMs: () => now,
      execute: async () => ({}), api: async action => {
        if (action === '/enroll') return { service: service() };
        if (action === '/lease') return { job: job() };
        if (expired) throw Object.assign(Error('Expired'), { status: 409, code: 'lease_expired' });
        return { jobId, state: 'unknown' };
      } });
    await worker.start();
    if (expired) { const result = await worker.cycle(); assert.equal(result.paymentState, 'unpaid'); assert.equal(saved.data.pending, undefined); }
    else { await assert.rejects(worker.cycle(), /Unrecognized/); assert.ok(saved.data.pending); }
  }
});

test('different configured service cannot take over a saved rewards journal', async () => {
  const saved = journal(); saved.data.identity = { provider: makeConfig().wallet, serviceId: '00000000-0000-0000-0000-000000000001', revision: 1 };
  let calls = 0;
  const worker = createWorkRewardsWorker({ config: makeConfig(), journal: saved, api: async () => { calls++; } });
  await assert.rejects(worker.start(), /different provider/); assert.equal(calls, 0);
});
