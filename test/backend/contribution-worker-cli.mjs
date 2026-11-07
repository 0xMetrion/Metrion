import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { privateKeyToAccount } from 'viem/accounts';
import { recoverMessageAddress } from 'viem';
import { serviceRequestMessage } from '../../scripts/lib/service-worker-client.mjs';

test('bundled contribution tools discover funding, wait without compute and sign buyer attribution locally', async () => {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'metrion-contribution-cli-'));
  const key = `0x${'45'.repeat(32)}`, signer = privateKeyToAccount(key), referrer = `0x${'ab'.repeat(20)}`;
  const serviceId = '43fea98b-efc2-40e6-9690-2bd360f52c8c', requests = [];
  let running;
  let notifyLease; const leased = new Promise(resolve => { notifyLease = resolve; });
  const status = { phase: 'awaiting_funding', tasks: [{ kind: 'protocol.monitor', funded: false }],
    budget: { availableAtomic: '0' }, tiers: [{ name: 'Base', weight: 1 }] };
  const server = http.createServer(async (request, response) => {
    try {
      let body = ''; for await (const chunk of request) body += chunk;
      requests.push(request.url); response.setHeader('content-type', 'application/json');
      if (request.method === 'GET') {
        assert.equal(request.url, '/api/contributions'); assert.equal(request.headers['x-wallet-signature'], undefined);
        response.end(JSON.stringify(status)); return;
      }
      const headers = request.headers;
      assert.equal(await recoverMessageAddress({ message: serviceRequestMessage(request.url, body,
        headers['x-request-timestamp'], headers['x-request-nonce']), signature: headers['x-wallet-signature'] }), signer.address);
      if (request.url === '/api/contributions/enroll') {
        assert.deepEqual(JSON.parse(body), { serviceId });
        response.end(JSON.stringify({ participant: {}, service: { id: serviceId, provider: signer.address,
          revision: 1, capability: 'protocol.monitor', active: true } }));
      } else if (request.url === '/api/contributions/attribute') {
        assert.deepEqual(JSON.parse(body), { referrer });
        response.end(JSON.stringify({ attribution: { buyer: signer.address, referrer, lockedAt: new Date().toISOString(), firstPurchaseAt: null, expiresAt: null } }));
      } else {
        assert.equal(request.url, '/api/contributions/lease'); assert.deepEqual(JSON.parse(body), {});
        response.end(JSON.stringify({ job: null, reason: 'no_funded_tasks', pollAfter: 60 })); notifyLease();
      }
    } catch (error) { response.statusCode = 500; response.end(JSON.stringify({ error: error.message })); }
  });
  function child(script, args, extraEnv = {}) {
    const process = spawn(globalThis.process.execPath, [`dist/agents/${script}.mjs`, ...args], {
      env: { ...globalThis.process.env, ...extraEnv }, stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = ''; process.stdout.on('data', value => { output += value; }); process.stderr.on('data', value => { output += value; });
    return { process, output: () => output, exit: once(process, 'exit') };
  }
  try {
    server.listen(0, '127.0.0.1'); await once(server, 'listening');
    const origin = `http://127.0.0.1:${server.address().port}`;
    const discovery = child('contribution-worker', ['--status'], { METRION_ORIGIN: origin });
    assert.equal((await discovery.exit)[0], 0); assert.deepEqual(JSON.parse(discovery.output()), status);
    const config = path.join(folder, 'service.json'), stateFile = path.join(folder, 'service-state.json');
    await fs.writeFile(config, JSON.stringify({ wallet: signer.address, apiBase: origin,
      keyEnv: 'METRION_SERVICE_WORKER_KEY', stateFile,
      service: { id: serviceId, expectedRevision: 1, name: 'Monitor', capability: 'protocol.monitor', priceAtomic: '10000' } }));
    running = child('contribution-worker', ['--config', config], { METRION_SERVICE_WORKER_KEY: key });
    await Promise.race([leased, new Promise((_, reject) => { const timer = setTimeout(() => reject(Error(`No lease: ${running.output()}`)), 5000); timer.unref(); })]);
    const attribution = child('service-client', ['attribute', referrer], { METRION_BUYER_KEY: key, METRION_ORIGIN: origin });
    assert.equal((await attribution.exit)[0], 0); assert.equal(JSON.parse(attribution.output()).attribution.referrer, referrer);
    running.process.kill('SIGTERM'); assert.equal((await running.exit)[0], 0);
    assert.match(running.output(), /no_funded_tasks/); assert.match(running.output(), /Checking again in 60s/);
    assert.ok(!running.output().includes(key));
    assert.ok(requests.every(url => url.startsWith('/api/contributions'))); assert.ok(!requests.includes('/api/contributions/result'));
    const saved = JSON.parse(await fs.readFile(`${stateFile}.contributions`, 'utf8'));
    assert.equal(saved.identity.serviceId, serviceId); assert.equal(saved.pending, undefined);
    await assert.rejects(fs.stat(`${stateFile}.contributions.lock`), error => error.code === 'ENOENT');
  } finally {
    if (running?.process.exitCode === null) running.process.kill('SIGKILL');
    await new Promise(resolve => server.close(resolve)); await fs.rm(folder, { recursive: true, force: true });
  }
});
