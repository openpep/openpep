// Web-standard (fetch + WebCrypto) so the Edge SSO callback and the Node functions share one store.
// Shared by Node and Edge, so redirect:'manual' (Edge rejects 'error'); a 3xx is never followed and fails as http.
// reason is a closed category (fetch error name, http, json, redis) for logs; never a response body.
export class ServiceError extends Error { constructor(stage,status=0,reason){super(stage);this.stage=stage;this.status=status;if(reason)this.reason=reason;} }
export async function sha256(value){return [...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)))].map(b=>b.toString(16).padStart(2,'0')).join('');}
function redis(env,fetcher){
 return async function command(args){
  const base=env.KV_REST_API_URL||env.UPSTASH_REDIS_REST_URL,token=env.KV_REST_API_TOKEN||env.UPSTASH_REDIS_REST_TOKEN;
  let u;try{u=new URL(base);}catch{throw new ServiceError('storage-config');}
  if(u.protocol!=='https:'||!u.hostname.endsWith('.upstash.io')||!token)throw new ServiceError('storage-config');
  let response,body;
  try{response=await fetcher(u.href,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify(args),redirect:'manual',signal:AbortSignal.timeout(10000)});}
  catch(e){throw new ServiceError('storage',0,/^[A-Za-z]{1,40}$/.test(e?.name)?e.name:'fetch');}
  if(!response.ok){await response.body?.cancel();throw new ServiceError('storage',response.status,'http');}
  try{body=await response.json();}catch{throw new ServiceError('storage',response.status,'json');}
  if(body.error)throw new ServiceError('storage',response.status,'redis');
  return body.result;
 };
}
export function makeStore(env=process.env,fetcher=fetch,{namespace='openpep:rx:local:v1',ttl=900}={}){
 const command=redis(env,fetcher);
 const key=async id=>`${namespace}:${await sha256(id)}`;
 return {
  async allow(bucket,limit){
   const lua="local n=redis.call('INCR',KEYS[1]); if n==1 then redis.call('EXPIRE',KEYS[1],900) end; return n";
   return (await command(['EVAL',lua,'1',`${namespace}:limit:${bucket}`]))<=limit;
  },
  async get(id){const raw=await command(['GET',await key(id)]);return raw?JSON.parse(raw):null;},
  async create(id,data){return (await command(['SET',await key(id),JSON.stringify(data),'EX',ttl,'NX']))==='OK';},
  async remove(id){await command(['DEL',await key(id)]);},
  // Keeps the remaining TTL, unless ttl (seconds) is given: the confirmed entry extends to the VIDaaS session.
  async swap(id,revision,next,ttl){
   const lua="local v=redis.call('GET',KEYS[1]); if not v then return 0 end; local o=cjson.decode(v); if o.revision~=tonumber(ARGV[1]) then return 0 end; local t=redis.call('TTL',KEYS[1]); if t<=0 then return 0 end; if ARGV[3] then t=tonumber(ARGV[3]) end; redis.call('SET',KEYS[1],ARGV[2],'EX',t); return 1";
   return (await command(['EVAL',lua,'1',await key(id),String(revision),JSON.stringify(next),...(ttl?[String(Math.ceil(ttl))]:[])]))===1;
  },
  async change(id,expected,next){
   const lua="local v=redis.call('GET',KEYS[1]); if not v then return 0 end; local o=cjson.decode(v); if o.status~=ARGV[1] then return 0 end; local t=redis.call('TTL',KEYS[1]); if t<=0 then return 0 end; redis.call('SET',KEYS[1],ARGV[2],'EX',t); return 1";
   return (await command(['EVAL',lua,'1',await key(id),expected,JSON.stringify(next)]))===1;
  }
 };
}
// Permanent SSO account <-> CPF/CRM/UF link, written only after the ICP-Brasil certificate proved the CPF.
// No TTL. One account per CPF and one CPF per account, enforced atomically in one script.
export function makeBindings(env=process.env,fetcher=fetch,namespace='crx:binding:v1'){
 const command=redis(env,fetcher);
 const account=(issuer,subject)=>sha256(issuer+'|'+subject);
 return {
  async get(issuer,subject){const raw=await command(['GET',`${namespace}:account:${await account(issuer,subject)}`]);return raw?JSON.parse(raw):null;},
  // 'created', 'cpf-taken' (CPF linked to another account) or 'account-bound' (this account already has a link).
  async create(issuer,subject,binding){
   const owner=await account(issuer,subject);
   const lua="if redis.call('EXISTS',KEYS[1])==1 then return -1 end; local o=redis.call('GET',KEYS[2]); if o and o~=ARGV[1] then return 0 end; redis.call('SET',KEYS[2],ARGV[1]); redis.call('SET',KEYS[1],ARGV[2]); return 1";
   const result=await command(['EVAL',lua,'2',`${namespace}:account:${owner}`,`${namespace}:cpf:${await sha256(binding.cpf)}`,owner,JSON.stringify(binding)]);
   return result===1?'created':result===0?'cpf-taken':'account-bound';
  }
 };
}
