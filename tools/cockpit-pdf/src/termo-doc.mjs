// SPDX-FileCopyrightText: 2026 Carlos Pedrotti
// SPDX-License-Identifier: Apache-2.0
// Termos que acompanham as notificações de retinoides (NRR) e de talidomida (NRT), para o médico e o paciente
// assinarem: texto dos anexos em data/termos.json, preenchido com os dados da receita. As linhas que só o consultório
// sabe (RG, teste de gravidez, anticoncepção, diagnóstico na NRR) ficam em branco para preencher à mão.
// NRR: Portaria SVS/MS 344/1998, Anexo XV (mulheres com menos de 55 anos) ou XVI (homens e mulheres a partir de 55).
// NRT: RDC 11/2011, Anexo V-B (mulheres com menos de 55 anos) ou V-A (mulheres a partir de 55 e homens).
import {PDFDocument, rgb} from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';
import termos from './termos.json' with {type: 'json'};
import {MODELS, pregnancyPictogram} from './receita-doc.mjs';

export const TERM_TYPES = ['NRR', 'NRT'];
// "Menores de 55 anos" / "maiores que 55": in the usual legal reading ("maior de 18" = 18 or more), 55 goes to XVI / V-A.
export const TERM_AGE = 55;
export const TERMS = termos.termos;

