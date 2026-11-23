import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {prescriptionContent} from '../api/receita-doc.mjs';
import {merge, posologyFor} from '../medicamentos.js';

// Receita de Controle Especial: lists C1 and C5 and the A/B adendo exemptions (RDC 1.036/2026), ranked by SNGPC code 1.
const read = async name => JSON.parse(await readFile(new URL(`../data/${name}`, import.meta.url), 'utf8'));
const [rce, nr, ret, pos] = await Promise.all([read('medicamentos-rce.json'), read('medicamentos-controlados.json'), read('medicamentos-retencao.json'), read('posologias-rce.json')]);
const printable = (s, p) => prescriptionContent({tipo: 'RCE',
  emitente: {endereco: 'Av. Exemplo, 100', cidade: 'São Paulo', uf: 'SP', telefone: ''},
  paciente: {nome: 'Paciente Fictício', documento: 'AB123456', endereco: 'Rua Fictícia, 10', cidade: 'São Paulo', uf: 'SP'},
  medicamento: {nome: s.nome, concentracao: p.concentracao, forma: p.forma, quantidade: p.quantidade, unidade: p.unidade, posologia: 'Conforme orientação médica.'}}).error;

test('RCE catalog: every presentation prints as an RCE; lists and sentinels are right', () => {
  assert.ok(rce.substancias.length > 80);
  for (const s of rce.substancias) {
    assert.match(s.classe, /^(C1|C5|A1-adendo|A2-adendo|A3-adendo|B1-adendo)$/, s.nome);
    for (const p of s.apresentacoes) assert.equal(printable(s, p), undefined, `${s.nome} ${p.concentracao} ${p.forma}`);
  }
  const listOf = base => rce.substancias.find(s => s.busca.includes(base))?.classe;
  for (const [base, classe] of [['quetiapina', 'C1'], ['sertralina', 'C1'], ['pregabalina', 'C1'], ['tramadol', 'A2-adendo'], ['codeina', 'A2-adendo'], ['fenobarbital', 'B1-adendo']])
    assert.equal(listOf(base), classe, base);
  // Notification-only substances never appear here.
  for (const base of ['clonazepam', 'zolpidem', 'metilfenidato', 'morfina']) assert.equal(listOf(base), undefined, base);
});

test('the form search shows each product once: RCE items leave the notification catalog when the RCE catalog loads', () => {
  const list = merge(nr, ret, rce), tramadol = list.filter(s => s.keys.includes('tramadol') && !s.keys.includes('paracetamol') && !s.keys.includes('diclofenaco'));
  assert.equal(tramadol.length, 1);assert.ok(tramadol[0].apresentacoes.every(p => p.tipo === 'RCE'));
  assert.ok(list.filter(s => s.keys.includes('clonazepam')).every(s => s.apresentacoes.every(p => p.tipo === 'NRB')));
  assert.ok(!list.some(s => s.apresentacoes.some(p => p.receita === 'RCE' && s.lista)), 'no RCE-marked notification row left');
  // Without the RCE catalog, the notification rows marked RCE still go on RCE.
  assert.ok(merge(nr, ret, null).some(s => s.lista && s.apresentacoes.some(p => p.tipo === 'RCE')));
});

// Bula posologies for the RCE (data/posologias-rce.md lists sources, legal limits and doubts).
const withText = (s, p, posologia) => prescriptionContent({tipo: 'RCE',
  emitente: {endereco: 'Av. Exemplo, 100', cidade: 'São Paulo', uf: 'SP', telefone: ''},
  paciente: {nome: 'Paciente Fictício', documento: 'AB123456', endereco: 'Rua Fictícia, 10', cidade: 'São Paulo', uf: 'SP'},
  medicamento: {nome: s.nome, concentracao: p.concentracao, forma: p.forma, quantidade: p.quantidade, unidade: p.unidade, posologia}}).error;
