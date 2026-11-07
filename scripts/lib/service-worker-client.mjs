// Provider-controlled runner. Only EIP-191 request signatures leave this process.
// No transaction signer, token approval, hosted private key or inbound endpoint.
import crypto from 'node:crypto';
import { executeServiceCapability } from './service-executor.mjs';
import { validateServiceMonitorRPC } from './service-monitor.mjs';

const address=v=>typeof v==='string'&&/^0x[0-9a-f]{40}$/i.test(v)&&!/^0x0{40}$/i.test(v);
const uuid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const capabilities=['hash.sha256','hash.keccak256','transform.json','fetch.url','scrape.text','protocol.monitor'];
export function validateServiceWorkerConfig(config){
  if(!config||typeof config!=='object')throw Error('Configure the provider worker.');
  const base=new URL(config.apiBase||'https://metrion.network');
  if(base.username||base.password||base.hash||base.search||base.pathname!=='/'||
    (base.protocol!=='https:'&&!(base.protocol==='http:'&&['127.0.0.1','localhost'].includes(base.hostname))))throw Error('apiBase must be an HTTPS origin.');
  if(!address(config.wallet))throw Error('Set your public provider wallet address.');
  if(typeof config.keyEnv!=='string'||!/^METRION_[A-Z0-9_]{3,64}$/.test(config.keyEnv))throw Error('keyEnv must name a dedicated METRION_ environment variable.');
  if(typeof config.stateFile!=='string'||!config.stateFile)throw Error('Set a local private stateFile.');
  const s=config.service;
  if(!s||typeof s.name!=='string'||s.name.trim().length<3||s.name.trim().length>80||!capabilities.includes(s.capability)
    ||typeof s.priceAtomic!=='string'||! /^[1-9][0-9]{0,8}$/.test(s.priceAtomic)||BigInt(s.priceAtomic)>100000000n
    ||(s.description!==undefined&&(typeof s.description!=='string'||s.description.length>500))
    ||(s.id!==undefined&&(!uuid(s.id)||!Number.isSafeInteger(s.expectedRevision)||s.expectedRevision<1)))throw Error('Configure service name, supported capability and exact USDG priceAtomic (6 decimals).');
  config.pollSeconds??=3;if(!Number.isInteger(config.pollSeconds)||config.pollSeconds<3||config.pollSeconds>15)throw Error('pollSeconds must be 3 to 15.');
  const rpcUrl=validateServiceMonitorRPC(config.rpcUrl);
  return {...config,rpcUrl,apiBase:base.origin,wallet:config.wallet.toLowerCase(),service:{name:s.name.trim(),description:s.description||'',capability:s.capability,priceAtomic:s.priceAtomic,
    ...(s.id?{id:s.id,expectedRevision:s.expectedRevision}:{})}};
}
export function serviceRequestMessage(path,body,timestamp,nonce){
  return ['metrion-gateway-auth-v1','POST',path,String(timestamp),nonce,crypto.createHash('sha256').update(body).digest('hex')].join('\n');
}
export function createServiceWorkerApi(config,signer,{request=fetch,nowMs=Date.now}={}){
  return async(action,payload)=>{
    if(!['/publish','/me','/worker/lease','/worker/result'].includes(action))throw Error('Unsupported worker action');
    const path='/api/services'+action,body=JSON.stringify(payload),timestamp=String(nowMs()),nonce=crypto.randomBytes(16).toString('hex');
    const signature=await signer.signMessage({message:serviceRequestMessage(path,body,timestamp,nonce)});
    const response=await request(config.apiBase+path,{method:'POST',redirect:'error',signal:AbortSignal.timeout(30000),
      headers:{'content-type':'application/json','x-wallet-address':config.wallet,'x-request-timestamp':timestamp,'x-request-nonce':nonce,'x-wallet-signature':signature},body});
    const limit=256*1024;if(Number(response.headers.get('content-length'))>limit)throw Error('API response is too large');
    if(!response.body)throw Error('API response has no body');const reader=response.body.getReader(),parts=[];let size=0;
    try{for(;;){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>limit){await reader.cancel();throw Error('API response is too large');}parts.push(value);}}
    finally{reader.releaseLock();}
    let result;try{result=JSON.parse(Buffer.concat(parts).toString());}catch{throw Error('Invalid API response');}
    if(!response.ok)throw Object.assign(Error(`Service API ${action}: ${result.error||response.status}`),{status:response.status,code:result.error});
    return result;
  };
}
function verifyListing(config,listing){
  if(!listing||!uuid(listing.id)||listing.provider.toLowerCase()!==config.wallet||!Number.isSafeInteger(listing.revision)||listing.revision<1
    ||listing.capability!==config.service.capability||listing.priceAtomic!==config.service.priceAtomic||listing.name!==config.service.name
    ||(config.service.id&&(listing.id!==config.service.id||listing.revision!==config.service.expectedRevision)))throw Error('Published listing differs from the local provider configuration');
  return listing;
}
export function createServiceWorker({config,api,journal,execute,nowMs=Date.now}){
  const executeJob=execute||((capability,input)=>executeServiceCapability(capability,input,{rpcUrl:config.rpcUrl}));
  let running=false;
  async function submitPending(){
    const saved=journal.data.pending;if(!saved)return;
    if(saved.provider!==config.wallet||saved.serviceId!==journal.data.serviceId)throw Error('Saved work belongs to another provider or service');
    try{const result=await api('/worker/result',saved.payload);if(result.jobId!==saved.payload.jobId||!['complete','failed'].includes(result.state))throw Error('Unrecognized result acknowledgment');
      delete journal.data.pending;await journal.save();}
    catch(e){if(e.status===409&&e.code==='lease_expired'){delete journal.data.pending;await journal.save();return;}throw e;}
  }
  return {
    async start(){const listing=verifyListing(config,config.service.id
      ?(await api('/me',{})).services?.find(s=>s.id===config.service.id):(await api('/publish',config.service)).service);
      if(journal.data.serviceId&&journal.data.serviceId!==listing.id)throw Error('Provider service identity changed');
      journal.data.serviceId=listing.id;journal.data.revision=listing.revision;await journal.save();return listing;},
    async cycle(){if(running)return;running=true;try{
      await submitPending();
      const {job}=await api('/worker/lease',{serviceId:journal.data.serviceId});if(!job)return {state:'idle'};
      if(!uuid(job.jobId)||!uuid(job.leaseToken)||job.serviceId!==journal.data.serviceId||job.provider.toLowerCase()!==config.wallet
        ||job.capability!==config.service.capability||job.priceAtomic!==config.service.priceAtomic
        ||job.revision!==journal.data.revision||!Number.isFinite(Date.parse(job.leaseUntil))||Date.parse(job.leaseUntil)<=nowMs())throw Error('Work lease differs from local provider terms');
      let payload;try{const result=await executeJob(job.capability,job.input);if(Buffer.byteLength(JSON.stringify(result))>32768)throw Error('Result is too large');payload={jobId:job.jobId,leaseToken:job.leaseToken,result};}
      catch{payload={jobId:job.jobId,leaseToken:job.leaseToken,error:'execution_failed'};}
      journal.data.pending={provider:config.wallet,serviceId:job.serviceId,payload};await journal.save();
      await submitPending();return {state:payload.error?'failed':'submitted',jobId:job.jobId};
    }finally{running=false;}},
  };
}
