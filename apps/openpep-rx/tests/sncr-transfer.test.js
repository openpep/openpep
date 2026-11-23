import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {memoryD1} from './d1-fixture.mjs';
import {createRelay} from '../hosted/relay.mjs';
import {LocalDatabase,ownerOf} from '../local/database.mjs';
import {createLotImporter} from '../local/lots.mjs';
import {sealLot} from '../integracao/sncr-lote.mjs';
const origin='https://rx.provedor.br',profile={nome:'Profissional Fictício',cpf:'52998224725',crm:'12345',uf:'SP'},keyId='synthetic-key-2026';
const pair=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']);
const privateJwk=await crypto.subtle.exportKey('jwk',pair.privateKey),publicJwk=await crypto.subtle.exportKey('jwk',pair.publicKey);
const trustedKeys=[{issuer:origin,keyId,publicJwk}];
function local(t){const db=new LocalDatabase();t.after(()=>db.close());db.setSetting('profile',profile);const importer=createLotImporter({db,trustedKeys,portal:origin});return {db,importer,target:importer.target()};}
function setup(t){
  const {sql,DB}=memoryD1();t.after(()=>sql.close());let calls=0;
  const env={DB,SNCR_PORTAL_ORIGIN:origin,SNCR_EXPORT_KEY_ID:keyId,SNCR_EXPORT_PRIVATE_JWK:JSON.stringify(privateJwk)};
  const relay=createRelay({fetcher:async url=>{calls++;return new Response(JSON.stringify(String(url).includes('/auth/token')?{token_type:'Bearer',access_token:'synthetic-token-do-not-persist'}:{numeroReceita:['1234567890123456','1234567890123457']}),{headers:{'Content-Type':'application/json'}});}});
  const request=(path,body,headers={})=>relay(new Request(origin+path,{method:body?'POST':'GET',headers:{'oai-authenticated-user-id':'synthetic-user',...(body?{Origin:origin,'Content-Type':'application/json'}:{}),...headers},body:body?JSON.stringify(body):undefined}),env);
  const start=target=>({id:randomUUID(),receipt:'c'.repeat(64),destination:target,environment:'hmg',request:{tipo:'NRB',quantidade:10,conselho:'CRM',uf:'SP',documento:'12345'},confirm:true});
  async function finish(body){const response=await request('/api/relay/portal/start',body);assert.equal(response.status,200,await response.clone().text());const result=await response.json(),state=new URL(result.url).searchParams.get('state');const callback=await request('/sncr/retorno?session_id=synthetic-session&state='+state,null,{Cookie:response.headers.get('set-cookie').split(';')[0]});assert.equal(callback.status,303);assert.match(callback.headers.get('Location'),/^\/portal-sncr\.html/);return result.id;}
  return {sql,env,request,start,finish,get calls(){return calls;}};
}
async function seal(target,extra={}){return sealLot({version:1,id:randomUUID(),issuer:origin,destination:target,environment:'hmg',request:{tipo:'NRB',quantidade:10,conselho:'CRM',uf:target.uf,documento:target.crm},issuedAt:Date.now(),result:{kind:'success',http:200,body:{numeroReceita:['1234567890123456','1234567890123457']},message:'Fictício'},...extra},{keyId,privateJwk});}
test('portal obtains and exports without a local intent; redownload is identical and owner-bound',async t=>{
  const l=local(t),s=setup(t),body=s.start(l.target),id=await s.finish(body);
  const [a,b]=await Promise.all([s.request('/api/relay/portal/download',{id}),s.request('/api/relay/portal/download',{id})]);
  assert.equal(a.status,200);assert.equal(b.status,200);const bundle=await a.json();assert.deepEqual(bundle,await b.json());
  assert.equal((await s.request('/api/relay/portal/download',{id},{'oai-authenticated-user-id':'someone-else'})).status,404);
  assert.equal(s.calls,2);assert.equal(s.sql.prepare('SELECT COUNT(*) n FROM rx_export_numbers').get().n,2);
  assert.doesNotMatch(JSON.stringify(s.sql.prepare('SELECT * FROM rx_relay').all()),/synthetic-token|synthetic-session/);
  assert.equal((await l.importer.import({bundle,confirm:true})).alreadyImported,false);
  const docId=randomUUID();l.db.saveDraft({id:docId,owner:ownerOf(profile),type:'NRB',content:{},hash:'test',profile,environment:'hmg'});const reserved=l.db.reserve(docId,ownerOf(profile));
  assert.equal((await l.importer.import({bundle,confirm:true})).alreadyImported,true);
  assert.equal(l.db.get('SELECT status FROM rx_numbers WHERE number=?',reserved).status,'reservado');assert.equal(l.db.stock(ownerOf(profile),'hmg').NRB,1);
});
test('portal forbids reassigning a request to another stock, mismatched CRM, CSRF, and unconfirmed production',async t=>{
  const a=local(t),b=local(t),s=setup(t),body=s.start(a.target);
  assert.equal((await s.request('/api/relay/portal/start',{...body,environment:'prd'})).status,422);
  assert.equal((await s.request('/api/relay/portal/start',body,{Origin:'https://attacker.br'})).status,403);
  assert.equal((await s.request('/api/relay/portal/start',{...body,destination:{...a.target,crm:'999'}})).status,422);
  assert.equal((await s.request('/api/relay/portal/start',body)).status,200);
  assert.equal((await s.request('/api/relay/portal/start',{...body,destination:b.target})).status,422);assert.equal(s.calls,0);
});
test('local rejects other stock, other prescriber, unknown key and tampered payload before changing data',async t=>{
  const a=local(t),b=local(t),bundle=await seal(a.target);
  await assert.rejects(()=>b.importer.import({bundle,confirm:true}),/outro banco/);
  const forged={...bundle,payload:bundle.payload.slice(0,-5)+'AAAAA'};
  await assert.rejects(()=>a.importer.import({bundle:forged,confirm:true}),/Assinatura|inválido/);
  await assert.rejects(()=>a.importer.import({bundle:{...bundle,keyId:'unknown-key'},confirm:true}),/não reconhecida/);
  a.db.setSetting('profile',{...profile,crm:'999'});await assert.rejects(()=>a.importer.import({bundle,confirm:true}),/CRM/);
  assert.equal(a.db.get('SELECT COUNT(*) n FROM rx_requests').n,0);assert.equal(b.db.get('SELECT COUNT(*) n FROM rx_numbers').n,0);
});
test('overlapping lots are rejected atomically in portal and local database',async t=>{
  const l=local(t),s=setup(t),id=await s.finish(s.start(l.target));
  const first=await (await s.request('/api/relay/portal/download',{id})).json();await l.importer.import({bundle:first,confirm:true});
  const other=await s.finish(s.start(l.target));assert.equal((await s.request('/api/relay/portal/download',{id:other})).status,422);
  assert.equal(s.sql.prepare('SELECT COUNT(*) n FROM rx_exports').get().n,1);
  const overlap=await seal(l.target,{result:{kind:'success',http:200,body:{numeroReceita:['1234567890123458','1234567890123457']},message:'Fictício'}});
  await assert.rejects(()=>l.importer.import({bundle:overlap,confirm:true}),/já existentes/);
  assert.equal(l.db.get('SELECT COUNT(*) n FROM rx_requests').n,1);assert.equal(l.db.stock(ownerOf(profile),'hmg').NRB,2);
});
test('SQLite failure rolls back complete import; successful retry adds every number once',async t=>{
  const l=local(t),bundle=await seal(l.target);
  l.db.db.exec("CREATE TRIGGER synthetic_failure BEFORE INSERT ON rx_numbers WHEN NEW.canonical='1234567890123457' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END");
  await assert.rejects(()=>l.importer.import({bundle,confirm:true}));assert.equal(l.db.get('SELECT COUNT(*) n FROM rx_requests').n,0);assert.equal(l.db.get('SELECT COUNT(*) n FROM rx_numbers').n,0);
  l.db.db.exec('DROP TRIGGER synthetic_failure');await l.importer.import({bundle,confirm:true});assert.equal(l.db.stock(ownerOf(profile),'hmg').NRB,2);
});
test('production needs explicit confirmation and stays separate from homologation',async t=>{
  const l=local(t),hmg=await seal(l.target),prd=await seal(l.target,{environment:'prd'});
  await l.importer.import({bundle:hmg,confirm:true});await assert.rejects(()=>l.importer.import({bundle:prd,confirm:true}),/produção/);
  await l.importer.import({bundle:prd,confirm:true,confirmProduction:true});assert.equal(l.db.stock(ownerOf(profile),'prd').NRB,2);assert.equal(l.db.stock(ownerOf(profile),'hmg').NRB,2);
});

