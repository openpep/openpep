#!/usr/bin/env node
// Gera data/medicamentos-especiais.json: medicamentos das notificações especiais
//   - NRR: Notificação de Receita Especial para retinoides de uso sistêmico
//     (lista C2 do Anexo I da Portaria SVS/MS 344/1998; os de uso tópico são
//     venda sob prescrição sem retenção, adendo 2 da lista C2);
//   - NRT: Notificação de Receita de Talidomida (lista C3; RDC nº 11/2011).
// Listas na redação da RDC nº 1.036/2026. Vendas: SNGPC com TP_RECEITUARIO 3
// (Notificação de Receita Especial). Entram também as apresentações com preço
// na lista CMED sem venda no período (vendas 0), inclusive a talidomida, que é
// dispensada só em unidades públicas.
// Veja data/PROVENANCE.md (seção "Notificações especiais: NRR e NRT").
//
// Uso:
//   node scripts/medicamentos/gerar-especiais.mjs [opções]
//     --meses=202606,202607,202608   meses do SNGPC (AAAAMM)
//     --cache=DIR                    mesmo cache de gerar.mjs ($MEDICAMENTOS_CACHE
//                                    ou <tmpdir>/cockpit-rx-medicamentos)
//     --refazer                      ignora o cache e baixa tudo de novo
//     --relatorio                    imprime as apresentações e as exclusões
//     --data=AAAA-MM-DD              valor de "gerado" (padrão: hoje)
//     --saida=ARQUIVO                caminho do JSON (padrão: data/medicamentos-especiais.json)
//
// Não importa os outros geradores (eles executam ao ser carregados); as funções
// comuns foram copiadas de gerar-rce.mjs e usam o mesmo cache.

import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, rename, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const AQUI = dirname(fileURLToPath(import.meta.url));
const RAIZ = resolve(AQUI, '..', '..');

const args = Object.fromEntries(process.argv.slice(2).map((a) => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/);
  if (!m) throw new Error(`argumento inválido: ${a}`);
  return [m[1], m[2] ?? true];
}));
const MESES = String(args.meses || '202606,202607,202608').split(',').map((s) => s.trim()).filter(Boolean);
const CACHE = resolve(args.cache || process.env.MEDICAMENTOS_CACHE || join(tmpdir(), 'cockpit-rx-medicamentos'));
const SAIDA = resolve(args.saida || join(RAIZ, 'data', 'medicamentos-especiais.json'));

const SNGPC_URL = process.env.SNGPC_URL || 'https://dados.anvisa.gov.br/dados/SNGPC/Industrializados/';
const CMED_URL = 'https://dados.anvisa.gov.br/dados/TA_PRECO_MEDICAMENTO.csv';
const CODIGO = '3'; // TP_RECEITUARIO 3 = Notificação de Receita Especial
const FONTE_LISTAS = {
  ato: 'RDC nº 1.036/2026 (Anexo I da Portaria SVS/MS nº 344/1998, listas C2 e C3)',
  data: '2026-07-09',
  // Página oficial da Anvisa que lista a RDC vigente (a URL do texto integral tem "=" e "_").
  url: 'https://www.gov.br/anvisa/pt-br/assuntos/medicamentos/controlados/lista-substancias',
};

const log = (...a) => console.error(...a);

// ---------------------------------------------------------------------------
// Utilidades (copiadas de gerar.mjs)
// ---------------------------------------------------------------------------

function baixar(url) {
  return new Promise((ok, erro) => {
    const p = spawn('curl', ['-sSfL', '--retry', '3', '--connect-timeout', '30', '-A', 'Mozilla/5.0', url], { stdio: ['ignore', 'pipe', 'inherit'] });
    const partes = [];
    p.stdout.on('data', (b) => partes.push(b));
    p.on('close', (c) => (c === 0 ? ok(Buffer.concat(partes)) : erro(new Error(`curl saiu com código ${c}: ${url}`))));
  });
}

const semAcento = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '');
const espacos = (s) => s.replace(/[ \s]+/g, ' ').trim();
const soma = (xs, f) => xs.reduce((a, x) => a + f(x), 0);
const HIDRATO = /\b(?:mono|di|tri|tetra|penta|hexa|hepta|hemi|hemiepta|sesqui)?-?h?idratad[oa]s?\b|\banidr[oa]s?\b|\bh2o\b/gi;

function chave(s) {
  return semAcento(s.toLowerCase())
    .replace(/\([^)]*\)/g, ' ')
    .replace(HIDRATO, ' ')
    .replace(/(\w)-(\w)/g, '$1$2')
    .replace(/dihidro/g, 'diidro')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}
const exibicao = (s) => espacos(s.toLowerCase().replace(/\([^)]*\)/g, ' ').replace(HIDRATO, ' ')).replace(/\bcerio\b/g, 'cério');

const CABECALHO = 'NU_ANO_VENDA;NU_MES_VENDA;SG_UF_VENDA;NO_MUNICIPIO_VENDA;DS_PRINCIPIO_ATIVO;DS_DESCRICAO_APRESENTACAO;QT_VENDIDA;DS_UNIDADE_MEDIDA;NO_CONSELHO_PRESCRITOR;SG_UF_CONSELHO_PRESCRITOR;TP_RECEITUARIO;CO_CID10;SG_SEXO;NU_IDADE;NU_UNIDADE_IDADE';
const C_PA = 4, C_APRES = 5, C_QT = 6, C_UNID = 7, C_TP = 10;

function campos(linha) {
  const out = [];
  let i = 0;
  const n = linha.length;
  while (i <= n) {
    if (linha.charCodeAt(i) === 34) {
      let v = '';
      i++;
      for (;;) {
        const j = linha.indexOf('"', i);
        if (j < 0) { v += linha.slice(i); i = n; break; }
        v += linha.slice(i, j);
        if (linha.charCodeAt(j + 1) === 34) { v += '"'; i = j + 2; continue; }
        i = j + 1;
        break;
      }
      out.push(v);
      const k = linha.indexOf(';', i);
      if (k < 0) break;
      i = k + 1;
    } else {
      const k = linha.indexOf(';', i);
      if (k < 0) { out.push(linha.slice(i)); break; }
      out.push(linha.slice(i, k));
      i = k + 1;
    }
  }
  return out;
}

async function agregarMes(mes) {
  const destino = join(CACHE, `sngpc-${mes}.tsv`);
  if (!args.refazer) {
    try { await stat(destino); log(`[${mes}] usando cache ${destino}`); return destino; } catch {}
  }
  const url = `${SNGPC_URL}EDA_Industrializados_${mes}.csv`;
  log(`[${mes}] baixando e agregando ${url}`);
  const curl = spawn('curl', ['-sSfL', '--retry', '3', '--connect-timeout', '30', url], { stdio: ['ignore', 'pipe', 'inherit'] });
  const fim = new Promise((ok, erro) => curl.on('close', (c) => (c === 0 ? ok() : erro(new Error(`curl saiu com código ${c} em ${mes}`)))));
  const dec = new TextDecoder('windows-1252');
  const acc = new Map();
  let resto = '';
  let linhas = 0, ruins = 0, cabecalho = null;
  const processa = (linha) => {
    if (linha.endsWith('\r')) linha = linha.slice(0, -1);
    if (!linha) return;
    if (cabecalho === null) {
      cabecalho = linha.replace(/^﻿/, '');
      if (cabecalho !== CABECALHO) throw new Error(`[${mes}] cabeçalho inesperado: ${cabecalho}`);
      return;
    }
    linhas++;
    const f = campos(linha);
    if (f.length < 11) { ruins++; return; }
    const qt = Number(f[C_QT]);
    if (!Number.isFinite(qt)) { ruins++; return; }
    const k = [espacos(f[C_TP]), espacos(f[C_PA]), espacos(f[C_APRES]), espacos(f[C_UNID])].join('\t');
    acc.set(k, (acc.get(k) || 0) + qt);
  };
  for await (const pedaco of curl.stdout) {
    const texto = resto + dec.decode(pedaco, { stream: true });
    const partes = texto.split('\n');
    resto = partes.pop();
    for (const l of partes) processa(l);
  }
  processa(resto + dec.decode());
  await fim;
  if (!linhas) throw new Error(`[${mes}] nenhum dado lido`);
  log(`[${mes}] concluído: ${linhas} linhas (${ruins} descartadas), ${acc.size} chaves`);
  const corpo = ['TP_RECEITUARIO\tDS_PRINCIPIO_ATIVO\tDS_DESCRICAO_APRESENTACAO\tDS_UNIDADE_MEDIDA\tQT_VENDIDA'];
  for (const [k, v] of acc) corpo.push(`${k}\t${v}`);
  await writeFile(`${destino}.parcial`, corpo.join('\n') + '\n');
  await rename(`${destino}.parcial`, destino);
  return destino;
}

