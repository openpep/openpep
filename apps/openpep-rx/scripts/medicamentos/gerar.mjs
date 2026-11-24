#!/usr/bin/env node
// Gera data/medicamentos-controlados.json: substâncias das listas A1, A2, A3, B1
// e B2 do Anexo I da Portaria SVS/MS 344/1998, ranqueadas pelas dispensações
// registradas no SNGPC (dados abertos da Anvisa), com as apresentações mais
// vendidas de cada uma. Veja data/PROVENANCE.md.
//
// Uso:
//   node scripts/medicamentos/gerar.mjs [opções]
//     --meses=202606,202607,202608   meses do SNGPC (AAAAMM) a agregar
//     --cache=DIR                    agregados/downloads (padrão: $MEDICAMENTOS_CACHE
//                                    ou <tmpdir>/cockpit-rx-medicamentos)
//     --refazer                      ignora o cache e baixa tudo de novo
//     --apenas-agregar               só baixa/agrega o SNGPC
//     --sem-cmed                     não busca nomes comerciais na lista CMED
//     --verificar-listas             confere as listas embutidas com o texto da RDC
//     --relatorio                    imprime relatório detalhado (top 10, não lidas)
//     --data=AAAA-MM-DD              valor de "gerado" (padrão: hoje)
//     --saida=ARQUIVO                caminho do JSON (padrão: data/medicamentos-controlados.json)

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
const SAIDA = resolve(args.saida || join(RAIZ, 'data', 'medicamentos-controlados.json'));

const SNGPC_URL = process.env.SNGPC_URL || 'https://dados.anvisa.gov.br/dados/SNGPC/Industrializados/';
const CMED_URL = 'https://dados.anvisa.gov.br/dados/TA_PRECO_MEDICAMENTO.csv';
const RDC = {
  ato: 'RDC nº 1.036/2026',
  data: '2026-07-09',
  // Página oficial da Anvisa que lista a RDC vigente (a URL do texto integral,
  // em RDC_TEXTO_URL, tem "=" e "_", fora do conjunto de caracteres permitido).
  url: 'https://www.gov.br/anvisa/pt-br/assuntos/medicamentos/controlados/lista-substancias',
};
const RDC_TEXTO_URL = 'https://anvisalegis.datalegis.net/action/ActionDatalegis.php?acao=abrirTextoAto&tipo=RDC&numeroAto=00001036&seqAto=000&valorAno=2026&orgao=RDC/DC/ANVISA/MS&codTipo=&desItem=&desItemFim=&cod_menu=1696&cod_modulo=134&pesquisa=true';

// Códigos de TP_RECEITUARIO segundo o dicionário de dados do SNGPC
// (Industrializados, v3.00, fev/2026): 1 = Receita de Controle Especial,
// 2 = Notificação de Receita B (azul), 3 = Notificação de Receita Especial,
// 4 = Notificação de Receita A (amarela), 5 = Antimicrobiano/GLP-1.
// Não há código próprio para a Notificação B2: ela é escriturada como 2.
const CODIGO = { NRA: '4', NRB: '2', NRB2: '2' };
const TIPO_DA_LISTA = { A1: 'NRA', A2: 'NRA', A3: 'NRA', B1: 'NRB', B2: 'NRB2' };
const ORDEM_TIPO = ['NRA', 'NRB', 'NRB2'];

const log = (...a) => console.error(...a);

// ---------------------------------------------------------------------------
// Utilidades
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

// Termos de hidratação são removidos do nome (e da chave de agrupamento):
// "Cloridrato de sibutramina monoidratado" -> "Cloridrato de sibutramina".
const HIDRATO = /\b(?:mono|di|tri|tetra|penta|hexa|hepta|hemi|hemiepta|sesqui)?-?h?idratad[oa]s?\b|\banidr[oa]s?\b/gi;

// Chave de comparação: minúsculas, sem acento, sem hidratação, sem hífen.
function chave(s) {
  return semAcento(s.toLowerCase())
    .replace(/\([^)]*\)/g, ' ')
    .replace(HIDRATO, ' ')
    .replace(/(\w)-(\w)/g, '$1$2')
    .replace(/dihidro/g, 'diidro')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}
// Texto exibido de um componente: minúsculas com acentos, sem hidratação.
const exibicao = (s) => espacos(s.toLowerCase().replace(/\([^)]*\)/g, ' ').replace(HIDRATO, ' '));

// ---------------------------------------------------------------------------
// 1. Agregação do SNGPC (streaming: curl | decodificação windows-1252 | soma)
// ---------------------------------------------------------------------------

const CABECALHO = 'NU_ANO_VENDA;NU_MES_VENDA;SG_UF_VENDA;NO_MUNICIPIO_VENDA;DS_PRINCIPIO_ATIVO;DS_DESCRICAO_APRESENTACAO;QT_VENDIDA;DS_UNIDADE_MEDIDA;NO_CONSELHO_PRESCRITOR;SG_UF_CONSELHO_PRESCRITOR;TP_RECEITUARIO;CO_CID10;SG_SEXO;NU_IDADE;NU_UNIDADE_IDADE';
const C_PA = 4, C_APRES = 5, C_QT = 6, C_UNID = 7, C_TP = 10;

// Separa uma linha `"a";"b";;"c"` respeitando aspas (e "" como aspas escapadas).
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
  // Os CSVs do SNGPC são ISO-8859-1/windows-1252 (ex.: 0xD3 = "Ó", 0xA0 = espaço duro).
  const dec = new TextDecoder('windows-1252');
  const acc = new Map();
  let resto = '';
  let linhas = 0, ruins = 0, bytes = 0, cabecalho = null, ultimoLog = Date.now();
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
    bytes += pedaco.length;
    const texto = resto + dec.decode(pedaco, { stream: true });
    const partes = texto.split('\n');
    resto = partes.pop();
    for (const l of partes) processa(l);
    if (Date.now() - ultimoLog > 30000) {
      ultimoLog = Date.now();
      log(`[${mes}] ${(bytes / 1e6).toFixed(0)} MB, ${linhas} linhas, ${acc.size} chaves`);
    }
  }
  processa(resto + dec.decode());
  await fim;
  if (!linhas) throw new Error(`[${mes}] nenhum dado lido`);
  log(`[${mes}] concluído: ${(bytes / 1e6).toFixed(0)} MB, ${linhas} linhas (${ruins} descartadas), ${acc.size} chaves`);
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
    const [tp, pa, apres, unid] = k.split('\t');
    return { tp: tp.replace(/\.$/, ''), pa, apres, unid, qt };
  });
}

