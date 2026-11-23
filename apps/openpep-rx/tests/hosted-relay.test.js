import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {createRelay} from '../hosted/relay.mjs';
import {LocalDatabase,ownerOf} from '../local/database.mjs';
import {createLocalSNCR} from '../local/sncr.mjs';
const origin='https://rx.example.br',profile={nome:'Profissional Fictício',cpf:'52998224725',crm:'12345',uf:'SP'};
function setup(t,options={}){
  const sql=new DatabaseSync(':memory:');sql.exec(readFileSync(new URL('../hosted/schema.sql',import.meta.url),'utf8'));t.after(()=>sql.close());
  let failSave=false,calls=[];
  const DB={prepare(query){return {bind(...params){const statement=sql.prepare(query);return {async first(){return statement.get(...params)||null;},async all(){return {results:statement.all(...params)};},async run(){if(failSave&&query.includes('completed_at'))throw Error('synthetic write failure');return {meta:statement.run(...params)};}};}};}};
  const handler=createRelay({fetcher:async(url,init)=>{calls.push({url:String(url),method:init.method||'GET',origin:init.headers.Origin});if(String(url).includes('/auth/token'))return new Response(JSON.stringify({access_token:'synthetic-sensitive-token',token_type:'Bearer'}),{headers:{'Content-Type':'application/json'}});return new Response(JSON.stringify({numeroReceita:['1234567890123456']}),{headers:{'Content-Type':'application/json'}});},...options});
  const request=(path,body,extra={})=>handler(new Request(origin+path,{method:body?'POST':'GET',headers:{'oai-authenticated-user-id':'synthetic-owner',...(body?{Origin:origin,'Content-Type':'application/json'}:{}),...extra},body:body?JSON.stringify(body):undefined}),{DB});
  const intent=()=>({id:randomUUID(),receipt:'b'.repeat(64),environment:'prd',confirm:true,confirmProduction:true,request:{tipo:'NRB',quantidade:10,conselho:'CRM',uf:'SP',documento:'12345'}});
  const begin=async(body=intent())=>{const response=await request('/api/relay/start',body);assert.equal(response.status,200,await response.clone().text());const json=await response.json(),url=new URL(json.url);return {body,id:json.id,state:url.searchParams.get('state'),cookie:response.headers.get('set-cookie').split(';')[0]};};
  return {sql,request,begin,intent,calls,set failSave(value){failSave=value;}};
}
test('relay requires ChatGPT identity, same-origin confirmation and a .br HTTPS origin',async t=>{
  const s=setup(t),body=s.intent();
  assert.equal((await s.request('/api/relay/start',body,{'oai-authenticated-user-id':''})).status,401);
  assert.equal((await s.request('/api/relay/start',body,{Origin:'https://attacker.example'})).status,403);
  assert.equal((await s.request('/api/relay/start',{...body,confirmProduction:false})).status,422);
  assert.deepEqual(s.calls,[]);
});
test('relay exchanges and sends once, persists result, isolates history, never persists token',async t=>{
  const s=setup(t),start=await s.begin();
  const path='/sncr/retorno?state='+start.state+'&session_id=synthetic-session';
  assert.equal((await s.request(path,null,{Cookie:'wrong'})).status,422);assert.equal(s.calls.length,0);
  const callback=await s.request(path,null,{Cookie:start.cookie});assert.equal(callback.status,303);
  assert.equal((await s.request(path,null,{Cookie:start.cookie})).status,422);assert.equal(s.calls.length,2);assert.ok(s.calls.every(c=>c.origin===origin));
  const result=await (await s.request('/api/relay/result?id='+start.id)).json();assert.equal(result.receipt.result.kind,'success');assert.deepEqual(result.receipt.result.body.numeroReceita,['1234567890123456']);
  assert.equal((await s.request('/api/relay/result?id='+start.id,null,{'oai-authenticated-user-id':'other-owner'})).status,404);
  assert.doesNotMatch(JSON.stringify(s.sql.prepare('SELECT * FROM rx_relay').all()),/synthetic-sensitive-token|synthetic-session/);
});
test('relay enforces quota atomically and retains one request on duplicate starts',async t=>{
  const s=setup(t),body={...s.intent(),request:{...s.intent().request,quantidade:50}};await s.begin(body);
  const duplicate=await s.request('/api/relay/start',body);assert.equal((await duplicate.json()).pending,true);
  assert.equal((await s.request('/api/relay/start',s.intent())).status,422);assert.equal(s.sql.prepare('SELECT COUNT(*) n FROM rx_relay').get().n,1);assert.equal(s.calls.length,0);
});
test('relay persistence failure returns a recovery receipt without resending the request',async t=>{
  const s=setup(t),start=await s.begin();s.failSave=true;
  const response=await s.request('/sncr/retorno?state='+start.state+'&session_id=synthetic-session',null,{Cookie:start.cookie});
  assert.equal(response.status,200);assert.match(response.headers.get('Content-Disposition'),/recuperacao.json/);assert.equal((await response.json()).result.kind,'success');assert.equal(s.calls.length,2);
});
test('web receipt imports into its original local intent once and rejects another origin or registration',async t=>{
  const db=new LocalDatabase(':memory:');t.after(()=>db.close());db.setSetting('profile',profile);db.setSetting('sncr',{enabled:true,environment:'prd',cnpj:''});
  const local=createLocalSNCR({db}),intent=local.start({tipo:'NRB',quantidade:10,confirm:true,confirmProduction:true},'http://127.0.0.1:4197',origin);
  const receipt={...intent,result:{kind:'success',http:200,body:{numeroReceita:['1234567890123456']},message:'Recebido'}};
  assert.throws(()=>local.importRelay(receipt,'https://attacker.example'));
  assert.throws(()=>local.importRelay({...receipt,request:{...receipt.request,documento:'99999'}},origin));
  assert.equal(local.importRelay(receipt,origin),'recebido');assert.equal(local.importRelay(receipt,origin),'recebido');assert.equal(db.stock(ownerOf(profile),'prd').NRB,1);
});
