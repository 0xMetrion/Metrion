#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { privateKeyToAccount } from 'viem/accounts';
import { validateContributionConfig, createContributionApi, createContributionWorker } from './lib/contribution-client.mjs';

const args = process.argv.slice(2), at = args.indexOf('--config');
const usage = 'Usage: node contribution-worker.mjs --status | --config ./service.json\nInspect funded tasks and contribution criteria, or run your published protocol.monitor service using your existing local signer. Only funded assignments execute.';
if (args.includes('--help')) console.log(usage);
else if (args.length === 1 && args[0] === '--status') {
  try { console.log(JSON.stringify(await createContributionApi({ origin: process.env.METRION_ORIGIN })('/status'), null, 2)); }
  catch (error) { console.error(error.message || 'Contribution status unavailable.'); process.exitCode = 1; }
}
else if (at < 0 || !args[at + 1] || args.length !== 2) { console.error(usage); process.exitCode = 1; }
else {
  const stop = new AbortController();
  const onStop = () => stop.abort();
  process.on('SIGTERM', onStop); process.on('SIGINT', onStop);
  let lockHandle, lockPath;
  async function privateState(file, optional = true) {
    try {
      const stat = await fs.lstat(file);
      if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) || stat.size > 131_072) {
        throw Error('Worker state must be a private regular file, at most 128 KiB.');
      }
      const data = JSON.parse(await fs.readFile(file, 'utf8'));
      if (!data || typeof data !== 'object' || Array.isArray(data)) throw Error('Invalid worker state.');
      return data;
    } catch (error) { if (optional && error.code === 'ENOENT') return {}; throw error; }
  }
  async function wait(seconds) {
    if (stop.signal.aborted) return;
    await new Promise(resolve => {
      const finish = () => { clearTimeout(timer); stop.signal.removeEventListener('abort', finish); resolve(); };
      const timer = setTimeout(finish, seconds * 1000);
      stop.signal.addEventListener('abort', finish, { once: true });
    });
  }
  try {
    const raw = JSON.parse(await fs.readFile(args[at + 1], 'utf8'));
    const previous = !raw.service?.id && typeof raw.stateFile === 'string' ? await privateState(raw.stateFile) : {};
    const config = validateContributionConfig(raw, previous);
    const key = process.env[config.keyEnv]; delete process.env[config.keyEnv];
    if (typeof key !== 'string' || !/^0x[0-9a-f]{64}$/i.test(key)) throw Error('Set the dedicated worker key in the configured local environment variable.');
    const signer = privateKeyToAccount(key);
    if (signer.address.toLowerCase() !== config.wallet) throw Error('Worker key does not match the configured public wallet.');
    const statePath = path.resolve(config.contributionStateFile);
    await fs.mkdir(path.dirname(statePath), { recursive: true, mode: 0o700 });
    lockPath = `${statePath}.lock`;
    try { lockHandle = await fs.open(lockPath, 'wx', 0o600); }
    catch (error) {
      if (error.code === 'EEXIST') throw Error('Contribution worker state is locked. Stop the other contribution process first. After a crash, confirm it has stopped before removing only the .lock file.');
      throw error;
    }
    await lockHandle.writeFile(JSON.stringify({ pid: process.pid, serviceId: config.service.id }));
    const journal = { data: await privateState(statePath), async save() {
      const temporary = `${statePath}.${crypto.randomUUID()}.tmp`;
      let handle;
      try {
        handle = await fs.open(temporary, 'wx', 0o600);
        await handle.writeFile(JSON.stringify(this.data)); await handle.sync(); await handle.close(); handle = null;
        await fs.rename(temporary, statePath);
        const directory = await fs.open(path.dirname(statePath), 'r');
        try { await directory.sync(); } finally { await directory.close(); }
      } finally { await handle?.close(); await fs.unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; }); }
    } };
    const api = createContributionApi({ origin: config.apiBase, wallet: config.wallet, signer, signal: stop.signal });
    const worker = createContributionWorker({ config, api, journal, signal: stop.signal });
    let failures = 0, started = false, lastWaitReason = null;
    while (!stop.signal.aborted) {
      try {
        if (!started) {
          const status = await api('/status');
          console.log(`Contribution catalogue: ${JSON.stringify(status)}`);
          await worker.start(); started = true;
          console.log(`Monitor service ${config.service.id} enrolled. Provider ${config.wallet}. Waiting for funded, assigned work.`);
        }
        const result = await worker.cycle(); failures = 0;
        if (result.state === 'idle' && lastWaitReason !== (result.reason || 'awaiting_assignment')) {
          console.log(`No assigned work: ${JSON.stringify(result.reason || 'awaiting_assignment')}. Checking again in ${result.pollAfter || 5}s.`);
        }
        lastWaitReason = result.state === 'idle' ? result.reason || 'awaiting_assignment' : null;
        if (result.state !== 'idle' && result.state !== 'busy') {
          console.log(`Contribution ${result.jobId}: ${result.state}; payment ${result.paymentState || 'not confirmed'}. Credits and accepted work are not confirmed payments. See Earn for the receipt.`);
        }
        await wait(result.pollAfter || 5);
      } catch (error) {
        if (stop.signal.aborted) break;
        if (error.fatal || [400, 401, 403, 404, 422].includes(error.status)
          || (!error.status && !['TypeError', 'TimeoutError', 'AbortError'].includes(error.name))) throw error;
        failures++;
        const delay = Math.min(60, Math.max(error.retryAfter || 5, 5 * 2 ** Math.min(failures - 1, 4)));
        console.error(`Contribution request failed (${error.status || 'network'}). Saved results are retained; retrying in ${delay}s.`);
        await wait(delay);
      }
    }
  } catch (error) {
    if (!stop.signal.aborted) { console.error(error.message || 'Contribution worker failed.'); process.exitCode = 1; }
  } finally {
    await lockHandle?.close();
    if (lockHandle) await fs.unlink(lockPath).catch(() => {});
    process.off('SIGTERM', onStop); process.off('SIGINT', onStop);
  }
}
