// SPDX-FileCopyrightText: 2026 Carlos Pedrotti
// SPDX-License-Identifier: Apache-2.0
import {readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {merge, regimens, posologyFor} from './src/medication-assistance.mjs';
const load = async name => JSON.parse(await readFile(new URL(`data/${name}.json`, import.meta.url)));
const catalogs = await Promise.all(['controlados','retencao','rce','especiais'].map(n => load(`medicamentos-${n}`)));
const posologies = (await Promise.all(['retencao','rce','especiais'].map(n => load(`posologias-${n}`)))).flatMap(d => d.itens);
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const entries = merge(...catalogs).flatMap(s => s.apresentacoes.map(p => {
  const bula = s.classe ? posologyFor(posologies, s, p) : null;
  const plans = bula ? bula.regimes.map(r => ({label:r.rotulo, text:r.texto, quantity:r.quantidade ?? null, days:r.dias ?? null, tempo:r.tempo ?? null}))
    : p.tipo === 'RET' ? [] : regimens(s,p,{generic:!s.classe}).map(r => ({...r, days:30}));
  const entry = {substanceID:digest([s.nome,s.classe || s.lista]), name:s.nome, keys:s.keys,
    concentration:p.concentracao, form:p.forma, unit:p.unidade,
    quantity:/injet/i.test(p.forma) && !p.dispositivo ? null : p.quantidade,
    recipeType:p.tipo, category:s.rotulo, sales:p.vendas ?? 0, brands:p.marcas || [], dose:p.dose || '', device:p.dispositivo || '',
    plans, notes:bula?.orientacoes || [], calculator:bula?.pediatrico ?? null,
    sources:bula?.fontes || [], publication:'Cockpit RX · catálogo de 29–30/09/2026',
    origin:'19d91103d6e2140bb2ee84a1324dfc4a5bef5f83'};
  return {id:digest(entry), ...entry};
}));
if (new Set(entries.map(e=>e.id)).size !== entries.length) throw Error('Apresentações duplicadas.');
const bytes = Buffer.from(JSON.stringify({version:1, entries}));
const target = new URL('../../apps/macos/OpenPEP/Resources/CockpitPDF/medication-assistance.json',import.meta.url);
if (process.argv.includes('--check')) {
  if (!(await readFile(target)).equals(bytes)) throw Error('Catálogo assistido desatualizado; reconstrua o bundle.');
} else await writeFile(target,bytes);
