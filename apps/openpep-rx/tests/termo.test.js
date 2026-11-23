import test from 'node:test';
import assert from 'node:assert/strict';
import {PDFDocument} from 'pdf-lib';
import {termoPDF, termKey, termValues, retinoid, yearsAt, TERMS, FIELDS, MARKS, MARK, TERM_AGE} from '../api/termo-doc.mjs';
import {loadFonts} from '../api/receita.mjs';

// Consent forms of the NRR (Portaria 344/1998, Anexos XV/XVI) and NRT (RDC 11/2011, Anexos V-A/V-B).
const FONTS = await loadFonts(new URL('../assets/fonts/pdf/', import.meta.url));
const WHEN = Date.parse('2026-09-30T13:00:00Z');
const prescritor = {nome: 'Profissional Fictício', crm: '123456', uf: 'SP'};
const patient = over => ({nome: 'Paciente Fictícia da Silva', documento: '52998224725', endereco: 'Rua Fictícia, 10', cidade: 'São Paulo', uf: 'SP', sexo: 'F', nascimento: '1998-03-12', ...over});

test('every mark in the form texts is a known field, blank or check box', () => {
  assert.deepEqual(Object.keys(TERMS).sort(), ['NRR-XV', 'NRR-XVI', 'NRT-V-A', 'NRT-V-B']);
  for (const [key, term] of Object.entries(TERMS)) {
    const texts = [...term.blocos.flatMap(b => [b.t, b.p, b.h, b.assinatura].flat().filter(Boolean)), term.vias];
    for (const text of texts) {
      for (const m of text.matchAll(MARK)) {
        const [, blank, , , box, field] = m;
        assert.ok(blank || MARKS.includes(box) || FIELDS.includes(field), `${key}: ${m[0]}`);
      }
      // Nothing that looks like a mark is left unparsed.
      assert.doesNotMatch(text.replace(MARK, ''), /[{}]/, `${key}: ${text}`);
    }
    assert.ok(term.blocos.some(b => b.assinatura), key);
  }
});

test('the form follows sex and age on the issue date: women under 55 get XV / V-B; men and women from 55, XVI / V-A', () => {
  const at55 = '1971-09-30', eve = '1971-10-01';
  assert.equal(yearsAt(at55, WHEN), TERM_AGE);assert.equal(yearsAt(eve, WHEN), TERM_AGE - 1);
  for (const [sexo, nascimento, nrr, nrt] of [['F', eve, 'NRR-XV', 'NRT-V-B'], ['F', at55, 'NRR-XVI', 'NRT-V-A'], ['M', '2005-01-01', 'NRR-XVI', 'NRT-V-A'], ['F', '2010-06-01', 'NRR-XV', 'NRT-V-B']]) {
    assert.equal(termKey('NRR', {sexo, nascimento}, WHEN), nrr);assert.equal(termKey('NRT', {sexo, nascimento}, WHEN), nrt);
  }
  assert.equal(termKey('RCE', {sexo: 'F', nascimento: eve}, WHEN), null);
});

test('the checked retinoid comes from the prescribed name; missing data prints as blank lines, never the CPF', () => {
  assert.equal(retinoid('Isotretinoína'), 'isotretinoina');assert.equal(retinoid('Tretinoína'), 'tretinoina');
  assert.equal(retinoid('ACITRETINA'), 'acitretina');assert.equal(retinoid('Talidomida'), null);
  const nrr = termValues({tipo: 'NRR', conteudo: {paciente: patient(), medicamento: {nome: 'Isotretinoína'}}, prescritor, emitidaEm: WHEN});
  assert.deepEqual([...nrr.marks].sort(), ['F', 'isotretinoina']);
  assert.equal(nrr.values.idade, '28');assert.equal(nrr.values.telefone, '');assert.equal(nrr.values.diagnostico, '');assert.equal(nrr.values.responsavel, '');
  assert.equal(nrr.values.crmuf, '123456/SP');assert.equal(nrr.values.data, '30/09/2026');
  assert.ok(!Object.values(nrr.values).includes('52998224725'));
  const nrt = termValues({tipo: 'NRT', conteudo: {paciente: patient({sexo: 'M', cid: 'A30.5', telefone: '(11) 98765-4321'}), medicamento: {nome: 'Talidomida'}, responsavel: {nome: 'Responsável Fictício'}}, prescritor, emitidaEm: WHEN});
  assert.deepEqual([...nrt.marks], ['M']);assert.equal(nrt.values.diagnostico, 'CID A30.5');
  assert.equal(nrt.values.responsavel, 'Responsável Fictício');assert.equal(nrt.values.pacienteResponsavel, 'Paciente Fictícia da Silva');
});

test('each of the four forms renders; V-B, the longest, goes over two pages', async () => {
  for (const [tipo, over, medicamento, key, pages] of [
    ['NRR', {}, 'Isotretinoína', 'Anexo XV', 1], ['NRR', {sexo: 'M'}, 'Acitretina', 'Anexo XVI', 1],
    ['NRT', {sexo: 'M', cid: 'A30.5'}, 'Talidomida', 'Anexo V-A', 1], ['NRT', {cid: 'M32.1'}, 'Talidomida', 'Anexo V-B', 2]]) {
    const conteudo = {emitente: {}, paciente: patient({...over, nome: 'Paciente Com Um Nome Muito Longo Para Caber Numa Linha Só de Sobrenomes Fictícios'}), medicamento: {nome: medicamento}};
    const pdf = await PDFDocument.load(await termoPDF({tipo, numero: null, conteudo, prescritor, emitidaEm: WHEN, fonts: FONTS}));
    assert.match(pdf.getTitle(), new RegExp(`${key} — (?!.*HOMOLOGAÇÃO)`));assert.equal(pdf.getPageCount(), pages, key);
  }
});
