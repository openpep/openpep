import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {createRelay,START_LIMIT,START_WINDOW} from '../hosted/relay.mjs';
const origin='https://rx.example.br',keyId='synthetic-key-2026';
const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
const privateJwk=await crypto.subtle.exportKey('jwk',keys.privateKey);
const destination={format:'openpep-rx.estoque',version:1,stock:'d'.repeat(64),crm:'12345',uf:'SP'};
function setup(t,options={}){
  const sql=new DatabaseSync(':memory:');sql.exec(readFileSync(new URL('../hosted/schema.sql',import.meta.url),'utf8'));t.after(()=>sql.close());
  let failSave=false,calls=[];
  const DB={prepare(query){return {bind(...params){const statement=sql.prepare(query);return {async first(){return statement.get(...params)||null;},async all(){return {results:statement.all(...params)};},async run(){if(failSave&&query.includes('completed_at'))throw Error('synthetic write failure');return {meta:statement.run(...params)};}};}};}};
  const handler=createRelay({fetcher:async(url,init)=>{calls.push({url:String(url),method:init.method||'GET',origin:init.headers.Origin});if(String(url).includes('/auth/token'))return new Response(JSON.stringify({access_token:'synthetic-sensitive-token',token_type:'Bearer'}),{headers:{'Content-Type':'application/json'}});return new Response(JSON.stringify({numeroReceita:['1234567890123456']}),{headers:{'Content-Type':'application/json'}});},...options});
  const request=(path,body,extra={})=>handler(new Request(origin+path,{method:body?'POST':'GET',headers:{'oai-authenticated-user-id':'synthetic-owner',...(body?{Origin:origin,'Content-Type':'application/json'}:{}),...extra},body:body?JSON.stringify(body):undefined}),{DB,SNCR_PORTAL_ORIGIN:origin,SNCR_EXPORT_KEY_ID:keyId,SNCR_EXPORT_PRIVATE_JWK:JSON.stringify(privateJwk)});
  const intent=()=>({id:randomUUID(),receipt:'b'.repeat(64),destination,environment:'prd',confirm:true,confirmProduction:true,request:{tipo:'NRB',quantidade:10,conselho:'CRM',uf:'SP',documento:'12345'}});
  const begin=async(body=intent())=>{const response=await request('/api/relay/portal/start',body);assert.equal(response.status,200,await response.clone().text());const json=await response.json(),url=new URL(json.url);return {body,id:json.id,state:url.searchParams.get('state'),cookie:response.headers.get('set-cookie').split(';')[0]};};
  return {sql,request,begin,intent,calls,set failSave(value){failSave=value;}};
}
test('relay requires ChatGPT identity, same-origin confirmation and a .br HTTPS origin',async t=>{
  const s=setup(t),body=s.intent();
  assert.equal((await s.request('/api/relay/portal/start',body,{'oai-authenticated-user-id':''})).status,401);
  assert.equal((await s.request('/api/relay/portal/start',body,{Origin:'https://attacker.example'})).status,403);
  assert.equal((await s.request('/api/relay/portal/start',{...body,confirmProduction:false})).status,422);
  assert.deepEqual(s.calls,[]);
});
test('relay exchanges and sends once, persists result, isolates history, never persists token',async t=>{
  const s=setup(t),start=await s.begin();
  const path='/sncr/retorno?state='+start.state+'&session_id=synthetic-session';
  assert.equal((await s.request(path,null,{Cookie:'wrong'})).status,422);assert.equal(s.calls.length,0);
  const callback=await s.request(path,null,{Cookie:start.cookie});assert.equal(callback.status,303);
  assert.equal((await s.request(path,null,{Cookie:start.cookie})).status,422);assert.equal(s.calls.length,2);assert.ok(s.calls.every(c=>c.origin===origin));
  const [row]=(await (await s.request('/api/relay/portal/history')).json()).requests;assert.equal(row.id,start.id);assert.equal(row.resultKind,'success');assert.equal(row.count,1);
  assert.deepEqual((await (await s.request('/api/relay/portal/history',null,{'oai-authenticated-user-id':'other-owner'})).json()).requests,[]);
  assert.doesNotMatch(JSON.stringify(s.sql.prepare('SELECT * FROM rx_relay').all()),/synthetic-sensitive-token|synthetic-session/);
});
test('relay enforces quota atomically and retains one request on duplicate starts',async t=>{
  const s=setup(t),body={...s.intent(),request:{...s.intent().request,quantidade:50}};await s.begin(body);
  const duplicate=await s.request('/api/relay/portal/start',body);assert.equal((await duplicate.json()).pending,true);
  assert.equal((await s.request('/api/relay/portal/start',s.intent())).status,422);assert.equal(s.sql.prepare('SELECT COUNT(*) n FROM rx_relay').get().n,1);assert.equal(s.calls.length,0);
});
test('relay limits SNCR logins per account and window without blocking other accounts',async t=>{
  let time=Date.UTC(2026,0,5,12);const s=setup(t,{now:()=>time});
  // Distinct synthetic registrations keep the per-prescriber quota out of the way.
  const intent=n=>({...s.intent(),destination:{...destination,crm:String(10000+n)},request:{...s.intent().request,documento:String(10000+n)}});
  for(let n=0;n<START_LIMIT;n++)await s.begin(intent(n));
  const limited=await s.request('/api/relay/portal/start',intent(START_LIMIT));
  assert.equal(limited.status,429);assert.equal(limited.headers.get('Retry-After'),'3600');assert.match((await limited.json()).error,/última hora/);
  assert.equal((await s.request('/api/relay/portal/start',intent(START_LIMIT),{'oai-authenticated-user-id':'other-owner'})).status,200);
  time+=START_WINDOW;assert.equal((await s.request('/api/relay/portal/start',intent(START_LIMIT+1))).status,200);
  assert.equal(s.sql.prepare("SELECT COUNT(*) n FROM rx_relay WHERE user_id='synthetic-owner'").get().n,START_LIMIT+1);assert.equal(s.calls.length,0);
});
test('relay persistence failure returns a recovery receipt without resending the request',async t=>{
  const s=setup(t),start=await s.begin();s.failSave=true;
  const response=await s.request('/sncr/retorno?state='+start.state+'&session_id=synthetic-session',null,{Cookie:start.cookie});
  assert.equal(response.status,200);assert.match(response.headers.get('Content-Disposition'),/registro-sncr.json/);assert.equal((await response.json()).result.kind,'success');assert.equal(s.calls.length,2);
});
test('relay accepts only the signed-lot flow and returns to the local page on request',async t=>{
  const s=setup(t),body=s.intent();
  const legacy=await s.request('/api/relay/start',body);assert.equal(legacy.status,404);
  assert.equal((await s.request('/api/relay/result?id='+randomUUID())).status,404);
  assert.equal((await s.request('/api/relay/portal/start',{...body,back:'elsewhere'})).status,422);
  const start=await s.begin({...s.intent(),back:'local'});
  const callback=await s.request('/sncr/retorno?state='+start.state+'&session_id=synthetic-session',null,{Cookie:start.cookie});
  assert.equal(callback.status,303);assert.equal(callback.headers.get('Location'),'/dados-locais.html?relay='+start.id);
});
