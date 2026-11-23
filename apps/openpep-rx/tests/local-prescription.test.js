import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, rm, readFile, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {LocalDatabase, ownerOf, sha, dataDirectory} from '../local/database.mjs';
import {createPrescriptions, profileInput} from '../local/prescriptions.mjs';
import {createLocalSNCR, sncrConfig} from '../local/sncr.mjs';
import {classifyMedication} from '../medicamentos.js';
import {catalog} from '../local/catalog.mjs';
import {shortId} from '../api/receita-doc.mjs';
import {lockRuntime} from '../local/runtime-lock.mjs';

const p = {nome:'Profissional Fictício', cpf:'52998224725', crm:'12345', uf:'SP'};
const owner = ownerOf(p), identity = 'a'.repeat(64), origin = 'http://127.0.0.1:4197';
const body = (over = {}) => ({id:randomUUID(), tipo:'NRB', practice:true,
  paciente:{nome:'Paciente Fictício', documento:'AB123456', endereco:'Rua Exemplo, 10', cidade:'São Paulo', uf:'SP'},
  emitente:{endereco:'Av. Exemplo, 100', cidade:'São Paulo', uf:'SP', telefone:''},
  medicamento:{nome:'Clonazepam', concentracao:'2 mg', forma:'comprimido', quantidade:30, unidade:'comprimidos', posologia:'Tomar 1 comprimido à noite.'}, ...over});
function setup(t, overrides = {}) {
  const db = new LocalDatabase(); t.after(() => db.close()); db.setSetting('profile',profileInput(p));
  let calls = 0, input;
  const api = createPrescriptions({db, signer:async(command, request) => {
    calls++; input = Buffer.from(request.pdf,'base64'); const out=Buffer.from(input); out[request.range[1]+1]=49;
    return {pdf:out.toString('base64')};
  }, ...overrides});
  return {db, api, get calls(){return calls;}, get input(){return input;}};
}
function numbers(db, environment='prd', type='NRB', first='1234567890123456') {
  const state = randomUUID(), request={tipo:type,quantidade:10};
  const id=db.beginNumbers({owner,environment,type,quantity:10,request,state});
  const row=db.claimNumbers(state,Date.now());
  const result=db.recordNumbers(row,{kind:'success',http:200,body:{numeroReceita:[first]}});
  assert.equal(result,'recebido'); return id;
}

test('catalog classifies actual presentations and brands across all seven prescription models', () => {
  for (const [query,expected] of [['clonazepam','NRB'],['lisdexanfetamina','NRA'],['sibutramina','NRB2'],['tramadol','RCE'],['amoxicilina','RET'],['isotretinoina','NRR'],['talidomida','NRT']]) {
    const sub=catalog.find(s=>(s.busca||[]).includes(query)); assert.ok(sub,query);
    const selected=sub.apresentacoes[0];
    assert.equal(classifyMedication(catalog,{nome:sub.nome,concentracao:selected.concentracao,forma:selected.forma}).type,expected,query);
  }
  assert.equal(classifyMedication(catalog,{nome:'Rivotril',concentracao:'2 mg',forma:'comprimido'}).type,'NRB');
  assert.equal(classifyMedication(catalog,{nome:'Medicamento desconhecido'}).type,null);
});

test('composed prescription uses original PDF layout and signs those exact reviewed bytes without upload', async t => {
  const s=setup(t), draft=await s.api.draft(body(),origin);
  assert.equal(draft.practice,true); assert.equal(draft.signable,true); assert.equal(draft.numero,null);
  const preview=s.api.pdf(draft.id); assert.equal(sha(preview),draft.hash); assert.equal(s.calls,0);
  const signed=await s.api.sign({...draft,identity,confirm:true}); assert.equal(signed.estado,'assinada');
  assert.deepEqual(s.input,preview); assert.equal(s.api.state().receitas[0].estado,'assinada');
  assert.notDeepEqual(s.api.pdf(draft.id,true),preview);
  await assert.rejects(s.api.sign({...draft,identity,confirm:true})); assert.equal(s.calls,1);
});

test('wrong medication model is refused by backend; no stock does not stop review but prevents real signing', async t => {
  const s=setup(t);
  await assert.rejects(s.api.draft(body({tipo:'NRA'}),origin),/NRB/);
  const draft=await s.api.draft(body({practice:false}),origin);
  assert.equal(draft.signable,false); assert.equal(s.calls,0);
  await assert.rejects(s.api.sign({...draft,identity,confirm:true}));
});

