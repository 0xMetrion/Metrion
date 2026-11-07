// Downloadable agent buyer. Keys stay on this machine. The saved authorization
// and original request are reused after timeouts, never silently replaced.
import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { privateKeyToAccount } from 'viem/accounts';
import { x402Client } from '@x402/core/client';
import { ExactEvmScheme } from '@x402/evm/exact/client';
import { decodePaymentRequiredHeader, encodePaymentSignatureHeader } from '@x402/core/http';
import { attributeContributionBuyer } from './lib/contribution-client.mjs';

const TOKEN='0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168',NETWORK='eip155:4663';
const RESPONSE_LIMIT=512000,STATE_LIMIT=1024*1024;
const same=(a,b)=>String(a).toLowerCase()===String(b).toLowerCase();
const requireThat=(ok,message)=>{if(!ok)throw Error(message);};
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
export function checkedServiceOrigin(raw){
  const u=new URL(raw);requireThat(!u.username&&!u.password&&!u.search&&!u.hash&&u.pathname==='/', 'Use an origin without credentials, path or query.');
  requireThat(u.protocol==='https:'||(u.protocol==='http:'&&['localhost','127.0.0.1','[::1]'].includes(u.hostname)),'HTTPS is required outside local tests.');
  return u.origin;
}
export function checkServiceQuote(required,service,maxAtomic){
  const quote=required?.accepts?.find(a=>a.scheme==='exact'&&a.network===NETWORK&&same(a.asset,TOKEN));
  requireThat(required?.x402Version===2&&quote,'An exact USDG x402 v2 offer is required.');
  requireThat(/^[1-9][0-9]{0,8}$/.test(quote.amount||'')&&BigInt(quote.amount)<=BigInt(maxAtomic),'The price exceeds this agent’s per-call USDG limit.');
  requireThat(same(quote.payTo,service.provider)&&quote.amount===service.priceAtomic&&quote.maxTimeoutSeconds===120,
    'The quote changed the provider, price or authorization lifetime.');
  for(const [key,value]of Object.entries({serviceId:service.id,revision:service.revision,provider:service.provider,capability:service.capability}))requireThat(quote.extra?.[key]===value,'The service revision changed. Get a fresh offer.');
  requireThat(quote.extra.name==='Global Dollar'&&quote.extra.version==='1'&&quote.extra.assetTransferMethod==='eip3009','Unexpected USDG signing domain.');
  return { ...required, accepts:[quote] };
}

