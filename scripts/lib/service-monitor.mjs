// Fixed Robinhood Chain protocol snapshots. No caller-selected address, calldata
// or endpoint enters this service. Shared by the standalone worker and verifier.
import { createPublicClient, http, keccak256, parseAbi } from 'viem';
export const SERVICE_MONITOR_RPC='https://rpc.mainnet.chain.robinhood.com';
// Deployed runtime fingerprints. Registry includes its canonical stake immutable.
// Read-only confirmation: RH block 107404268, 2026-11-06.
export const SERVICE_MONITOR_TARGETS=Object.freeze([
  Object.freeze({target:'registry',address:'0xb62b6b66a8f417a7e82e96570cc8ecfcbc141b23',functions:['totalOwed'],codeHash:'0x3ad0b248a966b9fb98e2dd7e59da415f9ec085133fc9ef8a884c784ef30d1060'}),
  Object.freeze({target:'stake',address:'0x981a6db50da1d8c20c8e66136df070149a10a5c3',functions:['totalStaked'],codeHash:'0x45fc7b760e419a4b55a1f31d5d79c005c69df912f88f266d0c59495af4065920'}),
  Object.freeze({target:'jobBoard',address:'0x80b69052f24b961c9d66453dda419e396ef0fba2',functions:['totalCredits','totalBonded'],codeHash:'0x694f2022b267f21ca36a5570d0a33f1edc1b1d7acd482254aa7a471eb1fea699'}),
]);
export const SERVICE_MONITOR_ABI=parseAbi(['function totalOwed() view returns (uint256)','function totalStaked() view returns (uint256)',
  'function totalCredits() view returns (uint256)','function totalBonded() view returns (uint256)']);
