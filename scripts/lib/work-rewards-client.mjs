// A provider-owned runner for funded protocol work. Listing prices and buyer
// payment authorizations never enter this queue. The key signs API requests only.
import crypto from 'node:crypto';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { serviceRequestMessage, validateServiceWorkerConfig } from './service-worker-client.mjs';
import { createServiceMonitorClient, readServiceMonitorSnapshot, validateMonitorInput } from './service-monitor.mjs';

const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const atomic = value => typeof value === 'string' && /^[1-9][0-9]{0,8}$/.test(value) && BigInt(value) <= 100_000_000n;
const fail = message => { throw Object.assign(Error(message), { fatal: true }); };
// Match the public server's 60-second lease and 90-second job policy. A small
// clock-skew allowance never extends those remote durations.
function assignmentTiming(job, now) {
  const created = Date.parse(job.createdAt), lease = Date.parse(job.leaseUntil), deadline = Date.parse(job.deadline);
  if (![created, lease, deadline].every(Number.isFinite) || created > now + 15_000
    || lease <= now || deadline <= now || lease < created || deadline < lease
    || lease - created > 60_000 || deadline - created > 90_000) fail('Assignment timing is outside the bounded lease policy.');
  return { created, expires: Math.min(lease, deadline) };
}
function cancellable(run, signal) {
  signal?.throwIfAborted();
  if (!signal) return run();
  return new Promise((resolve, reject) => {
    const abort = () => reject(signal.reason || new DOMException('Worker stopped', 'AbortError'));
    signal.addEventListener('abort', abort, { once: true });
    Promise.resolve().then(() => { signal.throwIfAborted(); return run(); }).then(
      value => { signal.removeEventListener('abort', abort); resolve(value); },
      error => { signal.removeEventListener('abort', abort); reject(error); });
  });
}

export function validateWorkRewardsConfig(input, previousState = {}) {
  const config = validateServiceWorkerConfig(input);
  if (config.service.capability !== 'protocol.monitor') fail('Automatic rewards currently accept protocol.monitor services only.');
  const serviceId = config.service.id || previousState.serviceId;
  const revision = config.service.expectedRevision || previousState.revision;
  if (!uuid(serviceId) || !Number.isSafeInteger(revision) || revision < 1) {
    fail('Use the downloaded configuration for your published monitor service, or retain its existing worker state.');
  }
  const rewardsStateFile = input.rewardsStateFile || `${config.stateFile}.rewards`;
  if (typeof rewardsStateFile !== 'string' || !rewardsStateFile || path.resolve(rewardsStateFile) === path.resolve(config.stateFile)) {
    fail('Rewards and marketplace workers must use different state files.');
  }
  const minimumRewardAtomic = input.minimumRewardAtomic ?? '100000';
  if (!atomic(minimumRewardAtomic)) fail('minimumRewardAtomic must be an exact positive USDG amount with 6 decimals.');
  return { ...config, rewardsStateFile, minimumRewardAtomic,
    service: { ...config.service, id: serviceId, expectedRevision: revision } };
}

export function createWorkRewardsApi(config, signer, { request = fetch, nowMs = Date.now, signal } = {}) {
  return async (action, payload) => {
    if (!['/enroll', '/me', '/lease', '/result'].includes(action)) fail('Unsupported automatic rewards action.');
    const route = `/api/work-rewards${action}`;
    const body = JSON.stringify(payload), timestamp = String(nowMs()), nonce = crypto.randomBytes(16).toString('hex');
    const signature = await signer.signMessage({ message: serviceRequestMessage(route, body, timestamp, nonce) });
    const timeout = AbortSignal.timeout(30_000);
    const response = await request(config.apiBase + route, { method: 'POST', redirect: 'error',
      signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
      headers: { 'content-type': 'application/json', 'x-wallet-address': config.wallet,
        'x-request-timestamp': timestamp, 'x-request-nonce': nonce, 'x-wallet-signature': signature }, body });
    const limit = 256 * 1024;
    if (Number(response.headers.get('content-length')) > limit) { await response.body?.cancel(); fail('Rewards response is too large.'); }
    if (!response.body) fail('Rewards response has no body.');
    const reader = response.body.getReader(), parts = []; let size = 0;
    try {
      for (;;) {
        const { value, done } = await reader.read(); if (done) break;
        size += value.length;
        if (size > limit) { await reader.cancel(); fail('Rewards response is too large.'); }
        parts.push(value);
      }
    } finally { reader.releaseLock(); }
    let result;
    try { result = JSON.parse(Buffer.concat(parts).toString()); } catch { fail('Invalid rewards response.'); }
    if (!response.ok) throw Object.assign(Error(`Rewards API ${action}: ${result.error || response.status}`), {
      status: response.status, code: result.error, fatal: response.status === 409 && result.error === 'result_immutable',
      retryAfter: Math.min(60, Math.max(5, Number(response.headers.get('retry-after')) || 5)),
    });
    return result;
  };
}