export function createServiceBuyer({account,origin='https://metrion.network',maxPaymentAtomic='10000',stateFile='./metrion-payment.json',mcp=false,fetchFn=fetch}={}){
  origin=checkedServiceOrigin(origin);
  requireThat(/^[1-9][0-9]{0,8}$/.test(maxPaymentAtomic),'Set a positive atomic USDG per-call limit. One USDG is1000000 units.');
  const file=path.resolve(stateFile),lock=file+'.lock';
  async function request(uri,options={}){
    const r=await fetchFn(origin+uri,{...options,redirect:'error',signal:AbortSignal.timeout(35000)});
    if(Number(r.headers.get('content-length'))>RESPONSE_LIMIT){await r.body?.cancel();throw Error('Service response is too large.');}
    requireThat(r.body,'Service response has no body.');
    const reader=r.body.getReader(),chunks=[];let size=0;
    try{for(;;){const {value,done}=await reader.read();if(done)break;size+=value.byteLength;
      if(size>RESPONSE_LIMIT){await reader.cancel();throw Error('Service response is too large.');}chunks.push(value);}}
    finally{reader.releaseLock();}
    const text=Buffer.concat(chunks,size).toString('utf8');
    return {httpStatus:r.status,body:JSON.parse(text),paymentRequired:r.headers.get('PAYMENT-REQUIRED'),paymentResponse:r.headers.get('PAYMENT-RESPONSE')};
  }
  async function rpc(name,args){
    const r=await request('/mcp',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}})});
    requireThat(r.httpStatus===200&&!r.body.error&&!r.body.result?.isError,'MCP service call failed. Keep the saved request for recovery.');
    return r.body.result.structuredContent;
  }
  async function catalog(){const r=mcp?await rpc('services_list',{}):await request('/api/services');requireThat(r.httpStatus===200&&Array.isArray(r.body?.services),'Service catalog unavailable.');return r.body;}
  async function invoke(saved){
    const args=JSON.parse(saved.body);
    return mcp?rpc(saved.header?'services_call':'services_quote',{serviceId:saved.service.id,...args,...(saved.header?{paymentSignature:saved.header}:{})}):request(`/api/services/${saved.service.id}/x402`,{method:'POST',headers:{'content-type':'application/json',...(saved.header?{'PAYMENT-SIGNATURE':saved.header}:{})},body:saved.body});
  }
  async function quote(serviceId,input){
    const service=(await catalog()).services.find(s=>s.id===serviceId);
    requireThat(service?.active&&service.online,'The provider must be online before starting a new order.');
    const body=JSON.stringify({revision:service.revision,capability:service.capability,input});
    const r=await invoke({service,body});requireThat(r.httpStatus===402&&r.paymentRequired,'The service did not return a payment quote.');
    const required=checkServiceQuote(decodePaymentRequiredHeader(r.paymentRequired),service,maxPaymentAtomic);
    return {service,body,required};
  }
  async function save(value){
    const body=JSON.stringify(value);requireThat(Buffer.byteLength(body)<=STATE_LIMIT,'Payment state is too large; preserve the original authorization.');
    const temp=file+'.'+crypto.randomUUID()+'.tmp';let h;
    try{h=await fs.open(temp,'wx',0o600);await h.writeFile(body);await h.sync();await h.close();h=null;
      await fs.rename(temp,file);const directory=await fs.open(path.dirname(file),'r');
      try{await directory.sync();}finally{await directory.close();}
    }finally{await h?.close();await fs.unlink(temp).catch(e=>{if(e.code!=='ENOENT')throw e;});}
  }
  async function read(){let h;try{
    const before=await fs.lstat(file);
    requireThat(before.isFile()&&!before.isSymbolicLink()&&!(before.mode&0o077)&&before.size<=STATE_LIMIT,'Payment state must be a private regular file, at most 1 MiB.');
    h=await fs.open(file,constants.O_RDONLY|(constants.O_NOFOLLOW||0));const opened=await h.stat();
    requireThat(opened.isFile()&&!(opened.mode&0o077)&&opened.size<=STATE_LIMIT&&opened.dev===before.dev&&opened.ino===before.ino,
      'Payment state changed while opening; preserve the original authorization.');
    const bytes=Buffer.allocUnsafe(STATE_LIMIT+1);let size=0;
    for(;;){const {bytesRead}=await h.read(bytes,size,bytes.length-size,null);if(!bytesRead)break;size+=bytesRead;
      requireThat(size<=STATE_LIMIT,'Payment state is too large; preserve the original authorization.');}
    const state=JSON.parse(bytes.subarray(0,size).toString('utf8'));
    requireThat(state&&typeof state==='object'&&!Array.isArray(state),'Invalid saved payment state.');return state;
  }catch(e){if(e.code==='ENOENT')return null;throw e;}finally{await h?.close();}}
  async function locked(fn){
    let h;try{h=await fs.open(lock,'wx',0o600);}catch{throw Error('Another buyer process holds this payment file. Inspect it before removing a stale lock.');}
    try{await h.writeFile(String(process.pid));return await fn();}finally{await h.close();await fs.unlink(lock).catch(()=>{});}
  }
  async function settle(saved,maxWaitMs){
    requireThat(saved.origin===origin&&same(saved.payer,account.address)&&typeof saved.header==='string'&&saved.header.length<=24000,'Saved payment belongs to another origin or wallet.');
    const deadline=Date.now()+Math.min(90000,Math.max(0,maxWaitMs));
    for(;;){
      const r=await invoke(saved),v=r.body;
      if(r.httpStatus===200&&v?.paid===true){
        requireThat(same(v.payment?.payTo,saved.service.provider)&&same(v.payment?.payer,saved.payer)&&v.payment?.amount===saved.service.priceAtomic&&same(v.payment?.asset,TOKEN)&&v.payment?.network===NETWORK&&/^0x[0-9a-f]{64}$/i.test(v.payment.transaction||''),'Payment receipt does not match this order. Keep the original authorization.');
        await save({...saved,state:'paid',transaction:v.payment.transaction,result:v.result});return v;
      }
      if(r.httpStatus===422&&v?.paid===false&&v.terminalUnpaid===true){await save({...saved,state:'unpaid',error:v.message||v.error||v.result?.error});return v;}
      if(r.httpStatus!==202||Date.now()>=deadline)return {status:'pending',paymentState:'unknown',message:'Original authorization retained. Run resume with the same wallet; do not create a replacement payment.',httpStatus:r.httpStatus};
      await wait(2500);
    }
  }
  async function run(serviceId,input,{maxWaitMs=90000}={}){requireThat(account,'A local buyer signer is required.');return locked(async()=>{
    const existing=await read();requireThat(!existing||['paid','unpaid'].includes(existing.state),'A previous payment is unresolved. Use resume before starting another.');
    const offer=await quote(serviceId,input);
    const sdk=new x402Client().setSpendControls({allowedAssets:[{network:NETWORK,asset:TOKEN,maxAmountPerPayment:maxPaymentAtomic}]}).register(NETWORK,new ExactEvmScheme(account));
    const payload=await sdk.createPaymentPayload(offer.required);
    const saved={version:1,state:'pending',origin,payer:account.address,service:offer.service,body:offer.body,header:encodePaymentSignatureHeader(payload),createdAt:new Date().toISOString()};
    await save(saved);return settle(saved,maxWaitMs);
  });}
  async function resume({maxWaitMs=90000}={}){requireThat(account,'The original local buyer signer is required.');return locked(async()=>{
    const saved=await read();requireThat(saved,'There is no saved payment.');
    if(saved.state==='unpaid')return {paid:false,terminalUnpaid:true,message:saved.error};
    // Recheck even a previously paid intent so a chain reorganization cannot
    // turn a local historical receipt into a new authorization or duplicate run.
    return settle(saved,maxWaitMs);
  });}
  return {catalog,quote,run,resume};
}
async function main(){
  const [command,id,raw]=process.argv.slice(2);
  if(!['list','quote','run','resume','attribute'].includes(command)){console.log('Usage: node service-client.mjs list | quote SERVICE_ID INPUT_JSON | run SERVICE_ID INPUT_JSON | resume | attribute CONTRIBUTOR_WALLET');return;}
  let key=process.env.METRION_BUYER_KEY;delete process.env.METRION_BUYER_KEY;
  const account=key?privateKeyToAccount(key):undefined;key=undefined;
  if(command==='attribute'){
    const result=await attributeContributionBuyer({account,origin:process.env.METRION_ORIGIN||'https://metrion.network',referrer:id});
    console.log(JSON.stringify(result,null,2));return;
  }
  const buyer=createServiceBuyer({account,origin:process.env.METRION_ORIGIN||'https://metrion.network',maxPaymentAtomic:process.env.METRION_MAX_PAYMENT_ATOMIC||'10000',stateFile:process.env.METRION_PAYMENT_FILE||'./metrion-payment.json',mcp:process.env.METRION_TRANSPORT==='mcp'});
  const result=command==='list'?await buyer.catalog():command==='resume'?await buyer.resume():command==='quote'?await buyer.quote(id,JSON.parse(raw)):await buyer.run(id,JSON.parse(raw));
  console.log(JSON.stringify(result,null,2));
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))main().catch(error=>{
  console.error(process.argv[2]==='attribute'?`Attribution could not be confirmed: ${error.message||'request failed'}. Retry with the same contributor wallet. No payment was authorized.`
    :'Request stopped. If a payment was saved, use resume with the same wallet and payment file. No replacement signature was created automatically.');process.exitCode=1;
});