// ---------------------------------------------------------------------------
// 2. Listas A1, A2, A3, B1 e B2 (Anexo I da Portaria SVS/MS 344/1998, na
//    redação da RDC nº 1.036, de 9/7/2026, DOU 13/7/2026). Copiadas do texto
//    oficial; confira com --verificar-listas.
// ---------------------------------------------------------------------------

const LISTAS = {
  A1: ['Acetilmetadol', 'Alfacetilmetadol', 'Alfameprodina', 'Alfametadol', 'Alfaprodina', 'Alfentanila', 'Alilprodina', 'Anileridina', 'Bezitramida', 'Benzetidina', 'Benzilmorfina', 'Benzoilmorfina', 'Betacetilmetadol', 'Betameprodina', 'Betametadol', 'Betaprodina', 'Buprenorfina', 'Butorfanol', 'Clonitazeno', 'Codoxima', 'Concentrado de palha de dormideira', 'Dextromoramida', 'Diampromida', 'Dietiltiambuteno', 'Difenoxilato', 'Difenoxina', 'Diidromorfina', 'Dimefeptanol (metadol)', 'Dimenoxadol', 'Dimetiltiambuteno', 'Dioxafetila', 'Dipipanona', 'Drotebanol', 'Etilmetiltiambuteno', 'Etonitazeno', 'Etoxeridina', 'Fenadoxona', 'Fenampromida', 'Fenazocina', 'Fenomorfano', 'Fenoperidina', 'Fentanila', 'Furetidina', 'Hidrocodona', 'Hidromorfinol', 'Hidromorfona', 'Hidroxipetidina', 'Intermediário da metadona (4-ciano-2-dimetilamina-4,4-difenilbutano)', 'Intermediário da moramida (ácido 2-metil-3-morfolina-1,1-difenilpropano carboxílico)', 'Intermediário "a" da petidina (4-ciano-1-metil-4-fenilpiperidina)', 'Intermediário "b" da petidina (éster etílico do ácido 4-fenilpiperidina-4-carboxilíco)', 'Intermediário "c" da petidina (ácido-1-metil-4-fenilpiperidina-4-carboxílico)', 'Isometadona', 'Levofenacilmorfano', 'Levometorfano', 'Levomoramida', 'Levorfanol', 'Metadona', 'Metazocina', 'Metildesorfina', 'Metildiidromorfina', 'Metopona', 'Mirofina', 'Morferidina', 'Morfina', 'Morinamida', 'Nicomorfina', 'Noracimetadol', 'Norlevorfanol', 'Normetadona', 'Normorfina', 'Norpipanona', 'N-oxicodeína', 'N-oximorfina', 'Ópio', 'Oripavina', 'Oxicodona', 'Oximorfona', 'Petidina', 'Piminodina', 'Piritramida', 'Proeptazina', 'Properidina', 'Racemetorfano', 'Racemoramida', 'Racemorfano', 'Remifentanila', 'Sufentanila', 'Tapentadol', 'Tebacona', 'Tebaína', 'Tilidina', 'Trimeperidina', 'Viminol'],
  A2: ['Acetildiidrocodeina', 'Codeína', 'Dextropropoxifeno', 'Diidrocodeína', 'Etilmorfina', 'Folcodina', 'Nalbufina', 'Nalorfina', 'Nicocodina', 'Nicodicodina', 'Norcodeína', 'Propiram', 'Tramadol'],
  A3: ['Anfetamina', 'Catina', 'Clorfentermina', 'Dexanfetamina', 'Dronabinol', 'Femetrazina', 'Fenciclidina', 'Fenetilina', 'Fenfluramina', 'Levanfetamina', 'Lisdexanfetamina', 'Metilfenidato', 'Metilsinefrina', 'Tanfetamina'],
  B1: ['Alfaxalona', 'Alobarbital', 'Alprazolam', 'Amineptina', 'Amobarbital', 'Aprobarbital', 'Armodafinila', 'Barbexaclona', 'Barbital', 'Bromazepam', 'Bromazolam', 'Brotizolam', 'Butabarbital', 'Butalbital', 'Camazepam', 'Carisoprodol', 'Cetamina', 'Cetazolam', 'Ciclobarbital', 'Clobazam', 'Clonazepam', 'Clonazolam', 'Clorazepam', 'Clorazepato', 'Clordiazepóxido', 'Cloreto de etila', 'Cloreto de metileno/diclorometano', 'Clotiazepam', 'Cloxazolam', 'Delorazepam', 'Diazepam', 'Diclazepam', 'Escetamina', 'Estazolam', 'Eszopiclona', 'Etclorvinol', 'Etilanfetamina (N-etilanfetamina)', 'Etinamato', 'Etizolam', 'Fenazepam', 'Fenobarbital', 'Flualprazolam', 'Flubromazolam', 'Fludiazepam', 'Flunitrazepam', 'Flunitrazolam', 'Flurazepam', 'GBL', 'GHB - (ácido gama - hidroxibutírico)', 'Glutetimida', 'Halazepam', 'Haloxazolam', 'Lefetamina', 'Lemborexante', 'Loflazepato de etila', 'Loprazolam', 'Lorazepam', 'Lormetazepam', 'Medazepam', 'Meprobamato', 'Mesocarbo', 'Metilfenobarbital (prominal)', 'Metiprilona', 'Midazolam', 'Modafinila', 'Nimetazepam', 'Nitrazepam', 'Norcanfano (fencanfamina)', 'Nordazepam', 'Oxazepam', 'Oxazolam', 'Pemolina', 'Pentazocina', 'Pentobarbital', 'Perampanel', 'Pinazepam', 'Pipradrol', 'Pirovalerona', 'Prazepam', 'Prolintano', 'Propilexedrina', 'Remimazolam', 'Secbutabarbital', 'Secobarbital', 'Temazepam', 'Tetrazepam', 'Tiamilal', 'Tiopental', 'Triazolam', 'Tricloroetileno', 'Triexifenidil', 'Vinilbital', 'Zaleplona', 'Zolpidem', 'Zopiclona'],
  B2: ['Aminorex', 'Anfepramona', 'Femproporex', 'Fendimetrazina', 'Fentermina', 'Mazindol', 'Mefenorex', 'Sibutramina'],
};

