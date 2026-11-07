// Buyer attribution and provider contributions use locally signed requests.
// No attribution, registration or heartbeat authorizes a token transfer.
import crypto from 'node:crypto';
import path from 'node:path';
import { serviceRequestMessage } from './service-worker-client.mjs';
import { createWorkRewardsWorker, validateWorkRewardsConfig } from './work-rewards-client.mjs';

function checkedOrigin(raw = 'https://metrion.network') {
  const origin = new URL(raw);
  if (origin.username || origin.password || origin.hash || origin.search || origin.pathname !== '/'
    || !(origin.protocol === 'https:' || origin.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(origin.hostname))) {
    throw Error('Use an HTTPS origin without credentials, query or path.');
  }
  return origin.origin;
}

export function validateContributionConfig(input, previousState = {}) {
  const contributionStateFile = input.contributionStateFile || `${input.stateFile}.contributions`;
  const config = validateWorkRewardsConfig({ ...input, rewardsStateFile: contributionStateFile }, previousState);
  if (path.resolve(contributionStateFile) === path.resolve(input.rewardsStateFile || `${input.stateFile}.rewards`)) {
    throw Error('Contribution and legacy rewards workers must use different state files.');
  }
  return { ...config, contributionStateFile };
}

export function createContributionApi({ origin = 'https://metrion.network', signer, wallet = signer?.address,
  request = fetch, nowMs = Date.now, signal } = {}) {
  origin = checkedOrigin(origin);
  return async (action, payload = {}) => {
    if (!['/status', '/enroll', '/lease', '/result', '/me', '/attribute'].includes(action)) throw Error('Unsupported contribution action.');
    const publicRead = action === '/status', route = `/api/contributions${publicRead ? '' : action}`;
    const method = publicRead ? 'GET' : 'POST', headers = {};
    let body;
    if (!publicRead) {
      if (!signer || !/^0x[0-9a-f]{40}$/i.test(wallet || '') || signer.address?.toLowerCase() !== wallet.toLowerCase()) {
        throw Error('A matching local wallet signer is required.');
      }
      body = JSON.stringify(payload);
      const timestamp = String(nowMs()), nonce = crypto.randomBytes(16).toString('hex');
      Object.assign(headers, { 'content-type': 'application/json', 'x-wallet-address': wallet.toLowerCase(),
        'x-request-timestamp': timestamp, 'x-request-nonce': nonce,
        'x-wallet-signature': await signer.signMessage({ message: serviceRequestMessage(route, body, timestamp, nonce) }) });
    }
    const timeout = AbortSignal.timeout(30_000);
    const response = await request(origin + route, { method, headers, ...(body === undefined ? {} : { body }), redirect: 'error',
      signal: signal ? AbortSignal.any([signal, timeout]) : timeout });
    const limit = 256 * 1024;
    if (Number(response.headers.get('content-length')) > limit) { await response.body?.cancel(); throw Error('Contribution response is too large.'); }
    if (!response.body) throw Error('Contribution response has no body.');
    const reader = response.body.getReader(), parts = []; let size = 0;
    try {
      for (;;) {
        const { value, done } = await reader.read(); if (done) break;
        size += value.length;
        if (size > limit) { await reader.cancel(); throw Error('Contribution response is too large.'); }
        parts.push(value);
      }
    } finally { reader.releaseLock(); }
    let result; try { result = JSON.parse(Buffer.concat(parts).toString()); } catch { throw Error('Invalid contribution response.'); }
    if (!response.ok) throw Object.assign(Error(`Contribution API ${action}: ${result.error || response.status}`), {
      status: response.status, code: result.error, fatal: response.status === 409 && result.error === 'result_immutable',
      retryAfter: Math.min(60, Math.max(5, Number(response.headers.get('retry-after')) || 5)),
    });
    return result;
  };
}

export function createContributionWorker(options) {
  return createWorkRewardsWorker({ ...options, funding: 'protocol-contributions' });
}

export async function attributeContributionBuyer({ account, origin, referrer, request, nowMs }) {
  if (!account) throw Error('Attribution requires the buyer’s local wallet signer.');
  if (!/^0x[0-9a-f]{40}$/i.test(referrer || '') || /^0x0{40}$/i.test(referrer)
    || account.address.toLowerCase() === referrer.toLowerCase()) throw Error('Set a different, nonzero contributor wallet.');
  const api = createContributionApi({ origin, signer: account, request, nowMs });
  const result = await api('/attribute', { referrer: referrer.toLowerCase() });
  if (result?.attribution?.buyer?.toLowerCase() !== account.address.toLowerCase()
    || result?.attribution?.referrer?.toLowerCase() !== referrer.toLowerCase()) {
    throw Error('Attribution acknowledgment does not match the signed buyer and contributor.');
  }
  return result;
}