test('stock recovery reviews the saved recipe again, reserves only its own type/environment and invalidates old approval', async t => {
  const s=setup(t),draft=await s.api.draft(body({practice:false}),origin);
  assert.equal(draft.environment,'prd'); assert.equal(draft.signable,false);
  numbers(s.db,'hmg','NRB','1234567890123457'); numbers(s.db,'prd','NRA','1234567890123458');
  assert.equal((await s.api.review(draft.id,origin)).signable,false);
  numbers(s.db,'prd','NRB');
  const next=await s.api.review(draft.id,origin);
  assert.equal(next.id,draft.id); assert.equal(next.numero,'1234567890123456'); assert.equal(next.signable,true);
  assert.notEqual(next.hash,draft.hash); assert.notEqual(next.ticket,draft.ticket);
  await assert.rejects(s.api.sign({...draft,identity,confirm:true}));assert.equal(s.calls,0);
  await s.api.sign({...next,identity,confirm:true});assert.equal(s.calls,1);
  assert.equal(s.db.stock(owner,'hmg').NRB,1); assert.equal(s.db.stock(owner,'prd').NRA,1);
});

test('explicit practice mode permits signing an unnumbered preview without converting it into issued stock', async t => {
  const s=setup(t),b=body({practice:false}),blocked=await s.api.draft(b,origin);
  assert.equal(blocked.signable,false);
  const practice=await s.api.draft({...b,practice:true},origin);
  assert.equal(practice.signable,true); assert.equal(practice.practice,true); assert.equal(practice.numero,null);
  await assert.rejects(s.api.sign({...blocked,identity,confirm:true}));assert.equal(s.calls,0);
  const signed=await s.api.sign({...practice,identity,confirm:true}); assert.equal(signed.practice,true); assert.equal(signed.numero,null);
  assert.equal(s.db.get('SELECT COUNT(*) n FROM rx_numbers').n,0);
});

test('production numbers stay strings, reserve once, bind to a prescription and are consumed only on signing attempt', async t => {
  const s=setup(t); numbers(s.db); numbers(s.db,'hmg','NRB','1234567890123457');
  const draft=await s.api.draft(body({practice:false}),origin);
  assert.equal(draft.numero,'1234567890123456');
  assert.equal(s.db.summary(owner).allocated.find(n=>n.environment==='prd').status,'reservado');
  const reviewed=await s.api.review(draft.id,origin); assert.equal(reviewed.numero,draft.numero);
  await assert.rejects(s.api.sign({...draft,identity,confirm:true}));
  await s.api.sign({...reviewed,identity,confirm:true});
  const code=JSON.parse(s.db.document(draft.id,owner).content)._accessCode;
  assert.throws(()=>s.api.access({id:shortId(draft.id),codigo:'000000'}));
  assert.deepEqual(Buffer.from(s.api.access({id:shortId(draft.id),codigo:code}).pdf,'base64'),s.api.pdf(draft.id,true));
  assert.equal(s.db.summary(owner).allocated.find(n=>n.environment==='prd').status,'utilizado');
  assert.equal(s.db.stock(owner,'hmg').NRB,1);
});

test('failed signing retains the number and immutable PDF; retry needs a fresh review', async t => {
  const s=setup(t,{signer:async()=>{throw Error('synthetic cancellation');}}); numbers(s.db);
  const b=body({practice:false}), draft=await s.api.draft(b,origin), bytes=s.api.pdf(b.id);
  await assert.rejects(s.api.sign({...draft,identity,confirm:true}));
  assert.equal(s.db.document(b.id,owner).status,'pendente');
  assert.equal(s.db.stock(owner,'prd').NRB,undefined);
  await assert.rejects(s.api.draft({...b,medicamento:{...b.medicamento,posologia:'Tomar dois comprimidos.'}},origin));
  const next=await s.api.review(b.id,origin); assert.deepEqual(s.api.pdf(b.id),bytes); assert.notEqual(next.ticket,draft.ticket);
  await assert.rejects(s.api.draft({...b,medicamento:{...b.medicamento,posologia:'Texto alterado após nova revisão.'}},origin));
  const again=await s.api.review(b.id,origin);assert.deepEqual(s.api.pdf(b.id),bytes);assert.notEqual(again.ticket,next.ticket);
});

test('one local runtime owns the shared folder at a time', async t => {
  const dir=await mkdtemp(join(tmpdir(),'openpep-rx-lock-'));t.after(()=>rm(dir,{recursive:true,force:true}));
  const unlock=lockRuntime(dir);assert.throws(()=>lockRuntime(dir));unlock();const again=lockRuntime(dir);again();
});

test('SQLite survives reopening, shares parent folder with OpenPEP, and never persists native or OAuth credentials', async t => {
  const dir=await mkdtemp(join(tmpdir(),'openpep-rx-db-'));t.after(()=>rm(dir,{recursive:true,force:true}));
  let db=new LocalDatabase(dir);db.setSetting('profile',p);numbers(db);db.close();
  db=new LocalDatabase(dir);assert.equal(db.stock(owner,'prd').NRB,1);assert.equal(db.summary(owner).path,join(dir,'openpep-rx.sqlite'));db.close();
  assert.equal(dataDirectory({OPENPEP_DATA_DIR:dir}),join(dir,'prescricao'));
  assert.ok(!(await readFile(join(dir,'openpep-rx.sqlite'))).includes(Buffer.from('access_token')));
});