// Substâncias cujos adendos dispensam TODA preparação medicamentosa da
// notificação de receita: não entram no autocompletar de notificações.
// (Isenções parciais continuam na lista; as que o usuário confirmou vão marcadas
// com receita "RCE", veja RCE abaixo.)
const ISENTAS = {
  fenobarbital: 'B1, adendo 2: Receita de Controle Especial',
  metilfenobarbital: 'B1, adendo 2: Receita de Controle Especial',
  barbital: 'B1, adendo 2: Receita de Controle Especial',
  barbexaclona: 'B1, adendo 2: Receita de Controle Especial',
  perampanel: 'B1, adendo 9: Receita de Controle Especial',
  carisoprodol: 'B1, adendo 16: venda sob prescrição sem retenção',
};

// Apresentações que vão na Receita de Controle Especial, e não na notificação, pelos adendos (decisões do usuário
// em 29 e 30/09/2026): tramadol até 100 mg por unidade, isolado ou associado; codeína até 100 mg por unidade,
// isolada ou associada (inclui codeína + paracetamol e + diclofenaco); oxicodona de liberação prolongada até 40 mg,
// isolada ou com naloxona; buprenorfina em adesivo. Ficam marcadas com receita "RCE"; o catálogo da RCE as oferece.
const RCE = [
  { bases: ['tramadol'], ate: 100 },
  { bases: ['codeina'], ate: 100 },
  { bases: ['oxicodona'], forma: /liberacao prolongada|liberação prolongada/, ate: 40 },
  { bases: ['buprenorfina'], forma: /adesivo/ },
];
function doseMg(texto) {
  const m = String(texto).match(/^([\d.,]+)\s*(mcg|mg|g)\b/);
  if (!m) return null;
  const v = Number(m[1].replace(/\./g, '').replace(',', '.'));
  return m[2] === 'mcg' ? v / 1000 : m[2] === 'g' ? v * 1000 : v;
}
function vaiEmRCE(bases, p) {
  const b = bases.map(semAcento);
  return RCE.some((r) => {
    if (!r.bases.every((x) => b.includes(x))) return false;
    if (r.forma && !r.forma.test(p.forma)) return false;
    if (!r.ate) return true;
    const dose = doseMg(p.concentracao.split(' + ')[b.indexOf(r.bases[0])] || '');
    return dose !== null && dose <= r.ate;
  });
}

