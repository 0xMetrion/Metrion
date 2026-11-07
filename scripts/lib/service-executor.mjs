// Standalone provider-side HTTP execution. No database, app configuration or signer.
import crypto from 'node:crypto';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import { lookup as dnsLookup } from 'node:dns/promises';
import { createGunzip, createInflate, createBrotliDecompress } from 'node:zlib';
import { keccak256, toHex } from 'viem';
import { validateMonitorInput, readServiceMonitorSnapshot, createServiceMonitorClient } from './service-monitor.mjs';
const PRIVATE_V4 = new net.BlockList();
for (const [address, prefix] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8],
  ['169.254.0.0', 16], ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.0.2.0', 24],
  ['192.88.99.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15], ['198.51.100.0', 24], ['203.0.113.0', 24],
  ['168.63.129.16', 32],
  ['224.0.0.0', 4], ['240.0.0.0', 4],
]) PRIVATE_V4.addSubnet(address, prefix, 'ipv4');
const PUBLIC_V6 = new net.BlockList();
PUBLIC_V6.addSubnet('2000::', 3, 'ipv6');
const RESERVED_V6 = new net.BlockList();
for (const [address, prefix] of [['2001::', 23], ['2001:db8::', 32], ['2002::', 16], ['3fff::', 20]]) {
  RESERVED_V6.addSubnet(address, prefix, 'ipv6');
}
export function isPublicComputeAddress(address) {
  const family = net.isIP(address);
  return family === 4 ? !PRIVATE_V4.check(address, 'ipv4')
    : family === 6 && PUBLIC_V6.check(address, 'ipv6') && !RESERVED_V6.check(address, 'ipv6');
}

function safeUrl(raw) {
  let u;
  try { u = new URL(raw); } catch { return { ok: false, msg: 'invalid URL' }; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return { ok: false, msg: 'only http(s) URLs' };
  if (u.username || u.password) return { ok: false, msg: 'URL credentials are not allowed' };
  const host = u.hostname.toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '');
  // block localhost, link-local, cloud metadata, and internal TLDs
  if (
    host === 'localhost' || host.endsWith('.localhost') ||
    host.endsWith('.internal') || host.endsWith('.local') ||
    host === '169.254.169.254' || host === 'metadata.google.internal'
  ) return { ok: false, msg: 'host not allowed' };
  if (net.isIP(host) && !isPublicComputeAddress(host)) return { ok: false, msg: 'private or reserved address blocked' };
  return { ok: true, url: u.toString() };
}

function beforeDeadline(promise, signal) {
  return new Promise((resolve, reject) => {
    const abort = () => reject(new Error('fetch timed out'));
    if (signal.aborted) return abort();
    signal.addEventListener('abort', abort, { once: true });
    promise.then(resolve, reject).finally(() => signal.removeEventListener('abort', abort));
  });
}

