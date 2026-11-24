import test from 'node:test';
import assert from 'node:assert/strict';
import {once} from 'node:events';
import {request as httpRequest} from 'node:http';
import {createHash} from 'node:crypto';
import {PDFDocument, degrees} from 'pdf-lib';
import {createLocalServer} from '../local/server.mjs';
import {prepareSignature} from '../local/prepare-pdf.mjs';

async function pdf() {
  const doc = await PDFDocument.create(); doc.addPage([420, 595]);
  return Buffer.from(await doc.save());
}
const cert = 'a'.repeat(64);
async function setup(t, overrides = {}) {
  const calls = [];
  const server = createLocalServer({available: true, signer: async (command, request) => {
    calls.push(command);
    if (command === 'list') return [{id: cert, name: 'Titular sintético'}];
    // Protocol-only fake. No cryptographic validity is asserted by this test.
    const signed = Buffer.from(request.pdf, 'base64');
    signed[request.range[1] + 1] = 49;
    return {pdf: signed.toString('base64')};
  }, ...overrides});
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const base = {'X-OpenPEP-Request': 'local'};
  const opened = await fetch(origin + server.launchPath, {redirect: 'manual'});
  assert.equal(opened.status, 303);
  const cookie = opened.headers.get('Set-Cookie').split(';')[0];
  const session = await (await fetch(origin + '/api/local/session', {headers: {...base, Cookie: cookie}})).json();
  const request = (route, body, headers = {}) => fetch(origin + '/api/local/' + route, {
    method: 'POST', headers: {...base, 'X-OpenPEP-Local': session.token, Origin: origin,
      'Content-Type': Buffer.isBuffer(body) ? 'application/pdf' : 'application/json', ...headers},
    body: Buffer.isBuffer(body) ? body : JSON.stringify(body)});
  const prepare = async () => {
    const response = await request('prepare', await pdf()); assert.equal(response.status, 200);
    const bytes = Buffer.from(await response.arrayBuffer());
    const hash = response.headers.get('X-Document-SHA256');
    assert.equal(hash, createHash('sha256').update(bytes).digest('hex'));
    return {bytes, body: {ticket: response.headers.get('X-Document-Ticket'), hash, identity: cert, confirm: true}};
  };
  return {server, origin, request, prepare, calls, headers:{...base,'X-OpenPEP-Local':session.token}};
}

test('session token is handed only to the browser that opened the single-use launch address', async t => {
  const server = createLocalServer({available: true, signer: async () => { throw Error('native code must not run'); }});
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const origin = `http://127.0.0.1:${server.address().port}`, base = {'X-OpenPEP-Request': 'local'};
  const session = headers => fetch(origin + '/api/local/session', {headers: {...base, ...headers}});
  const open = path => fetch(origin + path, {redirect: 'manual'});
  assert.match(server.launchPath, /^\/abrir\?chave=[a-f0-9]{64}$/);
  assert.equal((await session()).status, 403);
  assert.equal((await session({Cookie: 'openpep_rx_local=' + 'f'.repeat(64)})).status, 403);
  assert.equal((await open('/abrir?chave=' + 'f'.repeat(64))).status, 403);
  assert.equal((await open('/abrir')).status, 403);
  const opened = await open(server.launchPath);
  assert.equal(opened.status, 303); assert.equal(opened.headers.get('Location'), '/');
  const setCookie = opened.headers.get('Set-Cookie');
  assert.match(setCookie, /^openpep_rx_local=[a-f0-9]{64}; HttpOnly; SameSite=Strict; Path=\/$/);
  assert.equal((await open(server.launchPath)).status, 403);
  const cookie = setCookie.split(';')[0], granted = await session({Cookie: cookie});
  assert.equal(granted.status, 200); assert.equal(granted.headers.get('Set-Cookie'), null);
  const {token} = await granted.json(); assert.equal(token, cookie.split('=')[1]);
  assert.equal((await fetch(origin + '/api/local/session', {headers: {Cookie: cookie}})).status, 403);
  assert.equal((await session({Cookie: cookie, Origin: 'https://attacker.example'})).status, 403);
});

test('PDF preparation preserves pages, reserves one signature and rejects forms or existing signatures', async () => {
  const prepared = await prepareSignature(await pdf());
  const doc = await PDFDocument.load(prepared.pdf);
  assert.equal(doc.getPageCount(), 1); assert.equal(doc.getPage(0).getWidth(), 420);
  const [zero, start, end, tail] = prepared.range;
  assert.equal(zero, 0); assert.equal(end + tail, prepared.pdf.length);
  assert.equal(prepared.pdf[start], 60); assert.equal(prepared.pdf[end - 1], 62);
  await assert.rejects(prepareSignature(prepared.pdf));
  const form = await PDFDocument.create(); form.addPage(); form.getForm().createTextField('name');
  await assert.rejects(prepareSignature(await form.save()));
  await assert.rejects(prepareSignature(Buffer.from('not a PDF')));
});