// Índice de nomes das listas (nome principal + sinônimo entre parênteses).
const INDICE = [];
for (const [lista, nomes] of Object.entries(LISTAS)) {
  for (const nome of nomes) {
    const principal = chave(nome.replace(/\(.*\)/, ''));
    const variantes = [principal];
    const par = nome.match(/\(([^)]*)\)/);
    if (par && !/\d/.test(par[1])) variantes.push(chave(par[1]));
    for (const v of variantes) if (v) INDICE.push({ tokens: v.split(' '), lista, base: principal });
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
function controlado(chaveComp) {
  const tokens = chaveComp.split(' ');
  for (const e of INDICE) if (contem(tokens, e.tokens)) return { lista: e.lista, base: e.base };
  return null;
}
const CANNABIS = /\b(?:cannabis|canabidiol|tetra?h?idrocann?abinol)\b/;

// Conferências pedidas: se alguma falhar, as listas embutidas estão erradas.
for (const [lista, nomes] of Object.entries({
  A1: ['morfina', 'oxicodona', 'metadona', 'fentanila'], A2: ['codeina', 'tramadol'],
  A3: ['metilfenidato', 'lisdexanfetamina'], B1: ['zolpidem', 'clonazepam', 'alprazolam', 'diazepam', 'lorazepam', 'bromazepam'],
  B2: ['sibutramina', 'anfepramona', 'femproporex', 'mazindol'],
})) {
  for (const n of nomes) {
    const c = controlado(n);
    if (c?.lista !== lista) throw new Error(`conferência de listas falhou: ${n} deveria ser ${lista}, está ${c?.lista}`);
  }
}

// Base de um componente não controlado (para busca): tira o sal/cátion.
const SAL = /^(?:(?:di|tri|mono|hemi|sesqui)?(?:cloridrato|bromidrato|fosfato|sulfato|maleato|tartarato|bitartarato|hemitartarato|citrato|succinato|mesilato|dimesilato|besilato|oxalato|fumarato|hemifumarato|acetato|carbonato|cloreto|brometo|nitrato|lactato|valerato|propionato|decanoato|benzoato|pamoato|tosilato|embonato|gluconato)\s+de\s+)/;
const CATION = /\s+(?:sodic[oa]|potassic[oa]|calcic[oa]|magnesic[oa]|de sodio|de potassio|de calcio|de magnesio|micronizad[oa])$/;
const baseDe = (c) => c.replace(SAL, '').replace(CATION, '').trim();

// ---------------------------------------------------------------------------
// 3. Apresentações (DS_DESCRICAO_APRESENTACAO, abreviações do Vocabulário
//    Controlado de Formas Farmacêuticas, Vias de Administração e Embalagens
//    de Medicamentos, Anvisa 2011)
// ---------------------------------------------------------------------------

const FORMAS = [
  ['COM REV LIB PROL', 'comprimido revestido de liberação prolongada'],
  ['COM REV LIB CONTR', 'comprimido revestido de liberação prolongada'],
  ['COM REV LIB LENTA', 'comprimido revestido de liberação prolongada'],
  ['COM REV LIB RETARD', 'comprimido revestido de liberação retardada'],
  ['COM REV LIB MOD', 'comprimido revestido de liberação modificada'],
  ['COM REV', 'comprimido revestido'],
  ['COM LIB PROL', 'comprimido de liberação prolongada'],
  ['COM LIB CONTR', 'comprimido de liberação prolongada'],
  ['COM LIB LENTA', 'comprimido de liberação prolongada'],
  ['COM DESINT LENTA', 'comprimido de liberação prolongada'],
  ['COM LIB MOD', 'comprimido de liberação modificada'],
  ['COM LIB RETARD', 'comprimido de liberação retardada'],
  ['COM ORODISP', 'comprimido orodispersível'],
  ['COM DISP', 'comprimido para suspensão'],
  ['COM DISPERS', 'comprimido para suspensão'],
  ['COM SUBL', 'comprimido sublingual'],
  ['COM SUB-LING', 'comprimido sublingual'],
  ['COM SUB', 'comprimido sublingual'],
  ['COM EFEV', 'comprimido efervescente'],
  ['COM MAST', 'comprimido mastigável'],
  ['COM SOL', 'comprimido para solução'],
  ['COM SUS', 'comprimido para suspensão'],
  ['COM', 'comprimido'],
  ['DRG', 'comprimido revestido'],
  ['CAP DURA LIB PROL', 'cápsula dura de liberação prolongada'],
  ['CAP GEL DURA LIB PROL', 'cápsula dura de liberação prolongada'],
  ['CAP DURA LIB RETARD', 'cápsula dura de liberação retardada'],
  ['CAP DURA LIB MOD', 'cápsula dura de liberação modificada'],
  ['CAP GEL C/MCGRAN AP', 'cápsula dura de liberação prolongada'],
  ['CAP GEL C/MCGRAN', 'cápsula dura'],
  ['CAP GEL DURA MCGRAN', 'cápsula dura'],
  ['CAP GEL MCGRAN', 'cápsula dura'],
  ['CAP GEL DURA', 'cápsula dura'],
  ['CAP DURA', 'cápsula dura'],
  ['CAP GEL', 'cápsula dura'],
  ['CAP', 'cápsula dura'],
  ['CAP MOLE LIB PROL', 'cápsula mole de liberação prolongada'],
  ['CAP GEL MOLE', 'cápsula mole'],
  ['CAP MOLE', 'cápsula mole'],
  ['SOL GOT OR', 'solução oral'],
  ['SOL GOT', 'solução oral'],
  ['SOL OR GOT', 'solução oral'],
  ['SOL OR', 'solução oral'],
  ['SOL INJ/DIL INFUS', 'solução injetável'],
  ['SOL INJ', 'solução injetável'],
  ['SOL INFUS', 'solução para infusão'],
  ['SOL DIL INFUS', 'solução para diluição para infusão'],
  ['SOL SPR NAS', 'solução spray nasal'],
  ['SOL SPR OR', 'solução spray oral'],
  ['SOL SPR', 'solução spray'],
  ['SOL', 'solução'],
  ['SUS GOT OR', 'suspensão oral'],
  ['SUS GOT', 'suspensão oral'],
  ['SUS OR', 'suspensão oral'],
  ['SUS INJ', 'suspensão injetável'],
  ['SUS', 'suspensão'],
  ['EMU OR', 'emulsão oral'],
  ['XPE', 'xarope'],
  ['ELX', 'elixir'],
  ['ADES TRANSD', 'adesivo transdérmico'],
  ['ADES TRANS', 'adesivo transdérmico'],
  ['ADES', 'adesivo transdérmico'],
  ['PO LIOF SOL INJ', 'pó liofilizado para solução injetável'],
  ['PO SOL INJ', 'pó para solução injetável'],
  ['PO SOL OR', 'pó para solução oral'],
  ['PO SUS OR', 'pó para suspensão oral'],
  ['GRAN', 'granulado'],
].map(([abr, forma]) => ({ tokens: abr.split(' '), forma }))
  .sort((a, b) => b.tokens.length - a.tokens.length);

const ROTAS = new Set(['OR', 'SUBL', 'BUC', 'NAS', 'IM', 'IV', 'SC', 'EPI', 'RET', 'IT', 'ID', 'IA', 'IAR', 'TRANSD', 'INAL', 'DERM', 'VAG', 'OFT', 'OTO']);
const EMBALAGEM = new Set(['CT', 'CX', 'EMB', 'EST', 'BL', 'STR', 'FR', 'FA', 'AMP', 'ENV', 'ENVOL', 'BG', 'TB', 'BOLS', 'SER', 'CAR', 'FLAC', 'PT', 'SACH', 'KIT', 'X']);
const RECIPIENTES = [
  ['AMP', 'ampola', 'ampolas'], ['FA', 'frasco-ampola', 'frascos-ampola'], ['SER', 'seringa preenchida', 'seringas preenchidas'],
  ['CAR', 'carpule', 'carpules'], ['BOLS', 'bolsa', 'bolsas'], ['FLAC', 'flaconete', 'flaconetes'], ['FR', 'frasco', 'frascos'],
  ['BG', 'bisnaga', 'bisnagas'], ['TB', 'tubo', 'tubos'], ['PT', 'pote', 'potes'], ['ENV', 'envelope', 'envelopes'],
  ['SACH', 'sachê', 'sachês'],
];

const NUM = String.raw`\d+(?:[.,]\d+)*`;
const UN = String.raw`(?:MCG|MG|G|UI|ML|MEQ|%)(?:\s*\/\s*(?:\d+(?:[.,]\d+)?\s*)?(?:ML|G|H|DOSES?|GOTAS?|GT|L|ACION(?:AMENTOS?)?))?`;
const RE_PAR = new RegExp(String.raw`^\(\s*(${NUM}(?:\s*\+\s*${NUM})+)\s*\)\s*(${UN})(?=[\s+]|$)`);
const RE_DOSE = new RegExp(String.raw`^(${NUM})\s*(${UN})(?=[\s+]|$)`);

function fmtNum(t) {
  t = t.trim();
  if (/^\d{1,3}(\.\d{3})+$/.test(t)) t = t.replace(/\./g, '');
  t = t.replace('.', ',');
  if (t.includes(',')) t = t.replace(/0+$/, '').replace(/,$/, '');
  return t.replace(/^0+(?=\d)/, '');
}
const UNIDADE = { MCG: 'mcg', MG: 'mg', G: 'g', UI: 'UI', ML: 'mL', MEQ: 'mEq', '%': '%', H: 'h', L: 'L', DOSE: 'dose', DOSES: 'dose', GOTA: 'gota', GOTAS: 'gota', GT: 'gota', ACION: 'acionamento', ACIONAMENTO: 'acionamento', ACIONAMENTOS: 'acionamento' };
function fmtUn(u) {
  return u.replace(/\s+/g, '').split('/').map((p) => {
    const m = p.match(/^(\d+(?:[.,]\d+)?)?([A-Z%]+)$/);
    if (!m || !UNIDADE[m[2]]) throw new Error(`unidade desconhecida: ${u}`);
    return (m[1] ? `${fmtNum(m[1])} ` : '') + UNIDADE[m[2]];
  }).join('/');
}
const fmtDose = (d) => (d.u === '%' ? `${fmtNum(d.n)}%` : `${fmtNum(d.n)} ${fmtUn(d.u)}`);
function emMg(d) {
  const v = Number(fmtNum(d.n).replace(',', '.'));
  const [cab, ...rest] = fmtUn(d.u).split('/');
  const f = { mcg: 0.001, mg: 1, g: 1000 }[cab];
  return f ? { v: v * f, por: rest.join('/') } : null;
}

// Lê a descrição de uma apresentação. Retorna { doses, forma, tipo, unidade, quantidade }
// ou { erro } explicando por que não foi possível.
function lerApresentacao(desc) {
  let s = espacos(desc.toUpperCase())
    .replace(/(\d)\s*(MCG|MG|ML|UI)\b/g, '$1 $2')
    .replace(/(\d)\s*G\b/g, '$1 G')
    .replace(/\s*\/\s*/g, '/');
  const doses = [];
  let m = s.match(RE_PAR);
  if (m) {
    for (const n of m[1].split('+')) doses.push({ n: n.trim(), u: m[2] });
    s = s.slice(m[0].length).trim();
  } else {
    for (;;) {
      const k = s.match(RE_DOSE);
      if (!k) break;
      doses.push({ n: k[1], u: k[2] });
      s = s.slice(k[0].length).trim();
      if (s.startsWith('+') && RE_DOSE.test(s.slice(1).trim())) { s = s.slice(1).trim(); continue; }
      break;
    }
  }
  if (!doses.length) return { erro: 'concentração' };
  try { doses.forEach(fmtDose); } catch { return { erro: 'unidade da concentração' }; }

  let tokens = s.split(' ');
  const f = FORMAS.find((x) => x.tokens.every((t, i) => tokens[i] === t));
  if (!f) return { erro: 'forma farmacêutica' };
  tokens = tokens.slice(f.tokens.length);
  while (tokens.length && tokens[0].split('/').every((t) => ROTAS.has(t))) tokens.shift();
  if (!tokens.length || !EMBALAGEM.has(tokens[0])) return { erro: 'forma farmacêutica' };
  // Acessórios depois de " + " (conta-gotas, seringa dosadora, porta-comprimido...) são ignorados.
  const emb = tokens.join(' ').split(/\s*\+\s*/)[0];

  const forma = f.forma;
  const solido = /^(comprimido|cápsula)/.test(forma);
  const adesivo = forma.startsWith('adesivo');
  if (solido || adesivo) {
    const mult = emb.match(/\b(?:CT|CX|EMB|EST)\s+(\d+)\s+(?:BL|STR|ENV|ENVOL|SACH|FR|FLAC|BG|TB|PT)\b/);
    const xs = [...emb.matchAll(/\bX\s*(\d+)(?![\d,.])(?!\s*(?:ML|L|G|MG|MCG|ACION\w*|DOSES?|JATOS?)\b)/g)];
    const n = xs.length ? Number(xs.at(-1)[1]) : null;
    const k = mult ? Number(mult[1]) : null;
    const quantidade = n && k ? n * k : n || k;
    if (!quantidade) return { erro: 'quantidade' };
    const unidade = adesivo ? 'adesivos' : forma.startsWith('comprimido') ? 'comprimidos' : 'cápsulas';
    return { doses, forma, unidade, quantidade };
  }
  const rec = RECIPIENTES.find(([abr]) => new RegExp(`\\b${abr}\\b`).test(emb)) || ['', 'frasco', 'frascos'];
  const mult = emb.match(new RegExp(String.raw`\b(?:CT|CX|EMB|EST)\s+(\d+)\s+(?:ENVOL\s+)?${rec[0] || 'FR'}\b`));
  const quantidade = mult ? Number(mult[1]) : 1;
  const vols = [...emb.matchAll(/\bX\s*(\d+(?:[.,]\d+)?)\s*(ML|L|G)\b/g)];
  const acion = emb.match(/\bX\s*(\d+)\s*(?:ACIONAMENTOS?|ACION|DOSES?|JATOS?)\b/);
  let unidade = quantidade > 1 ? rec[2] : rec[1];
  if (vols.length) unidade += ` de ${fmtNum(vols.at(-1)[1])} ${UNIDADE[vols.at(-1)[2]]}`;
  else if (acion) unidade += ` com ${acion[1]} acionamentos`;
  return { doses, forma, unidade, quantidade };
}

// Combinações em doses diferentes: qual componente tem a MAIOR dose. A ordem
// das doses na descrição do SNGPC não segue a ordem dos princípios ativos
// (ex.: "FOSFATO DE CODEÍNA + PARACETAMOL | 500MG + 30MG"), então as doses são
// atribuídas por magnitude. Combinação ausente daqui com doses diferentes é
// descartada e aparece no relatório.
const COMBINACOES = {
  'codeina+paracetamol': 'paracetamol',
  'paracetamol+tramadol': 'paracetamol',
  'naloxona+oxicodona': 'oxicodona',
  'amitriptilina+clordiazepoxido': 'amitriptilina',
  'bromazepam+sulpirida': 'sulpirida',
  'canabidiol+tetraidrocanabinol': 'tetraidrocanabinol',
};

// ---------------------------------------------------------------------------
// 4. Nomes comerciais (lista de preços CMED, dados abertos da Anvisa)
// ---------------------------------------------------------------------------

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
    await writeFile(arq, buf);
  }
  const texto = buf.toString('utf8').replace(/^﻿/, '');
  const ini = texto.search(/^SUBST[ÂA]NCIA;/m);
  if (ini < 0) throw new Error('[cmed] cabeçalho não encontrado');
  const it = linhasCSV(texto.slice(ini));
  const cab = it.next().value.map((c) => espacos(c));
  const col = (re) => {
    const i = cab.findIndex((c) => re.test(c));
    if (i < 0) throw new Error(`[cmed] coluna ausente: ${re}`);
    return i;
  };
  const cSub = col(/^SUBST/), cProd = col(/^PRODUTO$/), cTipo = col(/^TIPO DE PRODUTO/), cCom = col(/^COMERCIALIZA/);
  const marcas = new Map(); // chave ordenada de componentes -> Map(marca -> {novo, n})
  for (const r of it) {
    if (r.length < cab.length) continue;
    const tipo = chave(r[cTipo]);
    if (!tipo || tipo === 'generico' || chave(r[cCom]) !== 'sim') continue;
    const comps = [...new Set(r[cSub].split(/\s*[;+\n]\s*/).map(chave).filter(Boolean))].sort();
    const k = comps.join('|');
    const marca = chave(r[cProd]);
    if (!marca) continue;
    const tokensMarca = marca.split(' ');
    const bases = comps.map((c) => controlado(c)?.base || baseDe(c));
    if (bases.some((b) => contem(tokensMarca, b.split(' ')))) continue;
    if (!marcas.has(k)) marcas.set(k, new Map());
    const m = marcas.get(k);
    const e = m.get(marca) || { novo: false, n: 0 };
    e.novo ||= tipo === 'novo';
    e.n++;
    m.set(marca, e);
  }
  return marcas;
}