function validateService(config, service) {
  if (!service || service.id !== config.service.id || service.provider?.toLowerCase() !== config.wallet
    || service.revision !== config.service.expectedRevision || service.capability !== 'protocol.monitor' || service.active === false) {
    fail('Enrolled service differs from the local provider configuration.');
  }
  return service;
}

export async function readAssignedRewardSnapshot(config, job, { nowMs = Date.now,
  sleep = (milliseconds, { signal } = {}) => delay(milliseconds, undefined, { signal }),
  chain, read = readServiceMonitorSnapshot, signal } = {}) {
  signal?.throwIfAborted();
  const timing = assignmentTiming(job, nowMs()), minimumTimestamp = Math.floor(timing.created / 1000), expires = timing.expires;
  const deadlineSignal = AbortSignal.timeout(Math.max(1, Math.ceil(expires - nowMs())));
  const stopped = signal ? AbortSignal.any([signal, deadlineSignal]) : deadlineSignal;
  chain ||= createServiceMonitorClient(config.rpcUrl, { signal: stopped });
  // A just-assigned job can precede the latest block by a second. Wait for the
  // chain to reach its immutable assignment time before taking a full snapshot.
  while (nowMs() < expires) {
    const head = await cancellable(() => chain.getBlock({ blockTag: 'latest' }), stopped);
    if (typeof head.timestamp === 'bigint' && head.timestamp >= BigInt(minimumTimestamp)) {
      const report = await cancellable(() => read(chain, { nowMs, signal: stopped }), stopped);
      if (report.timestamp >= minimumTimestamp && nowMs() < expires) return report;
    }
    const remaining = expires - nowMs();
    if (remaining > 0) await cancellable(() => sleep(Math.min(1000, remaining), { signal: stopped }), stopped);
  }
  throw Error('The assignment expired before a sufficiently recent block was available.');
}