// The optional resolver/transport are test seams only; HTTP callers cannot supply them.
export async function fetchCapped(url, maxBytes = 512 * 1024, timeoutMs = 8000, { lookup = dnsLookup, request } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const { signal } = controller;
  try {
    for (let redirects = 0; redirects <= 5; redirects++) {
      const checked = safeUrl(url);
      if (!checked.ok) throw new Error(checked.msg);
      const target = new URL(checked.url);
      const host = target.hostname.replace(/^\[|\]$/g, '').replace(/\.$/, '');
      const addresses = net.isIP(host) ? [{ address: host, family: net.isIP(host) }]
        : await beforeDeadline(lookup(host, { all: true, verbatim: true }), signal);
      if (!addresses.length || addresses.some(({ address }) => !isPublicComputeAddress(address))) {
        throw new Error('private or reserved address blocked');
      }
      const pinned = addresses.map(({ address }) => ({ address, family: net.isIP(address) }));
      const result = await beforeDeadline(new Promise((resolve, reject) => {
        const transport = request || (target.protocol === 'https:' ? https.request : http.request);
        const req = transport(target, {
          method: 'GET', agent: false, signal,
          // Keep the original hostname for Host, TLS SNI and certificate verification.
          lookup: (_hostname, options, callback) => {
            const candidates = options?.family ? pinned.filter((a) => a.family === options.family) : pinned;
            if (!candidates.length) return callback(new Error('no permitted address for this family'));
            if (options?.all) return callback(null, candidates);
            callback(null, candidates[0].address, candidates[0].family);
          },
          headers: { 'user-agent': 'MetrionServiceWorker/1.0 (+https://metrion.network)', 'accept-encoding': 'identity' },
        }, (res) => {
          const status = res.statusCode || 502;
          if ([301, 302, 303, 307, 308].includes(status) && res.headers.location) {
            res.destroy();
            try { return resolve({ redirect: new URL(res.headers.location, target).toString() }); }
            catch { return reject(new Error('invalid redirect URL')); }
          }
          const encoding = (res.headers['content-encoding'] || '').trim().toLowerCase();
          const decoder = encoding === 'gzip' ? createGunzip() : encoding === 'deflate' ? createInflate()
            : encoding === 'br' ? createBrotliDecompress() : null;
          if (encoding && encoding !== 'identity' && !decoder) {
            res.destroy(); return reject(new Error('unsupported response encoding'));
          }
          const stream = decoder ? res.pipe(decoder) : res;
          const chunks = []; let size = 0, finished = false;
          const finish = (truncated = false) => {
            if (finished) return;
            finished = true;
            resolve({ status, finalUrl: target.toString(), contentType: res.headers['content-type'] || '', bytes: size,
              body: Buffer.concat(chunks), truncated });
          };
          const fail = (error) => {
            stream.destroy(); res.destroy(); req.destroy();
            reject(error);
          };
          res.on('error', fail);
          if (stream !== res) stream.on('error', fail);
          stream.on('data', (chunk) => {
            const kept = chunk.subarray(0, maxBytes - size);
            chunks.push(kept); size += kept.length;
            if (chunk.length > kept.length) { finish(true); stream.destroy(); res.destroy(); }
          });
          stream.on('end', () => finish());
        });
        req.on('error', reject);
        req.end();
      }), signal);
      if (!result.redirect) return result;
      if (redirects === 5) throw new Error('too many redirects');
      url = result.redirect;
    }
  } finally { controller.abort(); clearTimeout(timer); }
}

