// Public buyer regressions: no backend, database, network or real wallet needed.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createServiceBuyer } from '../../scripts/service-client.mjs';

const account={address:'0x1111111111111111111111111111111111111111'},provider='0x2222222222222222222222222222222222222222';
const token='0x5fc5360d0400a0fd4f2af552add042d716f1d168',transaction='0x'+'33'.repeat(32);
const saved=()=>({version:1,state:'pending',origin:'https://metrion.network',payer:account.address,
  service:{id:'41111111-1111-4111-8111-111111111111',provider,priceAtomic:'1000'},
  body:JSON.stringify({revision:1,capability:'hash.sha256',input:'example'}),header:'unchanged-original-authorization'});
const paid=()=>({paid:true,payment:{payTo:provider,payer:account.address,amount:'1000',asset:token,network:'eip155:4663',transaction},result:{hash:'example'}});
async function temporary(fn){const directory=await fs.mkdtemp(path.join(os.tmpdir(),'service-client-security-'));
  try{return await fn(directory);}finally{await fs.rm(directory,{recursive:true,force:true});}}

test('a chunked oversized response is cancelled while streaming, before buffering the full body',async()=>{
  let produced=0,cancelled=false;
  const stream=new ReadableStream({pull(controller){produced++;controller.enqueue(new Uint8Array(64*1024));},cancel(){cancelled=true;}});
  const buyer=createServiceBuyer({fetchFn:async()=>new Response(stream,{headers:{'content-type':'application/json'}})});
  await assert.rejects(buyer.catalog(),/response is too large/);assert.equal(cancelled,true);assert.ok(produced<=9);
});

test('advertised oversized responses are cancelled without consuming their body',async()=>{
  let reads=0,cancelled=false;
  const stream=new ReadableStream({pull(controller){reads++;controller.enqueue(new Uint8Array(1));},cancel(){cancelled=true;}},{highWaterMark:0});
  const buyer=createServiceBuyer({fetchFn:async()=>new Response(stream,{headers:{'content-length':'900000000'}})});
  await assert.rejects(buyer.catalog(),/response is too large/);assert.equal(reads,0);assert.equal(cancelled,true);
});

test('saved authorization files reject symlinks, public permissions and oversized content before sending',async()=>{
  await temporary(async directory=>{
    let requests=0;const file=path.join(directory,'payment.json'),target=path.join(directory,'target.json');
    const buyer=createServiceBuyer({account,stateFile:file,fetchFn:async()=>{requests++;return new Response(JSON.stringify(paid()));}});
    await fs.writeFile(target,JSON.stringify(saved()),{mode:0o600});await fs.symlink(target,file);
    await assert.rejects(buyer.resume(),/private regular file/);assert.equal(requests,0);await fs.unlink(file);
    await fs.writeFile(file,JSON.stringify(saved()),{mode:0o644});await fs.chmod(file,0o644);
    await assert.rejects(buyer.resume(),/private regular file/);assert.equal(requests,0);
    await fs.chmod(file,0o600);await fs.writeFile(file,Buffer.alloc(1024*1024+1));
    await assert.rejects(buyer.resume(),/private regular file/);assert.equal(requests,0);
  });
});

test('atomic writes cannot follow a preplanted predictable temporary symlink and preserve the original authorization',async()=>{
  await temporary(async directory=>{
    const file=path.join(directory,'payment.json'),victim=path.join(directory,'unrelated-file');
    await fs.writeFile(file,JSON.stringify(saved()),{mode:0o600});await fs.writeFile(victim,'do not overwrite',{mode:0o600});await fs.symlink(victim,file+'.tmp');
    let requests=0;
    const buyer=createServiceBuyer({account,stateFile:file,fetchFn:async(_url,options)=>{
      requests++;assert.equal(options.headers['PAYMENT-SIGNATURE'],saved().header);assert.equal(options.body,saved().body);
      return new Response(JSON.stringify(paid()));}});
    assert.equal((await buyer.resume({maxWaitMs:0})).paid,true);assert.equal(requests,1);
    const state=JSON.parse(await fs.readFile(file,'utf8'));assert.equal(state.header,saved().header);assert.equal(state.state,'paid');
    assert.equal(await fs.readFile(victim,'utf8'),'do not overwrite');assert.equal((await fs.stat(file)).mode&0o077,0);
    assert.deepEqual((await fs.readdir(directory)).sort(),['payment.json','payment.json.tmp','unrelated-file']);
  });
});

test('lost acknowledgments and malformed responses retain the same private pending authorization',async()=>{
  await temporary(async directory=>{
    const file=path.join(directory,'payment.json'),initial=JSON.stringify(saved());await fs.writeFile(file,initial,{mode:0o600});
    const failing=createServiceBuyer({account,stateFile:file,fetchFn:async()=>{throw new TypeError('lost acknowledgment');}});
    await assert.rejects(failing.resume({maxWaitMs:0}),/lost acknowledgment/);assert.equal(await fs.readFile(file,'utf8'),initial);
    const invalid=createServiceBuyer({account,stateFile:file,fetchFn:async()=>new Response('invalid-json')});
    await assert.rejects(invalid.resume({maxWaitMs:0}),SyntaxError);assert.equal(await fs.readFile(file,'utf8'),initial);
    const recovery=createServiceBuyer({account,stateFile:file,fetchFn:async(_url,options)=>{
      assert.equal(options.headers['PAYMENT-SIGNATURE'],saved().header);return new Response(JSON.stringify(paid()));}});
    assert.equal((await recovery.resume({maxWaitMs:0})).paid,true);
    assert.equal(JSON.parse(await fs.readFile(file,'utf8')).header,saved().header);
  });
});

test('an unsuccessful atomic rename removes only the random temporary file and retains recovery data',async()=>{
  await temporary(async directory=>{
    const file=path.join(directory,'payment.json'),backup=path.join(directory,'original.json');
    await fs.writeFile(file,JSON.stringify(saved()),{mode:0o600});
    const buyer=createServiceBuyer({account,stateFile:file,fetchFn:async()=>{
      await fs.rename(file,backup);await fs.mkdir(file);return new Response(JSON.stringify(paid()));}});
    await assert.rejects(buyer.resume({maxWaitMs:0}));assert.equal(JSON.parse(await fs.readFile(backup,'utf8')).header,saved().header);
    assert.deepEqual((await fs.readdir(directory)).sort(),['original.json','payment.json']);
  });
});
