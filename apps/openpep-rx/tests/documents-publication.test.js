import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {memoryD1} from './d1-fixture.mjs';
import {createDocuments} from '../hosted/documents.mjs';
import {createPublications} from '../local/publications.mjs';
import {createPrescriptions} from '../local/prescriptions.mjs';
import {LocalDatabase,sha} from '../local/database.mjs';
import {backupDatabase} from '../local/backup.mjs';
import {messageLinks,signedFile,publicDocumentURL} from '../compartilhar-documento.js';
const origin='https://documents.example.org',token='a'.repeat(64),key='B'.repeat(32),id='A'.repeat(26),pdf=Buffer.from('%PDF-1.7\nsynthetic only');
async function setup(t){
 const {sql,DB}=memoryD1();sql.exec(await readFile(new URL('../documentos/schema.sql',import.meta.url),'utf8'));t.after(()=>sql.close());const objects=new Map();
 const env={DB,DOCUMENT_PUBLISHERS:JSON.stringify([{id:'installation-one',tokenHash:sha(token)},{id:'installation-two',tokenHash:sha('b'.repeat(64))}]),BUCKET:{async put(k,v){objects.set(k,Buffer.from(v));},async get(k){const b=objects.get(k);return b?{arrayBuffer:async()=>Uint8Array.from(b).buffer}:null;},async delete(k){objects.delete(k);}}};
 const handler=createDocuments();const request=(path='',body=pdf,headers={})=>handler(new Request(origin+'/api/documents/'+id+path,{method:'POST',headers:{'Content-Type':path==='/access'?'application/json':'application/pdf',Authorization:'Bearer '+token,'X-Document-Access-Hash':sha(key),Origin:origin,...headers},body}),env);
 return {request,env,objects,handler};
}
test('publication requires publisher identity; individual capability preserves exact bytes and cannot enumerate',async t=>{
 const s=await setup(t);assert.equal((await s.request('',pdf,{Authorization:''})).status,401);assert.equal(s.objects.size,0);
 assert.equal((await s.request()).status,201);assert.equal((await s.request()).status,200);assert.equal(s.objects.size,1);
 assert.equal((await s.request('/access',JSON.stringify({token:'C'.repeat(32)}))).status,404);
 assert.equal((await s.request('/access',JSON.stringify({token:key}),{Origin:'https://evil.example'})).status,404);
 const r=await s.request('/access',JSON.stringify({token:key}));assert.equal(r.status,200);assert.deepEqual(Buffer.from(await r.arrayBuffer()),pdf);assert.equal(r.headers.get('X-Document-SHA256'),sha(pdf));assert.match(r.headers.get('Cache-Control'),/no-store/);
 assert.equal((await s.handler(new Request(origin+'/api/documents'),s.env)).status,404);
});
test('documents are immutable, isolated by publisher, and permanently revoked without deleting the original',async t=>{
 const s=await setup(t);await s.request();
 assert.equal((await s.request('',Buffer.from('%PDF-other'))).status,409);
 assert.equal((await s.request('',pdf,{Authorization:'Bearer '+'b'.repeat(64)})).status,409);
 assert.equal((await s.request('/revoke',null,{Authorization:'Bearer '+'b'.repeat(64)})).status,404);
 assert.equal((await s.request('/revoke',null)).status,200);assert.equal((await s.request('/access',JSON.stringify({token:key}))).status,404);assert.equal((await s.request()).status,409);assert.equal(s.objects.size,1);
});
test('storage failure does not claim publication and corrupted objects are never served',async t=>{
 const s=await setup(t),put=s.env.BUCKET.put;s.env.BUCKET.put=async()=>{throw Error('offline');};assert.equal((await s.request()).status,503);s.env.BUCKET.put=put;assert.equal((await s.request()).status,201);
 for(const k of s.objects.keys())s.objects.set(k,Buffer.from('%PDF-corrupt'));
 assert.equal((await s.request('/access',JSON.stringify({token:key}))).status,503);
});
test('consent gates network, retry is idempotent and standalone PDF remains unchanged',async t=>{
 const s=await setup(t),db=new LocalDatabase();t.after(()=>db.close());let calls=0,offline=true;
 const pub=createPublications({db,origin,token,fetcher:async(url,opts)=>{calls++;if(offline)throw Error('network');return s.handler(new Request(url,opts),s.env);}}),doc=randomUUID(),bytes=Buffer.from(pdf),planned=pub.plan(doc);
 assert.equal(calls,0);await assert.rejects(pub.publish(doc,bytes,false));assert.equal(calls,0);assert.equal(pub.info(doc).url,null);
 assert.equal((await pub.publish(doc,bytes,true)).status,'pendente');offline=false;const done=await pub.publish(doc,bytes,true);assert.equal(done.url,planned);assert.equal(done.status,'publicado');assert.equal(calls,2);
 assert.equal((await pub.publish(doc,bytes,true)).status,'publicado');assert.equal(calls,2);await assert.rejects(pub.publish(doc,Buffer.from('%PDF-other'),true));
 await assert.rejects(pub.revoke(doc,false));await pub.revoke(doc,true);assert.equal(pub.info(doc).url,null);assert.deepEqual(bytes,pdf);
});
const body=()=>({id:randomUUID(),tipo:'NRB',practice:true,publish:true,paciente:{nome:'Paciente Fictício',documento:'AB123456',endereco:'Rua Exemplo, 10',cidade:'São Paulo',uf:'SP'},emitente:{endereco:'Av. Exemplo, 100',cidade:'São Paulo',uf:'SP',telefone:''},medicamento:{nome:'Clonazepam',concentracao:'2 mg',forma:'comprimido',quantidade:30,unidade:'comprimidos',posologia:'Tomar 1 comprimido à noite.'}});
test('publication failure after signing does not consume another signature; exact signed bytes can be published later',async t=>{
 const s=await setup(t),db=new LocalDatabase();t.after(()=>db.close());db.setSetting('profile',{nome:'Profissional Fictício',cpf:'52998224725',crm:'12345',uf:'SP'});let signing=0,offline=true;
 const pub=createPublications({db,origin,token,fetcher:async(url,opts)=>{if(offline)throw Error('offline');return s.handler(new Request(url,opts),s.env);}});
 const api=createPrescriptions({db,publications:pub,signer:async(cmd,r)=>{signing++;const b=Buffer.from(r.pdf,'base64');b[r.range[1]+1]=49;return {pdf:b.toString('base64')};}});
 const draft=await api.draft(body(),'http://127.0.0.1:4197');assert.equal(draft.publicationRequested,true);assert.equal(draft.publicationOrigin,origin);
 await assert.rejects(api.sign({...draft,identity:token,confirm:true}),/publicação/);assert.equal(signing,0);
 const signed=await api.sign({...draft,identity:token,confirm:true,publish:true});assert.equal(signed.estado,'assinada');assert.equal(signed.publication.status,'pendente');assert.equal(api.state().receitas[0].estado,'assinada');const original=api.pdf(draft.id,true);
 offline=false;const published=await api.publish({id:draft.id,confirm:true});assert.equal(published.status,'publicado');assert.equal(signing,1);assert.deepEqual(original,api.pdf(draft.id,true));
 await assert.rejects(api.sign({...draft,identity:token,confirm:true,publish:true}));assert.equal(signing,1);
 // Even an unexpected publishing error cannot revert a completed signature.
 const next=await api.draft(body(),'http://127.0.0.1:4197');pub.publish=async()=>{throw Error('unexpected');};assert.equal((await api.sign({...next,identity:token,confirm:true,publish:true})).estado,'assinada');
});
test('sharing contains only the confirmed public link, rejects local URLs/header injection, and preserves PDF bytes',async()=>{
 const url=origin+'/r/'+id+'#'+key,r=messageLinks({phone:'(11) 99999-9999',email:'paciente@example.org',url});assert.match(r.whatsapp,/wa.me\/5511999999999/);assert.match(decodeURIComponent(r.email),/Abra seu documento: https:/);assert.ok(!r.text.includes('Clonazepam'));
 for(const bad of ['http://127.0.0.1:4197/r/'+id+'#'+key,'https://localhost/r/'+id+'#'+key,'https://example.org/?token=x'])assert.throws(()=>publicDocumentURL(bad));
 assert.throws(()=>messageLinks({email:'a@example.org\r\nBcc:b@example.org'}));assert.match(messageLinks({practice:true}).text,/sem validade/);assert.deepEqual(Buffer.from(await signedFile(pdf).arrayBuffer()),pdf);
});
test('consistent backup includes WAL transactions and leaves stock unchanged',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'rx-backup-test-'));t.after(()=>rm(dir,{recursive:true,force:true}));const db=new LocalDatabase(dir);t.after(()=>db.close());db.setSetting('synthetic','retained');const path=await backupDatabase(dir);const copy=new (await import('node:sqlite')).DatabaseSync(path,{readOnly:true});assert.equal(copy.prepare("SELECT value FROM rx_settings WHERE name='synthetic'").get().value,'"retained"');copy.close();assert.equal(db.setting('synthetic'),'retained');
});
test('ITI temporary PDF links require the permanent capability, expire, rotate and follow revocation',async t=>{
 const s=await setup(t);await s.request();let time=1_000;const handler=createDocuments({now:()=>time});
 const issue=body=>handler(new Request(origin+'/api/documents/'+id+'/validation',{method:'POST',headers:{Origin:origin,'Content-Type':'application/json'},body:JSON.stringify(body)}),s.env);
 assert.equal((await issue({token:'C'.repeat(32)})).status,404);
 const generated=await (await issue({token:key})).json();assert.ok(!generated.url.includes(key));assert.equal(generated.expiresAt,time+900_000);
 const get=(url,method='GET')=>handler(new Request(url,{method}),s.env);
 let r=await get(generated.url);assert.equal(r.status,200);assert.equal(r.headers.get('Content-Type'),'application/pdf');assert.deepEqual(Buffer.from(await r.arrayBuffer()),pdf);assert.match(r.headers.get('Cache-Control'),/no-store/);
 r=await get(generated.url,'HEAD');assert.equal(r.status,200);assert.equal(r.headers.get('Content-Length'),String(pdf.length));assert.equal(await r.text(),'');
 time=generated.expiresAt;assert.equal((await get(generated.url)).status,404);
 const next=await (await issue({token:key})).json();assert.equal((await get(next.url)).status,200);assert.equal((await get(generated.url)).status,404);
 const renewed=await (await issue({token:key})).json();assert.equal((await get(next.url)).status,404);
 await s.request('/revoke',null);assert.equal((await get(renewed.url)).status,404);assert.equal((await issue({token:key})).status,404);
});
test('verified domain alias preserves old plans and publishes/revokes only at the current configured origin',async t=>{
 const s=await setup(t),db=new LocalDatabase(':memory:');t.after(()=>db.close());const doc=randomUUID(),next='https://documentos.example.org';
 const old=createPublications({db,origin,token}),planned=old.plan(doc);let calls=0;
 const migrated=createPublications({db,origin:next,token,previousOrigins:origin,fetcher:async(u,o)=>{calls++;assert.equal(new URL(u).origin,next);return s.handler(new Request(u,o),s.env);}});
 assert.equal(migrated.plan(doc),planned);assert.equal((await migrated.publish(doc,pdf,true)).url,planned.replace(origin,next));assert.equal(db.get('SELECT origin FROM rx_publications WHERE document_id=?',doc).origin,origin);
 await migrated.revoke(doc,true);assert.equal(calls,2);
 const foreign=createPublications({db,origin:'https://unrelated.example.org',token});await assert.rejects(foreign.revoke(doc,true));assert.equal(calls,2);
});