const htmlSpace = (c) => c === ' ' || c === '\t' || c === '\r' || c === '\n' || c === '\f';
function tagEnd(html, from) {
  let quote = '';
  for (let i = from; i < html.length; i++) {
    const c = html[i];
    if (quote) { if (c === quote) quote = ''; }
    else if (c === '"' || c === "'") quote = c;
    else if (c === '>') return i;
  }
  return -1;
}
function attributes(raw, from) {
  const attrs = {};
  for (let i = from; i < raw.length;) {
    while (i < raw.length && (htmlSpace(raw[i]) || raw[i] === '/')) i++;
    const start = i;
    while (i < raw.length && !htmlSpace(raw[i]) && raw[i] !== '=' && raw[i] !== '/') i++;
    const name = raw.slice(start, i).toLowerCase();
    while (htmlSpace(raw[i])) i++;
    if (raw[i] !== '=') continue;
    i++; while (htmlSpace(raw[i])) i++;
    let value = '';
    if (raw[i] === '"' || raw[i] === "'") {
      const quote = raw[i++], end = raw.indexOf(quote, i);
      if (end < 0) break;
      value = raw.slice(i, end); i = end + 1;
    } else {
      const begin = i;
      while (i < raw.length && !htmlSpace(raw[i])) i++;
      value = raw.slice(begin, i);
    }
    if (name === 'name' || name === 'content') attrs[name] = value;
  }
  return attrs;
}
// A linear scan, rather than backtracking HTML regexes on attacker-controlled
// responses. Each tag/body span is consumed once, including malformed markup.
export function parseComputeHtml(html) {
  // ASCII tags only. Unicode case folding can change string length and corrupt offsets.
  const lower = html.replace(/[A-Z]/g, (c) => c.toLowerCase()), pieces = [];
  let at = 0, title = '', description = '', titleChecked = false;
  while (at < html.length) {
    const open = html.indexOf('<', at);
    if (open < 0) { pieces.push(html.slice(at)); break; }
    pieces.push(html.slice(at, open), ' ');
    const end = tagEnd(html, open + 1);
    if (end < 0) break;
    const raw = html.slice(open + 1, end);
    let i = 0;
    while (htmlSpace(raw[i])) i++;
    const closing = raw[i] === '/';
    if (closing) { i++; while (htmlSpace(raw[i])) i++; }
    const begin = i;
    while (i < raw.length && /[a-z0-9:-]/i.test(raw[i])) i++;
    const name = raw.slice(begin, i).toLowerCase();
    at = end + 1;
    if (!closing && (name === 'script' || name === 'style')) {
      const marker = `</${name}`;
      let close = lower.indexOf(marker, at);
      while (close >= 0 && lower[close + marker.length] !== '>' && !htmlSpace(lower[close + marker.length])) {
        close = lower.indexOf(marker, close + marker.length);
      }
      if (close < 0) break;
      const closeEnd = tagEnd(html, close + marker.length);
      if (closeEnd < 0) break;
      at = closeEnd + 1;
    } else if (!closing && name === 'title' && !titleChecked) {
      titleChecked = true;
      const close = lower.indexOf('</title>', at);
      if (close >= 0) title = html.slice(at, close).trim().slice(0, 200);
    } else if (!closing && name === 'meta' && !description) {
      const attrs = attributes(raw, i);
      if (attrs.name?.toLowerCase() === 'description') description = (attrs.content || '').trim().slice(0, 300);
    }
  }
  return { title, description, text: pieces.join('').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim() };
}


export async function executeServiceCapability(kind,input,{rpcUrl,monitorChain}={}){
  if(Buffer.byteLength(JSON.stringify(input))>32768)throw Error('Input exceeds 32 KiB');
  if(kind==='protocol.monitor'){validateMonitorInput(input);return readServiceMonitorSnapshot(monitorChain||createServiceMonitorClient(rpcUrl));}
  if(kind==='hash.sha256'||kind==='hash.keccak256'){
    if(typeof input!=='string')throw Error('Hash input must be a string');
    return {hash:kind==='hash.sha256'?'0x'+crypto.createHash('sha256').update(input).digest('hex'):keccak256(toHex(input))};
  }
  if(kind==='transform.json'){
    if(!input||typeof input.path!=='string'||input.path.length>512)throw Error('Invalid JSON path');
    const parts=input.path.split('.').filter(Boolean);
    if(parts.length>32||parts.some(k=>['__proto__','prototype','constructor'].includes(k)))throw Error('Unsafe JSON path');
    let value=typeof input.json==='string'?JSON.parse(input.json):input.json;
    for(const part of parts){if(value===null||typeof value!=='object'||!Object.hasOwn(value,part))return {value:null};value=value[part];}
    return {value:value??null};
  }
  if(kind!=='fetch.url'&&kind!=='scrape.text')throw Error('Unsupported capability');
  const result=await fetchCapped(typeof input==='string'?input:input?.url,524288,8000);
  const parsed=parseComputeHtml(result.body.toString('utf8'));
  if(kind==='fetch.url')return {status:result.status,finalUrl:result.finalUrl,contentType:result.contentType.slice(0,256),bytes:result.bytes,title:parsed.title,description:parsed.description};
  return {status:result.status,finalUrl:result.finalUrl,words:parsed.text?parsed.text.split(' ').length:0,chars:parsed.text.length,text:parsed.text.slice(0,4000)};
}
