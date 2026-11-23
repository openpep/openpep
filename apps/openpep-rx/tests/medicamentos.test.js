import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {prescriptionContent} from '../api/receita-doc.mjs';
import {indexed, regimens, DAYS} from '../medicamentos.js';

const catalog = JSON.parse(await readFile(new URL('../data/medicamentos-controlados.json', import.meta.url), 'utf8'));
const TYPE = {A1: 'NRA', A2: 'NRA', A3: 'NRA', B1: 'NRB', B2: 'NRB2'};
const body = (s, p, posologia = 'Tomar 1 comprimido por via oral à noite.') => ({tipo: s.tipo,
  emitente: {endereco: 'Av. Exemplo, 100', cidade: 'São Paulo', uf: 'SP', telefone: ''},
  paciente: {nome: 'Paciente Fictício', documento: 'AB123456', endereco: 'Rua Fictícia, 10', cidade: 'São Paulo', uf: 'SP'},
  medicamento: {nome: s.nome, concentracao: p.concentracao, forma: p.forma, quantidade: p.quantidade, unidade: p.unidade, posologia}});

test('every catalog entry is a valid prescription as picked: printable text, field limits, type of its list', () => {
  assert.ok(catalog.substancias.length > 20);
  for (const s of catalog.substancias) {
    assert.equal(s.tipo, TYPE[s.lista], s.nome);
    assert.ok(s.apresentacoes.length >= 1 && s.apresentacoes.length <= 6, s.nome);
    for (const p of s.apresentacoes) {
      const r = prescriptionContent(body(s, p));
      assert.equal(r.error, undefined, `${s.nome} ${p.concentracao} ${p.forma}: ${r.error}`);
    }
  }
});

test('catalog places the sentinel substances on the right lists and ranks by dispensations', () => {
  const find = base => catalog.substancias.find(s => s.busca.includes(base));
  for (const [base, lista] of [['zolpidem', 'B1'], ['clonazepam', 'B1'], ['alprazolam', 'B1'], ['metilfenidato', 'A3'], ['lisdexanfetamina', 'A3'], ['morfina', 'A1'], ['oxicodona', 'A1'], ['metadona', 'A1']])
    assert.equal(find(base)?.lista, lista, base);
  for (const t of ['NRA', 'NRB', 'NRB2']) {
    const sales = catalog.substancias.filter(s => s.tipo === t).map(s => s.vendas);
    assert.deepEqual(sales, [...sales].sort((a, b) => b - a), t);
  }
});

test('regimen chips give printable posologies and whole quantities for the picked presentation', () => {
  const at = base => indexed(catalog.substancias.find(s => s.busca.includes(base)));
  const zolpidem = at('zolpidem'), clonazepam = at('clonazepam'), metilfenidato = at('metilfenidato');
  assert.ok(regimens(zolpidem, zolpidem.apresentacoes[0]).every(r => /ao deitar/.test(r.text)));
  assert.ok(regimens(metilfenidato, metilfenidato.apresentacoes[0]).some(r => /pela manhã/.test(r.text)));
  // Twice a day only for immediate-release methylphenidate; lisdexamfetamine and the anorectics are once daily.
  const twice = (s, p) => regimens(s, p).some(r => /meio-dia/.test(r.text));
  assert.ok(twice(metilfenidato, metilfenidato.apresentacoes.find(p => !/liberação/.test(p.forma))));
  assert.ok(metilfenidato.apresentacoes.filter(p => /liberação/.test(p.forma)).every(p => !twice(metilfenidato, p)));
  for (const base of ['lisdexanfetamina', 'sibutramina']) assert.ok(at(base).apresentacoes.every(p => !twice(at(base), p)), base);
  const plain = clonazepam.apresentacoes.find(p => p.forma === 'comprimido');
  assert.deepEqual(regimens(clonazepam, plain).map(r => r.quantity), [DAYS, 2 * DAYS, 3 * DAYS, DAYS / 2]);
  for (const s of catalog.substancias.map(indexed)) for (const p of s.apresentacoes) for (const r of regimens(s, p)) {
    assert.ok(r.quantity === undefined || (Number.isInteger(r.quantity) && r.quantity >= 1 && r.quantity <= 999), r.label);
    // Drops keep a blank for the number of drops; everything else must already be a valid prescription.
    if (!r.text.includes('__')) assert.equal(prescriptionContent(body(s, p, r.text)).error, undefined, `${s.nome}: ${r.text}`);
  }
});

test('the build publishes the catalog and the search script', async () => {
  const published = JSON.parse(await readFile(new URL('../.vercel/output/static/medicamentos.json', import.meta.url), 'utf8'));
  assert.deepEqual(published, catalog);
  await readFile(new URL('../.vercel/output/static/medicamentos.js', import.meta.url));
});

test('adendo exemptions confirmed by the user go on the Receita de Controle Especial, not on a notification', () => {
  const at = base => catalog.substancias.filter(s => s.busca.includes(base));
  const rce = s => s.apresentacoes.every(p => p.receita === 'RCE');
  // Tramadol up to 100 mg, alone or associated; codeine + paracetamol up to 30 mg; buprenorphine patches.
  assert.ok(at('tramadol').length >= 2 && at('tramadol').every(rce));
  assert.ok(at('buprenorfina').every(rce));
  const codeinaParacetamol = at('codeina').find(s => s.busca.includes('paracetamol'));assert.ok(rce(codeinaParacetamol));
  // 30/09/2026: codeine up to 100 mg alone or combined, and extended-release oxycodone up to 40 mg (alone or with
  // naloxone) also go on RCE, as the adendos say.
  for (const s of [...at('codeina'), ...at('oxicodona')]) assert.ok(rce(s), s.nome);
});
