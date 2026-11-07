import test from 'node:test';
import assert from 'node:assert/strict';
import { recoverMessageAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { serviceRequestMessage } from '../../scripts/lib/service-worker-client.mjs';
import { attributeContributionBuyer, createContributionApi, createContributionWorker, validateContributionConfig } from '../../scripts/lib/contribution-client.mjs';

const signer = privateKeyToAccount(`0x${'34'.repeat(32)}`), now = Date.parse('2026-11-07T12:00:00Z');
const serviceId = '43fea98b-efc2-40e6-9690-2bd360f52c8c';
const jobId = '12345678-1234-1234-1234-123456789012', leaseToken = 'abcdefab-1234-1234-1234-123456789012';
const raw = () => ({ wallet: signer.address, stateFile: '/tmp/marketplace-state.json', keyEnv: 'METRION_SERVICE_WORKER_KEY',
  service: { id: serviceId, expectedRevision: 1, name: 'Monitor', capability: 'protocol.monitor', priceAtomic: '10000' } });
const service = { id: serviceId, provider: signer.address, revision: 1, capability: 'protocol.monitor', active: true };
const job = () => ({ jobId, leaseToken, serviceId, provider: signer.address, revision: 1, capability: 'protocol.monitor',
  funding: 'protocol-contributions', rewardAtomic: '100000', input: {}, windowId: Math.floor(now / 1_800_000), epochId: Math.floor(now / 86_400_000),
  createdAt: new Date(now).toISOString(), deadline: new Date(now + 90_000).toISOString(), leaseUntil: new Date(now + 60_000).toISOString() });

test('contribution config keeps marketplace and legacy reward journals separate', () => {
  const config = validateContributionConfig(raw());
  assert.equal(config.contributionStateFile, '/tmp/marketplace-state.json.contributions');
  assert.equal(config.service.priceAtomic, '10000');
  assert.throws(() => validateContributionConfig({ ...raw(), contributionStateFile: '/tmp/marketplace-state.json' }), /different state/);
  assert.throws(() => validateContributionConfig({ ...raw(), contributionStateFile: '/tmp/marketplace-state.json.rewards' }), /legacy rewards/);
});

test('public catalogue needs no wallet signature and signed attribution binds buyer and referrer', async () => {
  const requests = [];
  const request = async (url, options) => { requests.push({ url, ...options }); return new Response(JSON.stringify(
    options.method === 'GET' ? { tasks: [] } : { attribution: { buyer: signer.address, referrer: JSON.parse(options.body).referrer } })); };
  await createContributionApi({ request })('/status');
  assert.equal(requests[0].url, 'https://metrion.network/api/contributions');
  assert.equal(requests[0].method, 'GET'); assert.deepEqual(requests[0].headers, {}); assert.equal(requests[0].body, undefined);
  const referrer = `0x${'ab'.repeat(20)}`;
  await attributeContributionBuyer({ account: signer, referrer, request, nowMs: () => now });
  const sent = requests[1], headers = sent.headers;
  assert.equal(sent.url, 'https://metrion.network/api/contributions/attribute');
  assert.deepEqual(JSON.parse(sent.body), { referrer });
  assert.equal(await recoverMessageAddress({ message: serviceRequestMessage('/api/contributions/attribute', sent.body,
    headers['x-request-timestamp'], headers['x-request-nonce']), signature: headers['x-wallet-signature'] }), signer.address);
  assert.equal(requests.length, 2); assert.equal(sent.redirect, 'error');
  await assert.rejects(attributeContributionBuyer({ account: signer, referrer: signer.address, request }), /different/);
  await assert.rejects(attributeContributionBuyer({ referrer, request }), /local wallet signer/);
  assert.equal(requests.length, 2);
});

test('a contribution worker executes only funded monitor jobs and preserves the exact accepted report', async () => {
  let executions = 0, submits = 0; const payloads = [];
  const journal = { data: {}, save: async () => {} };
  const api = async (action, payload) => {
    if (action === '/enroll') return { participant: {}, service };
    if (action === '/lease') return { job: job(), pollAfter: 5 };
    assert.equal(action, '/result'); payloads.push(structuredClone(payload));
    if (submits++ === 0) throw new TypeError('Lost acknowledgment');
    return { jobId, state: 'complete', paymentState: 'queued', creditId: 'earned-credit-id', creditAtomic: '100000' };
  };
  const worker = createContributionWorker({ config: validateContributionConfig(raw()), api, journal, nowMs: () => now,
    execute: async () => { executions++; return { timestamp: Math.floor(now / 1000) }; } });
  await worker.start(); await assert.rejects(worker.cycle(), /Lost acknowledgment/);
  const result = await worker.cycle(); assert.equal(result.paymentState, 'queued'); assert.equal(result.creditAtomic, '100000');
  assert.equal(executions, 1); assert.deepEqual(payloads[0], payloads[1]);
  assert.equal(journal.data.lastResult.creditId, 'earned-credit-id'); assert.equal(journal.data.lastResult.epochId, job().epochId);
});

test('no funded task is an idle state and never starts compute', async () => {
  let executions = 0;
  const worker = createContributionWorker({ config: validateContributionConfig(raw()), journal: { data: {}, save: async () => {} },
    nowMs: () => now, execute: async () => { executions++; },
    api: async action => action === '/enroll' ? { service } : { job: null, reason: 'no_funded_tasks', pollAfter: 60 } });
  await worker.start(); assert.deepEqual(await worker.cycle(), { state: 'idle', reason: 'no_funded_tasks', pollAfter: 60 });
  assert.equal(executions, 0);
});

test('legacy queue jobs cannot execute in the contribution runner', async () => {
  let executions = 0;
  const worker = createContributionWorker({ config: validateContributionConfig(raw()), journal: { data: {}, save: async () => {} },
    nowMs: () => now, execute: async () => { executions++; },
    api: async action => action === '/enroll' ? { service } : { job: { ...job(), funding: 'protocol-rewards' } } });
  await worker.start(); await assert.rejects(worker.cycle(), /local provider terms/); assert.equal(executions, 0);
});

test('API errors retain immutable-attribution failures without producing a payment', async () => {
  let requests = 0;
  await assert.rejects(attributeContributionBuyer({ account: signer, referrer: `0x${'ab'.repeat(20)}`, request: async () => {
    requests++; return new Response(JSON.stringify({ error: 'attribution_already_fixed' }), { status: 409 });
  } }), error => error.status === 409 && error.code === 'attribution_already_fixed');
  assert.equal(requests, 1);
});