async function carregarAgregados() {
  await mkdir(CACHE, { recursive: true });
  const arquivos = await Promise.all(MESES.map(agregarMes));
  const acc = new Map();
  for (const arq of arquivos) {
    const linhas = (await readFile(arq, 'utf8')).split('\n');
    for (let i = 1; i < linhas.length; i++) {
      if (!linhas[i]) continue;
      const p = linhas[i].split('\t');
      const k = p.slice(0, 4).join('\t');
      acc.set(k, (acc.get(k) || 0) + Number(p[4]));
    }
  }
  return [...acc].map(([k, qt]) => {
    const [tp, pa, apres] = k.split('\t');
    return { tp: tp.replace(/\.$/, ''), pa, apres, qt };
  });
}

function* linhasCSV(t) {
  let row = [], campo = '', aspas = false;
  for (let i = 0; i < t.length; i++) {
    const c = t[i];
    if (aspas) {
      if (c === '"') { if (t[i + 1] === '"') { campo += '"'; i++; } else aspas = false; } else campo += c;
    } else if (c === '"' && campo === '') aspas = true;
    else if (c === ';') { row.push(campo); campo = ''; }
    else if (c === '\n') { row.push(campo.replace(/\r$/, '')); yield row; row = []; campo = ''; }
    else campo += c;
  }
  if (campo || row.length) { row.push(campo); yield row; }
}


// ---------------------------------------------------------------------------
// Listas C2 e C3 (Anexo I, RDC nº 1.036, de 9/7/2026)
// ---------------------------------------------------------------------------

const LISTAS = {
  // C2: "Sujeitas à Notificação de Receita Especial". Adendo 2: os de uso tópico
  // são venda sob prescrição sem retenção.
  C2: ['Acitretina', 'Adapaleno', 'Bexaroteno', 'Isotretinoína', 'Tretinoína'],
  // C3: talidomida em Notificação de Receita de Talidomida (RDC nº 11/2011).
  // Lenalidomida e pomalidomida (adendo 4) seguem a RDC nº 735/2022: Notificação
  // de Receita da Lista C3, fornecida conforme o PPG do detentor do registro.
  C3: ['Ftalimidoglutarimida (talidomida)', 'Lenalidomida', 'Pomalidomida'],
};
const TIPO = { C2: 'NRR', C3: 'NRT' };
const FORA = {
  lenalidomida: 'C3, adendo 4: lenalidomida usa a Notificação de Receita da Lista C3 da RDC nº 735/2022 (formulário do PPG do fabricante), não a NRT',
  pomalidomida: 'C3, adendo 4: pomalidomida usa a Notificação de Receita da Lista C3 da RDC nº 735/2022 (formulário do PPG do fabricante), não a NRT',
};

const INDICE = [];
for (const [lista, nomes] of Object.entries(LISTAS)) {
  for (const nome of nomes) {
    const principal = chave(nome.replace(/\(.*\)/, ''));
    const par = nome.match(/\(([^)]*)\)/);
    const base = par ? chave(par[1]) : principal; // "talidomida", não "ftalimidoglutarimida"
    for (const v of [principal, ...(par ? [chave(par[1])] : [])]) INDICE.push({ tokens: v.split(' '), lista, base });
  }
}
INDICE.sort((a, b) => b.tokens.length - a.tokens.length);

function contem(tokens, alvo) {
  outer: for (let i = 0; i + alvo.length <= tokens.length; i++) {
    for (let j = 0; j < alvo.length; j++) if (tokens[i + j] !== alvo[j]) continue outer;
    return true;
  }
  return false;
}
function listado(c) {
  const tokens = c.split(' ');
  for (const e of INDICE) if (contem(tokens, e.tokens)) return e;
  return null;
}

// Excipientes que às vezes aparecem como "princípio ativo" no SNGPC.
const EXCIPIENTES = new Set(['acido estearico', 'estearato de magnesio']);

// Base de componente não listado: tira sal/éster/cátion (para chave e busca).
const SAL = /^(?:(?:17 )?(?:di|tri|mono|hemi|sesqui)?(?:cloridrato|bromidrato|fosfato dissodico|fosfato|sulfato|maleato|tartarato|bitartarato|citrato|succinato|mesilato|besilato|oxalato|fumarato|acetato|carbonato|cloreto|brometo|nitrato|lactato|valerato|dipropionato|propionato|furoato|decanoato|benzoato|acetonida|estolato|hiclato)\s+de\s+)/;
const CATION = /\s+(?:dissodic[oa]|sodic[oa]|potassic[oa]|calcic[oa]|magnesic[oa]|zincic[oa]|de sodio|de potassio|de calcio|de magnesio|micronizad[oa]|acetonida|trometamol|pivoxila|proxetila?|benzatina|procaina)$/;
const SINONIMOS = { benzalconico: 'benzalconio', levometionina: 'metionina', 'amino acidos': 'aminoacidos', fludoxicortida: 'fludroxicortida' };
function baseDe(c) {
  let b = c;
  for (let i = 0; i < 3; i++) b = b.replace(SAL, '').replace(CATION, '').trim();
  return SINONIMOS[b] || b;
}

const ASSOCIACOES = {};

// ---------------------------------------------------------------------------
// Leitura de DS_DESCRICAO_APRESENTACAO (abreviações do Vocabulário Controlado)
// ---------------------------------------------------------------------------

