#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { privateKeyToAccount } from 'viem/accounts';
import { validateServiceWorkerConfig, createServiceWorkerApi, createServiceWorker } from './lib/service-worker-client.mjs';

const args=process.argv.slice(2),at=args.indexOf('--config');
if(at<0||!args[at+1]){console.error('Usage: node service-worker.mjs --config ./service-worker.json');process.exitCode=1;}
else{
  let stopping=false;process.on('SIGTERM',()=>{stopping=true;});process.on('SIGINT',()=>{stopping=true;});
  try{
    const config=validateServiceWorkerConfig(JSON.parse(await fs.readFile(args[at+1],'utf8')));
    const key=process.env[config.keyEnv];delete process.env[config.keyEnv];
    if(typeof key!=='string'||!/^0x[0-9a-f]{64}$/i.test(key))throw Error('Set the dedicated worker key in the configured local environment variable.');
    const signer=privateKeyToAccount(key);if(signer.address.toLowerCase()!==config.wallet)throw Error('Worker key does not match the configured public wallet.');
    const statePath=path.resolve(config.stateFile);await fs.mkdir(path.dirname(statePath),{recursive:true,mode:0o700});
    let data={};try{const stat=await fs.lstat(statePath);if(!stat.isFile()||stat.isSymbolicLink()||(stat.mode&0o077)||stat.size>131072)throw Error('Worker state must be a private regular file, at most 128 KiB.');data=JSON.parse(await fs.readFile(statePath,'utf8'));}
    catch(e){if(e.code!=='ENOENT')throw e;}
    const journal={data,async save(){const tmp=statePath+'.'+crypto.randomUUID()+'.tmp';await fs.writeFile(tmp,JSON.stringify(this.data),{mode:0o600,flag:'wx'});await fs.rename(tmp,statePath);}};
    const worker=createServiceWorker({config,api:createServiceWorkerApi(config,signer),journal});
    const listing=await worker.start();console.log(`Service ${listing.id} published. Provider ${config.wallet}. ${listing.priceAtomic} atomic USDG per call.`);
    while(!stopping){try{const result=await worker.cycle();if(result?.state&&result.state!=='idle')console.log(`Work ${result.jobId}: ${result.state}. Payment is confirmed separately on-chain.`);}
      catch(e){console.error(`Worker request failed (${e.status||'network'}). Retrying saved work; no new payment is authorized.`);}
      if(!stopping)await new Promise(resolve=>setTimeout(resolve,config.pollSeconds*1000));}
  }catch(e){console.error(e.message||'Worker configuration failed');process.exitCode=1;}
}