test('RCE posologies join the catalog, print, and keep the Portaria 344 quantity limits', () => {
  const byKey = Map.groupBy(rce.substancias, s => s.chave);
  let regimens = 0;
  for (const item of pos.itens) {
    const entries = byKey.get(item.chave) || [];assert.ok(entries.length, item.chave);
    for (const p of item.apresentacoes) {
      const entry = entries.find(e => e.apresentacoes.some(c => c.concentracao === p.concentracao && c.forma === p.forma));
      assert.ok(entry, `${item.chave} ${p.concentracao} ${p.forma}`);
      const row = entry.apresentacoes.find(c => c.concentracao === p.concentracao && c.forma === p.forma);
      for (const r of p.regimes) {
        regimens++;
        assert.equal(withText(entry, row, r.texto), undefined, `${item.chave}: ${r.texto}`);
        assert.ok(Number.isInteger(r.quantidade) && r.quantidade >= 1 && r.quantidade <= 999 && r.rotulo.length <= 40, r.rotulo);
        // Art. 59: up to 60 days of treatment, or 5 ampoules for injectables (their interval regimens run longer).
        if (/injet/.test(p.forma)) assert.ok(r.quantidade <= 5, `${item.chave}: ${r.rotulo}`);
        else assert.ok(r.dias <= 60 || /carbamazepina|lamotrigina|topiramato|levetiracetam|valpro|fenobarbital|perampanel|gabapentina|pregabalina/.test(item.chave), `${item.chave}: ${r.rotulo} ${r.dias} dias`);
      }
      for (const text of [...item.orientacoes, ...p.orientacoes]) assert.equal(withText(entry, row, text), undefined, `${item.chave}: ${text}`);
      if (p.pediatrico) assert.equal(withText(entry, row, p.pediatrico.texto.replace('__', '5')), undefined, item.chave);
    }
  }
  assert.ok(regimens > 300, String(regimens));
  // The form finds them: sertraline 50 mg gets its bula regimens.
  const list = merge(nr, ret, rce), sertralina = list.find(s => s.chave === 'sertralina'), p50 = sertralina.apresentacoes.find(p => p.concentracao === '50 mg');
  assert.ok(posologyFor(pos.itens, sertralina, p50).regimes.length >= 1);
});

test('special notifications catalog: retinoids go on NRR, thalidomide on NRT, and every presentation prints', async () => {
  const special = await read('medicamentos-especiais.json');
  for (const s of special.substancias) {
    assert.equal(s.tipo, {C2: 'NRR', C3: 'NRT'}[s.classe], s.nome);
    for (const p of s.apresentacoes) assert.equal(printable(s, p), undefined, `${s.nome} ${p.concentracao}`);
  }
  const list = merge(nr, ret, rce, special);
  assert.ok(list.find(s => s.keys.includes('isotretinoina')).apresentacoes.every(p => p.tipo === 'NRR'));
  assert.ok(list.find(s => s.keys.includes('talidomida')).apresentacoes.every(p => p.tipo === 'NRT'));
});

test('special notifications posologies join their catalog, print, and stay within 30 days of treatment', async () => {
  const [special, pos] = await Promise.all([read('medicamentos-especiais.json'), read('posologias-especiais.json')]);
  const bySubstance = new Map(special.substancias.map(s => [s.chave, s]));
  for (const item of pos.itens) {
    const s = bySubstance.get(item.chave);assert.ok(s, item.chave);
    for (const p of item.apresentacoes) {
      const row = s.apresentacoes.find(c => c.concentracao === p.concentracao && c.forma === p.forma);assert.ok(row, `${item.chave} ${p.concentracao}`);
      for (const r of p.regimes) {
        assert.ok(r.dias <= 30 && Number.isInteger(r.quantidade), `${item.chave}: ${r.rotulo}`);
        assert.equal(prescriptionContent({tipo: 'RCE', emitente: {endereco: 'Av. Exemplo, 100', cidade: 'São Paulo', uf: 'SP', telefone: ''},
          paciente: {nome: 'Paciente Fictício', documento: 'AB123456', endereco: 'Rua Fictícia, 10', cidade: 'São Paulo', uf: 'SP'},
          medicamento: {nome: s.nome, concentracao: row.concentracao, forma: row.forma, quantidade: r.quantidade, unidade: row.unidade, posologia: r.texto}}).error, undefined, r.texto);
      }
    }
  }
});
