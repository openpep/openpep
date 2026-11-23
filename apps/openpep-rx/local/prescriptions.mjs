// SPDX-License-Identifier: AGPL-3.0-or-later
import {randomBytes, randomInt} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {prescriptionContent, prescriptionPDF, items, fromShortId} from '../api/receita-doc.mjs';
import {termoPDF, TERM_TYPES} from '../api/termo-doc.mjs';
import {normalizedCPF} from '../api/entry-oidc.mjs';
import {ownerOf, sha} from './database.mjs';
import {checkMedicationTypes} from './catalog.mjs';
import {prepareSignature} from './prepare-pdf.mjs';
import {normalizeContact} from '../contato.js';

const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const fonts = Object.fromEntries(await Promise.all(Object.entries({regular:400, medium:500, semibold:600, bold:700}).map(async ([k,w]) => [k, await readFile(new URL(`../assets/fonts/pdf/inter-${w}-latin.ttf`, import.meta.url))])));
export function profileInput(body) {
  const nome = typeof body.nome === 'string' ? body.nome.trim() : '', crm = String(body.crm || '').trim(), uf = String(body.uf || '').toUpperCase();
  const cpf = normalizedCPF(body.cpf);
  if (!/^[A-Za-zÀ-ÿ .'-]{3,120}$/.test(nome) || !/^\d{1,10}$/.test(crm) || !'AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO'.split(' ').includes(uf) || !cpf) throw Error('Confira nome, CPF, CRM e UF do emitente.');
  return {nome, cpf, crm, uf};
}
export function officeInput(body) {
  const clean = (value, min, max) => {
    if (typeof value !== 'string') throw Error('Confira o endereço do consultório.');
    const text = value.trim().replace(/\s+/g, ' ');
    if (text.length < min || text.length > max || /[^\x20-\x7e\u00a0-\u00ff]/.test(text)) throw Error('Confira o endereço do consultório.');
    return text;
  };
  const cidade = clean(body.cidade, 2, 80), uf = clean(body.uf, 2, 2);
  if (!'AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO'.split(' ').includes(uf)) throw Error('Selecione a UF do consultório.');
  const telefone = clean(body.telefone ?? '', 0, 30);
  if (telefone && (!/^[0-9 ()+-]+$/.test(telefone) || telefone.replace(/\D/g,'').length < 8)) throw Error('Confira o telefone do consultório.');
  let endereco, parts;
  if (body.parts) {
    const p = body.parts, cep = clean(p.cep ?? '', 0, 9).replace(/\D/g,'');
    if (cep && cep.length !== 8) throw Error('Confira o CEP do consultório.');
    parts = {cep, logradouro:clean(p.logradouro,2,100), numero:clean(p.numero,1,10), complemento:clean(p.complemento ?? '',0,40), bairro:clean(p.bairro ?? '',0,60)};
    endereco = [[parts.logradouro,parts.numero,parts.complemento].filter(Boolean).join(', '),parts.bairro,cep ? `CEP ${cep.slice(0,5)}-${cep.slice(5)}` : ''].filter(Boolean).join(' - ');
  } else endereco = body.endereco;
  return {endereco:clean(endereco,3,160),cidade,uf,telefone,...(parts ? {parts} : {})};
}
export function checkedSignature(result, prepared) {
  if (typeof result?.pdf !== 'string' || result.pdf.length > 36 * 1024 * 1024 || !/^JVBERi0[A-Za-z0-9+/]*={0,2}$/.test(result.pdf)) throw Error('Resposta de assinatura inválida.');
  const signed = Buffer.from(result.pdf, 'base64'), [, start, end] = prepared.range, pdf = Buffer.from(prepared.pdf);
  if (signed.length !== pdf.length || !signed.subarray(0, start).equals(pdf.subarray(0, start)) || !signed.subarray(end).equals(pdf.subarray(end)) || sha(signed) === sha(pdf)) throw Error('O documento assinado não corresponde à prévia.');
  return signed;
}
export function createPrescriptions({db, signer, now = Date.now, publications}) {
  const profile = () => { const p = db.profile(); if (!p) throw Error('Cadastre o emitente na seção Emitente antes de revisar a receita.'); return p; };
  const document = id => { if (!UUID.test(id || '')) throw Error('Receita inválida.'); const row = db.document(id, ownerOf(profile())); if (!row) throw Error('Receita não encontrada.'); return row; };
  async function prepareReview(row, origin) {
    // Pending operations are retried against their immutable original bytes, after a new review.
    let prepared;
    if (row.attempted_at !== null && row.prepared) {
      const pdf = Buffer.from(row.prepared), match = /\/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]/.exec(pdf.toString('latin1'));
      if (!match) throw Error('Prévia indisponível.');
      prepared = {pdf, range: match.slice(1).map(Number)};
    } else {
      const practice = JSON.parse(row.content)._practice === true;
      const number = practice ? null : db.reserve(row.id, row.owner);
      const pdf = await prescriptionPDF({id: row.id, tipo: row.type, numero: number, conteudo: JSON.parse(row.content),
        prescritor: JSON.parse(row.profile), emitidaEm: now(), fonts, previa: !number,
        codigo: JSON.parse(row.content)._accessCode,
        platform: {name: 'OpenPEP-Rx', url: new URL(origin).host, scheme:'http', signature:'VIDaaS local',access:false,documentURL:JSON.parse(row.content)._delivery || null}});
      prepared = await prepareSignature(pdf);
    }
    const practice = JSON.parse(row.content)._practice === true, number = db.document(row.id, row.owner).number;
    const ticket = randomBytes(32).toString('hex'), hash = sha(prepared.pdf);
    const signable = practice || Boolean(number);
    db.review(row.id, row.owner, Buffer.from(prepared.pdf), hash, ticket, now() + 600_000, signable);
    return {id: row.id, hash, ticket, tipo: row.type, environment: row.environment, numero: number, practice, signable, publicationRequested:Boolean(JSON.parse(row.content)._delivery), publicationOrigin:JSON.parse(row.content)._delivery ? new URL(JSON.parse(row.content)._delivery).origin : null};
  }
  return {
    state() {
      const p = db.profile(), config = db.config(), owner = p ? ownerOf(p) : '';
      const docs = db.documents(owner);
      return {local: true, configured: Boolean(p), prescritor: p || {nome: 'Configure o emitente', crm: '', uf: ''},
        publication:publications?.config()||{configured:false,origin:null}, environment: config.environment, estoque: db.stock(owner, config.environment), podeAssinar: true,
        emitente: db.setting('office:' + owner) || (docs.length ? JSON.parse(docs[0].content).emitente : null),
        receitas: docs.map(r => { const c = JSON.parse(r.content); return {id:r.id, tipo:r.type, estado:r.status, numero:r.number, hash:r.content_hash, paciente:c.paciente.nome,
          medicamento:items(c).map(m => m.nome).join(' + '), criadaEm:new Date(r.created_at).toISOString(), emitidaEm:r.signed_at ? new Date(r.signed_at).toISOString() : null, practice:c._practice === true}; })};
    },
    async draft(body, origin) {
      if (!UUID.test(body.id || '')) throw Error('Receita inválida.');
      const contact = body.contact === undefined ? undefined : normalizeContact(body.contact);
      checkMedicationTypes(body);
      const checked = prescriptionContent(body, now()); if (checked.error) throw Error(checked.error);
      const p = profile(), config = db.config(), practice = body.practice === true;
      const previous = db.document(body.id, ownerOf(p));
      const delivery=body.publish===true ? publications?.plan(body.id) : null;
      if(body.publish===true&&!delivery)throw Error('Configure o portal de documentos antes de gerar o link.');
      const content = {...checked.conteudo, _practice: practice, _delivery:delivery, _accessCode: previous ? JSON.parse(previous.content)._accessCode || String(randomInt(100000,1000000)) : String(randomInt(100000,1000000))};
      const row = db.saveDraft({id:body.id, owner:ownerOf(p), type:body.tipo, content, hash:sha(JSON.stringify(content)), profile:p, environment:config.environment, contact});
      return prepareReview(row, origin);
    },
    review(id, origin) { return prepareReview(document(id), origin); },
    access(body) {
      const id = fromShortId(body.id), row = id ? document(id) : null;
      if (!row || row.status !== 'assinada' || !/^\d{6}$/.test(body.codigo || '') || JSON.parse(row.content)._accessCode !== body.codigo) throw Error('Receita assinada não encontrada. Confira o código e o emitente local.');
      const p = JSON.parse(row.profile);
      return {tipo:row.type, numero:row.number, emitidaEm:new Date(row.signed_at).toISOString(), prescritor:{nome:p.nome,conselho:'CRM',inscricao:p.crm,uf:p.uf}, pdf:Buffer.from(row.signed_pdf).toString('base64')};
    },
    pdf(id, signed = false) {
      const row = document(id), pdf = signed ? row.signed_pdf : row.prepared;
      if (!pdf || (signed && row.status !== 'assinada')) throw Error('PDF indisponível.');
      return Buffer.from(pdf);
    },
    async term(id) { const row = document(id); if (!TERM_TYPES.includes(row.type)) throw Error('Este tipo não tem termo.'); return termoPDF({id, tipo:row.type, conteudo:JSON.parse(row.content), prescritor:JSON.parse(row.profile), emitidaEm:now(), fonts}); },
    async sign(body) {
      if (body.confirm !== true || !UUID.test(body.id || '') || !/^[a-f0-9]{64}$/.test(body.identity || '') || !/^[a-f0-9]{64}$/.test(body.ticket || '')) throw Error('Selecione o certificado, revise e confirme a receita.');
      const previous=document(body.id),wantsPublication=Boolean(JSON.parse(previous.content)._delivery);
      const contact=body.contact===undefined?undefined:normalizeContact(body.contact);
      if(wantsPublication&&body.publish!==true)throw Error('Confirme a publicação do PDF no portal antes de assinar.');
      const row = db.claim(body.id, ownerOf(profile()), body.ticket, body.hash, now());
      let signed;
      try {
        if(contact)db.saveContact(row.id,contact);
        const pdf = Buffer.from(row.prepared), match = /\/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]/.exec(pdf.toString('latin1'));
        const prepared = {pdf, range:match.slice(1).map(Number)};
        const result = await signer('sign', {pdf:pdf.toString('base64'), range:prepared.range, identity:body.identity});
        signed = checkedSignature(result, prepared);
        db.signed(row.id, signed, body.identity);
      } catch { db.failed(row.id); throw Error('A assinatura não foi confirmada. O documento e seu número foram preservados. Revise novamente antes de tentar outra vez.'); }
      // Publishing is independent of the completed signature. Never mark a signed document failed.
      let publication;
      try { publication=wantsPublication ? await publications.publish(row.id,signed,true) : publications?.info(row.id); }
      catch { publication={status:'pendente',error:'PDF assinado e salvo localmente. Abra Enviar documento para tentar publicar novamente.'}; }
      return {id:row.id, estado:'assinada', numero:row.number, practice:JSON.parse(row.content)._practice === true,publication};
    },
    sharing(id){const row=document(id);if(row.status!=='assinada')throw Error('Assine o documento antes de compartilhá-lo.');const content=JSON.parse(row.content);return {...(publications?.info(id)||{configured:false,status:'local'}),printedQR:Boolean(content._delivery),patient:content.paciente.nome,contact:db.contact(id)};},
    contact(body){document(body.id);return db.saveContact(body.id,normalizeContact(body.contact));},
    async publish(body){const row=document(body.id);if(row.status!=='assinada')throw Error('Assine o documento antes de publicá-lo.');if(!publications)throw Error('Portal de documentos indisponível.');return publications.publish(row.id,Buffer.from(row.signed_pdf),body.confirm);},
    async revoke(body){document(body.id);if(!publications)throw Error('Portal indisponível.');return publications.revoke(body.id,body.confirm);},
    cancel(body) { if (typeof body.motivo !== 'string' || body.motivo.trim().length < 3 || body.motivo.length > 200) throw Error('Informe o motivo do cancelamento.'); db.cancel(document(body.id).id, ownerOf(profile()), body.motivo.trim()); return {estado:'cancelada'}; },
  };
}