function normDesc(desc) {
  return espacos(semAcento(desc.toUpperCase()).replace(/\(\s*\d+(?:[.,]\d+)?\s*UI\s*\)/g, ' ')) // "15 MG (45UI)"
    .replace(/(\d)M\/G\b/g, '$1 MG/G') // "10M/G" (erro de digitação na origem)
    .replace(/(\d)\s*(MCG|MG|ML|MUI|UI|UTR|U|G)\b/g, '$1 $2')
    .replace(/\s*\/\s*/g, '/')
    .replace(/\bSUSP\b/g, 'SUS')
    .replace(/\bOTOL\b/g, 'OTO')
    .replace(/\bORAL\b/g, 'OR')
    .replace(/\bSPRAY\b/g, 'SPR')
    .replace(/\bGELE(?:IA)?\b/g, 'GEL')
    .replace(/\bPARA\b/g, 'P/')
    .replace(/\b(GRAN SUS|GRAN SOL|PO SUS|SUS|SOL) PED\b/g, '$1')
    .replace(/ PED\b/g, '')
    .replace(/\bLIB (?:CONTROLADA|CONTROL|CONTR|CONT|LENTA|LENT)\b/g, 'LIB PROL')
    .replace(/^(\S+ MG) RETARD COM REV\b/, '$1 COM REV LIB PROL')
    .replace(/\bCOMP\b/g, 'COM')
    .replace(/\bCAP GELAT\b/g, 'CAP GEL')
    .replace(/\bSOL OR GOT\b/g, 'SOL OR')
    .replace(/\bSOL LIB PROL (IM)\b/g, 'SOL INJ $1')
    .replace(/\bACUPHASE\b/g, '')
    .replace(/\bCT(\d)/g, 'CT $1')
    .replace(/[.\-]+$/, '')
    .replace(/\bLIB PROL 24 ?H\b/g, 'LIB PROL')
    .replace(/\bCOM ABS RET\b/g, 'COM LIB PROL')
    .replace(/\bORODISPERSIVE(?:IS|L)\b/g, 'ORODISP')
    .replace(/\bSOL INJ (IM|IV) DEPOT\b/g, 'SOL INJ $1')
    .replace(/\bPO LIOF (?=CT|CX|FA)/g, 'PO LIOF SOL INJ ')
    .replace(/\bCR\b(?= (?:DERM|VAG))/g, 'CREM')
    .replace(/\bPO (?:P\/? ?)?(?:PREP )?(?:EXTEMP|EXT)\b(?: (?:SUS|SOL))?/g, 'PO SUS')
    .replace(/\bPO P\/? ?(SUS|SOL)\b/g, 'PO $1')
    .replace(/\bSUS OR EXT\b/g, 'SUS OR')
    .replace(/\b(SOL|SUS) INJ\/INFUS\b/g, '$1 INJ')
    .replace(/\bPO LIOF P\/? ?SOL\b/g, 'PO LIOF SOL')
    .replace(/\bPO (LIOF )?INJ\b/g, 'PO $1SOL INJ')
    .replace(/\bCOMP ?REV\b|\bCOMREV\b/g, 'COM REV')
    .replace(/\bSUS OR INF\b/g, 'SUS OR')
    .replace(/([A-Z]{3,})X (\d)/g, '$1 X $2')
    .replace(/\b(PVC|PVDC|PE|PEAD|PEBD|AL|PET|PP|PCTFE|PLAS|PAP)\+(?=(?:PVC|PVDC|PE|PEAD|PEBD|AL|PET|PP|PCTFE|PLAS|PAP)\b)/g, '$1/')
    .replace(/  +/g, ' ');
}

const UNI = { MCG: 'mcg', MG: 'mg', G: 'g', MUI: 'MUI', UI: 'UI', U: 'U', UTR: 'UTR', ML: 'mL', MEQ: 'mEq', '%': '%', L: 'L', H: 'h', DOSE: 'dose' };
const NUM = String.raw`\d+(?:[.,]\d+)*`;
const UN = String.raw`(?:MCG|MG|G|MUI|UI|UTR|U|ML|MEQ|%)`;
const DEN = String.raw`(?:\/(?:\d+(?:,\d+)?\s*)?(?:ML|G|L|H|DOSE))`;

function fmtNum(t) {
  t = t.trim();
  if (/^\d{1,3}(\.\d{3})+$/.test(t)) t = t.replace(/\./g, '');
  t = t.replace('.', ',');
  if (t.includes(',')) t = t.replace(/0+$/, '').replace(/,$/, '');
  t = t.replace(/^0+(?=\d)/, '');
  // milhares com ponto (6.000 UI -> 6.000; 100000 -> 100.000)
  const [int, dec] = t.split(',');
  const intFmt = int.length > 3 ? int.replace(/\B(?=(\d{3})+(?!\d))/g, '.') : int;
  return dec ? `${intFmt},${dec}` : intFmt;
}
const valor = (n) => Number(n.replace(/\.(?=\d{3}\b)/g, '').replace(',', '.'));
// Massa na unidade usual: 0,5 g -> 500 mg; 1000 mg -> 1 g; 0,05 mg -> 50 mcg.
function normalizarMassa(d) {
  const v = valor(d.n);
  if (d.u === 'G' && v < 1) return { ...d, n: String(Math.round(v * 1e6) / 1e3).replace('.', ','), u: 'MG' };
  if (d.u === 'MG' && v >= 1000 && v % 1000 === 0) return { ...d, n: String(v / 1000), u: 'G' };
  if (d.u === 'MG' && v > 0 && v < 0.1) return { ...d, n: String(Math.round(v * 1e6) / 1e3).replace('.', ','), u: 'MCG' };
  return d;
}
function fmtDose(d) {
  d = normalizarMassa(d);
  const den = d.den ? `/${d.den.replace(/^\//, '').replace(/^(\d+(?:,\d+)?)\s*/, (m, n) => `${fmtNum(n)} `).replace(/[A-Z]+$/, (u) => UNI[u])}` : '';
  return d.u === '%' ? `${fmtNum(d.n)}%` : `${fmtNum(d.n)} ${UNI[d.u]}${den}`;
}

// Concentração impressa (máx. 40 caracteres): "875 mg + 125 mg"; se passar do
// limite e todas as doses tiverem o mesmo denominador, fatora
// "(3,5 mg + 10.000 UI + 0,25 mg + 20 mg)/mL" e, em último caso, tira os
// espaços em volta de "+".
function fmtConcentracao(doses) {
  const normal = doses.map(fmtDose).join(' + ');
  const dens = new Set(doses.map((d) => d.den || ''));
  const comum = doses.length > 1 && dens.size === 1 && doses[0].den;
  if (!comum || (normal.length <= 40 && !/\d/.test(doses[0].den))) return normal;
  const semDen = doses.map((d) => fmtDose({ ...d, den: undefined }));
  const den = fmtDose({ n: '1', u: 'MG', den: doses[0].den }).replace(/^1 mg/, '');
  const fatorada = `(${semDen.join(' + ')})${den}`;
  return fatorada.length <= 40 ? fatorada : `(${semDen.join('+')})${den}`;
}