// ---------------------------------------------------------------------------
// 5. Montagem
// ---------------------------------------------------------------------------

function sentenca(s) {
  s = s.charAt(0).toUpperCase() + s.slice(1);
  return s.replace(/\bsativa l\.?$/, 'sativa L.');
}

function montar(agregados, marcasCmed) {
  const grupos = new Map();
  const excluidas = new Map();
  const cacheComp = new Map();
  for (const row of agregados) {
    let info = cacheComp.get(row.pa);
    if (info === undefined) {
      const vistos = new Set();
      const comps = [];
      for (const bruto of row.pa.split(/\s+\+\s+/)) {
        const c = chave(bruto);
        if (!c || vistos.has(c)) continue;
        vistos.add(c);
        const ctl = controlado(c);
        const cannabis = !ctl && CANNABIS.test(c);
        comps.push({ chave: c, exib: exibicao(bruto), ctl, cannabis, base: ctl?.base || (cannabis ? c.replace(/ l$/, '') : baseDe(c)) });
      }
      const ctls = comps.filter((c) => c.ctl);
      if (ctls.length) {
        info = { lista: ctls[0].ctl.lista, cannabis: false };
        if (ctls.every((c) => ISENTAS[c.ctl.base])) info = { isenta: ISENTAS[ctls[0].ctl.base] };
      } else if (comps.some((c) => c.cannabis)) {
        info = { lista: 'A3', cannabis: true };
      } else info = null;
      if (info && !info.isenta) {
        comps.sort((a, b) => Number(!(a.ctl || a.cannabis)) - Number(!(b.ctl || b.cannabis)));
        info.comps = comps;
        info.chave = comps.map((c) => c.chave).join(' + ');
      } else if (info?.isenta) info.chave = comps.map((c) => c.chave).join(' + ');
      cacheComp.set(row.pa, info);
    }
    if (!info) continue;
    if (info.isenta) {
      const e = excluidas.get(info.chave) || { motivo: info.isenta, vendas: 0 };
      e.vendas += row.qt;
      excluidas.set(info.chave, e);
      continue;
    }
    let g = grupos.get(info.chave);
    if (!g) {
      g = { chave: info.chave, lista: info.lista, cannabis: info.cannabis, comps: info.comps, nomes: new Map(), linhas: [] };
      grupos.set(info.chave, g);
    }
    const nome = info.comps.map((c) => c.exib).join(' + ');
    g.nomes.set(nome, (g.nomes.get(nome) || 0) + row.qt);
    g.linhas.push(row);
  }

  const naoLidas = [];
  const semApresentacao = [];
  const substancias = [];
  for (const g of grupos.values()) {
    const tipo = TIPO_DA_LISTA[g.lista];
    let linhas = g.linhas;
    if (g.cannabis) {
      // Produtos de Cannabis: A3 (adendo 10) só se THC > 0,2%; até 0,2% é
      // Receita de Controle Especial (adendo 12). O SNGPC não informa o teor
      // de THC, então só entram apresentações dispensadas majoritariamente
      // com Notificação de Receita A.
      const porApres = new Map();
      for (const r of linhas) {
        const e = porApres.get(r.apres) || { a: 0, t: 0 };
        e.t += r.qt;
        if (r.tp === CODIGO.NRA) e.a += r.qt;
        porApres.set(r.apres, e);
      }
      linhas = linhas.filter((r) => { const e = porApres.get(r.apres); return e.a / e.t > 0.5; });
    }
    const notif = linhas.filter((r) => r.tp === CODIGO[tipo]);
    const usadas = soma(notif, (r) => r.qt) > 0 ? notif : g.cannabis ? [] : linhas;
    const vendas = soma(usadas, (r) => r.qt);
    if (!vendas) continue;

    const bases = g.comps.map((c) => c.base);
    const combo = bases.length > 1 ? COMBINACOES[[...bases].sort().join('+')] : undefined;
    const pres = new Map();
    for (const r of usadas) {
      const a = lerApresentacao(r.apres);
      if (!a.erro && a.doses.length !== g.comps.length && !(a.doses.length === 1 && g.comps.length === 1)) a.erro = 'nº de doses diferente do nº de componentes';
      if (!a.erro && g.comps.length > 1) {
        const mg = a.doses.map(emMg);
        const iguais = mg.every((x) => x && mg[0] && x.v === mg[0].v && x.por === mg[0].por);
        if (!iguais) {
          if (!combo || g.comps.length !== 2 || mg.some((x) => !x) || mg[0].por !== mg[1].por) a.erro = 'combinação sem regra de doses';
          else {
            const [maior, menor] = mg[0].v >= mg[1].v ? [a.doses[0], a.doses[1]] : [a.doses[1], a.doses[0]];
            a.doses = bases.map((b) => (b === combo ? maior : menor));
          }
        }
      }
      if (a.erro) { naoLidas.push({ nome: g.chave, apres: r.apres, vendas: r.qt, motivo: a.erro }); continue; }
      const concentracao = a.doses.map(fmtDose).join(' + ');
      const k = `${concentracao}\t${a.forma}`;
      const p = pres.get(k) || { concentracao, forma: a.forma, vendas: 0, pacotes: new Map() };
      p.vendas += r.qt;
      if (a.quantidade >= 1 && a.quantidade <= 999) {
        const kp = `${a.unidade}\t${a.quantidade}`;
        p.pacotes.set(kp, (p.pacotes.get(kp) || 0) + r.qt);
      }
      pres.set(k, p);
    }
    const apresentacoes = [...pres.values()]
      .filter((p) => p.pacotes.size)
      .sort((a, b) => b.vendas - a.vendas || a.concentracao.localeCompare(b.concentracao))
      .slice(0, 6)
      .map((p) => {
        const [unidade, q] = [...p.pacotes].sort((a, b) => b[1] - a[1])[0][0].split('\t');
        return { concentracao: p.concentracao, forma: p.forma, unidade, quantidade: Number(q), vendas: p.vendas,
          ...(vaiEmRCE(bases, p) ? { receita: 'RCE' } : {}) };
      });

    // Nome exibido: a variante mais vendida, preferindo as que têm acentos.
    const nome = sentenca([...g.nomes].sort((a, b) => Number(/[^\x00-\x7f]/.test(b[0])) - Number(/[^\x00-\x7f]/.test(a[0])) || b[1] - a[1])[0][0]);
    const busca = [...new Set(bases.map((b) => semAcento(b)))];
    const marcas = marcasCmed?.get([...g.comps.map((c) => c.chave)].sort().join('|'));
    if (marcas) {
      const ord = [...marcas].sort((a, b) => Number(b[1].novo) - Number(a[1].novo) || b[1].n - a[1].n || a[0].localeCompare(b[0]));
      for (const [m] of ord.slice(0, 8)) if (!busca.includes(m)) busca.push(m);
    }
    if (!apresentacoes.length) { semApresentacao.push({ nome, tipo, vendas }); continue; }
    substancias.push({ nome, lista: g.lista, tipo, busca, vendas, apresentacoes });
  }
  substancias.sort((a, b) => ORDEM_TIPO.indexOf(a.tipo) - ORDEM_TIPO.indexOf(b.tipo) || b.vendas - a.vendas || a.nome.localeCompare(b.nome));
  return { substancias, naoLidas, excluidas, semApresentacao };
}