// Completed years on the issue date (São Paulo time).
export function yearsAt(nascimento, when) {
  const [y, m, d] = nascimento.split('-').map(Number), [ty, tm, td] = new Date(when).toLocaleDateString('en-CA', {timeZone: 'America/Sao_Paulo'}).split('-').map(Number);
  return ty - y - (tm < m || (tm === m && td < d) ? 1 : 0);
}
export function termKey(tipo, paciente, when) {
  if (!TERM_TYPES.includes(tipo)) return null;
  const young = paciente.sexo === 'F' && yearsAt(paciente.nascimento, when) < TERM_AGE;
  return tipo === 'NRR' ? (young ? 'NRR-XV' : 'NRR-XVI') : (young ? 'NRT-V-B' : 'NRT-V-A');
}
// The retinoid checked on the form, from the prescribed name ("isotretinoína" contains "tretinoína": checked first).
export function retinoid(nome) {
  const n = String(nome || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  return /isotretino/.test(n) ? 'isotretinoina' : /acitretin/.test(n) ? 'acitretina' : /tretino/.test(n) ? 'tretinoina' : null;
}

// Values for the {campo} marks; empty ones print as blank lines.
export function termValues({tipo, conteudo, prescritor, emitidaEm}) {
  const p = conteudo.paciente, r = conteudo.responsavel;
  const values = {
    medico: prescritor.nome, crm: prescritor.crm, ufcrm: prescritor.uf, crmuf: `${prescritor.crm}/${prescritor.uf}`,
    paciente: p.nome, idade: String(yearsAt(p.nascimento, emitidaEm)), endereco: p.endereco, cidade: p.cidade, uf: p.uf,
    telefone: p.telefone || '', diagnostico: tipo === 'NRT' && p.cid ? `CID ${p.cid}` : '',
    responsavel: r?.nome || '', pacienteResponsavel: r ? p.nome : '',
    data: new Date(emitidaEm).toLocaleDateString('pt-BR', {timeZone: 'America/Sao_Paulo'}),
  };
  const marks = new Set([p.sexo, tipo === 'NRR' ? retinoid(conteudo.medicamento?.nome) : null].filter(Boolean));
  return {values, marks};
}
export const FIELDS = ['medico', 'crm', 'ufcrm', 'crmuf', 'paciente', 'idade', 'endereco', 'cidade', 'uf', 'telefone', 'diagnostico', 'responsavel', 'pacienteResponsavel', 'data'];
export const MARKS = ['isotretinoina', 'tretinoina', 'acitretina', 'M', 'F', '-'];
// {campo} {campo:*} {_} {_:90} {_*} {x:chave}
export const MARK = /\{(?:(_)(?::(\d+)|(\*))?|x:([A-Za-z-]+)|([A-Za-z]+)(:\*)?)\}/g;

const INK = rgb(0.08, 0.12, 0.16), LABEL = rgb(0.35, 0.41, 0.46), LINE = rgb(0.16, 0.2, 0.24);
const W = 595, H = 842, LEFT = 50, RIGHT = 545, TOP = 44, BOTTOM = 790;

// numero null = before issue (preview). The physician's CPF is not on the forms: prescritor = {nome, crm, uf}.
export async function termoPDF({tipo, numero, conteudo, prescritor, emitidaEm, fonts, previa = true}) {
  const key = termKey(tipo, conteudo.paciente, emitidaEm);
  if (!key) throw Error('tipo sem termo');
  const term = TERMS[key], {values, marks} = termValues({tipo, conteudo, prescritor, emitidaEm});
  const doc = await PDFDocument.create();
  doc.registerFontkit(fontkit);
  doc.setTitle(`${term.anexo} — ${conteudo.paciente.nome}`);
  doc.setAuthor(prescritor.nome);doc.setCreator('OpenPEP');doc.setProducer('OpenPEP');
  doc.setCreationDate(new Date(emitidaEm));doc.setModificationDate(new Date(emitidaEm));
  const [regular, medium, semibold, bold] = await Promise.all(['regular', 'medium', 'semibold', 'bold'].map(k => doc.embedFont(fonts[k])));
  const width = (s, size, font) => font.widthOfTextAtSize(s, size);
  const wrap = (s, max, size, font) => {
    const lines = [];let line = '';
    for (const word of s.split(' ')) { const next = line ? line + ' ' + word : word; if (line && width(next, size, font) > max) { lines.push(line);line = word; } else line = next; }
    return [...lines, line];
  };

  // Text with marks -> atoms: words (plain or filled in), blank lines of a width or to the end of the line, check boxes.
  // space: preceded by a space in the text; group: filled words of one value share the underline across their spaces.
  function atoms(text, font) {
    const out = [];let group = 0;
    for (const [i, line] of text.split('\n').entries()) {
      if (i) out.push({kind: 'break'});
      let last = 0, space = false;
      const words = s => { for (const [j, w] of s.split(' ').entries()) { if (j) space = true; if (w) { out.push({kind: 'word', s: w, font, space});space = false; } } };
      for (const m of line.matchAll(MARK)) {
        words(line.slice(last, m.index));last = m.index + m[0].length;
        const [, blank, bw, brest, box, field, frest] = m;
        if (blank) out.push({kind: 'blank', w: bw ? +bw : brest ? null : 100, space});
        else if (box) out.push({kind: 'box', checked: marks.has(box), space});
        else {
          const v = values[field] ?? '';
          if (!v) out.push({kind: 'blank', w: frest ? null : 120, space});
          else { group++;for (const [j, w] of (/^[\d\s()+./-]+$/.test(v) ? [v] : v.split(' ')).entries()) out.push({kind: 'word', s: w, font: semibold, fill: group, space: j ? true : space}); if (frest) out.push({kind: 'blank', w: null, space: true, fill: group}); }
        }
        space = false;
      }
      words(line.slice(last));
    }
    return out;
  }
  // Lays atoms out in [x, x + w]: returns lines of positioned atoms.
  function flow(list, x, w, size) {
    const sp = width(' ', size, regular), box = size * 0.78, lines = [[]];let cx = x;
    for (const a of list) {
      if (a.kind === 'break') { lines.push([]);cx = x;continue; }
      const line = lines.at(-1), gap = line.length && a.space ? sp : 0;
      if (a.kind === 'blank' && a.w === null) {
        // To the end of the line, at least 60 pt wide.
        if (line.length && x + w - (cx + gap) < 60) { lines.push([]);cx = x; }
        const at = cx + (lines.at(-1).length && a.space ? sp : 0);
        lines.at(-1).push({...a, x: at, w: x + w - at, gapFrom: cx});cx = x + w;continue;
      }
      const aw = a.kind === 'word' ? width(a.s, size, a.font) : a.kind === 'box' ? box + 1.5 : a.w;
      if (line.length && cx + gap + aw > x + w) { lines.push([{...a, x, w: aw}]);cx = x + aw;continue; }
      lines.at(-1).push({...a, x: cx + gap, w: aw, gapFrom: cx});cx += gap + aw;
    }
    return lines;
  }

  // Lays the blocks out from s.t, opening pages as needed; s.measure only adds up the height.
  function run(blocks, size, s) {
    const lead = size * 1.4;
    const room = need => { if (!s.measure && s.t + need > BOTTOM) { s.pages.push([]);s.t = TOP + 6; } };
    const put = (lines, sz = size) => { for (const l of lines) { room(lead);s.pages.at(-1).push({line: l, t: s.t + sz, size: sz});s.t += lead; } };
    for (const [i, b] of blocks.entries()) {
      if (b.h) {
        // A section (up to the next heading) that does not fit the rest of the page, but fits a page, starts on the next.
        if (!s.measure) {
          const next = blocks.findIndex((x, j) => j > i && x.h), m = {t: 0, pages: [[]], measure: true};
          run(blocks.slice(i, next < 0 ? undefined : next), size, m);
          if (s.t + m.t > BOTTOM && m.t < BOTTOM - TOP - 6) { s.pages.push([]);s.t = TOP + 6 - size * 0.7; }
        }
        s.t += size * 0.7;room(lead * 2);put(flow(atoms(b.h, bold), LEFT, RIGHT - LEFT, size));s.t += size * 0.15;
      } else if (b.n) {
        const lines = flow(atoms(b.t, regular), LEFT + 16, RIGHT - LEFT - 16, size);
        room(lead * Math.min(lines.length, 2));
        s.pages.at(-1).push({line: [{kind: 'word', s: `${b.n}.`, font: semibold, x: LEFT, w: 0}], t: s.t + size, size});
        put(lines);s.t += size * 0.45;
      } else if (b.p) { put(flow(atoms(b.p, regular), LEFT, RIGHT - LEFT, size));s.t += size * 0.45; }
      else if (b.assinatura) {
        // Room above the line to sign by hand; columns side by side (the first, the signature, is the widest).
        const cols = [b.assinatura].flat(), shares = {1: [1], 2: [0.66, 0.34], 3: [0.56, 0.24, 0.2]}[cols.length], gap = 14;
        s.t += size * 1.3;
        let x = LEFT;const laid = cols.map((c, i) => { const w = (RIGHT - LEFT - gap * (cols.length - 1)) * shares[i], l = flow(atoms(c, regular), x, w, size);x += w + gap;return l; });
        const rows = Math.max(...laid.map(l => l.length));room(lead * rows);
        for (let r = 0; r < rows; r++) { s.pages.at(-1).push({line: laid.flatMap(l => l[r] || []), t: s.t + size, size});s.t += lead; }
        s.t += size * 0.45;
      } else if (b.vias) { s.t += size * 0.6;put(flow(atoms(b.vias, semibold), LEFT, RIGHT - LEFT, size - 1), size - 1); }
    }
    return s.pages;
  }
  const layout = size => run([...term.blocos, {vias: term.vias}], size, {t: header(null), pages: [[]]});
  // Heading of the first page; with page = null only measures.
  function header(page) {
    const art = term.pictograma ? 92 : 0, tw = RIGHT - LEFT - art;
    const kicker = term.anexo.toUpperCase();
    if (page) page.drawText(kicker, {x: LEFT, y: H - TOP, size: 7.5, font: semibold, color: LABEL});
    let t = TOP + 16;
    for (const l of wrap(term.titulo, tw, 11, bold)) { if (page) page.drawText(l, {x: LEFT, y: H - t, size: 11, font: bold, color: INK});t += 14; }
    if (term.instrucao) { t += 1;for (const l of wrap(term.instrucao, tw, 8, regular)) { if (page) page.drawText(l, {x: LEFT, y: H - t, size: 8, font: regular, color: LABEL});t += 10.5; } }
    if (art && page) {
      const cx = RIGHT - art / 2 + 4;
      pregnancyPictogram(page, cx, TOP + 16, 0.34);
      const caption = (s, t, size, font) => page.drawText(s, {x: cx - width(s, size, font) / 2, y: H - t, size, font, color: INK});
      caption('GRAVIDEZ PROIBIDA!', TOP + 42, 6.8, bold);
      wrap('Risco de graves defeitos na face, nas orelhas, no coração e no sistema nervoso do feto', art - 6, 5.6, semibold).forEach((l, i) => caption(l, TOP + 50 + i * 7, 5.6, semibold));
    }
    return Math.max(t, art ? TOP + 72 : 0) + 8;
  }

  // The largest body size that fits one page; a longer form (V-B) goes over two at 9.5 pt, split between sections.
  let pages;
  for (const size of [9.5, 9.25, 9, 8.75, 8.5]) { pages = layout(size); if (pages.length === 1) break; }
  if (pages.length > 1) pages = layout(9.5);
  const reference = `${MODELS[tipo].name} ${numero ? `nº ${numero}` : '(prévia, antes do número)'} · ${conteudo.paciente.nome}`;
  for (const [i, ops] of pages.entries()) {
    const page = doc.addPage([W, H]);
    if (i === 0) header(page);
    for (const {line, t, size} of ops) {
      const y = H - t, box = size * 0.78;
      for (const [j, a] of line.entries()) {
        if (a.kind === 'word') {
          page.drawText(a.s, {x: a.x, y, size, font: a.font, color: INK});
          if (a.fill) {
            // Filled-in values keep the form's line under them, across the spaces of one value.
            const prev = line[j - 1], from = prev?.fill === a.fill ? a.gapFrom : a.x;
            page.drawLine({start: {x: from, y: y - 2}, end: {x: a.x + a.w, y: y - 2}, thickness: 0.5, color: LINE});
          }
        } else if (a.kind === 'blank') {
          const prev = line[j - 1], from = a.fill && prev?.fill === a.fill ? a.gapFrom : a.x;
          page.drawLine({start: {x: from, y: y - 2}, end: {x: a.x + a.w, y: y - 2}, thickness: 0.5, color: LINE});
        } else if (a.kind === 'box') {
          page.drawRectangle({x: a.x, y: y - 1, width: box, height: box, borderColor: LINE, borderWidth: 0.7});
          if (a.checked) for (const [s, e] of [[[0, 0], [1, 1]], [[0, 1], [1, 0]]]) page.drawLine({start: {x: a.x + 1.4 + s[0] * (box - 2.8), y: y - 1 + 1.4 + s[1] * (box - 2.8)}, end: {x: a.x + 1.4 + e[0] * (box - 2.8), y: y - 1 + 1.4 + e[1] * (box - 2.8)}, thickness: 1.1, color: INK});
        }
      }
    }
    // Footer: which notification this form goes with; the page count when it runs over one page.
    page.drawLine({start: {x: LEFT, y: H - 808}, end: {x: RIGHT, y: H - 808}, thickness: 0.4, color: LABEL});
    const foot = wrap(reference, RIGHT - LEFT - 70, 7, regular)[0];
    page.drawText(foot, {x: LEFT, y: H - 819, size: 7, font: regular, color: LABEL});
    const count = pages.length > 1 ? `página ${i + 1} de ${pages.length}` : term.anexo.split(' · ')[1];
    page.drawText(count, {x: RIGHT - width(count, 7, regular), y: H - 819, size: 7, font: regular, color: LABEL});
    if (previa) page.drawText('ENSAIO SINTÉTICO · SEM VALIDADE CLÍNICA', {x: LEFT, y: H - 833, size: 7, font: semibold, color: rgb(0.65, 0.1, 0.15)});
  }
  return doc.save({useObjectStreams: false});
}