// Lê a sequência de doses do início da descrição. Formatos vistos:
// "875 MG + 125 MG", "(875+ 125) MG", "(1 MG + 5 MG + 6.000 UI)/ML",
// "(10 +5) MG/ML + 10.000 UI/ML", "62,5 + 4,380 + 1,250 + 2,5 MG".
function lerDoses(s) {
  const doses = [];
  let r = s;
  const reGrupo = new RegExp(String.raw`^\(\s*([^()]*?)\s*\)\s*(${UN})?\s*(${DEN})?`);
  const reParte = new RegExp(String.raw`^(${NUM})\s*(${UN})?\s*(${DEN})?$`);
  const reDose = new RegExp(String.raw`^(${NUM})\s*(${UN})?\s*(${DEN})?(?=[\s+]|$)`);
  for (;;) {
    let m = r.match(reGrupo);
    if (m && /\d/.test(m[1])) {
      for (const parte of m[1].split('+')) {
        const p = parte.trim().match(reParte);
        if (!p) return null;
        doses.push({ n: p[1], u: p[2] || m[2], den: p[3] || m[3] });
      }
      r = r.slice(m[0].length).trim();
    } else {
      m = r.match(reDose);
      if (!m) break;
      doses.push({ n: m[1], u: m[2], den: m[3] });
      r = r.slice(m[0].length).trim();
    }
    const prox = r.match(/^\+\s*(?=[\d(])/);
    if (!prox) break;
    r = r.slice(prox[0].length);
  }
  if (!doses.length) return null;
  // Números sem unidade herdam a unidade seguinte ("62,5 + 4,38 MG").
  for (let i = doses.length - 1, u = null, den = null; i >= 0; i--) {
    if (doses[i].u) { u = doses[i].u; den = doses[i].den; } else if (u) { doses[i].u = u; doses[i].den ||= den; }
  }
  if (doses.some((d) => !d.u)) return null;
  // Denominador ausente em parte das doses ("2,0 MG + 10 MG/ML"): herda o comum.
  const dens = [...new Set(doses.filter((d) => d.den).map((d) => d.den))];
  if (dens.length === 1) for (const d of doses) d.den ||= dens[0];
  return { doses, resto: r };
}

// Formas: [abreviação, forma base, via implícita]
const FORMAS = [
  ['COM REV LIB PROL', 'comprimido revestido de liberação prolongada', 'oral'],
  ['COM REV LIB RETARD', 'comprimido revestido de liberação retardada', 'oral'],
  ['COM REV LIB MOD', 'comprimido revestido de liberação modificada', 'oral'],
  ['COM REV', 'comprimido revestido', 'oral'],
  ['COM LIB PROL', 'comprimido de liberação prolongada', 'oral'],
  ['COM LIB RETARD', 'comprimido de liberação retardada', 'oral'],
  ['COM LIB MOD', 'comprimido de liberação modificada', 'oral'],
  ['COM DISP', 'comprimido para suspensão', 'oral'],
  ['COM DISPERS', 'comprimido para suspensão', 'oral'],
  ['COM SUS', 'comprimido para suspensão', 'oral'],
  ['COM EFEV', 'comprimido efervescente', 'oral'],
  ['COM SOL', 'comprimido para solução', 'oral'],
  ['COM MAST', 'comprimido mastigável', 'oral'],
  ['COM VAG', 'comprimido vaginal', 'vaginal'],
  ['COM ORODISP', 'comprimido orodispersível', 'oral'],
  ['COM SUBL', 'comprimido sublingual', 'sublingual'],
  ['COM SUB-LING', 'comprimido sublingual', 'sublingual'],
  ['COM LIB CONTR', 'comprimido de liberação prolongada', 'oral'],
  ['COM LIB LENTA', 'comprimido de liberação prolongada', 'oral'],
  ['COM DESINT LENTA', 'comprimido de liberação prolongada', 'oral'],
  ['COM REV LIB CONTR', 'comprimido revestido de liberação prolongada', 'oral'],
  ['COM REV LIB LENTA', 'comprimido revestido de liberação prolongada', 'oral'],
  ['COM', 'comprimido', 'oral'],
  ['DRG', 'comprimido revestido', 'oral'],
  ['CAP DURA LIB PROL', 'cápsula dura de liberação prolongada', 'oral'],
  ['CAP DURA LIB RETARD', 'cápsula dura de liberação retardada', 'oral'],
  ['CAP DURA C/MGRAN RETARD', 'cápsula dura de liberação retardada', 'oral'],
  ['CAP GEL DURA LIB PROL', 'cápsula dura de liberação prolongada', 'oral'],
  ['CAP DURA LIB MOD', 'cápsula dura de liberação modificada', 'oral'],
  ['CAP MOLE LIB PROL', 'cápsula mole de liberação prolongada', 'oral'],
  ['CAP GEL DURA', 'cápsula dura', 'oral'],
  ['CAP DURA', 'cápsula dura', 'oral'],
  ['CAP GEL MOLE', 'cápsula mole', 'oral'],
  ['CAP MOLE', 'cápsula mole', 'oral'],
  ['CAP GEL', 'cápsula dura', 'oral'],
  ['CAP', 'cápsula dura', 'oral'],
  ['OVL', 'óvulo', 'vaginal'],
  ['PO SUS OR', 'pó para suspensão', 'oral'],
  ['PO SUS', 'pó para suspensão', 'oral'],
  ['PO SOL OR', 'pó para solução', 'oral'],
  ['PO LIOF SOL INJ', 'pó liofilizado para solução injetável', null],
  ['PO SOL INJ', 'pó para solução injetável', null],
  ['PO SOL INFUS', 'pó para solução para infusão', 'intravenosa'],
  ['PO SUS INJ', 'pó para suspensão injetável', null],
  ['PO', 'pó', 'dermatológica'],
  ['GRAN SOL', 'granulado para solução', 'oral'],
  ['GRAN SUS', 'granulado para suspensão', 'oral'],
  ['GRAN', 'granulado', 'oral'],
  ['SOL INJ', 'solução injetável', null],
  ['SOL INFUS', 'solução para infusão', 'intravenosa'],
  ['SUS INJ', 'suspensão injetável', null],
  ['SOL GOT', 'solução', null],
  ['SOL SPR', 'solução spray', null],
  ['SOL', 'solução', null],
  ['SUS GOT', 'suspensão', null],
  ['SUS', 'suspensão', null],
  ['EMU', 'emulsão', null],
  ['XPE', 'xarope', 'oral'],
  ['ELX', 'elixir', 'oral'],
  ['GEL CREM', 'gel creme', 'dermatológica'],
  ['CREM', 'creme', 'dermatológica'],
  ['POM', 'pomada', 'dermatológica'],
  ['GEL', 'gel', 'dermatológica'],
  ['LOC', 'loção', 'dermatológica'],
  ['SAB', 'sabonete', 'dermatológica'],
  ['ADES TRANSD', 'adesivo transdérmico', 'transdérmica'],
  ['ADES TRANS', 'adesivo transdérmico', 'transdérmica'],
  ['ADES', 'adesivo transdérmico', 'transdérmica'],
].map(([abr, forma, via]) => ({ tokens: abr.split(' '), forma, via }))
  .sort((a, b) => b.tokens.length - a.tokens.length);

const VIAS = {
  OR: 'oral', OFT: 'oftálmica', OTO: 'otológica', VAG: 'vaginal', GINEC: 'vaginal', DERM: 'dermatológica', TOP: 'dermatológica',
  NAS: 'nasal', IM: 'intramuscular', IV: 'intravenosa', SC: 'subcutânea', INAL: 'inalatória', RET: 'retal', EPI: 'epidural', IT: 'intratecal',
  SUBL: 'sublingual', BUC: 'bucal', IA: 'intra-articular', ID: 'intradérmica', TRANSD: 'transdérmica',
};
const USO_DA_VIA = { oftálmica: 'oftalmico', otológica: 'otologico', vaginal: 'vaginal', dermatológica: 'topico', nasal: 'topico' };
const ADJETIVO = { oral: 'oral', oftálmica: 'oftálmica', otológica: 'otológica', vaginal: 'vaginal', nasal: 'nasal' };
const EMBALAGEM = new Set(['CT', 'CX', 'EMB', 'EST', 'BL', 'STR', 'STRIP', 'FR', 'FA', 'AMP', 'ENV', 'ENVOL', 'BG', 'TB', 'BOLS', 'SER', 'CAR', 'CARP', 'FLAC', 'PT', 'SACH', 'KIT', 'X', 'DISP', '+']);
const RECIPIENTES = [
  ['AMP', 'ampola', 'ampolas'], ['FA', 'frasco-ampola', 'frascos-ampola'], ['SER', 'seringa preenchida', 'seringas preenchidas'],
  ['CARP?', 'carpule', 'carpules'], ['BOLS', 'bolsa', 'bolsas'], ['FLAC', 'flaconete', 'flaconetes'], ['FR', 'frasco', 'frascos'],
  ['BG', 'bisnaga', 'bisnagas'], ['TB', 'tubo', 'tubos'], ['PT', 'pote', 'potes'], ['ENV', 'envelope', 'envelopes'], ['SACH', 'sachê', 'sachês'],
  ['CAN', 'caneta', 'canetas'],
];
const CONTAVEIS = [[/^comprimido/, 'comprimidos'], [/^cápsula/, 'cápsulas'], [/^óvulo/, 'óvulos'], [/^adesivo/, 'adesivos']];

// Kits de erradicação de H. pylori: "500 MG CAP DURA + 500 MG COM REV + 20 MG COM REV LIB RETARD CT ..."
function lerKit(s) {
  const doses = [...s.matchAll(/(?:^|\+\s*)(\d+(?:,\d+)?)\s*MG\s+(?:CAP|COM)\b/g)].map((m) => ({ n: m[1], u: 'MG' }));
  return doses.length >= 2 ? doses : null;
}

function lerApresentacao(desc) {
  const s = normDesc(desc);
  const kit = lerKit(s);
  if (kit) return { doses: kit, forma: 'kit', via: 'oral', unidade: 'kit', quantidade: 1 };
  const ld = lerDoses(s);
  if (!ld) return { erro: 'concentração' };
  let tokens = ld.resto.split(' ');
  const f = FORMAS.find((x) => x.tokens.every((t, i) => tokens[i] === t));
  if (!f) return { erro: 'forma farmacêutica' };
  tokens = tokens.slice(f.tokens.length);
  const rotas = [];
  let sufixo = '';
  let base = f.forma;
  for (let i = 0; i < 2; i++) {
    if (tokens[0] === 'LIB' && tokens[1] === 'PROL') { tokens = tokens.slice(2); sufixo = ' de liberação prolongada'; }
    while (tokens.length && tokens[0].split('/').every((t) => VIAS[t])) rotas.push(...tokens.shift().split('/'));
  }
  if (tokens[0] === 'SPR' && base === 'solução') { tokens = tokens.slice(1); base = 'solução spray'; }
  if (tokens.length && !EMBALAGEM.has(tokens[0])) return { erro: 'forma farmacêutica' };
  let via = rotas.length ? [...new Set(rotas.map((r) => VIAS[r]))].join(' ou ') : f.via;
  if (!rotas.length && /^pó para solução injetável|^pó liofilizado|^solução injetável|^suspensão injetável|^pó para suspensão injetável/.test(f.forma)) via = null;
  const primeiraVia = rotas.length ? VIAS[rotas[0]] : f.via;
  let forma = base;
  if (primeiraVia && ADJETIVO[primeiraVia] && /^(solução|suspensão|emulsão|pomada|creme|gel|pó para suspensão|pó para solução|granulado para suspensão|granulado para solução)$/.test(forma)) forma += ` ${ADJETIVO[primeiraVia]}`;
  forma += sufixo;
  const emb = tokens.join(' ');
  const semAcessorios = emb.split(/\s*\+\s*/)[0];

  const contavel = CONTAVEIS.find(([re]) => re.test(forma));
  if (contavel) {
    const mult = semAcessorios.match(/\b(?:CT|CX|EMB|EST)\s+(\d+)\s+(?:BL|STR|STRIP|ENV|ENVOL|SACH|FR|FLAC|BG|TB|PT)\b/);
    const xs = [...semAcessorios.matchAll(/\bX\s*(\d+)(?![\d,.])(?!\s*(?:ML|L|G|MG|MCG)\b)/g)];
    const n = xs.length ? Number(xs.at(-1)[1]) : null;
    const k = mult ? Number(mult[1]) : null;
    const quantidade = n && k ? n * k : n || k;
    if (!quantidade) return { erro: 'quantidade' };
    // Rótulo sempre no plural, como em medicamentos-controlados.json (o PDF imprime "quantidade unidade").
    return { doses: ld.doses, forma, via, unidade: contavel[1], quantidade };
  }
  const rec = RECIPIENTES.find(([abr]) => new RegExp(`\\b${abr}\\b`).test(semAcessorios)) || ['', 'frasco', 'frascos'];
  const mult = semAcessorios.match(new RegExp(String.raw`\b(?:CT|CX|EMB|EST)\s+(?:X\s*)?(\d+)\s+(?:ENVOL\s+)?${rec[0] || 'FR'}\b`));
  const quantidade = mult ? Number(mult[1]) : 1;
  let unidade = quantidade > 1 ? rec[2] : rec[1];
  if (/^pó para solução injetável|^pó liofilizado|^pó para suspensão injetável|^pó para solução para infusão/.test(forma)) {
    if (/\bDIL\b/.test(emb)) unidade += ' com diluente';
  } else {
    // Volume antes dos acessórios; "FR ... + GOT X 5 ML" (conta-gotas antes do volume) também vale.
    let vols = [...semAcessorios.matchAll(/\bX\s*(\d+(?:,\d+)?)\s*(ML|L|G)\b/g)];
    if (!vols.length) vols = [...emb.matchAll(/\+\s*(?:GOT|CGT)\s+X\s*(\d+(?:,\d+)?)\s*(ML)\b/g)];
    if (vols.length) unidade += ` de ${fmtNum(vols.at(-1)[1])} ${UNI[vols.at(-1)[2]]}`;
  }
  return { doses: ld.doses, forma, via, unidade, quantidade };
}

function emMassa(d) {
  if (d.u === '%') return valor(d.n); // só se compara % com % (mesmo denominador)
  const f = { MCG: 0.001, MG: 1, G: 1000 }[d.u];
  return f ? valor(d.n) * f : null;
}
const eUI = (d) => ['UI', 'MUI', 'U', 'UTR'].includes(d.u);

// Atribui as doses lidas aos componentes (na ordem do nome impresso).
function atribuirDoses(doses, bases) {
  if (bases.length === 1) return doses.length === 1 ? doses : null;
  const regra = ASSOCIACOES[[...bases].sort().join('+')];
  if (doses.length === 1 && regra?.doseTotal) return doses; // dose total do produto
  if (doses.length !== bases.length) return null;
  const iguais = doses.every((d) => d.u === doses[0].u && d.den === doses[0].den && valor(d.n) === valor(doses[0].n));
  if (iguais) return doses;
  if (!regra) return null;
  if (regra.posicional) {
    const ordem = [...bases].sort();
    return bases.map((b) => doses[ordem.indexOf(b)]);
  }
  const massa = doses.filter((d) => !eUI(d));
  const ui = doses.filter(eUI);
  if (massa.length !== regra.massa.length || ui.length !== (regra.ui?.length || 0)) return null;
  if (massa.some((d) => emMassa(d) === null)) return null;
  if (new Set(massa.map((d) => d.u === '%')).size > 1) return null;
  const densMassa = new Set(massa.map((d) => d.den || ''));
  if (densMassa.size > 1) return null;
  massa.sort((a, b) => emMassa(b) - emMassa(a));
  ui.sort((a, b) => valor(b.n) - valor(a.n));
  const porBase = new Map();
  regra.massa.forEach((b, i) => porBase.set(b, massa[i]));
  (regra.ui || []).forEach((b, i) => porBase.set(b, ui[i]));
  const out = bases.map((b) => porBase.get(b));
  return out.every(Boolean) ? out : null;
}

// ---------------------------------------------------------------------------
// CMED: marca (PRODUTO), laboratório, tipo (genérico/similar/novo...), tarja
// e restrição hospitalar por texto de apresentação.
// ---------------------------------------------------------------------------

const chaveApres = (s) => semAcento(s.toUpperCase()).replace(/\s+/g, '').replace(/(\d)\.(\d{3})(?!\d)/g, '$1$2').replace(/\./g, ',');

function marcaExibida(p) {
  const MANTER = new Set(['BD', 'XR', 'LA', 'SL', 'CR', 'XL', 'LP', 'ODT', 'AP', 'IV', 'IM', 'EF', 'SR', 'UD', 'DU', 'MR', 'ER', 'AC', 'HC', 'TR', 'DS', 'OD', 'II', 'III', 'NF', 'AM', 'IBL', 'MD', 'SP', 'EMS', 'IBP', 'MT', 'AT']);
  const MINUSC = new Set(['DE', 'DA', 'DO', 'E', 'COM']);
  return espacos(p.replace(/[–—]/g, '-').replace(/[®™]/g, '').replace(/\([^)]*\)/g, ' '))
    .split(' ')
    .map((w, i) => {
      if (/\d/.test(w) || MANTER.has(w) || (w.length <= 2 && i > 0)) return w;
      if (i && MINUSC.has(w)) return w.toLowerCase();
      return w.toLowerCase().replace(/(^|[-/.])(\p{L})/gu, (_, a, b) => a + b.toUpperCase());
    })
    .join(' ');
}