const hash=v=>typeof v==='string'&&/^0x[0-9a-f]{64}$/.test(v);
const decimal=v=>typeof v==='string'&&/^(0|[1-9][0-9]{0,77})$/.test(v)&&BigInt(v)<2n**256n;
const exact=(object,keys)=>object&&typeof object==='object'&&!Array.isArray(object)&&Object.keys(object).sort().join(',')===[...keys].sort().join(',');
const check=(ok,message)=>{if(!ok)throw Error(message);};
export function validateMonitorInput(input){check(exact(input,[]),'protocol.monitor accepts only {} and checks all three fixed targets');return input;}
export function validateMonitorResult(result){
  check(exact(result,['chainId','blockNumber','blockHash','timestamp','targets'])&&result.chainId===4663&&decimal(result.blockNumber)&&hash(result.blockHash)
    &&Number.isSafeInteger(result.timestamp)&&result.timestamp>0&&Array.isArray(result.targets)&&result.targets.length===3,'Invalid monitoring report');
  result.targets.forEach((row,i)=>{
    const target=SERVICE_MONITOR_TARGETS[i];
    check(exact(row,['target','address','codeHash','codeMatchesExpected','balanceWei','liabilityWei','readable','solvent'])
      &&row.target===target.target&&row.address===target.address&&hash(row.codeHash)&&decimal(row.balanceWei)
      &&typeof row.codeMatchesExpected==='boolean'&&row.codeMatchesExpected===(row.codeHash===target.codeHash)&&typeof row.readable==='boolean','Invalid monitoring target');
    check(row.readable?decimal(row.liabilityWei)&&typeof row.solvent==='boolean'&&row.solvent===(BigInt(row.balanceWei)>=BigInt(row.liabilityWei))
      :row.liabilityWei===null&&row.solvent===null,'Unreadable liabilities must stay unknown');
  });return result;
}
export function validateServiceMonitorRPC(raw=SERVICE_MONITOR_RPC){
  const u=new URL(raw);const host=u.hostname.replace(/^\[|\]$/g,'').toLowerCase();
  check(u.protocol==='https:'&&!u.username&&!u.password&&!u.search&&!u.hash&&raw.length<=2048&&host.includes('.')
    &&!/(^|\.)(localhost|local|internal)$/.test(host)&&!/^\d+\.\d+\.\d+\.\d+$/.test(host)&&!host.includes(':'),'Monitoring RPC must be a public HTTPS hostname without credentials or query');
  return u.toString();
}
export function createServiceMonitorClient(rpcUrl,{signal}={}){return createPublicClient({transport:http(validateServiceMonitorRPC(rpcUrl),{
  timeout:6000,retryCount:0,...(signal?{fetchFn:(url,options)=>fetch(url,{...options,
    signal:AbortSignal.any([signal,options.signal,AbortSignal.timeout(6000)].filter(Boolean))})}:{}),
}),batch:{multicall:false}});}
function deterministicUnavailable(error){
  for(let e=error,i=0;e&&i<8;e=e.cause,i++)if(['ContractFunctionRevertedError','ContractFunctionZeroDataError','AbiDecodingZeroDataError','AbiDecodingDataSizeTooSmallError'].includes(e.name))return true;
  return false;
}
export async function readServiceMonitorSnapshot(chain,{blockNumber,nowMs=Date.now}={}){
  check(await chain.getChainId()===4663,'Monitoring RPC chain mismatch');
  const head=await chain.getBlock({blockTag:'latest'});
  check(typeof head.number==='bigint'&&typeof head.timestamp==='bigint'&&Math.abs(Number(head.timestamp)-Math.floor(nowMs()/1000))<=120,'Monitoring head is stale');
  const block=blockNumber===undefined?head:await chain.getBlock({blockNumber});
  check(typeof block.number==='bigint'&&block.number<=head.number&&block.timestamp<=head.timestamp&&head.timestamp-block.timestamp<=120n
    &&Math.abs(Number(block.timestamp)-Math.floor(nowMs()/1000))<=120&&hash(block.hash?.toLowerCase()),'Monitoring block is stale or noncanonical');
  if(blockNumber!==undefined)check(block.number===blockNumber,'Monitoring RPC returned another block');
  const targets=await Promise.all(SERVICE_MONITOR_TARGETS.map(async target=>{
    const [code,balance,parts]=await Promise.all([
      chain.getCode({address:target.address,blockNumber:block.number}),chain.getBalance({address:target.address,blockNumber:block.number}),
      Promise.all(target.functions.map(async functionName=>{
        try{const value=await chain.readContract({address:target.address,abi:SERVICE_MONITOR_ABI,functionName,blockNumber:block.number});
          check(typeof value==='bigint'&&value>=0n&&value<2n**256n,'Invalid monitoring liability');return value;}
        catch(error){if(deterministicUnavailable(error))return null;throw error;}
      })),
    ]);
    check(typeof code==='string'&&/^0x(?:[0-9a-f]{2})*$/i.test(code)&&code.length<=49154&&typeof balance==='bigint'&&balance>=0n,'Monitoring data unavailable');
    const readable=parts.every(value=>value!==null),liability=readable?parts.reduce((a,b)=>a+b,0n):null;
    check(liability===null||liability<2n**256n,'Monitoring liabilities overflow');
    const codeHash=keccak256(code);
    return {target:target.target,address:target.address,codeHash,codeMatchesExpected:codeHash===target.codeHash,balanceWei:String(balance),
      liabilityWei:liability===null?null:String(liability),readable,solvent:liability===null?null:balance>=liability};
  }));
  const canonical=await chain.getBlock({blockNumber:block.number});
  check(canonical.hash?.toLowerCase()===block.hash.toLowerCase(),'Monitoring block reorganized during reads');
  check(Math.abs(Number(block.timestamp)-Math.floor(nowMs()/1000))<=120,'Monitoring block aged during reads');
  return validateMonitorResult({chainId:4663,blockNumber:String(block.number),blockHash:block.hash.toLowerCase(),timestamp:Number(block.timestamp),targets});
}