// ---------------------------------------------------------------------------
// 6. Validação (falha alto antes de gravar)
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
  const nomes = new Set();
  let anterior = null;
  saida.substancias.forEach((s, i) => {
    const onde = `substancias[${i}] (${s.nome})`;
    max(s.nome, 120, `${onde}.nome`);
    if (nomes.has(s.nome)) erros.push(`${onde}: nome duplicado`);
    nomes.add(s.nome);
    if (TIPO_DA_LISTA[s.lista] !== s.tipo) erros.push(`${onde}: lista ${s.lista} incompatível com tipo ${s.tipo}`);
    if (!Array.isArray(s.busca) || !s.busca.length || s.busca.some((b) => !/^[a-z0-9 .\-+&\/]+$/.test(b))) erros.push(`${onde}: busca inválida ${JSON.stringify(s.busca)}`);
    if (!Number.isInteger(s.vendas) || s.vendas < 1) erros.push(`${onde}: vendas inválidas`);
    if (anterior && (ORDEM_TIPO.indexOf(anterior.tipo) > ORDEM_TIPO.indexOf(s.tipo) || (anterior.tipo === s.tipo && anterior.vendas < s.vendas))) erros.push(`${onde}: fora de ordem`);
    anterior = s;
    if (!Array.isArray(s.apresentacoes) || !s.apresentacoes.length || s.apresentacoes.length > 6) erros.push(`${onde}: apresentacoes inválidas`);
    const vistas = new Set();
    let somaVendas = 0;
    s.apresentacoes.forEach((p, j) => {
      const o = `${onde}.apresentacoes[${j}]`;
      max(p.concentracao, 40, `${o}.concentracao`);
      max(p.forma, 60, `${o}.forma`);
      max(p.unidade, 40, `${o}.unidade`);
      if (!Number.isInteger(p.quantidade) || p.quantidade < 1 || p.quantidade > 999) erros.push(`${o}: quantidade ${p.quantidade}`);
      if (!Number.isInteger(p.vendas) || p.vendas < 1) erros.push(`${o}: vendas inválidas`);
      if (p.forma !== p.forma.toLowerCase()) erros.push(`${o}: forma deve ser minúscula`);
      if (/µ/.test(p.concentracao)) erros.push(`${o}: use mcg`);
      if (p.receita !== undefined && p.receita !== 'RCE') erros.push(`${o}: receita inválida ${p.receita}`);
      const k = `${p.concentracao}|${p.forma}`;
      if (vistas.has(k)) erros.push(`${o}: (concentracao, forma) repetida`);
      vistas.add(k);
      if (j && s.apresentacoes[j - 1].vendas < p.vendas) erros.push(`${o}: fora de ordem`);
      somaVendas += p.vendas;
    });
    if (somaVendas > s.vendas) erros.push(`${onde}: soma das apresentações maior que vendas`);
  });
  if (erros.length) throw new Error(`validação falhou (${erros.length}):\n  ${erros.slice(0, 50).join('\n  ')}`);
}

