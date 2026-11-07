// Bounded provider work and local shutdown. No server, network or real key used.
import test from 'node:test';
import assert from 'node:assert/strict';
import { validateContributionConfig,createContributionWorker } from '../../scripts/lib/contribution-client.mjs';
import { readAssignedRewardSnapshot } from '../../scripts/lib/work-rewards-client.mjs';
import { createServiceMonitorClient } from '../../scripts/lib/service-monitor.mjs';

const now=Date.parse('2026-11-07T12:00:00Z'),wallet='0x1111111111111111111111111111111111111111';
const serviceId='11111111-1111-4111-8111-111111111111',jobId='22222222-2222-4222-8222-222222222222';
const config=validateContributionConfig({wallet,keyEnv:'METRION_WORKER_KEY',stateFile:'/tmp/lease-test.json',
  service:{id:serviceId,expectedRevision:1,name:'Monitor',capability:'protocol.monitor',priceAtomic:'10000'}});
const service={id:serviceId,provider:wallet,revision:1,capability:'protocol.monitor',active:true};
const job=()=>({jobId,leaseToken:'33333333-3333-4333-8333-333333333333',serviceId,provider:wallet,revision:1,
  capability:'protocol.monitor',funding:'protocol-contributions',rewardAtomic:'100000',input:{},windowId:Math.floor(now/1800000),epochId:0,
  createdAt:new Date(now).toISOString(),leaseUntil:new Date(now+60000).toISOString(),deadline:new Date(now+90000).toISOString()});

test('future-dated or expanded remote leases never start monitoring',async()=>{
  for(const change of [
    value=>{for(const key of ['createdAt','leaseUntil','deadline'])value[key]=new Date(Date.parse(value[key])+365*86400000).toISOString();},
    value=>{value.leaseUntil=new Date(now+60001).toISOString();},
    value=>{value.deadline=new Date(now+90001).toISOString();},
    value=>{value.deadline=new Date(now+59999).toISOString();},
  ]){
    const assigned=job();change(assigned);let executions=0;
    const worker=createContributionWorker({config,nowMs:()=>now,journal:{data:{},save:async()=>{}},execute:async()=>{executions++;return {};},
      api:async action=>action==='/enroll'?{service}:{job:assigned}});
    await worker.start();await assert.rejects(worker.cycle(),/bounded lease policy/);assert.equal(executions,0);
  }
});

test('real60-second lease/90-second deadline tolerate small clock skew without extending the job duration',async()=>{
  const assigned=job();for(const key of ['createdAt','leaseUntil','deadline'])assigned[key]=new Date(Date.parse(assigned[key])+5000).toISOString();
  let clock=now,reads=0;
  const result=await readAssignedRewardSnapshot(config,assigned,{nowMs:()=>clock,sleep:async ms=>{clock+=ms;},
    chain:{getBlock:async()=>({timestamp:BigInt(Math.floor(clock/1000))})},read:async()=>{reads++;return {timestamp:Math.floor(clock/1000)};}});
  assert.equal(clock,now+5000);assert.equal(reads,1);assert.equal(result.timestamp,Math.floor(clock/1000));
});

test('a local assignment deadline also bounds an unresponsive RPC promise',async()=>{
  const at=Date.now(),assigned={...job(),createdAt:new Date(at).toISOString(),leaseUntil:new Date(at+40).toISOString(),deadline:new Date(at+90).toISOString()};
  const keepAlive=setTimeout(()=>{},1000);
  try{await assert.rejects(readAssignedRewardSnapshot(config,assigned,{chain:{getBlock:async()=>new Promise(()=>{})}}),error=>error.name==='TimeoutError');
    assert.ok(Date.now()-at<750);
  }finally{clearTimeout(keepAlive);}
});

test('shutdown interrupts a monitor wait immediately instead of persisting a false execution failure',async()=>{
  const stop=new AbortController();let begin;const started=new Promise(resolve=>{begin=resolve;});let submitted=0;
  const journal={data:{},save:async()=>{}};
  const worker=createContributionWorker({config,nowMs:()=>now,signal:stop.signal,journal,
    execute:async(_capability,_input,{signal})=>{assert.equal(signal,stop.signal);begin();return new Promise(()=>{});},
    api:async action=>{if(action==='/enroll')return {service};if(action==='/lease')return {job:job()};submitted++;return {jobId,state:'failed'};}});
  await worker.start();const working=worker.cycle();await started;stop.abort();
  await assert.rejects(working,error=>error.name==='AbortError');assert.equal(submitted,0);assert.equal(journal.data.pending,undefined);
});

test('monitor sleep and its HTTP transport receive the shutdown signal',async()=>{
  const stop=new AbortController();let asleep;const sleeping=new Promise(resolve=>{asleep=resolve;});
  const waiting=readAssignedRewardSnapshot(config,job(),{nowMs:()=>now,signal:stop.signal,
    chain:{getBlock:async()=>({timestamp:BigInt(Math.floor(now/1000)-1)})},
    sleep:async(_ms,{signal})=>{assert.equal(signal.aborted,false);asleep();return new Promise(()=>{});}});
  await sleeping;stop.abort();await assert.rejects(waiting,error=>error.name==='AbortError');
  const previous=globalThis.fetch,networkStop=new AbortController();let received,fetchStarted;
  const started=new Promise(resolve=>{fetchStarted=resolve;});
  globalThis.fetch=async(_url,options)=>{received=options.signal;fetchStarted();return new Promise((_resolve,reject)=>{
    options.signal.addEventListener('abort',()=>reject(options.signal.reason),{once:true});});};
  try{const request=createServiceMonitorClient('https://rpc.example.com',{signal:networkStop.signal}).getBlock({blockTag:'latest'});
    await started;networkStop.abort();await assert.rejects(request);assert.equal(received.aborted,true);
  }finally{globalThis.fetch=previous;}
});