async function carregarCmed() {
  const arq = join(CACHE, 'cmed.csv');
  let buf;
  try {
    if (args.refazer) throw new Error();
    buf = await readFile(arq);
    log(`[cmed] usando cache ${arq}`);
  } catch {
    log(`[cmed] baixando ${CMED_URL}`);
    buf = await baixar(CMED_URL);
    await mkdir(CACHE, { recursive: true });
    await writeFile(arq, buf);
  }
  const texto = buf.toString('utf8').replace(/^﻿/, '');
  const ini = texto.search(/^SUBST[ÂA]NCIA;/m);
  if (ini < 0) throw new Error('[cmed] cabeçalho não encontrado');
  const preambulo = texto.slice(0, ini);
  const publicacao = (preambulo.match(/Publicada em\s*(\d{2}\/\d{2}\/\d{4})/i) || [])[1] || null;
  const it = linhasCSV(texto.slice(ini));
  const cab = it.next().value.map((c) => espacos(c));
  const col = (re) => {
    const i = cab.findIndex((c) => re.test(c));
    if (i < 0) throw new Error(`[cmed] coluna ausente: ${re}`);
    return i;
  };
  const c = {
    sub: col(/^SUBST/), lab: col(/^LABORAT/), prod: col(/^PRODUTO$/), apres: col(/^APRESENTA/), tipo: col(/^TIPO DE PRODUTO/),
    hosp: col(/^RESTRI..O HOSPITALAR/), tarja: col(/^TARJA/), com: col(/^COMERCIALIZA/),
  };
  const linhas = [];
  for (const r of it) {
    if (r.length < cab.length) continue;
    const comps = [...new Set(r[c.sub].split(/\s*[;+\n]\s*/).map(chave).filter((x) => x && !EXCIPIENTES.has(x)))];
    linhas.push({
      comps, produto: espacos(r[c.prod]), lab: espacos(r[c.lab]), apres: espacos(r[c.apres]), tipo: espacos(r[c.tipo]),
      hosp: /^sim$/i.test(espacos(r[c.hosp])), semTarja: /sem tarja/i.test(r[c.tarja]), comercializado: /^sim$/i.test(espacos(r[c.com])),
      colunaComercializacao: cab[c.com],
    });
  }
  return { linhas, publicacao, colunaComercializacao: cab[c.com] };
}