test('SNCR production requires explicit configuration and confirmation, preserves Origin, and exchanges/sends only once', async t => {
  const s=setup(t), calls=[];
  const sncr=createLocalSNCR({db:s.db,fetcher:async(url,options)=>{
    calls.push({url:String(url),options});
    return calls.length===1?Response.json({token_type:'Bearer',access_token:'SYNTHETIC-TOKEN'}):Response.json({numeroReceita:['1234567890123456']});
  }});
  assert.throws(()=>sncr.start({tipo:'NRB',quantidade:10,confirm:true},origin));
  assert.throws(()=>sncrConfig({enabled:true,environment:'prd'}));
  s.db.setSetting('sncr',sncrConfig({enabled:true,environment:'prd',confirmProduction:true,cnpj:''}));
  assert.throws(()=>sncr.start({tipo:'NRB',quantidade:10,confirm:true},origin));
  const result=sncr.start({tipo:'NRB',quantidade:10,confirm:true,confirmProduction:true},origin);
  assert.match(result.url,/api-gateway\.prd/);assert.equal(calls.length,0);
  const callback=new URL(origin+'/sncr/retorno');callback.searchParams.set('state',result.state);callback.searchParams.set('session_id','SYNTHETIC');
  await assert.rejects(sncr.finish(callback,'0'.repeat(64),origin));assert.equal(calls.length,0);
  assert.equal(await sncr.finish(callback,result.state,origin),'recebido');assert.equal(calls.length,2);
  for(const c of calls)assert.equal(c.options.headers.Origin,origin);
  assert.equal(JSON.parse(calls[1].options.body).documento,'12345');
  await assert.rejects(sncr.finish(callback,result.state,origin));assert.equal(calls.length,2);
  assert.ok(!JSON.stringify(s.db.summary(owner)).includes('SYNTHETIC-TOKEN'));
});

test('ambiguous SNCR results count toward limits; duplicate or numeric identifiers never reach stock', t => {
  const s=setup(t);
  for(let n=0;n<5;n++) {const state='attempt'+n;s.db.beginNumbers({owner,environment:'prd',type:'NRA',quantity:10,request:{},state});const r=s.db.claimNumbers(state,Date.now());s.db.recordNumbers(r,{kind:'ambiguous',http:503,body:null});}
  assert.throws(()=>s.db.beginNumbers({owner,environment:'prd',type:'NRA',quantity:10,request:{},state:'next'}));
  const state='invalid';s.db.beginNumbers({owner,environment:'prd',type:'NRB',quantity:10,request:{},state});const r=s.db.claimNumbers(state,Date.now());
  assert.equal(s.db.recordNumbers(r,{kind:'success',http:200,body:{numeroReceita:[1234567890123456]}}),'quarentena');
  assert.equal(s.db.stock(owner,'prd').NRB,undefined);
});

test('SNCR token failure records safe HTTP diagnostics and never sends numbers or stores returned secrets', async t => {
  const s=setup(t);s.db.setSetting('sncr',{enabled:true,environment:'prd',cnpj:''});let calls=0;
  const sncr=createLocalSNCR({db:s.db,fetcher:async()=>{calls++;return new Response('<html>SECRET synthetic response</html>',{status:403,headers:{server:'cloudflare','content-type':'text/html'}});}});
  const start=sncr.start({tipo:'NRB',quantidade:10,confirm:true,confirmProduction:true},origin);
  const result=await sncr.finish(new URL(origin+'/sncr/retorno?state='+start.state+'&session_id=synthetic-session'),start.state,origin);
  assert.equal(result,'nao-enviado');assert.equal(calls,1);
  const row=s.db.summary(owner).requests[0];assert.equal(row.http,403);assert.match(row.message,/Cloudflare/);assert.match(row.message,/Nenhum pedido/);
  assert.doesNotMatch(JSON.stringify(s.db.all('SELECT * FROM rx_requests')),/SECRET|synthetic-session/);
});

test('an abandoned login expires without consuming quota, but an uncertain sent request still counts', t => {
  const s=setup(t), now=Date.now(), request={owner,environment:'prd',type:'NRB',quantity:50,request:{},state:'abandoned',now};
  s.db.beginNumbers(request);
  s.db.beginNumbers({...request,state:'next',now:now+300001});
  assert.equal(s.db.summary(owner).requests.find(r=>r.status==='nao-enviado').quantity,50);
  assert.throws(()=>s.db.claimNumbers('abandoned',now+300002));
  const sent=s.db.claimNumbers('next',now+300002);s.db.recordNumbers(sent,{kind:'ambiguous',http:503,body:null});
  assert.throws(()=>s.db.beginNumbers({...request,state:'repeat',now:now+600003}));
});
