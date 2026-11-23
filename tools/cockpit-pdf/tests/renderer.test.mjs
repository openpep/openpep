// SPDX-FileCopyrightText: 2026 Carlos Pedrotti
// SPDX-License-Identifier: Apache-2.0
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {PDFDocument,PDFName} from 'pdf-lib';
import {render,prepareSignature} from '../src/renderer.mjs';
const root = new URL('../../../apps/macos/OpenPEP/Resources/CockpitPDF/',import.meta.url);
const fonts = Object.fromEntries(await Promise.all([['regular',400],['medium',500],['semibold',600],['bold',700]].map(async ([k,w]) => [k,await readFile(new URL(`inter-${w}-latin.ttf`,root))])));
export const input = type => ({id:'0198f5c4-0000-4000-8000-000000000001',date:Date.parse('2026-10-11T12:00:00Z'),
  number:'2610.1-00.0000001', prescriber:{nome:'Médico Sintético OpenPEP',crm:'000001',uf:'SP',cpf:'52998224725'},body:{tipo:type,
    emitente:{endereco:'Rua Sintética, 100, Sala de Ensaio',cidade:'São Paulo',uf:'SP',telefone:'(11) 0000-0000',especialidade:'Especialidade de ensaio',cadastro:'000001'},
    paciente:{nome:'Paciente Sintético OpenPEP',documento:'52998224725',endereco:'Rua Fictícia, 200',cidade:'São Paulo',uf:'SP',nascimento:'1990-01-01',sexo:'F',cid:'A30.5'},
    medicamento:{nome:'Medicamento de ensaio',concentracao:'10 mg',forma:'comprimido',quantidade:30,unidade:'comprimidos',posologia:'Posologia sintética para teste de diagramação. Sem orientação de uso clínico.',tempo:'30 dias',orientacoes:'Texto de ensaio.'}}});
for (const type of ['NRA','NRB','NRB2','RCE','RET','NRR','NRT']) test(`model ${type}, attached term and signature field preserve pages`,async()=>{
  const args = input(type);
  if (['RCE','RET'].includes(type)) { args.body.medicamentos = Array.from({length:3},(_,i)=>({...args.body.medicamento,nome:`Medicamento sintético ${i+1}`}));delete args.body.medicamento; }
  const result = await render(args,fonts), doc = await PDFDocument.load(result.pdf);
  assert.equal(doc.getPageCount(),1);assert.equal(doc.getCreator(),'OpenPEP');
  assert.equal(Boolean(result.term),['NRR','NRT'].includes(type));
  if(result.term) assert.ok((await PDFDocument.load(result.term)).getPageCount()>=1);
  const prepared = await prepareSignature(result.pdf);
  const parsed = await PDFDocument.load(prepared.pdf);
  assert.equal(parsed.getPageCount(),1);assert.ok(parsed.catalog.has(PDFName.of('AcroForm')));
  const [zero,start,end,tail]=prepared.range;assert.equal(zero,0);assert.equal(end+tail,prepared.pdf.length);
  assert.equal(prepared.pdf[start],60);assert.equal(prepared.pdf[end-1],62);
  await assert.rejects(prepareSignature(prepared.pdf),/não aceito/);
  if(process.env.OPENPEP_PDF_QA_DIR){
    await mkdir(process.env.OPENPEP_PDF_QA_DIR,{recursive:true});
    await writeFile(`${process.env.OPENPEP_PDF_QA_DIR}/${type}.pdf`,result.pdf);
    if(result.term)await writeFile(`${process.env.OPENPEP_PDF_QA_DIR}/${type}-termo.pdf`,result.term);
    if(type==='NRB')await writeFile(`${process.env.OPENPEP_PDF_QA_DIR}/prepared.pdf`,prepared.pdf);
  }
});
test('overflow and missing dosage refuse the PDF',async()=>{
  const args=input('NRB');args.body.medicamento.posologia='';await assert.rejects(render(args,fonts),/posologia/);
  args.body.medicamento.posologia='W'.repeat(590);await assert.rejects(render(args,fonts),/posologia-longa/);
});

test('only the explicit production environment drops the trial marks',async()=>{
  const trial = await render(input('NRR'),fonts), production = await render({...input('NRR'),environment:'production'},fonts);
  const unknown = await render({...input('NRR'),environment:'prd'},fonts);
  assert.equal(JSON.parse(trial.source).ambiente,'homologation');
  assert.equal(JSON.parse(unknown.source).ambiente,'homologation');
  assert.equal(JSON.parse(production.source).ambiente,'production');
  // The trial mark and watermark are extra drawing operations in both documents.
  assert.ok(production.pdf.length < trial.pdf.length);assert.ok(production.term.length < trial.term.length);
  assert.equal(unknown.pdf.length,trial.pdf.length);
});