// ---------------------------------------------------------------------------
// 7. Conferência opcional das listas embutidas com o texto oficial
// ---------------------------------------------------------------------------

// Drops <script> and <style> blocks by scanning tags, so no partial block can be reassembled.
function semScriptsNemEstilos(html) {
  let texto = '', ignorando = null;
  for (const [indice, parte] of html.split('<').entries()) {
    if (indice === 0) { texto += parte; continue; }
    const minuscula = parte.toLowerCase();
    if (ignorando) {
      if (minuscula.startsWith('/' + ignorando)) { ignorando = null; texto += parte.slice(parte.indexOf('>') + 1); }
      continue;
    }
    const bloco = ['script', 'style'].find(nome => minuscula.startsWith(nome) && !/[a-z0-9-]/.test(minuscula[nome.length] ?? ''));
    if (bloco) { ignorando = bloco; continue; }
    texto += '<' + parte;
  }
  return texto;
}

function textoDeHtml(html) {
  const marcas = { acute: '́', grave: '̀', circ: '̂', tilde: '̃', uml: '̈', cedil: '̧' };
  const nomeadas = { nbsp: ' ', quot: '"', amp: '&', lt: '<', gt: '>', ordm: 'º', ordf: 'ª', sect: '§', ndash: '-', mdash: '-', ldquo: '"', rdquo: '"' };
  return semScriptsNemEstilos(html)
    .replace(/<br\s*\/?>|<\/(p|div|tr|li|h\d)>/gi, '\n')
    .replace(/<[^>]+>/g, '')
    // Plain text for comparison only: drop any angle bracket left by malformed markup.
    .replace(/[<>]/g, ' ')
    .replace(/&([A-Za-z])(acute|grave|circ|tilde|uml|cedil);/g, (_, l, m) => (l + marcas[m]).normalize('NFC'))
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&([a-z]+);/g, (x, n) => nomeadas[n] ?? x);
}

