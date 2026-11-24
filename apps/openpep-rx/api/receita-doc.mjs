// Notificação de Receita eletrônica: validação do conteúdo e PDF (docs/SNCR-NUMEROS-FLUXO.md, seções 5 e 12).
// O PDF segue o modelo da Anvisa (references/anvisa-modelos/), que não admite customização: mesmos blocos,
// rótulos, ordem, faixa colorida do tipo e rodapé. Os ajustes são só de encaixe e tipografia dos dados.
// Uma substância por notificação (Portaria SVS/MS 344/1998). Sem marca de teste: os testes seguem o documento de produção.
import {createHash} from 'node:crypto';
import {PDFDocument, rgb, degrees} from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';
import qrcode from 'qrcode/lib/core/qrcode.js';
import {normalizedCPF} from './entry-oidc.mjs';
import {HOST} from './origin.mjs';

// A, B e B2 compartilham o modelo. Retinoides e talidomida têm campos próprios (sexo, especialidade, advertências).
// RCE segue o modelo eletrônico da Anvisa (sem faixa colorida). A RET (Receita Sujeita a Retenção: antimicrobianos,
// RDC 471/2021, e agonistas de GLP-1, RDC 973/2025) não tem modelo definido pela Anvisa: usa o da RCE, com o título
// do manual do SNCR e a idade e o sexo do paciente, exigidos pela RDC 471/2021.
// NRR (retinoides sistêmicos, lista C2) e NRT (talidomida, lista C3) seguem seus modelos eletrônicos: data de nascimento
// e sexo do paciente; na NRT, também CPF, cadastro e especialidade do médico, CID e responsável pelo paciente.
export const PRESCRIPTION_TYPES = ['NRA', 'NRB', 'NRB2', 'RCE', 'RET', 'NRR', 'NRT'];
const GRAY = rgb(0.851, 0.851, 0.851); // faixa cinza das notificações especiais (#D9D9D9)
const WHITE = rgb(1, 1, 1);
export const MODELS = {
  NRA: {title: 'NOTIFICAÇÃO DE RECEITA', letter: 'A', name: 'Notificação de Receita A', band: rgb(0.922, 0.847, 0.541)},  // faixa amarela (#EBD88A)
  NRB: {title: 'NOTIFICAÇÃO DE RECEITA', letter: 'B', name: 'Notificação de Receita B', band: rgb(0.639, 0.769, 0.843)},  // faixa azul (#A3C4D7)
  NRB2: {title: 'NOTIFICAÇÃO DE RECEITA', letter: 'B2', name: 'Notificação de Receita B2', band: rgb(0.639, 0.769, 0.843)},
  RCE: {title: 'RECEITA DE CONTROLE ESPECIAL', name: 'Receita de Controle Especial', band: WHITE},
  RET: {title: 'RECEITA SUJEITA A RETENÇÃO', name: 'Receita Sujeita a Retenção', band: WHITE, patientAge: true},
  NRR: {title: 'NOTIFICAÇÃO DE RECEITA ESPECIAL', subtitle: 'RETINÓIDES SISTÊMICOS', name: 'Notificação de Receita Especial (retinoides)', band: GRAY, patientBirth: true, physician: true, pregnancy: true},
  NRT: {title: 'NOTIFICAÇÃO DE RECEITA DE', subtitle: 'TALIDOMIDA', name: 'Notificação de Receita de Talidomida', band: GRAY, patientBirth: true, physician: true, thalidomide: true},
};
export const SNCR_CONSULT = 'https://sncr.anvisa.gov.br/receita/consultar?numero=';
// Short, case-insensitive form of the prescription id for the platform link and QR: the 16 UUID bytes in base32
// (26 characters, all in the QR alphanumeric set).
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
export function shortId(uuid) {
  let bits = '', out = '';
  for (const byte of Buffer.from(uuid.replace(/-/g, ''), 'hex')) bits += byte.toString(2).padStart(8, '0');
  for (let i = 0; i < bits.length; i += 5) out += B32[parseInt(bits.slice(i, i + 5).padEnd(5, '0'), 2)];
  return out;
}
export function fromShortId(token) {
  const t = typeof token === 'string' ? token.toUpperCase() : '';
  if (!/^[A-Z2-7]{26}$/.test(t)) return null;
  const bits = [...t].map(c => B32.indexOf(c).toString(2).padStart(5, '0')).join('').slice(0, 128);
  const hex = bits.match(/.{4}/g).map(b => parseInt(b, 2).toString(16)).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
const UFS = new Set('AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO'.split(' '));
// Letras latinas com acento, dígitos e pontuação comum: tudo o que a fonte do PDF imprime.
const TEXT = /^[A-Za-zÀ-ÖØ-öø-ÿ0-9 .,;:()/\-'"ªº°%+&#*!?]*$/;
const MULTILINE = /^[A-Za-zÀ-ÖØ-öø-ÿ0-9 .,;:()/\-'"ªº°%+&#*!?\n]*$/;

function text(value, label, min, max, {multiline = false, optional = false} = {}) {
  if (value === undefined || value === null || value === '') {
    if (optional) return {value: ''};
    return {error: `Preencha ${label}.`};
  }
  if (typeof value !== 'string') return {error: `Confira ${label}.`};
  let v = value.normalize('NFC').replace(/\r\n?/g, '\n');
  v = multiline ? v.split('\n').map(l => l.trim().replace(/\s+/g, ' ')).join('\n').replace(/\n{3,}/g, '\n\n').trim() : v.trim().replace(/\s+/g, ' ');
  if (v.length < min || v.length > max) return {error: `${label[0].toUpperCase()}${label.slice(1)}: use de ${min} a ${max} caracteres.`};
  if (!(multiline ? MULTILINE : TEXT).test(v)) return {error: `${label[0].toUpperCase()}${label.slice(1)} tem caracteres não aceitos no PDF.`};
  return {value: v};
}
// "CPF ou, se estrangeiro, PASSAPORTE": 11 dígitos são CPF, com dígitos verificadores; senão, passaporte com letras e dígitos.
function patientDocument(value) {
  const raw = typeof value === 'string' ? value.trim().toUpperCase() : '';
  const digits = raw.replace(/[.\-\s]/g, '');
  if (/^\d{11}$/.test(digits)) return normalizedCPF(digits) ? {value: digits} : {error: 'CPF do paciente inválido: confira os dígitos.'};
  if (/^[A-Z0-9]{5,20}$/.test(raw.replace(/\s/g, ''))) return {value: raw.replace(/\s/g, '')};
  return {error: 'Informe o CPF (11 dígitos) ou, se estrangeiro, o passaporte do paciente.'};
}
const shownDocument = d => /^\d{11}$/.test(d || '') ? d.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, '$1.$2.$3-$4') : d || '—';

// Data de nascimento (AAAA-MM-DD) para a idade na RET: data real, não futura, até 130 anos.
function birthDate(value, now = Date.now()) {
  const m = typeof value === 'string' && value.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!m) return {error: 'Informe a data de nascimento do paciente.'};
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  if (d.getUTCFullYear() !== +m[1] || d.getUTCMonth() !== +m[2] - 1 || d.getUTCDate() !== +m[3]) return {error: 'Confira a data de nascimento do paciente.'};
  if (d.getTime() > now || +m[1] < new Date(now).getUTCFullYear() - 130) return {error: 'Confira a data de nascimento do paciente.'};
  return {value};
}
// Idade na data da emissão (fuso de São Paulo): anos; abaixo de 2 anos, meses; abaixo de 1 mês, dias.
export function ageAt(nascimento, when) {
  const [y, mo, d] = nascimento.split('-').map(Number), [ty, tm, td] = new Date(when).toLocaleDateString('en-CA', {timeZone: 'America/Sao_Paulo'}).split('-').map(Number);
  let months = (ty - y) * 12 + (tm - mo) - (td < d ? 1 : 0);
  if (months >= 24) return `${Math.floor(months / 12)} anos`;
  if (months >= 1) return months === 1 ? '1 mês' : `${months} meses`;
  const days = Math.round((Date.UTC(ty, tm - 1, td) - Date.UTC(y, mo - 1, d)) / 86400000);
  return days === 1 ? '1 dia' : `${days} dias`;
}
export const SEXES = {F: 'Feminino', M: 'Masculino'};

// Conteúdo canônico: mesma ordem de campos sempre, para o hash da prévia valer na emissão.
// Até 3 medicamentos por receita na RCE e na RET (decisão do prescritor, 30/09/2026; a Portaria 344, art. 57, admite
// até 3 substâncias da lista C1 por receita). As notificações seguem com um só (conteudo.medicamento).
export const MAX_ITEMS = 3;
export const multiItem = tipo => tipo === 'RCE' || tipo === 'RET';
// Every reader goes through this: RCE and RET keep an array, notifications a single object.
export const items = c => c.medicamentos ?? [c.medicamento];
function medication(m, prefix) {
  m = m || {};
  const fields = [['nome', m.nome, 'o medicamento ou substância', 2, 120], ['concentracao', m.concentracao, 'a concentração', 1, 40],
    ['forma', m.forma, 'a forma farmacêutica', 2, 60], ['unidade', m.unidade, 'a unidade da quantidade', 2, 40],
    ['posologia', m.posologia, 'a posologia', 5, 600, {multiline: true}]];
  const out = {};
  for (const [key, value, label, min, max, options] of fields) {
    const r = text(value, label, min, max, options);
    if (r.error) return {error: prefix + r.error};
    out[key] = r.value;
  }
  const quantidade = Number(m.quantidade);
  if (!Number.isInteger(quantidade) || quantidade < 1 || quantidade > 999) return {error: `${prefix}A quantidade deve ser um número inteiro de 1 a 999.`};
  return {value: {nome: out.nome, concentracao: out.concentracao, forma: out.forma, quantidade, unidade: out.unidade, posologia: out.posologia}};
}

// Conteúdo canônico: mesma ordem de campos sempre, para o hash da prévia valer na emissão.
export function prescriptionContent(body, now = Date.now()) {
  if (!PRESCRIPTION_TYPES.includes(body?.tipo)) return {error: 'Escolha o tipo de receita.'};
  const e = body.emitente || {}, p = body.paciente || {};
  const fields = [
    ['emitente', 'endereco', e.endereco, 'o endereço do emitente', 5, 160], ['emitente', 'cidade', e.cidade, 'a cidade do emitente', 2, 80],
    ['emitente', 'telefone', e.telefone, 'o telefone do emitente', 8, 20, {optional: true}],
    ['paciente', 'nome', p.nome, 'o nome do paciente', 3, 120], ['paciente', 'endereco', p.endereco, 'o endereço do paciente', 5, 160],
    ['paciente', 'cidade', p.cidade, 'a cidade do paciente', 2, 80],
  ];
  const out = {emitente: {}, paciente: {}};
  for (const [group, key, value, label, min, max, options] of fields) {
    const r = text(value, label, min, max, options);
    if (r.error) return r;
    out[group][key] = r.value;
  }
  if (out.emitente.telefone && !/^[0-9 ()+-]{8,20}$/.test(out.emitente.telefone)) return {error: 'Confira o telefone do emitente.'};
  const documento = patientDocument(p.documento);
  if (documento.error) return documento;
  for (const [group, source] of [['emitente', e], ['paciente', p]]) {
    const uf = typeof source.uf === 'string' ? source.uf.trim().toUpperCase() : '';
    if (!UFS.has(uf)) return {error: `Selecione a UF do ${group === 'emitente' ? 'emitente' : 'paciente'}.`};
    out[group].uf = uf;
  }
  // RET: idade e sexo (RDC 471/2021, art. 6º); NRR e NRT: data de nascimento e sexo (modelos da Anvisa).
  let retencao = {};
  const model = MODELS[body.tipo];
  if (model.patientAge || model.patientBirth) {
    if (!SEXES[p.sexo]) return {error: 'Informe o sexo do paciente.'};
    const nascimento = birthDate(p.nascimento, now);
    if (nascimento.error) return nascimento;
    retencao = {sexo: p.sexo, nascimento: nascimento.value};
  }
  // NRT: especialidade e Nº do cadastro do médico; CID e telefone do paciente; responsável, se houver.
  let talidomida = {};
  if (model.thalidomide) {
    const especialidade = text(e.especialidade, 'a especialidade do médico', 3, 60), cadastro = text(e.cadastro, 'o Nº do cadastro do médico', 1, 30);
    if (especialidade.error) return especialidade;
    if (cadastro.error) return cadastro;
    const cid = typeof p.cid === 'string' ? p.cid.trim().toUpperCase().replace(/\s/g, '') : '';
    if (!/^[A-Z][0-9]{2}(\.?[0-9A-Z]{1,2})?$/.test(cid)) return {error: 'Informe o CID do paciente (ex.: A30.5).'};
    const phone = text(p.telefone, 'o telefone do paciente', 8, 20, {optional: true});
    if (phone.error) return phone;
    if (phone.value && !/^[0-9 ()+-]{8,20}$/.test(phone.value)) return {error: 'Confira o telefone do paciente.'};
    talidomida = {emitente: {especialidade: especialidade.value, cadastro: cadastro.value}, paciente: {cid, ...(phone.value ? {telefone: phone.value} : {})}};
    const rp = body.responsavel;
    if (rp && (rp.nome || rp.documento || rp.endereco)) {
      const nome = text(rp.nome, 'o nome do responsável', 3, 120), endereco = text(rp.endereco, 'o endereço do responsável', 5, 160);
      const telefone = text(rp.telefone, 'o telefone do responsável', 8, 20, {optional: true}), documento = patientDocument(rp.documento);
      for (const r of [nome, endereco, telefone]) if (r.error) return r;
      if (documento.error) return {error: 'Confira o CPF ou passaporte do responsável.'};
      talidomida.responsavel = {nome: nome.value, documento: documento.value, endereco: endereco.value, ...(telefone.value ? {telefone: telefone.value} : {})};
    }
  }
  const conteudo = {
    emitente: {endereco: out.emitente.endereco, cidade: out.emitente.cidade, uf: out.emitente.uf, telefone: out.emitente.telefone, ...talidomida.emitente},
    paciente: {nome: out.paciente.nome, documento: documento.value, endereco: out.paciente.endereco, cidade: out.paciente.cidade, uf: out.paciente.uf, ...retencao, ...talidomida.paciente},
    ...(talidomida.responsavel ? {responsavel: talidomida.responsavel} : {}),
  };
  if (multiItem(body.tipo)) {
    const list = Array.isArray(body.medicamentos) ? body.medicamentos : body.medicamento ? [body.medicamento] : [];
    if (!list.length) return {error: 'Preencha o medicamento.'};
    if (list.length > MAX_ITEMS) return {error: `Até ${MAX_ITEMS} medicamentos por receita.`};
    conteudo.medicamentos = [];
    for (const [i, m] of list.entries()) {
      const r = medication(m, list.length > 1 ? `Medicamento ${i + 1}: ` : '');
      if (r.error) return r;
      conteudo.medicamentos.push(r.value);
    }
  } else {
    if (body.medicamentos !== undefined) return {error: 'A notificação de receita tem um medicamento só.'};
    const r = medication(body.medicamento, '');
    if (r.error) return r;
    conteudo.medicamento = r.value;
    // NRT: tempo de tratamento e outras orientações, campos próprios do modelo.
    if (model.thalidomide) {
      const tempo = text(body.medicamento?.tempo, 'o tempo de tratamento', 2, 60), orientacoes = text(body.medicamento?.orientacoes, 'as outras orientações', 3, 300, {multiline: true, optional: true});
      if (tempo.error) return tempo;
      if (orientacoes.error) return orientacoes;
      conteudo.medicamento.tempo = tempo.value;
      if (orientacoes.value) conteudo.medicamento.orientacoes = orientacoes.value;
    }
  }
  return {tipo: body.tipo, conteudo, sha256: contentHash(body.tipo, conteudo)};
}
const hashedItem = m => ({nome: m.nome, concentracao: m.concentracao, forma: m.forma, quantidade: m.quantidade, unidade: m.unidade, posologia: m.posologia,
  tempo: m.tempo, orientacoes: m.orientacoes});
export const contentHash = (tipo, c) => createHash('sha256').update(JSON.stringify({tipo, conteudo: {
  emitente: {endereco: c.emitente.endereco, cidade: c.emitente.cidade, uf: c.emitente.uf, telefone: c.emitente.telefone,
    especialidade: c.emitente.especialidade, cadastro: c.emitente.cadastro},
  // Type-specific fields (sexo, nascimento, cid, …) exist only where the model has them: undefined keys drop out of the
  // JSON, so the hashes of the other types are unchanged.
  paciente: {nome: c.paciente.nome, documento: c.paciente.documento, endereco: c.paciente.endereco, cidade: c.paciente.cidade, uf: c.paciente.uf,
    sexo: c.paciente.sexo, nascimento: c.paciente.nascimento, cid: c.paciente.cid, telefone: c.paciente.telefone},
  responsavel: c.responsavel && {nome: c.responsavel.nome, documento: c.responsavel.documento, endereco: c.responsavel.endereco, telefone: c.responsavel.telefone},
  // Notifications hash `medicamento` exactly as before; RCE and RET hash the ordered list.
  medicamento: c.medicamento && hashedItem(c.medicamento),
  medicamentos: c.medicamentos?.map(hashedItem),
}})).digest('hex');

// Quantidade por extenso (1 a 999), exigida na Notificação de Receita.
const UNITS = ['', 'um', 'dois', 'três', 'quatro', 'cinco', 'seis', 'sete', 'oito', 'nove', 'dez', 'onze', 'doze', 'treze', 'quatorze', 'quinze', 'dezesseis', 'dezessete', 'dezoito', 'dezenove'];
const TENS = ['', '', 'vinte', 'trinta', 'quarenta', 'cinquenta', 'sessenta', 'setenta', 'oitenta', 'noventa'];
const HUNDREDS = ['', 'cento', 'duzentos', 'trezentos', 'quatrocentos', 'quinhentos', 'seiscentos', 'setecentos', 'oitocentos', 'novecentos'];
export function inWords(n) {
  if (!Number.isInteger(n) || n < 1 || n > 999) throw RangeError('quantidade');
  if (n === 100) return 'cem';
  const parts = [], h = Math.floor(n / 100), rest = n % 100;
  if (h) parts.push(HUNDREDS[h]);
  if (rest >= 20) parts.push(TENS[Math.floor(rest / 10)] + (rest % 10 ? ' e ' + UNITS[rest % 10] : ''));
  else if (rest) parts.push(UNITS[rest]);
  return parts.join(' e ');
}

const INK = rgb(0.08, 0.12, 0.16), LABEL = rgb(0.35, 0.41, 0.46), LINE = rgb(0.16, 0.2, 0.24), RED = rgb(0.61, 0.16, 0.23);
// Rótulos do quadro da prescrição: mais claros e menores, para o conteúdo (escuro, seminegrito) sobressair.
const SOFT = rgb(0.47, 0.52, 0.57);
const W = 595, H = 842, top = t => H - t; // coordenadas do modelo medidas a partir do topo da página
const date = t => new Date(t).toLocaleDateString('pt-BR', {timeZone: 'America/Sao_Paulo'});

// Pregnant silhouette in a crossed circle ("GRAVIDEZ PROIBIDA"), centered at (cx, t from the top), 100 units * sc wide.
// Shared by the NRR panel and the NRR consent forms (termo-doc.mjs).
export function pregnancyPictogram(page, cx, t, sc, color = INK) {
  const y = v => H - v;
  page.drawEllipse({x: cx + (52 - 50) * sc, y: y(t + (20 - 50) * sc), xScale: 9 * sc, yScale: 9 * sc, color});
  page.drawSvgPath('M47 31 C40 33 38 42 40 52 L43 62 L41 92 L49 92 L51 68 L54 92 L62 92 L60 64 C69 62 74 54 72 46 C70 39 64 37 59 36 C57 33 53 31 47 31 Z',
    {x: cx - 50 * sc, y: y(t - 50 * sc), scale: sc, color});
  page.drawEllipse({x: cx, y: y(t), xScale: 46 * sc, yScale: 46 * sc, borderColor: color, borderWidth: 3 * sc / 0.44});
  page.drawLine({start: {x: cx - 32 * sc, y: y(t - 32 * sc)}, end: {x: cx + 32 * sc, y: y(t + 32 * sc)}, thickness: 3 * sc / 0.44, color});
}

// The posologies do not fit the prescription block (thrown by prescriptionPDF; the draft is refused before saving).
export class PrescriptionTooLong extends Error { constructor(item) { super('posologia-longa'); this.item = item; } }

// numero null = prévia. fonts = {regular, medium, semibold, bold}: subconjuntos latinos da Inter (assets/fonts/pdf, OFL),
// embutidos inteiros (o subconjunto do fontkit em tempo de execução perde glifos desta fonte).
export async function prescriptionPDF({id, tipo, numero, conteudo, prescritor, emitidaEm, fonts, platform = {name: 'OpenPEP-Rx', url: HOST}, previa = false, codigo = null}) {
  const model = MODELS[tipo];
  if (!model) throw Error('tipo sem modelo');
  const doc = await PDFDocument.create();
  doc.registerFontkit(fontkit);
  doc.setTitle(`${model.name} ${numero || '(prévia)'}`);
  doc.setAuthor(prescritor.nome);doc.setCreator('OpenPEP-Rx');doc.setProducer('OpenPEP-Rx');
  doc.setCreationDate(new Date(emitidaEm));doc.setModificationDate(new Date(emitidaEm));
  const [regular, medium, semibold, bold] = await Promise.all(['regular', 'medium', 'semibold', 'bold'].map(k => doc.embedFont(fonts[k])));
  const page = doc.addPage([W, H]);
  const draw = (s, x, t, size, font = regular, color = INK) => page.drawText(s, {x, y: top(t), size, font, color});
  const width = (s, size, font = regular) => font.widthOfTextAtSize(s, size);
  const wrap = (s, max, size, font = regular) => String(s).split('\n').flatMap(paragraph => {
    const lines = [];let line = '';
    for (const word of paragraph.split(' ')) {
      const next = line ? line + ' ' + word : word;
      if (line && width(next, size, font) > max) { lines.push(line);line = word; } else line = next;
    }
    return [...lines, line];
  });
  // Ajuste de encaixe: o valor reduz a fonte até caber no número de linhas do campo.
  // floor: identification fields (names, addresses, the footer) may shrink below min rather than cross a border; the
  // prescription keeps min and is refused when it does not fit (PrescriptionTooLong).
  const fit = (s, max, lines, size, min = 7.5, font = medium, floor = min) => {
    // A long word (an address, a URL) does not wrap, so each line's width is checked too.
    for (let z = size; z >= floor; z -= z > min ? 0.5 : 0.25) { const w = wrap(s, max, z, font); if (w.length <= lines && w.every(l => width(l, z, font) <= max)) return {lines: w, size: z}; }
    const w = wrap(s, max, floor, font); return {lines: [...w.slice(0, lines - 1), w.slice(lines - 1).join(' ')], size: floor};
  };
  // Medidas (ajuste de encaixe aprovado pelo prescritor em 30/09/2026, em todos os tipos; mesma estrutura, rótulos e
  // ordem do modelo): emitente e paciente compactos, quadro da prescrição mais alto e 20 pt de margem à direita (R).
  const R = 575, X1 = 63, BW = (R - X1 - 12) / 2, X2 = X1 + BW + 12;
  // Footer: QR of 78 pt with the same 20 pt margin to the bottom edge as to the right one; the prescription box runs to
  // 14 pt above it. Emitter and patient rows close together; the prescription block starts right below them.
  const FOOT = {qr: 78, top: 842 - 20 - 78};
  const L = {head: 20, title: 9.5, titleAt: 13.5, label: 6.5, labelAt: 7, valueAt: 16.5, value: 9, address: 8.5, blocks: [104, 150], rows: [126, 155, 181, 224], rx: 266, rh: FOOT.top - 14 - 266, first: 40, step: 17};
  const box = (x, t, w, h, title) => {
    page.drawRectangle({x, y: top(t + h), width: w, height: h, borderColor: LINE, borderWidth: 0.8});
    page.drawRectangle({x, y: top(t + L.head), width: w, height: L.head, color: model.band, opacity: 0.35, borderColor: LINE, borderWidth: 0.8});
    draw(title, x + (w - width(title, L.title, bold)) / 2, t + L.titleAt, L.title, bold);
  };
  // Campo do modelo: rótulo em maiúsculas e o valor logo abaixo.
  const field = (label, value, x, t, w, {lines = 1, size = L.value} = {}) => {
    draw(label, x, t + L.labelAt, L.label, semibold, LABEL);
    const f = fit(value || '—', w, lines, size, Math.min(7.5, size), medium, 5.5);
    f.lines.forEach((l, i) => draw(l, x, t + L.valueAt + i * (f.size + 2), f.size, medium));
  };

  const qr = (content, x, t, size) => {
    const q = qrcode.create(content, {errorCorrectionLevel: 'M'}), n = q.modules.size, cell = size / n;
    for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (q.modules.get(r, c)) page.drawRectangle({x: x + c * cell, y: top(t + (r + 1) * cell), width: cell + 0.05, height: cell + 0.05, color: INK});
  };
  const centered = (s, x, t, w, size, font = semibold, color = INK) => draw(s, x + (w - width(s, size, font)) / 2, t, size, font, color);
  const access = `${platform.url}/r/${shortId(id)}`;
  const onlineAccess = platform.documentURL || null, showAccess = platform.access !== false || Boolean(onlineAccess);

  // Faixa lateral na cor do tipo, como no modelo.
  page.drawRectangle({x: 0, y: 0, width: 56, height: H, color: model.band});
  // No alto da faixa, longe do QR do SNCR: "Acesse:", o QR da receita na plataforma (link com o código do paciente
  // no fragmento, que não chega ao servidor) e o código, para digitar se o leitor não abrir o link.
  // On the white band (RCE, RET) the card keeps a thin border so it still reads as a card.
  // Card and QR kept 10 pt from the left edge and 14 pt from the top, clear of what printers cut off.
  const cx = 10, cw = 44;
  if(showAccess) {
  page.drawRectangle({x: cx, y: top(98), width: cw, height: 84, color: rgb(1, 1, 1), ...(model.letter ? {} : {borderColor: LABEL, borderWidth: 0.5})});
  centered('Acesse:', cx, 24, cw, 7, bold);
  if (onlineAccess) {
    qr(onlineAccess.toUpperCase(),cx + 3,28,38);
    centered('PDF',cx,79,cw,7,bold);centered('original',cx,89,cw,6,regular,LABEL);
  } else if (codigo && !previa) {
    qr(`${platform.scheme === 'http' ? 'HTTP' : 'HTTPS'}://${access}`.toUpperCase() + '#' + codigo, cx + 3, 28, 38);
    centered('CÓDIGO', cx, 76, cw, 5.5, semibold, LABEL);centered(codigo, cx, 88, cw, 9, bold);
  } else {
    page.drawRectangle({x: cx + 3, y: top(66), width: 38, height: 38, borderColor: LABEL, borderWidth: 0.6, borderDashArray: [3, 2]});
    centered('na', cx, 79, cw, 6, regular, LABEL);centered('emissão', cx, 87, cw, 6, regular, LABEL);
  }

  }

  // Cabeçalho: título, letra do tipo (notificações), "ELETRÔNICA" e N.º. Títulos sem letra encolhem até caber antes do N.º.
  const title = model.title, letter = model.letter || '', letterSize = 34, eletronica = 'ELETRÔNICA';
  let nx;
  if (model.subtitle) {
    // NRR and NRT: two title lines aligned right, before the N.º box, as in their models.
    const right = 386, size = Math.min(15.5, 310 / Math.max(width(title, 1, bold), width(model.subtitle, 1, bold)));
    draw(title, right - width(title, size, bold), 44, size, bold);draw(model.subtitle, right - width(model.subtitle, size, bold), 44 + size + 3, size, bold);
    draw(eletronica, right - width(eletronica, 9.5, bold), 44 + 2 * size + 14, 9.5, bold);
    nx = 400;
  } else {
    const titleSize = letter ? 17 : Math.min(17, 310 / width(title, 1, bold));
    const titleW = width(title, titleSize, bold), letterX = 69 + titleW + (letter ? 8 : 0), letterW = letter ? width(letter, letterSize, bold) : 0;
    draw(title, 69, 50, titleSize, bold);if (letter) draw(letter, letterX, 56, letterSize, bold);
    const center = letter ? (69 + letterX + letterW) / 2 : 69 + titleW - width(eletronica, 9.5, bold) / 2;
    draw(eletronica, center - width(eletronica, 9.5, bold) / 2, 75, 9.5, bold);
    nx = Math.max(letterX + letterW + 14, 400);
  }
  page.drawRectangle({x: nx, y: top(60), width: R - nx, height: 36, borderColor: LINE, borderWidth: 0.8});
  draw('N.º', nx + 8, 35, 8.5, semibold, LABEL);
  if (numero) draw(numero, nx + 8 + (R - nx - 16 - width(numero, 14, bold)) / 2 + 8, 50, 14, bold);
  else draw('atribuído na emissão', nx + 28, 45, 9, regular, LABEL);
  // A prévia (inclusive de receita pendente, que já tem número) nunca passa por documento assinado.
  if (previa) {
    const mark = 'PRÉVIA · NÃO ASSINADA';
    draw(mark, R - width(mark, 8, bold), 72, 8, bold, RED);
    page.drawText('PRÉVIA', {x: 190, y: 360, size: 90, font: bold, color: RED, opacity: 0.07, rotate: degrees(35)});
  }

  const FW = BW - 16, EX = X1 + 8, PX = X2 + 8;
  const e = conteudo.emitente, p = conteudo.paciente;
  const born = () => p.nascimento.split('-').reverse().join('/');
  if (model.thalidomide) return finishThalidomide();
  // Emitente e paciente.
  box(X1, L.blocks[0], BW, L.blocks[1], 'EMITENTE');box(X2, L.blocks[0], BW, L.blocks[1], 'PACIENTE');
  // Campos nas alturas do modelo (rótulos a cada ~40 pt); o endereço usa até 3 linhas.
  const [r1, r2, r3, r4] = L.rows;
  field(model.physician ? 'NOME DO MÉDICO:' : 'NOME DO PRESCRITOR:', prescritor.nome, EX, r1, FW, {lines: 2});
  field(model.physician ? 'INSCRIÇÃO NO CRM / UF:' : 'INSCRIÇÃO NO CONSELHO PROFISSIONAL / UF:', `CRM ${prescritor.crm} / ${prescritor.uf}`, EX, r2, FW);
  field('ENDEREÇO COMPLETO:', `${e.endereco}, ${e.cidade} / ${e.uf}`, EX, r3, FW, {lines: 3, size: L.address});
  field('TELEFONE:', e.telefone || '—', EX, r4, FW);
  field('NOME:', p.nome, PX, r1, FW, {lines: 2});
  field('CPF ou, se estrangeiro, PASSAPORTE:', shownDocument(p.documento), PX, r2, FW);
  field('ENDEREÇO COMPLETO:', `${p.endereco}, ${p.cidade} / ${p.uf}`, PX, r3, FW, {lines: 3, size: L.address});
  if (model.patientAge) field('IDADE / SEXO:', `${ageAt(p.nascimento, emitidaEm)} · ${SEXES[p.sexo]} · nascimento ${born()}`, PX, r4, FW);
  // NRR: the model's "DATA DE NASCIMENTO" and "SEXO", side by side in the last row.
  if (model.patientBirth) { field('DATA DE NASCIMENTO:', born(), PX, r4, FW / 2 - 4); field('SEXO:', SEXES[p.sexo], PX + FW / 2 + 4, r4, FW / 2 - 4); }

  // Prescrição: rótulo e valor na mesma linha, como no modelo; posologia em bloco.
  box(X1, L.rx, R - X1, L.rh, 'PRESCRIÇÃO');
  // Prescrição: rótulo pequeno e claro, valor em seminegrito escuro na mesma linha; linhas próximas (ajuste de encaixe
  // pedido pelo prescritor, 30/09/2026). Com 2 ou 3 medicamentos (RCE, RET), cada um ganha uma faixa igual do quadro,
  // numerada e separada por uma linha tracejada leve, e as fontes diminuem um pouco.
  const list = items(conteudo), n = list.length;
  const S = [{label: 7.5, value: 10, step: 17, text: 9.5, gap: 3, first: 14, min: 8},
    {label: 7, value: 9.5, step: 15.5, text: 9, gap: 2.5, first: 13, min: 7.5},
    {label: 6.5, value: 9, step: 14, text: 8.5, gap: 2.5, first: 12, min: 7}][n - 1];
  const inline = (label, value, x0, t0) => {
    draw(label, x0, t0, S.label, semibold, SOFT);
    const x = x0 + width(label, S.label, semibold) + 7, f = fit(value, textRight - x, 1, S.value, S.min, semibold);
    draw(f.lines[0], x, t0 + 0.5, f.size, semibold);
  };
  // NRR: the model's "GRAVIDEZ PROIBIDA" panel at the top right of the prescription; the text keeps clear of it.
  const panel = model.pregnancy ? pregnancyPanel(R - 128, L.rx + L.head + 8) : null, textRight = panel ? R - 136 : R - 8;
  const contentTop = L.rx + L.head, band = (L.rx + L.rh - 8 - contentTop) / n;
  list.forEach((m, i) => {
    const t = contentTop + i * band, x0 = n > 1 ? 86 : 72, y0 = t + (i ? 18 : 20), posologiaAt = y0 + 4 * S.step;
    if (i) page.drawLine({start: {x: X1 + 10, y: top(t)}, end: {x: R - 10, y: top(t)}, thickness: 0.5, color: SOFT, dashArray: [3, 3]});
    if (n > 1) draw(`${i + 1}.`, 72, y0 + 0.5, S.value, bold);
    inline('NOME DO MEDICAMENTO OU SUBSTÂNCIA:', m.nome, x0, y0);
    inline('CONCENTRAÇÃO:', m.concentracao, x0, y0 + S.step);
    inline('FORMA FARMACÊUTICA:', m.forma, x0, y0 + 2 * S.step);
    inline('QUANTIDADE:', `${m.quantidade} (${inWords(m.quantidade)}) ${m.unidade}`, x0, y0 + 3 * S.step);
    draw('POSOLOGIA:', x0, posologiaAt, S.label, semibold, SOFT);
    const max = textRight - 2 - x0, lines = Math.floor((t + band - 6 - (posologiaAt + S.first)) / (S.text + S.gap)) + 1;
    const posologia = fit(m.posologia, max, lines, S.text, S.min, regular);
    // fit() squeezes what does not fit into the last line: that would print past the border, so it is refused.
    if (posologia.lines.length > lines || posologia.lines.some(l => width(l, posologia.size, regular) > max + 0.5)) throw new PrescriptionTooLong(i);
    posologia.lines.forEach((l, j) => draw(l, x0, posologiaAt + S.first + j * (posologia.size + S.gap), posologia.size));
  });

  drawFooter();

  function drawFooter() {
    // Rodapé do modelo, preenchido e discreto: as cinco linhas ocupam a altura do QR do SNCR, que fica maior.
    const qs = FOOT.qr, qx = R - qs, qt = FOOT.top, step = (qs - 7) / 4;
    const foot = (label, value, i, right = qx - 12) => {
      const t0 = qt + 6 + i * step;
      draw(label, 65, t0, 6.5, semibold, SOFT);
      if (value) { const x = 65 + width(label, 6.5, semibold) + 5, f = fit(value, right - x, 1, 7.5, 6, regular, 4.5); draw(f.lines[0], x, t0, f.size, regular, LABEL); }
    };
    foot('IDENTIFICAÇÃO DA PLATAFORMA', platform.name, 0);
    foot('REGISTRO DA ASSINATURA DIGITAL E DATA', previa ? 'aplicado na emissão' : `${platform.signature || 'ICP-Brasil (PAdES)'} · ${prescritor.nome} · ${date(emitidaEm)}`, 1);
    foot('VALIDE ESSA ASSINATURA EM', 'validar.iti.gov.br', 2);
    foot('ESTA PRESCRIÇÃO PODE SER VERIFICADA EM:', onlineAccess ? 'Link individual no QR acima; confira também o arquivo no ITI.' : !showAccess ? 'Arquivo PDF original; validar.iti.gov.br' : previa ? 'endereço gerado na emissão' : `${access} · código ${codigo ?? '—'}`, 3);
    foot('VERIFIQUE A NUMERAÇÃO E REGISTRE A UTILIZAÇÃO DESTA PRESCRIÇÃO EM', 'sncr.anvisa.gov.br', 4);

    // QR da Notificação de Receita: consulta do SNCR com o número (exigência da Anvisa), no lugar do modelo.
    if (numero) {
      qr(SNCR_CONSULT + encodeURIComponent(numero), qx, qt, qs);
    } else {
      page.drawRectangle({x: qx, y: top(qt + qs), width: qs, height: qs, borderColor: LABEL, borderWidth: 0.6, borderDashArray: [3, 2]});
      draw('QR na emissão', qx + (qs - width('QR na emissão', 7.5)) / 2, qt + qs / 2 + 3, 7.5, regular, LABEL);
    }
  }

  // NRR: "GRAVIDEZ PROIBIDA" panel of the model, with its pictogram (pregnant silhouette in a crossed circle).
  function pregnancyPanel(x, t) {
    const w = 120, h = 112;
    page.drawRectangle({x, y: top(t + h), width: w, height: h, borderColor: LINE, borderWidth: 0.8});
    pregnancyPictogram(page, x + w / 2, t + 34, 0.44);
    centered('GRAVIDEZ PROIBIDA', x, t + 70, w, 7.5, bold);
    wrap('Risco de graves defeitos na face, nas orelhas, no coração e no sistema nervoso do feto.', w - 12, 6.8, semibold)
      .forEach((l, i) => centered(l, x, t + 81 + i * 8.5, w, 6.8, semibold));
    return {x, w, h};
  }

  // NRT: its own model. "ATENÇÃO" banner, emitter and patient with the model's seven fields each, the patient's guardian
  // (if any), and the prescription as quantity, dose per unit, posology, treatment time and other instructions.
  async function finishThalidomide() {
    // Rows by a cursor: label and value on one line; names and addresses take their own lines under the label.
    const row = (label, value, x, t, w) => {
      draw(label, x, t, 6.5, semibold, SOFT);
      const vx = x + width(label, 6.5, semibold) + 5, f = fit(value || '—', x + w - vx, 1, 8.5, 6.5, medium, 5);
      draw(f.lines[0], vx, t, f.size, medium);
      return 1;
    };
    const stacked = (label, value, x, t, w, lines) => {
      draw(label, x, t, 6.5, semibold, SOFT);
      const f = fit(value || '—', w, lines, 8.5, 6.5, medium, 5);
      f.lines.forEach((l, i) => draw(l, x, t + 10.5 + i * (f.size + 2), f.size, medium));
      return lines === 1 ? 1.75 : lines === 2 ? 2.4 : 3;
    };
    const column = (x, w, fields) => { let t = r0; for (const [kind, label, value, lines] of fields) t += step * (kind === 'row' ? row(label, value, x, t, w) : stacked(label, value, x, t, w, lines)); };
    // "ATENÇÃO" banner under the title.
    page.drawRectangle({x: X1, y: top(124), width: R - X1, height: 30, borderColor: LINE, borderWidth: 0.8});
    page.drawEllipse({x: X1 + 30, y: top(109), xScale: 24, yScale: 10, color: INK});
    centered('ATENÇÃO', X1 + 6, 111.5, 48, 7, bold, rgb(1, 1, 1));
    for (const [i, quote] of ['"Proibida para mulheres grávidas ou com chance de engravidar"', '"Talidomida causa o nascimento de crianças sem braços e sem pernas"'].entries())
      centered(quote, X1 + 60, 105 + i * 11, R - X1 - 64, 8.5, bold);
    // Emitter and patient.
    const bt = 132, bh = 176, step = 14.5, r0 = bt + L.head + 13;
    box(X1, bt, BW, bh, 'EMITENTE');box(X2, bt, BW, bh, 'PACIENTE');
    const cpf = String(prescritor.cpf || '').replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, '$1.$2.$3-$4');
    column(EX, FW, [['stacked', 'NOME DO MÉDICO:', prescritor.nome, 1], ['row', 'CPF:', cpf], ['row', 'INSCRIÇÃO NO CRM / UF:', `CRM ${prescritor.crm} / ${prescritor.uf}`],
      ['row', 'Nº. DO CADASTRO:', e.cadastro], ['row', 'ESPECIALIDADE:', e.especialidade], ['stacked', 'ENDEREÇO COMPLETO:', `${e.endereco}, ${e.cidade} / ${e.uf}`, 3], ['row', 'TELEFONE:', e.telefone]]);
    column(PX, FW, [['stacked', 'NOME:', p.nome, 1], ['row', 'CPF ou, se estrangeiro, PASSAPORTE:', shownDocument(p.documento)],
      ['stacked', 'ENDEREÇO COMPLETO:', `${p.endereco}, ${p.cidade} / ${p.uf}`, 3], ['row', 'DATA DE NASCIMENTO:', born()], ['row', 'SEXO:', SEXES[p.sexo]],
      ['row', 'CID:', p.cid], ['row', 'TELEFONE (se houver):', p.telefone]]);
    // Guardian of the patient, if any (the model keeps the block; empty fields print a dash).
    const gt = bt + bh + 8, gh = 112, g = conteudo.responsavel || {}, gw = R - X1 - 16;
    box(X1, gt, R - X1, gh, 'IDENTIFICAÇÃO DO RESPONSÁVEL PELO PACIENTE (SE FOR O CASO)');
    let gy = gt + L.head + 13;
    gy += step * row('NOME:', g.nome, X1 + 8, gy, gw);
    gy += step * row('CPF ou, se estrangeiro, PASSAPORTE:', g.documento ? shownDocument(g.documento) : '', X1 + 8, gy, gw);
    gy += step * stacked('ENDEREÇO COMPLETO:', g.endereco, X1 + 8, gy, gw, 2);
    row('TELEFONE (se houver):', g.telefone, X1 + 8, gy, gw);
    // Prescription.
    const pt = gt + gh + 8, ph = FOOT.top - 14 - pt, m = conteudo.medicamento, x0 = 72, max = R - 10 - x0;
    box(X1, pt, R - X1, ph, 'PRESCRIÇÃO');
    const inl = (label, value, t0) => {
      draw(label, x0, t0, 7.5, semibold, SOFT);
      const x = x0 + width(label, 7.5, semibold) + 7, f = fit(value, R - 8 - x, 1, 10, 8, semibold);
      draw(f.lines[0], x, t0 + 0.5, f.size, semibold);
    };
    const block = (label, value, t0, lines) => {
      draw(label, x0, t0, 7.5, semibold, SOFT);
      const f = fit(value || '—', max, lines, 9.5, 8, regular);
      if (f.lines.length > lines || f.lines.some(l => width(l, f.size, regular) > max + 0.5)) throw new PrescriptionTooLong(0);
      f.lines.forEach((l, j) => draw(l, x0, t0 + 14 + j * (f.size + 3), f.size));
      return t0 + 14 + lines * 12.5 + 6;
    };
    let y = pt + L.head + 20;
    inl('QUANTIDADE DE COMPRIMIDOS (EM ALGARISMOS ARÁBICOS E POR EXTENSO):', `${m.quantidade} (${inWords(m.quantidade)})`, y); y += 17;
    inl('DOSE POR UNIDADE POSOLÓGICA (EX.: 100MG):', m.concentracao, y); y += 17;
    y = block('POSOLOGIA:', m.posologia, y, 6);
    inl('TEMPO DE TRATAMENTO:', m.tempo, y); y += 17;
    block('OUTRAS ORIENTAÇÕES (SE HOUVER):', m.orientacoes, y, Math.max(1, Math.floor((pt + ph - 8 - (y + 14)) / 12.5)));
    drawFooter();
    return Buffer.from(await doc.save({useObjectStreams: false}));
  }

  return Buffer.from(await doc.save({useObjectStreams: false}));
}
