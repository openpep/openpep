// SPDX-FileCopyrightText: 2026 Carlos Pedrotti
// SPDX-License-Identifier: Apache-2.0
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {prescriptionContent} from '../src/receita-doc.mjs';
const catalog = JSON.parse(await readFile(new URL('../../../apps/macos/OpenPEP/Resources/CockpitPDF/medication-assistance.json', import.meta.url)));
const entries = catalog.entries;

test('presentation sentinels keep their type, exemption and device distinctions', () => {
  assert.equal(entries.length,768);
  const choices = key => entries.filter(e => e.keys.includes(key));
  for (const [key,type] of [['clonazepam','NRB'],['metilfenidato','NRA'],['sibutramina','NRB2'],['semaglutida','RET'],['isotretinoina','NRR'],['talidomida','NRT']]) {
    assert.ok(choices(key).length>0);assert.ok(choices(key).every(e=>e.recipeType===type),key);
  }
  assert.ok(choices('tramadol').some(e=>e.concentration==='50 mg' && e.recipeType==='RCE'));
  assert.ok(choices('semaglutida').some(e=>e.device && e.quantity>0));
  assert.ok(entries.filter(e=>/injet/.test(e.form) && !e.device).every(e=>e.quantity===null));
});

test('plans retain immediate-release and incomplete-dose safeguards', () => {
  const methyl = entries.filter(e=>e.keys.includes('metilfenidato'));
  assert.ok(methyl.some(e=>e.form==='comprimido' && e.plans.some(p=>p.text.includes('meio-dia'))));
  assert.ok(methyl.filter(e=>e.form.includes('liberação')).every(e=>e.plans.every(p=>!p.text.includes('meio-dia'))));
  const drops = entries.find(e=>e.keys.includes('clonazepam') && e.form==='solução oral');
  assert.ok(drops.plans.every(p=>p.text.includes('__')));
  assert.ok(entries.some(e=>e.recipeType==='RCE' && e.plans.length===0));
});

test('all materialized plans fit prescription field contracts with their provenance', () => {
  for (const entry of entries) for (const plan of entry.plans) {
    assert.ok(plan.text.length<=600);
    assert.ok(plan.quantity==null || Number.isInteger(plan.quantity) && plan.quantity>=1 && plan.quantity<=999);
    assert.equal(entry.origin,'19d91103d6e2140bb2ee84a1324dfc4a5bef5f83');
    const body={tipo:entry.recipeType,
      paciente:{nome:'Paciente Sintético',documento:'52998224725',endereco:'Rua Sintética, 100',cidade:'São Paulo',uf:'SP',nascimento:'1990-01-01',sexo:'F',cid:'A30.5'},
      emitente:{endereco:'Rua Sintética, 200',cidade:'São Paulo',uf:'SP',especialidade:'Especialidade de ensaio',cadastro:'000001'},
      medicamento:{nome:entry.name,concentracao:entry.concentration,forma:entry.form,unidade:entry.unit,quantidade:plan.quantity ?? entry.quantity ?? 1,
        posologia:plan.text.replaceAll('__','1'),tempo:plan.tempo || '30 dias'}};
    const result=prescriptionContent(body,Date.parse('2026-10-11T12:00:00Z'));
    assert.equal(result.error,undefined,`${entry.name} ${entry.concentration}: ${result.error}`);
  }
});