export function createWorkRewardsWorker({ config, api, journal, execute, nowMs = Date.now, funding = 'protocol-rewards', signal }) {
  if (!['protocol-rewards', 'protocol-contributions'].includes(funding)) fail('Unsupported funded work queue.');
  let running = false;
  const identity = { provider: config.wallet, serviceId: config.service.id, revision: config.service.expectedRevision };
  function verifyJournal() {
    if (journal.data.identity && Object.entries(identity).some(([key, value]) => journal.data.identity[key] !== value)) {
      fail('Saved rewards work belongs to a different provider, service or revision.');
    }
  }
  async function submitPending() {
    const saved = journal.data.pending;
    if (!saved) return null;
    verifyJournal();
    if (saved.provider !== config.wallet || saved.serviceId !== config.service.id || !uuid(saved.payload?.jobId)
      || !uuid(saved.payload?.leaseToken)) fail('Saved rewards result has an invalid identity.');
    let acknowledgment;
    try {
      acknowledgment = await api('/result', saved.payload);
      if (acknowledgment?.jobId !== saved.payload.jobId || !['complete', 'failed', 'paying', 'paid'].includes(acknowledgment.state)) {
        fail('Unrecognized rewards acknowledgment; keeping saved result for recovery.');
      }
    } catch (error) {
      if (!saved.payload.error && (error.status === 422 && ['monitor_report_mismatch', 'monitor_report_precedes_purchase'].includes(error.code)
        || error.status === 409 && error.code === 'report_already_submitted')) {
        // A conclusively rejected report earns nothing. Close that lease using
        // the same identity; do not invent a replacement report for this slot.
        saved.payload = { jobId: saved.payload.jobId, leaseToken: saved.payload.leaseToken, error: 'execution_failed' };
        await journal.save();
        return submitPending();
      }
      // An expired unaccepted lease cannot earn a reward. Other errors retain the
      // exact report so a lost acknowledgment cannot cause another execution.
      if (error.status !== 409 || error.code !== 'lease_expired') throw error;
      acknowledgment = { jobId: saved.payload.jobId, state: 'failed', paymentState: 'unpaid', error: 'lease_expired' };
    }
    journal.data.lastResult = { jobId: acknowledgment.jobId, state: acknowledgment.state,
      paymentState: acknowledgment.paymentState ?? null, rewardAtomic: saved.rewardAtomic, receivedAt: new Date(nowMs()).toISOString(),
      ...(Number.isSafeInteger(saved.epochId) ? { epochId: saved.epochId } : {}),
      ...(typeof acknowledgment.creditId === 'string' && acknowledgment.creditId.length <= 128 ? { creditId: acknowledgment.creditId } : {}),
      ...(acknowledgment.error ? { error: acknowledgment.error } : {}) };
    delete journal.data.pending;
    await journal.save();
    return { ...acknowledgment, rewardAtomic: saved.rewardAtomic };
  }
  return {
    async start() {
      verifyJournal();
      const result = await api('/enroll', { serviceId: config.service.id });
      validateService(config, result.service);
      journal.data.identity = identity;
      await journal.save();
      return result;
    },
    async cycle() {
      if (running) return { state: 'busy', pollAfter: 5 };
      running = true;
      try {
        signal?.throwIfAborted();
        verifyJournal();
        // Finish saved work before asking for another slot, including on restart.
        const recovered = await submitPending();
        if (recovered) return { ...recovered, recovered: true, pollAfter: 5 };
        let lease;
        try { lease = await api('/lease', {}); }
        catch (error) {
          if (error.status === 409 && error.code === 'recurring_rewards_policy_not_configured') {
            return { state: 'idle', reason: error.code, pollAfter: 60 };
          }
          throw error;
        }
        const pollAfter = Math.min(60, Math.max(5, Number(lease?.pollAfter) || config.pollSeconds));
        const job = lease?.job;
        if (!job) return { state: 'idle', pollAfter, reason: lease?.reason ?? null };
        if (!uuid(job.jobId) || !uuid(job.leaseToken) || job.serviceId !== config.service.id
          || job.provider?.toLowerCase() !== config.wallet || job.revision !== config.service.expectedRevision
          || job.capability !== 'protocol.monitor' || job.funding !== funding
          || funding === 'protocol-contributions' && (!Number.isSafeInteger(job.epochId) || job.epochId < 0)
          || !atomic(job.rewardAtomic) || BigInt(job.rewardAtomic) < BigInt(config.minimumRewardAtomic)
          || !Number.isFinite(Date.parse(job.leaseUntil)) || Date.parse(job.leaseUntil) <= nowMs()
          || !Number.isFinite(Date.parse(job.deadline)) || Date.parse(job.deadline) <= nowMs()
          || !Number.isFinite(Date.parse(job.createdAt)) || Date.parse(job.createdAt) > Date.parse(job.leaseUntil)
          || Date.parse(job.createdAt) > Date.parse(job.deadline)
          || !(typeof job.windowId === 'number' && Number.isSafeInteger(job.windowId) && job.windowId >= 0
            || typeof job.windowId === 'string' && /^(0|[1-9][0-9]{0,14})$/.test(job.windowId))) {
          fail('Rewards lease differs from the local provider terms.');
        }
        validateMonitorInput(job.input);
        assignmentTiming(job, nowMs());
        let payload;
        try {
          const result = execute ? await cancellable(() => execute(job.capability, job.input, { signal }), signal)
            : await readAssignedRewardSnapshot(config, job, { nowMs, signal });
          if (Buffer.byteLength(JSON.stringify(result)) > 32_768) fail('Monitoring result is too large.');
          payload = { jobId: job.jobId, leaseToken: job.leaseToken, result };
        } catch (error) {
          if (signal?.aborted) throw error;
          payload = { jobId: job.jobId, leaseToken: job.leaseToken, error: 'execution_failed' };
        }
        journal.data.pending = { provider: config.wallet, serviceId: config.service.id, rewardAtomic: job.rewardAtomic,
          ...(funding === 'protocol-contributions' ? { epochId: job.epochId } : {}), payload };
        await journal.save();
        const acknowledgment = await submitPending();
        return { ...acknowledgment, pollAfter };
      } finally { running = false; }
    },
  };
}