async function verificarListas() {
  log(`[listas] baixando ${RDC_TEXTO_URL}`);
  const linhas = textoDeHtml(new TextDecoder('windows-1252').decode(await baixar(RDC_TEXTO_URL))).split('\n').map(espacos);
  let ok = true;
  for (const [lista, nomes] of Object.entries(LISTAS)) {
    const i = linhas.findIndex((l) => l === `LISTA - ${lista}`);
    if (i < 0) { log(`[listas] ${lista}: cabeçalho não encontrado`); ok = false; continue; }
    const oficiais = [];
    for (let j = i + 1; j < linhas.length && !linhas[j].startsWith('ADENDO'); j++) {
      const m = linhas[j].match(/^\d+\.\s*(.+)$/);
      if (m) oficiais.push(m[1]);
    }
    const faltam = oficiais.filter((n) => !nomes.includes(n));
    const sobram = nomes.filter((n) => !oficiais.includes(n));
    if (faltam.length || sobram.length) {
      ok = false;
      log(`[listas] ${lista}: divergência. No texto e não embutidas: ${JSON.stringify(faltam)}; embutidas e não no texto: ${JSON.stringify(sobram)}`);
    } else log(`[listas] ${lista}: ${nomes.length} substâncias conferem`);
  }
  if (!ok) throw new Error('listas embutidas divergem do texto da RDC');
}

// ---------------------------------------------------------------------------
// 8. Execução
// ---------------------------------------------------------------------------

if (args['verificar-listas']) await verificarListas();

const agregados = await carregarAgregados();
if (args['apenas-agregar']) {
  log(`agregado: ${agregados.length} combinações`);
  process.exit(0);
}

let marcasCmed = null;
if (!args['sem-cmed']) marcasCmed = await carregarCmed();

const { substancias, naoLidas, excluidas, semApresentacao } = montar(agregados, marcasCmed);
const d = new Date();
const hoje = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const mes = (m) => `${m.slice(0, 4)}-${m.slice(4)}`;
const saida = {
  gerado: args.data || hoje,
  fontes: {
    listas: RDC,
    sngpc: {
      periodo: MESES.length > 1 ? `${mes(MESES[0])} a ${mes(MESES.at(-1))}` : mes(MESES[0]),
      url: SNGPC_URL.startsWith('https://dados.anvisa.gov.br/') ? SNGPC_URL : 'https://dados.anvisa.gov.br/dados/SNGPC/Industrializados/',
      receituario: { ...CODIGO },
    },
  },
  substancias,
};
validar(saida);

// Uma substância por linha: arquivo pequeno e diffs legíveis.
const json = `{"gerado":${JSON.stringify(saida.gerado)},"fontes":${JSON.stringify(saida.fontes)},"substancias":[\n${substancias.map((s) => JSON.stringify(s)).join(',\n')}\n]}\n`;
JSON.parse(json);
await mkdir(dirname(SAIDA), { recursive: true });
await writeFile(SAIDA, json);

// Relatório
const porTipo = Object.fromEntries(ORDEM_TIPO.map((t) => [t, substancias.filter((s) => s.tipo === t).length]));
const vendasNaoLidas = soma(naoLidas, (n) => n.vendas);
log(`\ngravado ${SAIDA} (${(Buffer.byteLength(json) / 1024).toFixed(1)} KB)`);
log(`período: ${saida.fontes.sngpc.periodo}; substâncias por tipo: ${JSON.stringify(porTipo)}`);
log(`excluídas por isenção de notificação (adendos): ${[...excluidas].map(([k, e]) => `${k} [${e.vendas}]`).join('; ') || 'nenhuma'}`);
log(`apresentações não lidas: ${naoLidas.length} linhas, ${vendasNaoLidas} embalagens`);
log(`descartadas por não ter apresentação legível: ${semApresentacao.map((s) => `${s.nome} (${s.tipo}) [${s.vendas}]`).join('; ') || 'nenhuma'}`);
if (args.relatorio) {
  for (const t of ORDEM_TIPO) {
    log(`\n== ${t}: top 10`);
    for (const s of substancias.filter((x) => x.tipo === t).slice(0, 10)) {
      const p = s.apresentacoes[0];
      log(`  ${s.nome} (${s.lista}) ${s.vendas} | ${p ? `${p.concentracao} ${p.forma}, ${p.quantidade} ${p.unidade}` : 'sem apresentação'} | busca: ${s.busca.join(', ')}`);
    }
  }
  log('\n== apresentações não lidas (por vendas)');
  for (const n of naoLidas.sort((a, b) => b.vendas - a.vendas).slice(0, 80)) log(`  ${n.vendas}\t${n.motivo}\t${n.nome} | ${n.apres}`);
}
