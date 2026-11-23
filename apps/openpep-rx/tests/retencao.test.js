import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {prescriptionContent} from '../api/receita-doc.mjs';
import {merge, posologyFor} from '../medicamentos.js';

// Retention prescriptions (SNCR "RET"): antimicrobials (IN 360/2025, art. 1º) and GLP-1 agonists (art. 2º).
const catalog = JSON.parse(await readFile(new URL('../data/medicamentos-retencao.json', import.meta.url), 'utf8'));
// The PDF text rules are the same for every prescription: checked through the notification validator.
const printable = (s, p, posologia = 'Conforme orientação médica.') => prescriptionContent({tipo: 'NRB',
  emitente: {endereco: 'Av. Exemplo, 100', cidade: 'São Paulo', uf: 'SP', telefone: ''},
  paciente: {nome: 'Paciente Fictício', documento: 'AB123456', endereco: 'Rua Fictícia, 10', cidade: 'São Paulo', uf: 'SP'},
  medicamento: {nome: s.nome, concentracao: p.concentracao, forma: p.forma, quantidade: p.quantidade, unidade: p.unidade, posologia}}).error;

test('retention catalog: every presentation prints as picked, with a class, a use and a join key', () => {
  assert.ok(catalog.substancias.length > 50);
  const keys = new Set();
  for (const s of catalog.substancias) {
    assert.ok(['antimicrobiano', 'glp1'].includes(s.classe), s.nome);
    assert.ok(['sistemico', 'oftalmico', 'otologico', 'topico', 'vaginal'].includes(s.uso), s.nome);
    assert.match(s.chave, /^[a-z0-9 ]+(\+[a-z0-9 ]+)*$/, s.nome);
    keys.add(s.chave);
    for (const p of s.apresentacoes) assert.equal(printable(s, p), undefined, `${s.nome} ${p.concentracao} ${p.forma}`);
  }
  // Every GLP-1 presentation says the dose per application; the injectables also say the device (pen, syringe, vial).
  for (const s of catalog.substancias.filter(s => s.classe === 'glp1')) for (const p of s.apresentacoes)
    assert.ok(p.dose && (p.via !== 'subcutânea' || p.dispositivo), `${s.nome} ${p.concentracao} ${p.unidade}`);
  for (const k of ['semaglutida', 'tirzepatida', 'liraglutida', 'dulaglutida', 'insulina degludeca+liraglutida', 'insulina glargina+lixisenatida', 'amoxicilina+clavulanato', 'azitromicina', 'cefalexina'])
    assert.ok(keys.has(k), k);
});

// Posologies and special instructions from the bulas (data/posologias-retencao.md lists the sources and doubts).
const posologies = JSON.parse(await readFile(new URL('../data/posologias-retencao.json', import.meta.url), 'utf8'));

test('every posology joins a catalog presentation and prints; quantities are whole packages', () => {
  // One key can span several catalog entries (the same substance for systemic, eye and ear use).
  const byKey = Map.groupBy(catalog.substancias, s => s.chave);
  let regimens = 0, calculators = 0;
  for (const item of posologies.itens) {
    const entries = byKey.get(item.chave) || [];
    assert.ok(entries.length, item.chave);
    const s = entries[0];
    for (const text of item.orientacoes) assert.equal(printable(s, s.apresentacoes[0], text), undefined, `${item.chave}: ${text}`);
    for (const p of item.apresentacoes) {
      assert.ok(entries.some(e => e.apresentacoes.some(c => c.concentracao === p.concentracao && c.forma === p.forma && (item.classe !== 'glp1' || c.dose === p.dose))), `${item.chave} ${p.concentracao} ${p.forma} ${p.dose || ''}`);
      const row = {...s.apresentacoes[0], concentracao: p.concentracao, forma: p.forma};
      for (const r of p.regimes) {
        regimens++;
        assert.ok(r.rotulo.length <= 40 && Number.isInteger(r.quantidade) && r.quantidade >= 1 && r.quantidade <= 999 && Number.isInteger(r.dias) && r.dias >= 1, `${item.chave}: ${r.rotulo}`);
        assert.equal(printable(s, {...row, quantidade: r.quantidade}, r.texto), undefined, `${item.chave}: ${r.texto}`);
      }
      for (const text of p.orientacoes) assert.equal(printable(s, row, text), undefined, `${item.chave}: ${text}`);
      if (p.pediatrico) {
        calculators++;
        const c = p.pediatrico;
        assert.ok(c.mgKgDia > 0 && c.dosesDia >= 1 && c.mgPorMl > 0 && c.maxMgDia > 0 && c.dias >= 1, item.chave);
        // The volume blank is filled by the calculator before printing.
        assert.ok(c.texto.includes('__'));assert.equal(printable(s, row, c.texto.replace('__', '5')), undefined, `${item.chave}: ${c.texto}`);
      }
    }
  }
  assert.ok(regimens > 200 && calculators > 10, `${regimens} regimens, ${calculators} calculators`);
});

test('the form finds the bula regimens of each presentation, on its own route and device', () => {
  const list = merge(null, catalog), find = (chave, test) => { const s = list.find(x => x.chave === chave && x.apresentacoes.some(test)); return [s, s.apresentacoes.find(test)]; };
  // Ceftriaxone: the IM kit keeps the gonorrhea regimen; the IV vial never shows intramuscular regimens.
  const [im, imPres] = find('ceftriaxona+lidocaina', p => p.via === 'intramuscular' && p.concentracao === '1 g + 10 mg/mL');
  assert.ok(posologyFor(posologies.itens, im, imPres).regimes.some(r => /500 mg de ceftriaxona por via intramuscular/.test(r.texto)));
  const [iv, ivPres] = find('ceftriaxona', p => p.via === 'intravenosa');
  assert.ok((posologyFor(posologies.itens, iv, ivPres)?.regimes || []).every(r => !/intramuscular/i.test(r.texto)));
  // GLP-1 by dose; Wegovy 7,2 mg carries the prescriber's condition in the regimen itself.
  const [sema, wegovy] = find('semaglutida', p => p.dose === '2,4 mg' && p.marcas.includes('Wegovy'));
  assert.ok(posologyFor(posologies.itens, sema, wegovy).regimes.some(r => /7,2 mg/.test(r.texto) && /pelo menos 4 semanas com 2,4 mg/.test(r.texto)));
  // Every retention presentation of the merged list is on the RET.
  assert.ok(list.every(s => s.apresentacoes.every(p => p.tipo === 'RET')));
});