// ---------------------------------------------------------------------------
// Montagem
// ---------------------------------------------------------------------------

// Material de embalagem com "+" ("CT 3 ENV AL + POLIET X 10") não é acessório.
const MATERIAL = /\b(AL|PLAS|PVC|PVDC|PE|PEAD|PEBD|POLIET|PAP|PET|PP)\s*\+\s*(?=(?:AL|PLAS|PVC|PVDC|PE|PEAD|PEBD|POLIET|PAP|PET|PP)\b)/g;
const ler = (apres) => lerApresentacao(normDesc(apres).replace(MATERIAL, '$1/'));
// "20 MG CAP BL X 100", "10 MG CAP GEL CT ...": cápsula sem DURA/MOLE; a forma
// vem das outras apresentações com a mesma concentração.
const capsulaGenerica = (apres) => /\bCAP (?:GEL )?(?!DURA|MOLE|GEL)/.test(normDesc(apres));

function componentes(pa) {
  const vistos = new Set();
  const comps = [];
  for (const bruto of pa.split(/\s+\+\s+|;/)) {
    const c = chave(bruto);
    if (!c || vistos.has(c) || EXCIPIENTES.has(c)) continue;
    vistos.add(c);
    const e = listado(c);
    comps.push({ chave: c, exib: exibicao(bruto), listado: e, base: e ? e.base : baseDe(c) });
  }
  return comps;
}

function classificar(comps) {
  const c = comps.filter((x) => x.listado);
  if (!c.length) return null;
  for (const x of c) if (FORA[x.base]) return { fora: FORA[x.base] };
  // Ordem impressa: substância da lista primeiro.
  const ordem = [...c, ...comps.filter((x) => !x.listado).sort((a, b) => a.base.localeCompare(b.base))];
  return { classe: c[0].listado.lista, tipo: TIPO[c[0].listado.lista], comps: ordem, bases: ordem.map((x) => x.base) };
}

function sentenca(s) {
  return s.charAt(0).toUpperCase() + s.slice(1);
}
function escolherNome(nomes) {
  const grupos = new Map();
  for (const [n, v] of nomes) {
    const k = semAcento(n);
    const e = grupos.get(k) || { v: 0, variantes: [] };
    e.v += v;
    e.variantes.push([n, v]);
    grupos.set(k, e);
  }
  const melhor = [...grupos.values()].sort((a, b) => b.v - a.v)[0];
  const acentos = (x) => (x.match(/[^\x00-\x7f]/g) || []).length;
  return sentenca(melhor.variantes.sort((a, b) => acentos(b[0]) - acentos(a[0]) || b[1] - a[1])[0][0]);
}

// Marca exibida: PRODUTO não genérico; tira o nome da substância ("FUNED - TALIDOMIDA" -> "Funed").
function marcaDe(l, bases) {
  if (l.tipo === 'Genérico') return null;
  const tokensBase = new Set(bases.flatMap((b) => b.split(' ')));
  const resto = marcaExibida(l.produto).split(' ').filter((w) => !tokensBase.has(chave(w))).join(' ').replace(/^[\s\-]+|[\s\-]+$/g, '');
  return resto && /[A-Za-zÀ-ÿ]/.test(resto) ? resto : null;
}

