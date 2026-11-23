import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {lookupCEP,createCEPLookup} from '../api/cep.mjs';
import {bindCEP} from '../cep.js';
import {normalizeContact} from '../contato.js';
import {LocalDatabase} from '../local/database.mjs';
import {createPrescriptions} from '../local/prescriptions.mjs';
const address={cep:'01001-000',logradouro:'Praça da Sé',bairro:'Sé',cidade:'São Paulo',uf:'SP'};
test('CEP falls back on timeout/malformed data, supports city-wide postal codes and rejects invalid input',async()=>{
 for(const bad of [null,{cep:'99999999',localidade:'Wrong',uf:'SP'},{cep:'01001000',localidade:'City',uf:'XX'}]){
  const calls=[];const a=await lookupCEP('01001000',async url=>{calls.push(url);return Response.json(calls.length===1?bad:{cep:'01001000',city:'São Paulo',state:'SP',street:'Praça da Sé',neighborhood:'Sé'});});assert.deepEqual(a,address);assert.equal(calls.length,2);
 }
 assert.equal((await lookupCEP('01001000',async()=>Response.json({cep:'01001000',localidade:'São Paulo',uf:'SP'}))).logradouro,'');
 await assert.rejects(lookupCEP('01001-000',()=>{throw Error('should not call');}),/oito/);
 await assert.rejects(lookupCEP('01001000',async()=>{throw Error('timeout');}),/consultar/);
 const lookup=createCEPLookup({fetcher:async()=>Response.json({erro:true})});assert.deepEqual(await Promise.all([lookup('00000000'),lookup('00000000')]),[null,null]);
});
test('CEP UI ignores old replies and preserves edits made while waiting',async()=>{
 const doc={activeElement:null},control=()=>({value:'',disabled:false,ownerDocument:doc,setAttribute(){},removeAttribute(){},addEventListener(){},focus(){},querySelector:()=>true});
 const input=control(),button=control(),fields=Object.fromEntries(['logradouro','bairro','cidade','uf','numero'].map(k=>[k,control()])),pending=[];let fills=0;
 const binding=bindCEP({input,button,fields,lookup:()=>new Promise(resolve=>pending.push(resolve)),notify(){},onFill:()=>fills++});
 input.value='01001000';const old=binding.search();binding.reset();input.value='20040002';const next=binding.search();pending[0]({ok:true,json:address});await old;assert.equal(fields.cidade.value,'');pending[1]({ok:true,json:{...address,cidade:'Rio de Janeiro',uf:'RJ'}});await next;assert.equal(fields.cidade.value,'Rio de Janeiro');
 input.value='01001000';const manual=binding.search();fields.logradouro.value='Manual';pending[2]({ok:true,json:address});await manual;assert.equal(fields.logradouro.value,'Manual');assert.equal(fills,1);
 const reset=binding.search(true);binding.reset();pending[3]({ok:true,json:address});await reset;assert.equal(fields.logradouro.value,'Manual');
});
test('contacts are tied to one prescription and can be corrected without changing its signed bytes',async t=>{
 const db=new LocalDatabase(':memory:');t.after(()=>db.close());db.setSetting('profile',{nome:'Profissional Fictício',cpf:'52998224725',crm:'12345',uf:'SP'});let signs=0;
 const api=createPrescriptions({db,signer:async(cmd,r)=>{signs++;const b=Buffer.from(r.pdf,'base64');b[r.range[1]+1]=49;return {pdf:b.toString('base64')};}});
 const body=contact=>({id:randomUUID(),tipo:'NRB',practice:true,contact,paciente:{nome:'Paciente Fictício',documento:'AB123456',endereco:'Rua Exemplo, 10',cidade:'São Paulo',uf:'SP'},emitente:{endereco:'Av. Exemplo, 100',cidade:'São Paulo',uf:'SP',telefone:''},medicamento:{nome:'Clonazepam',concentracao:'2 mg',forma:'comprimido',quantidade:30,unidade:'comprimidos',posologia:'Tomar 1 comprimido à noite.'}});
 const a=await api.draft(body({phone:'11999999999',email:'um@example.org'}),'http://127.0.0.1:4197');await api.sign({...a,identity:'a'.repeat(64),confirm:true});const bytes=api.pdf(a.id,true),before=db.get('SELECT signed_hash,content_hash,number,status FROM rx_documents WHERE id=?',a.id);
 const b=await api.draft(body({phone:'21988888888',email:'dois@example.org'}),'http://127.0.0.1:4197');await api.sign({...b,identity:'a'.repeat(64),confirm:true});assert.equal(api.sharing(a.id).contact.email,'um@example.org');assert.equal(api.sharing(b.id).contact.email,'dois@example.org');
 api.contact({id:a.id,contact:{phone:'11977777777',email:'novo@example.org'}});assert.equal(api.sharing(a.id).contact.phone,'5511977777777');assert.deepEqual(api.pdf(a.id,true),bytes);assert.deepEqual(db.get('SELECT signed_hash,content_hash,number,status FROM rx_documents WHERE id=?',a.id),before);assert.equal(signs,2);assert.equal(db.get('SELECT COUNT(*) n FROM rx_numbers').n,0);
 assert.throws(()=>api.contact({id:a.id,contact:{email:'x@example.org\r\nBcc:y@example.org'}}));
 db.setSetting('profile',{...db.profile(),crm:'54321'});assert.throws(()=>api.sharing(a.id));assert.throws(()=>api.contact({id:a.id,contact:{email:'other@example.org'}}));
 assert.throws(()=>normalizeContact({phone:'garbage11999999999'}));
});