test('Gov.br cross-site return can navigate to the page shell but cannot read APIs or embed pages', async t => {
  const s=await setup(t);
  const navigate=(path,extra={})=>new Promise((resolve,reject)=>{
    const req=httpRequest(s.origin+path,{headers:{'Sec-Fetch-Site':'cross-site','Sec-Fetch-Mode':'navigate','Sec-Fetch-Dest':'document',...s.headers,...extra}},res=>{res.resume();resolve(res.statusCode);});req.on('error',reject);req.end();
  });
  assert.equal(await navigate('/dados-locais.html?sncr=nao-enviado'),200);
  assert.equal(await navigate('/api/local/settings'),403);
  assert.equal(await navigate('/api/receita/estado'),403);
  assert.equal(await navigate('/dados-locais.html',{'Sec-Fetch-Dest':'iframe'}),403);
  assert.equal(await navigate('/dados-locais.html',{'Sec-Fetch-Mode':'cors'}),403);
  assert.deepEqual(s.calls,[]);
});

test('web pairing needs local consent; tokens are scoped to one configured origin and expire', async t => {
  let time=0;const web='https://rx.example.br',s=await setup(t,{webOrigins:web,now:()=>time}),challenge='c'.repeat(64);
  const foreign=(path,body,token)=>fetch(s.origin+'/api/local/'+path,{method:body?'POST':'GET',headers:{Origin:web,'Sec-Fetch-Site':'cross-site','X-OpenPEP-Request':'local',...(token?{'X-OpenPEP-Local':token}:{}),...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined});
  assert.equal((await foreign('session')).status,403);
  assert.equal((await foreign('settings',null,s.headers['X-OpenPEP-Local'])).status,403);
  assert.equal((await s.request('pair',{origin:'https://attacker.example',challenge})).status,422);
  const paired=await (await s.request('pair',{origin:web,challenge})).json();assert.match(paired.token,/^[a-f0-9]{64}$/);assert.notEqual(paired.token,s.headers['X-OpenPEP-Local']);
  assert.equal((await foreign('pair',{origin:web,challenge},paired.token)).status,403);
  const session=await foreign('session',null,paired.token);assert.equal(session.status,200);assert.equal(session.headers.get('Access-Control-Allow-Origin'),web);assert.equal(session.headers.get('Set-Cookie'),null);assert.equal((await session.json()).token,paired.token);
  assert.equal((await s.request('certificates',{}, {Origin:'https://attacker.example','X-OpenPEP-Local':paired.token})).status,403);
  const complete=await foreign('pair/complete',{challenge,code:paired.code});assert.equal(complete.status,200);
  assert.equal((await foreign('pair/complete',{challenge,code:paired.code})).status,403);
  time=12*3600_000+1;assert.equal((await foreign('settings',null,paired.token)).status,403);assert.deepEqual(s.calls,[]);
});

test('inline emitter stores profile and office atomically and keeps offices isolated by registration', async t => {
  const s=await setup(t),profile={nome:'Profissional Fictício',cpf:'52998224725',crm:'12345',uf:'SP'},office={cidade:'Cidade Exemplo',uf:'SP',telefone:'',parts:{cep:'01001000',logradouro:'Rua Exemplo',numero:'100',complemento:'Sala 2',bairro:'Centro'}};
  assert.equal((await s.request('settings',{profile,office})).status,200);
  const state=async()=>await (await fetch(s.origin+'/api/receita/estado',{headers:s.headers})).json();
  const saved=await state(); assert.equal(saved.prescritor.nome,profile.nome);assert.equal(saved.emitente.parts.numero,'100');assert.match(saved.emitente.endereco,/CEP 01001-000/);
  assert.equal((await s.request('settings',{profile:{...profile,nome:'Não salvar'},office:{...office,uf:'XX'}})).status,422);
  assert.equal((await state()).prescritor.nome,profile.nome);
  assert.equal((await s.request('settings',{profile:{...profile,crm:'54321'}})).status,200);assert.equal((await state()).emitente,null);
  assert.equal((await s.request('settings',{profile})).status,200);assert.deepEqual((await state()).emitente,saved.emitente);

});

test('visible mark is reviewed again, binds the certificate, and does not stack when repositioned', async t => {
  const s=await setup(t),first=await s.prepare();
  const mark=await s.request('appearance',{...first.body,page:1,x:.1,y:.2,width:220/420,height:72/595});
  assert.equal(mark.status,200);const bytes=Buffer.from(await mark.arrayBuffer());assert.notEqual(mark.headers.get('X-Document-SHA256'),first.body.hash);
  const marked={ticket:mark.headers.get('X-Document-Ticket'),hash:mark.headers.get('X-Document-SHA256'),identity:cert,confirm:true};
  assert.equal((await s.request('sign',first.body)).status,409);
  assert.equal((await s.request('sign',{...marked,identity:'b'.repeat(64)})).status,409);
  const moved=await s.request('appearance',{...marked,page:1,x:.1,y:.6,width:220/420,height:72/595});assert.equal(moved.status,200);
  const movedBytes=Buffer.from(await moved.arrayBuffer());assert.ok(Math.abs(movedBytes.length-bytes.length)<100);
  const final={...marked,ticket:moved.headers.get('X-Document-Ticket'),hash:moved.headers.get('X-Document-SHA256')};
  assert.equal((await s.request('sign',marked)).status,409);assert.equal((await s.request('sign',final)).status,200);
  assert.deepEqual(s.calls,['list','list','sign']);
});

test('mark accepts cropped rotated pages and rejects out-of-page positions', async () => {
  for(const angle of [0,90,180,270]){
    const doc=await PDFDocument.create(),p=doc.addPage([600,800]);p.setCropBox(40,60,500,700);p.setRotation(degrees(angle));
    const bytes=await doc.save(),dw=angle%180?700:500,dh=angle%180?500:700;
    const prepared=await prepareSignature(bytes,{appearance:{page:1,x:.1,y:.2,width:220/dw,height:72/dh,name:'Titular Fictício'}});
    const out=await PDFDocument.load(prepared.pdf);assert.deepEqual(out.getPage(0).getCropBox(),p.getCropBox());assert.equal(out.getPage(0).getRotation().angle,angle);
    await assert.rejects(prepareSignature(bytes,{appearance:{page:1,x:1,y:.2,width:220/dw,height:72/dh,name:'Titular Fictício'}}));
  }
});

test('loopback API rejects foreign origins, hosts, absent headers and tokens without invoking native code', async t => {
  const s = await setup(t);
  assert.equal((await fetch(s.origin + '/api/local/session')).status, 403);
  assert.equal((await s.request('certificates', {}, {Origin: 'https://attacker.example'})).status, 403);
  const foreignHost = await new Promise((resolve, reject) => {
    const req = httpRequest(s.origin + '/api/local/session', {headers: {Host: 'attacker.example', 'X-OpenPEP-Request': 'local'}}, res => { res.resume(); resolve(res.statusCode); });
    req.on('error', reject); req.end();
  });
  assert.equal(foreignHost, 403);
  assert.equal((await s.request('certificates', {}, {'X-OpenPEP-Local': 'invalid'})).status, 403);
  assert.equal((await s.request('certificates', {}, {'Sec-Fetch-Site': 'cross-site'})).status, 403);
  assert.equal((await fetch(s.origin + '/api/local/sign', {method: 'OPTIONS'})).status, 405);
  assert.deepEqual(s.calls, []);
  assert.equal((await s.request('certificates', {})).status, 200);
  assert.deepEqual(s.calls, ['list']);
});

test('only the reviewed PDF can be authorized once, and the returned PDF matches its exact byte ranges', async t => {
  const s = await setup(t), reviewed = await s.prepare();
  assert.equal((await s.request('sign', {...reviewed.body, confirm: false})).status, 409);
  assert.equal((await s.request('sign', {...reviewed.body, hash: '0'.repeat(64)})).status, 409);
  assert.deepEqual(s.calls, []);
  const response = await s.request('sign', reviewed.body); assert.equal(response.status, 200);
  const signed = Buffer.from(await response.arrayBuffer());
  assert.equal(signed.length, reviewed.bytes.length); assert.notDeepEqual(signed, reviewed.bytes);
  assert.equal((await s.request('sign', reviewed.body)).status, 409);
  assert.deepEqual(s.calls, ['sign']);
});

test('cancellation consumes authorization; no automatic repeat or success PDF', async t => {
  let calls = 0;
  const s = await setup(t, {signer: async () => { calls++; throw Error('synthetic cancellation'); }});
  const {body} = await s.prepare();
  const response = await s.request('sign', body); assert.equal(response.status, 422);
  assert.equal(response.headers.get('content-type'), 'application/json');
  assert.equal((await s.request('sign', body)).status, 409); assert.equal(calls, 1);
});

test('expired or replaced previews cannot sign', async t => {
  let time = 0; const s = await setup(t, {now: () => time});
  const first = await s.prepare(); const second = await s.prepare();
  assert.equal((await s.request('sign', first.body)).status, 409);
  time = 600001;
  assert.equal((await s.request('sign', second.body)).status, 409);
  assert.deepEqual(s.calls, []);
});

test('one active native operation blocks a second signing and replacement upload', async t => {
  let finish, started;
  const running = new Promise(resolve => { started = resolve; });
  const s = await setup(t, {signer: () => { started(); return new Promise((resolve, reject) => { finish = () => reject(Error('synthetic cancellation')); }); }});
  const {body} = await s.prepare(); const first = s.request('sign', body); await running;
  assert.equal((await s.request('sign', body)).status, 409);
  assert.equal((await s.request('prepare', await pdf())).status, 409);
  finish(); assert.equal((await first).status, 422);
});

test('native output that changes reviewed content is rejected', async t => {
  const s = await setup(t, {signer: async (command, request) => {
    const altered = Buffer.from(request.pdf, 'base64'); altered[6] = 48;
    return {pdf: altered.toString('base64')};
  }});
  const {body} = await s.prepare(); assert.equal((await s.request('sign', body)).status, 422);
});

test('local preview worker and fonts are served with correct types, while source and configuration stay private', async t => {
  const s = await setup(t);
  for (const [path, type] of [['vendor/pdfjs/pdf.worker.mjs', 'text/javascript'], ['vendor/pdfjs/standard_fonts/LiberationSans-Regular.ttf', 'font/ttf'], ['assinatura-local.pdf', 'application/pdf']]) {
    const response = await fetch(s.origin + '/' + path);
    assert.equal(response.status, 200, path); assert.equal(response.headers.get('content-type'), type);
    await response.arrayBuffer();
  }
  for (const path of ['.env', 'local/VIDaaSSigner.swift', 'package.json', 'README.md']) {
    assert.equal((await fetch(s.origin + '/' + path)).status, 404, path);
  }
});

test('standalone signed PDFs persist in local storage; publication requires matching bytes and explicit consent',async t=>{
  let uploads=0;
  const s=await setup(t,{publicationOptions:{origin:'https://documents.example.org',token:'b'.repeat(64)},fetcher:async(url,options)=>{uploads++;return Response.json({published:true,hash:createHash('sha256').update(options.body).digest('hex')});}});
  const draft=await s.prepare(),r=await s.request('sign',draft.body),id=r.headers.get('X-Document-ID'),signed=Buffer.from(await r.arrayBuffer()),hash=createHash('sha256').update(signed).digest('hex');
  assert.ok(id);const get=path=>fetch(s.origin+'/api/local/'+path,{headers:s.headers});
  const list=await (await get('signed-files')).json();assert.equal(list.documents.length,1);assert.equal(list.documents[0].id,id);
  assert.deepEqual(Buffer.from(await (await get('signed-file?id='+id)).arrayBuffer()),signed);
  assert.equal((await fetch(s.origin+'/api/local/signed-file?id='+id,{headers:{'X-OpenPEP-Request':'local'}})).status,403);
  assert.equal((await get('document-share?id='+id+'&hash='+hash)).status,200);
  assert.equal((await s.request('document-share',{id,hash,confirm:false})).status,422);assert.equal(uploads,0);
  assert.equal((await s.request('document-share',{id,hash:'c'.repeat(64),confirm:true})).status,409);assert.equal(uploads,0);
  const published=await (await s.request('document-share',{id,hash,confirm:true})).json();assert.equal(published.status,'publicado');assert.equal(uploads,1);assert.deepEqual(s.calls,['sign']);
  assert.deepEqual(Buffer.from(await (await get('signed-file?id='+id)).arrayBuffer()),signed);
});

test('local CEP endpoint authenticates, validates and caches only the postal lookup',async t=>{
 let count=0;const s=await setup(t,{fetcher:async(url)=>{count++;assert.equal(url,'https://viacep.com.br/ws/01001000/json/');return Response.json({cep:'01001-000',localidade:'São Paulo',uf:'SP',logradouro:'Praça da Sé',bairro:'Sé'});}});
 const get=(path,headers=s.headers)=>fetch(s.origin+'/api/receita/cep'+path,{headers});
 assert.equal((await get('?cep=01001000',{})).status,403);
 for(const q of ['?cep=01001-000','?cep=01001000&name=Patient','?cep=01001000&cep=01001000'])assert.equal((await get(q)).status,400);
 for(let i=0;i<2;i++){const r=await get('?cep=01001000');assert.equal(r.status,200);assert.equal((await r.json()).cidade,'São Paulo');}assert.equal(count,1);
});