function montar(agregados, cmed) {
  const excluidas = new Map(); // motivo -> Map(item -> embalagens com código 3)
  const excluir = (motivo, item, qt) => {
    if (!excluidas.has(motivo)) excluidas.set(motivo, new Map());
    const m = excluidas.get(motivo);
    m.set(item, (m.get(item) || 0) + qt);
  };
  const semVendaExcluidas = []; // apresentações CMED excluídas
  const naoLidas = [];

  // 1) SNGPC
  const grupos = new Map();
  const cacheComp = new Map();
  const grupo = (info) => {
    const k = info.bases.join('+');
    if (!grupos.has(k)) grupos.set(k, { ...info, nomes: new Map(), itens: [], cmed: [] });
    return grupos.get(k);
  };
  for (const row of agregados) {
    let info = cacheComp.get(row.pa);
    if (info === undefined) { info = classificar(componentes(row.pa)); cacheComp.set(row.pa, info); }
    if (!info) { if (row.tp === CODIGO) excluir('fora das listas C2/C3 (código 3 trocado na origem)', row.pa || '(vazio)', row.qt); continue; }
    if (info.fora) { if (row.tp === CODIGO) excluir(info.fora, row.pa, row.qt); continue; }
    const g = grupo(info);
    const nome = componentes(row.pa).map((x) => x.exib).join(' + ');
    g.nomes.set(nome, (g.nomes.get(nome) || 0) + row.qt);
    g.itens.push(row);
  }

  // 2) CMED: todas as apresentações das substâncias C2/C3 (menos lenalidomida e pomalidomida)
  for (const l of cmed.linhas) {
    const comps = l.comps.map((c) => { const e = listado(c); return { chave: c, exib: c, listado: e, base: e ? e.base : baseDe(c) }; });
    const info = classificar(comps);
    if (!info) continue;
    if (info.fora) { semVendaExcluidas.push(`${l.produto} | ${l.apres} (${info.fora.split(':')[0]})`); continue; }
    const g = grupo(info);
    if (!g.nomesCmed) g.nomesCmed = new Map();
    g.nomesCmed.set(exibicao(l.substanciaTexto || l.comps.join(' + ')), 1);
    g.cmed.push(l);
  }

  const substancias = [];
  for (const g of grupos.values()) {
    const notif = g.itens.filter((r) => r.tp === CODIGO);
    const usadas = soma(notif, (r) => r.qt) > 0 ? notif : g.itens;
    const pres = new Map();
    const porChave = (a) => `${fmtConcentracao(a.doses)}\t${a.forma}\t${a.via}`;
    const novo = (a) => ({ concentracao: fmtConcentracao(a.doses), forma: a.forma, via: a.via, vendas: 0, pacotesVenda: new Map(), pacotesCmed: new Map(), marcas: new Map(), generico: false, generica: true });
    const aceitar = (a, apres, qt, ondeExcluir) => {
      if (a.erro) { naoLidas.push(`${apres} (${a.erro})`); if (qt) ondeExcluir('descrição não lida', apres, qt); return false; }
      const uso = USO_DA_VIA[(a.via || 'oral').split(' ou ')[0]] || 'sistemico';
      if (uso !== 'sistemico') { if (qt) ondeExcluir('C2, adendo 2: retinoide de uso tópico (venda sem retenção)', apres, qt); return false; }
      const d = atribuirDoses(a.doses, g.bases);
      if (!d) { naoLidas.push(`${apres} (doses)`); if (qt) ondeExcluir('descrição não lida', apres, qt); return false; }
      a.doses = d;
      if (!a.via) a.via = 'oral';
      return true;
    };
    // Vendas (SNGPC)
    const porDesc = new Map();
    for (const r of usadas) porDesc.set(r.apres, (porDesc.get(r.apres) || 0) + r.qt);
    const cmedPorApres = new Map();
    for (const l of g.cmed) {
      const k = chaveApres(l.apres);
      if (!cmedPorApres.has(k)) cmedPorApres.set(k, []);
      cmedPorApres.get(k).push(l);
    }
    for (const [apres, qt] of porDesc) {
      const a = ler(apres);
      if (!aceitar(a, apres, qt, (m, i, v) => excluir(m, `${[...g.nomes.keys()][0]} | ${i}`, v))) continue;
      const linhas = cmedPorApres.get(chaveApres(apres)) || [];
      if (linhas.length && linhas.every((l) => l.hosp)) { excluir('uso restrito a hospitais (CMED)', apres, qt); continue; }
      const k = porChave(a);
      const p = pres.get(k) || novo(a);
      p.vendas += qt;
      if (!capsulaGenerica(apres)) p.generica = false;
      const kp = `${a.unidade}\t${a.quantidade}`;
      if (a.quantidade >= 1 && a.quantidade <= 999) p.pacotesVenda.set(kp, (p.pacotesVenda.get(kp) || 0) + qt);
      for (const l of linhas) {
        const m = marcaDe(l, g.bases);
        if (m) p.marcas.set(m, (p.marcas.get(m) || 0) + qt / linhas.length);
        if (l.tipo === 'Genérico') p.generico = true;
      }
      pres.set(k, p);
    }
    // Apresentações com preço CMED (com ou sem venda)
    for (const l of g.cmed) {
      if (l.hosp) { semVendaExcluidas.push(`${l.produto} | ${l.apres} (uso restrito a hospitais)`); continue; }
      if (l.semTarja) { semVendaExcluidas.push(`${l.produto} | ${l.apres} (isento de prescrição)`); continue; }
      const a = ler(l.apres);
      if (!aceitar(a, l.apres, 0, () => {})) { if (!a.erro) semVendaExcluidas.push(`${l.produto} | ${l.apres} (uso tópico)`); continue; }
      const k = porChave(a);
      const p = pres.get(k) || novo(a);
      p.generica = false;
      const kp = `${a.unidade}\t${a.quantidade}`;
      if (a.quantidade >= 1 && a.quantidade <= 999) p.pacotesCmed.set(kp, (p.pacotesCmed.get(kp) || 0) + 1);
      const m = marcaDe(l, g.bases);
      if (m && !p.marcas.has(m)) p.marcas.set(m, 0);
      if (l.tipo === 'Genérico') p.generico = true;
      pres.set(k, p);
    }
    // Cápsula sem DURA/MOLE: junta na apresentação de cápsula com a mesma concentração.
    for (const [k, p] of [...pres]) {
      if (!p.generica || !/^cápsula/.test(p.forma)) continue;
      const alvo = [...pres.values()].find((q) => q !== p && !q.generica && /^cápsula/.test(q.forma) && q.concentracao === p.concentracao && q.via === p.via);
      if (!alvo) continue;
      alvo.vendas += p.vendas;
      for (const [kp, v] of p.pacotesVenda) alvo.pacotesVenda.set(kp, (alvo.pacotesVenda.get(kp) || 0) + v);
      pres.delete(k);
    }
    const valorConc = (c) => valor((c.match(/[\d.,]+/) || ['0'])[0]);
    const apresentacoes = [...pres.values()]
      .map((p) => {
        const pacotes = p.pacotesVenda.size ? [...p.pacotesVenda].sort((a, b) => b[1] - a[1]) : [...p.pacotesCmed].sort((a, b) => b[1] - a[1] || Number(a[0].split('\t')[1]) - Number(b[0].split('\t')[1]));
        if (!pacotes.length) return null;
        const [unidade, q] = pacotes[0][0].split('\t');
        const marcas = [...p.marcas].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([m]) => m);
        return { concentracao: p.concentracao, forma: p.forma, via: p.via, unidade, quantidade: Number(q), vendas: p.vendas, marcas, generico: p.generico };
      })
      .filter(Boolean)
      .sort((a, b) => b.vendas - a.vendas || valorConc(a.concentracao) - valorConc(b.concentracao) || a.forma.localeCompare(b.forma));
    if (!apresentacoes.length) continue;
    const nomes = g.nomes.size ? g.nomes : g.nomesCmed;
    const marcasBusca = [...new Set(apresentacoes.flatMap((p) => p.marcas.map((m) => semAcento(m.toLowerCase()))))];
    substancias.push({
      nome: escolherNome(nomes), chave: g.bases.map(semAcento).join('+'), classe: g.classe, tipo: g.tipo, uso: 'sistemico',
      busca: [...new Set([...g.bases.map(semAcento), ...marcasBusca])], vendas: soma(apresentacoes, (p) => p.vendas), apresentacoes,
    });
  }
  const ordemTipo = ['NRR', 'NRT'];
  substancias.sort((a, b) => ordemTipo.indexOf(a.tipo) - ordemTipo.indexOf(b.tipo) || b.vendas - a.vendas || a.nome.localeCompare(b.nome));
  return { substancias, excluidas, semVendaExcluidas, naoLidas };
}