test('a full RCE range and its used numbers survive reopening the same local database',async t=>{
  const directory=mkdtempSync(join(tmpdir(),'rx-lot-restart-'));let db=new LocalDatabase(directory);
  t.after(()=>{db.close();rmSync(directory,{recursive:true,force:true});});
  db.setSetting('profile',profile);let importer=createLotImporter({db,trustedKeys,portal:origin});const target=importer.target();
  const bundle=await seal(target,{request:{tipo:'RCE',quantidade:1000,conselho:'CRM',uf:'SP',documento:'12345',cnpj:'12345678000195'},result:{kind:'success',http:200,body:{inicio:'9911635999999000',fim:'9911635999999999',quantidade:1000}}});
  await importer.import({bundle,confirm:true});
  db.run("UPDATE rx_numbers SET status='utilizado' WHERE canonical='9911635999999000'");db.close();db=new LocalDatabase(directory);
  importer=createLotImporter({db,trustedKeys,portal:origin});assert.deepEqual(importer.target(),target);
  assert.equal((await importer.import({bundle,confirm:true})).alreadyImported,true);
  assert.equal(db.stock(ownerOf(profile),'hmg').RCE,999);
  assert.equal(db.get("SELECT status FROM rx_numbers WHERE canonical='9911635999999000'").status,'utilizado');
  assert.equal(db.get('SELECT COUNT(*) n FROM rx_numbers').n,1000);
});
test('unusable export configuration prevents beginning a Gov.br transaction',async t=>{
  const l=local(t),s=setup(t);s.env.SNCR_EXPORT_PRIVATE_JWK='invalid-private-value';
  const response=await s.request('/api/relay/portal/start',s.start(l.target));
  assert.equal(response.status,422);assert.doesNotMatch(await response.text(),/invalid-private-value/);
  assert.equal(s.calls,0);assert.equal(s.sql.prepare('SELECT COUNT(*) n FROM rx_relay').get().n,0);
  s.env.SNCR_PORTAL_ORIGIN='http://invalid';assert.equal((await s.request('/api/relay/meta')).status,422);
});
