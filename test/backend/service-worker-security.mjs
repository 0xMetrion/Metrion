// Public provider revision binding. No network, database or wallet key required.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServiceWorker,validateServiceWorkerConfig } from '../../scripts/lib/service-worker-client.mjs';

const wallet='0x1111111111111111111111111111111111111111',id='11111111-1111-4111-8111-111111111111';
function fixture(revision,{publishedRevision=1,newService=false}={}){
  const config=validateServiceWorkerConfig({wallet,keyEnv:'METRION_WORKER_KEY',stateFile:'/tmp/provider-revision-state.json',
    service:{...(!newService?{id,expectedRevision:1}:{}),name:'SHA worker',capability:'hash.sha256',priceAtomic:'1000'}});
  const listing={id,provider:wallet,revision:publishedRevision,capability:'hash.sha256',priceAtomic:'1000',name:'SHA worker'};
  let executed=0,submitted=0;
  const job={jobId:'22222222-2222-4222-8222-222222222222',leaseToken:'33333333-3333-4333-8333-333333333333',
    serviceId:id,provider:wallet,revision,capability:'hash.sha256',priceAtomic:'1000',input:'work',leaseUntil:new Date(Date.now()+60000).toISOString()};
  const journal={data:{},save:async()=>{}};
  const worker=createServiceWorker({config,journal,execute:async()=>{executed++;return {hash:'result'};},api:async action=>{
    if(action==='/publish')return {service:listing};if(action==='/me')return {services:[listing]};if(action==='/worker/lease')return {job};
    submitted++;return {jobId:job.jobId,state:'complete'};
  }});
  return {worker,journal,counts:()=>({executed,submitted})};
}

test('changed, old, missing and nonnumeric lease revisions cannot execute under a pinned listing',async()=>{
  for(const revision of [999,0,-1,undefined,'1']){
    const f=fixture(revision);await f.worker.start();await assert.rejects(f.worker.cycle(),/local provider terms/);
    assert.deepEqual(f.counts(),{executed:0,submitted:0});assert.equal(f.journal.data.pending,undefined);
  }
});

test('a matching configured revision executes and submits once',async()=>{
  const f=fixture(1);await f.worker.start();assert.equal((await f.worker.cycle()).state,'submitted');
  assert.deepEqual(f.counts(),{executed:1,submitted:1});assert.equal(f.journal.data.revision,1);
});

test('new publication binds leases to its acknowledged revision and rejects invalid publication revisions',async()=>{
  const changed=fixture(3,{newService:true,publishedRevision:2});await changed.worker.start();
  await assert.rejects(changed.worker.cycle(),/local provider terms/);assert.deepEqual(changed.counts(),{executed:0,submitted:0});
  const matching=fixture(2,{newService:true,publishedRevision:2});await matching.worker.start();await matching.worker.cycle();
  assert.deepEqual(matching.counts(),{executed:1,submitted:1});
  for(const revision of [0,-1])await assert.rejects(fixture(revision,{newService:true,publishedRevision:revision}).worker.start(),/local provider configuration/);
});