// ---------------------------------------------------------------------------
// Validação (falha alto antes de gravar)
// ---------------------------------------------------------------------------

const PERMITIDOS = /^[A-Za-zÀ-ÖØ-öø-ÿ0-9 .,;:()\/\-'"ªº°%+&#*!?]*$/;
function validar(saida) {
  const erros = [];
  const strings = (v, onde) => {
    if (typeof v === 'string') { if (!PERMITIDOS.test(v)) erros.push(`${onde}: caractere não permitido em ${JSON.stringify(v)}`); }
    else if (Array.isArray(v)) v.forEach((x, i) => strings(x, `${onde}[${i}]`));
    else if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) strings(x, `${onde}.${k}`);
  };
  strings(saida, '$');
  const max = (s, n, onde) => { if (typeof s !== 'string' || !s || s.length > n) erros.push(`${onde}: vazio ou maior que ${n}: ${JSON.stringify(s)}`); };
  const vistos = new Set();
  let anterior = null;
  saida.substancias.forEach((s, i) => {
    const onde = `substancias[${i}] (${s.nome})`;
    if (Object.keys(s).join(',') !== 'nome,chave,classe,tipo,uso,busca,vendas,apresentacoes') erros.push(`${onde}: campos inesperados`);
    max(s.nome, 120, `${onde}.nome`);
    if (!/^[a-z0-9 ]+(\+[a-z0-9 ]+)*$/.test(s.chave)) erros.push(`${onde}: chave inválida ${s.chave}`);
    if (!TIPO[s.classe] || TIPO[s.classe] !== s.tipo) erros.push(`${onde}: classe/tipo inválidos ${s.classe}/${s.tipo}`);
    if (s.uso !== 'sistemico') erros.push(`${onde}: só uso sistêmico`);
    if (vistos.has(s.chave)) erros.push(`${onde}: chave repetida`);
    vistos.add(s.chave);
    if (!Array.isArray(s.busca) || s.busca.some((b) => !/^[a-z0-9 .\-+&\/]+$/.test(b))) erros.push(`${onde}: busca inválida ${JSON.stringify(s.busca)}`);
    for (const b of s.chave.split('+')) if (!s.busca.includes(b)) erros.push(`${onde}: busca sem a base ${b}`);
    if (!Number.isInteger(s.vendas) || s.vendas < 0) erros.push(`${onde}: vendas inválidas`);
    if (anterior && anterior.tipo === s.tipo && anterior.vendas < s.vendas) erros.push(`${onde}: fora de ordem`);
    anterior = s;
    if (!Array.isArray(s.apresentacoes) || !s.apresentacoes.length || s.apresentacoes.length > 20) erros.push(`${onde}: apresentacoes inválidas`);
    const chaves = new Set();
    let somaV = 0;
    s.apresentacoes.forEach((p, j) => {
      const o = `${onde}.apresentacoes[${j}]`;
      if (Object.keys(p).join(',') !== 'concentracao,forma,via,unidade,quantidade,vendas,marcas,generico') erros.push(`${o}: campos inesperados`);
      max(p.concentracao, 40, `${o}.concentracao`);
      max(p.forma, 60, `${o}.forma`);
      max(p.via, 40, `${o}.via`);
      max(p.unidade, 40, `${o}.unidade`);
      if (p.forma !== p.forma.toLowerCase()) erros.push(`${o}: forma deve ser minúscula`);
      if (/µ/.test(p.concentracao)) erros.push(`${o}: use mcg`);
      if (!Number.isInteger(p.quantidade) || p.quantidade < 1 || p.quantidade > 999) erros.push(`${o}: quantidade ${p.quantidade}`);
      if (!Number.isInteger(p.vendas) || p.vendas < 0) erros.push(`${o}: vendas ${p.vendas}`);
      if (!Array.isArray(p.marcas) || p.marcas.some((m) => typeof m !== 'string' || !m || m.length > 60)) erros.push(`${o}: marcas inválidas`);
      if (typeof p.generico !== 'boolean') erros.push(`${o}: generico deve ser booleano`);
      const kp = `${p.concentracao}|${p.forma}|${p.via}`;
      if (chaves.has(kp)) erros.push(`${o}: apresentação repetida`);
      chaves.add(kp);
      if (j && s.apresentacoes[j - 1].vendas < p.vendas) erros.push(`${o}: fora de ordem`);
      somaV += p.vendas;
    });
    if (somaV !== s.vendas) erros.push(`${onde}: vendas diferente da soma das apresentações`);
  });
  if (erros.length) throw new Error(`validação falhou (${erros.length}):\n  ${erros.slice(0, 60).join('\n  ')}`);
}

// ---------------------------------------------------------------------------
// Execução
// ---------------------------------------------------------------------------

const agregados = await carregarAgregados();
const cmed = await carregarCmed();
const { substancias, excluidas, semVendaExcluidas, naoLidas } = montar(agregados, cmed);
const d = new Date();
const hoje = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const mes = (m) => `${m.slice(0, 4)}-${m.slice(4)}`;
const saida = {
  gerado: args.data || hoje,
  fontes: {
    listas: FONTE_LISTAS,
    sngpc: {
      periodo: MESES.length > 1 ? `${mes(MESES[0])} a ${mes(MESES.at(-1))}` : mes(MESES[0]),
      url: 'https://dados.anvisa.gov.br/dados/SNGPC/Industrializados/',
      receituario: CODIGO,
    },
    // O arquivo é TA_PRECO_MEDICAMENTO.csv; "_" não é permitido, então vai a pasta.
    cmed: { arquivo: `Lista de preços de medicamentos CMED${cmed.publicacao ? `, publicada em ${cmed.publicacao}` : ''}`, url: 'https://dados.anvisa.gov.br/dados/' },
  },
  substancias,
};
validar(saida);

const json = `{"gerado":${JSON.stringify(saida.gerado)},"fontes":${JSON.stringify(saida.fontes)},"substancias":[\n${substancias.map((s) => JSON.stringify(s)).join(',\n')}\n]}\n`;
JSON.parse(json);
await mkdir(dirname(SAIDA), { recursive: true });
await writeFile(SAIDA, json);

const totalMap = (m) => [...m.values()].reduce((a, b) => a + b, 0);
log(`\ngravado ${SAIDA} (${(Buffer.byteLength(json) / 1024).toFixed(1)} KB); substâncias: ${substancias.length}; apresentações: ${soma(substancias, (s) => s.apresentacoes.length)}`);
for (const s of substancias) {
  log(`${s.tipo} ${s.classe} ${s.nome} [${s.chave}] ${s.vendas}`);
  for (const p of s.apresentacoes) log(`   ${String(p.vendas).padStart(7)} | ${p.concentracao} ${p.forma} (${p.via}), ${p.quantidade} ${p.unidade} | ${p.marcas.join(', ') || '-'}${p.generico ? ' + genéricos' : ''}`);
}
log('exclusões (embalagens com código 3):');
for (const [motivo, m] of [...excluidas].sort((a, b) => totalMap(b[1]) - totalMap(a[1]))) {
  log(`  ${String(totalMap(m)).padStart(9)}  ${motivo} (${m.size})`);
  if (args.relatorio) for (const [n, v] of [...m].sort((a, b) => b[1] - a[1]).slice(0, 15)) log(`      ${v}\t${n}`);
}
log(`apresentações CMED excluídas: ${semVendaExcluidas.length}`);
if (args.relatorio) { for (const x of semVendaExcluidas) log(`  ${x}`); log(`não lidas: ${naoLidas.length}`); for (const x of naoLidas) log(`  ${x}`); }
