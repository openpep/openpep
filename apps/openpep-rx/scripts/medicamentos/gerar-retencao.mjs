#!/usr/bin/env node
// Gera data/medicamentos-retencao.json: medicamentos de venda sob prescrição com
// RETENÇÃO DA RECEITA (RDC nº 471/2021, lista na IN nº 360/2025): antimicrobianos
// e agonistas do receptor de GLP-1. Ranking pelas dispensações do SNGPC
// (TP_RECEITUARIO 5), marcas e genéricos pela lista de preços CMED.
// Veja data/PROVENANCE.md (seção "Retenção de receita").
//
// Uso:
//   node scripts/medicamentos/gerar-retencao.mjs [opções]
//     --meses=202606,202607,202608   meses do SNGPC (AAAAMM)
//     --cache=DIR                    mesmo cache de gerar.mjs ($MEDICAMENTOS_CACHE
//                                    ou <tmpdir>/cockpit-rx-medicamentos)
//     --refazer                      ignora o cache e baixa tudo de novo
//     --relatorio                    imprime tabela GLP-1, top 20 e pendências
//     --data=AAAA-MM-DD              valor de "gerado" (padrão: hoje)
//     --saida=ARQUIVO                caminho do JSON (padrão: data/medicamentos-retencao.json)
//
// Não importa gerar.mjs porque aquele script executa ao ser carregado; as
// funções comuns (agregação do SNGPC, CSV, normalização) foram copiadas e
// gravam/leem o mesmo cache (sngpc-AAAAMM.tsv, cmed.csv).

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
const SAIDA = resolve(args.saida || join(RAIZ, 'data', 'medicamentos-retencao.json'));

const SNGPC_URL = process.env.SNGPC_URL || 'https://dados.anvisa.gov.br/dados/SNGPC/Industrializados/';
const CMED_URL = 'https://dados.anvisa.gov.br/dados/TA_PRECO_MEDICAMENTO.csv';
const CODIGO = '5'; // TP_RECEITUARIO 5 = Receita Antimicrobiano e GLP-1 em 2 vias

// As URLs do texto integral (anvisalegis) têm "=" e "_", fora da regex de
// caracteres permitidos; o README traz os links completos.
const FONTES = {
  antimicrobianos: {
    ato: 'RDC nº 471/2021 (redação da RDC nº 973/2025); lista: IN nº 360/2025, art. 1º',
    data: '2025-04-23',
    url: 'https://www.conass.org.br/conass-informa-n-46-2025-publicada-a-instrucao-normativas/',
  },
  glp1: {
    ato: 'RDC nº 973/2025 e IN nº 360/2025, art. 2º',
    data: '2025-04-23',
    url: 'https://www.gov.br/anvisa/pt-br/assuntos/noticias-anvisa/2025/canetas-emagrecedoras-so-poderao-ser-vendidas-com-retencao-de-receita',
  },
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
// Escopo legal: IN nº 360/2025. Art. 1º (antimicrobianos; o item 42 não existe
// no texto publicado) e art. 2º (GLP-1). "Isoladas ou em associação", e a
// RDC 471 alcança sais, éteres, ésteres e isômeros (art. 1º, parágrafo único).
// Cada entrada: nome no texto da IN | grafias equivalentes. O primeiro nome
// após "=" é a base usada em "chave" (grafia da DCB).
// ---------------------------------------------------------------------------

const IN360_ANTIMICROBIANOS = `ácido clavulânico|clavulanato=clavulanato; ácido fusídico|fusidato=acido fusidico; ácido nalidíxico; ácido oxolínico; ácido pipemídico;
amicacina; amoxicilina; ampicilina; axetilcefuroxima|axetil cefuroxima; azitromicina; aztreonam; bacitracina; besifloxacino|besifloxacina; brodimoprima;
capreomicin|capreomicina=capreomicina; carbenicilina; cefaclor; cefadroxil|cefadroxila=cefadroxila; cefalexina; cefalotina; cefazolina; cefepima;
cefodizima; cefoperazona; cefotaxima; cefoxitina; cefpodoxima; cefefpiroma|cefpiroma=cefpiroma; cefprozil|cefprozila=cefprozila;
ceftadizima|ceftazidima=ceftazidima; ceftarolina fosamila|ceftarolina=ceftarolina; ceftobiprol|ceftobiprole; ceftriaxona; cefuroxima;
ciprofloxacina|ciprofloxacino=ciprofloxacino; claritromicina; clindamicina; clofazimina; clorfenesina; cloranfenicol; cloxacilina;
dactinomicina; daptomicina; dapsona; delamanide|delamanida; dicloxacilina; difenilsulfona; diidroestreptomicina; diritromicina; doripenem;
doxiciclina; eritromicina; ertapenem; espectinomicina; espiramicina; estreptomicina; etambutol; etionamida; fosfomicina; ftalilsulfatiazol;
gatifloxacina|gatifloxacino=gatifloxacino; gemifloxacino|gemifloxacina; gentamicina; gramicidina; imipenem; isoniazida;
levofloxacina|levofloxacino=levofloxacino; linezolida; limeciclina; lincomicina; lomefloxacina|lomefloxacino=lomefloxacino; loracarbef;
mandelamina; meropenem; metampicilina; metronidazol; benzoilmetronidazol; minociclina; miocamicina; mitomicina;
moxifloxacino|moxifloxacina; mupirocina; neomicina; netilmicina; nitrofural|nitrofurazona; nitrofurantoína; nitroxolina;
norfloxacina|norfloxacino=norfloxacino; ofloxacina|ofloxacino=ofloxacino; oxacilina; oxitetraciclina; pefloxacina|pefloxacino=pefloxacino;
penicilina G|benzilpenicilina=benzilpenicilina; penicilina V|fenoximetilpenicilina=fenoximetilpenicilina; piperacilina; pirazinamida;
polimixina B; pristinamicina; protionamida; retapamulina; rifabutina; rifamicina; rifampicina; rifapentina; rosoxacina; roxitromicina;
sulbactam; sulfacetamida; sulfadiazina; sulfadoxina; sulfaguanidina; sulfamerazina; sulfanilamida; sulfametizol; sulfametoxazol;
sulfametoxipiridazina; sulfametoxipirimidina; sulfatiazol; sultamicilina; tazobactam; tedizolida; teicoplanina; telitromicina;
tetraciclina; tianfenicol; ticarcilina; tigeciclina; tirotricina; tobramicina; trimetoprima; trovafloxacina|trovafloxacino=trovafloxacino; vancomicina`;
// Benzoilmetronidazol é éster do metronidazol (coberto pelo parágrafo único da RDC 471).
const IN360_GLP1 = ['semaglutida', 'liraglutida', 'dulaglutida', 'tirzepatida', 'lixisenatida'];

const INDICE = [];
for (const item of IN360_ANTIMICROBIANOS.split(';').map((s) => s.trim()).filter(Boolean)) {
  const [nomes, canon] = item.split('=');
  const variantes = nomes.split('|').map(chave);
  const base = canon ? chave(canon) : variantes.at(-1).includes('floxacin') ? variantes.find((v) => v.endsWith('o')) || variantes[0] : variantes[0];
  for (const v of variantes) INDICE.push({ tokens: v.split(' '), base, classe: 'antimicrobiano' });
}
for (const g of IN360_GLP1) INDICE.push({ tokens: [g], base: g, classe: 'glp1' });
// Incluídos por decisão do prescritor, embora fora da IN 360/2025: as farmácias
// retêm a receita (o SNGPC registra com código 5). Saem com "fora_da_lista": true.
const FORA_DA_LISTA = ['cefdinir'];
for (const f of FORA_DA_LISTA) INDICE.push({ tokens: f.split(' '), base: f, classe: 'antimicrobiano', foraDaLista: true });
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
const INIBIDORES = new Set(['clavulanato', 'sulbactam', 'tazobactam']);

// Base de componente não listado: tira sal/éster/cátion (para chave e busca).
const SAL = /^(?:(?:17 )?(?:di|tri|mono|hemi|sesqui)?(?:cloridrato|bromidrato|fosfato dissodico|fosfato|sulfato|maleato|tartarato|bitartarato|citrato|succinato|mesilato|besilato|oxalato|fumarato|acetato|carbonato|cloreto|brometo|nitrato|lactato|valerato|dipropionato|propionato|furoato|decanoato|benzoato|acetonida|estolato|hiclato)\s+de\s+)/;
const CATION = /\s+(?:dissodic[oa]|sodic[oa]|potassic[oa]|calcic[oa]|magnesic[oa]|zincic[oa]|de sodio|de potassio|de calcio|de magnesio|micronizad[oa]|acetonida|trometamol|pivoxila|proxetila?|benzatina|procaina)$/;
const SINONIMOS = { benzalconico: 'benzalconio', levometionina: 'metionina', 'amino acidos': 'aminoacidos', fludoxicortida: 'fludroxicortida' };
function baseDe(c) {
  let b = c;
  for (let i = 0; i < 3; i++) b = b.replace(SAL, '').replace(CATION, '').trim();
  return SINONIMOS[b] || b;
}

// ---------------------------------------------------------------------------
// Doses de associações: a ordem das doses na descrição NÃO segue a ordem
// (alfabética) dos princípios ativos no SNGPC. As doses são atribuídas por
// tipo de unidade (UI/U) e por magnitude, segundo a composição conhecida de
// cada associação (bula). Associação com doses diferentes fora desta tabela
// é descartada e aparece no relatório.
//   massa: componentes em mg/g/mcg, da MAIOR para a menor dose
//   ui:    componentes dosados em UI ou U, da maior para a menor
// ---------------------------------------------------------------------------
const ASSOCIACOES = {
  'amoxicilina+clavulanato': { massa: ['amoxicilina', 'clavulanato'] },
  'amoxicilina+sulbactam': { massa: ['amoxicilina', 'sulbactam'] },
  'piperacilina+tazobactam': { massa: ['piperacilina', 'tazobactam'] },
  'ampicilina+sulbactam': { massa: ['ampicilina', 'sulbactam'] },
  'avibactam+ceftazidima': { massa: ['ceftazidima', 'avibactam'] },
  'fludroxicortida+neomicina': { massa: ['neomicina', 'fludroxicortida'] },
  'sulfametoxazol+trimetoprima': { massa: ['sulfametoxazol', 'trimetoprima'] },
  'dexametasona+moxifloxacino': { massa: ['moxifloxacino', 'dexametasona'] },
  'ciprofloxacino+hidrocortisona': { massa: ['hidrocortisona', 'ciprofloxacino'] },
  'ciprofloxacino+dexametasona': { massa: ['ciprofloxacino', 'dexametasona'] },
  'dexametasona+tobramicina': { massa: ['tobramicina', 'dexametasona'] },
  'dexametasona+neomicina': { massa: ['neomicina', 'dexametasona'] },
  'betametasona+gentamicina': { massa: ['gentamicina', 'betametasona'] },
  'desonida+gentamicina': { massa: ['gentamicina', 'desonida'] },
  'gatifloxacino+prednisolona': { massa: ['prednisolona', 'gatifloxacino'] },
  'acido fusidico+betametasona': { massa: ['acido fusidico', 'betametasona'] },
  'acido fusidico+mometasona': { massa: ['acido fusidico', 'mometasona'] },
  'adapaleno+clindamicina': { massa: ['clindamicina', 'adapaleno'] },
  'clindamicina+peroxido de benzoila': { massa: ['peroxido de benzoila', 'clindamicina'] },
  'clindamicina+tretinoina': { massa: ['clindamicina', 'tretinoina'] },
  'anfotericina b+tetraciclina': { massa: ['tetraciclina', 'anfotericina b'] },
  'metronidazol+miconazol': { massa: ['metronidazol', 'miconazol'] },
  'metronidazol+nistatina': { massa: ['metronidazol'], ui: ['nistatina'] },
  'cloranfenicol+colagenase': { massa: ['cloranfenicol'], ui: ['colagenase'] },
  'bacitracina+neomicina': { massa: ['neomicina'], ui: ['bacitracina'] },
  'lidocaina+polimixina b': { massa: ['lidocaina'], ui: ['polimixina b'] },
  'dexametasona+neomicina+polimixina b': { massa: ['neomicina', 'dexametasona'], ui: ['polimixina b'] },
  'hidrocortisona+neomicina+polimixina b': { massa: ['hidrocortisona', 'neomicina'], ui: ['polimixina b'] },
  'fluocinolona+lidocaina+neomicina+polimixina b': { massa: ['lidocaina', 'neomicina', 'fluocinolona'], ui: ['polimixina b'] },
  'benzalconio+benzoilmetronidazol+nistatina': { massa: ['benzoilmetronidazol', 'benzalconio'], ui: ['nistatina'] },
  'gramicidina+neomicina+nistatina+triancinolona': { massa: ['neomicina', 'triancinolona', 'gramicidina'], ui: ['nistatina'] },
  'betametasona+clioquinol+gentamicina+tolnaftato': { massa: ['clioquinol', 'tolnaftato', 'gentamicina', 'betametasona'] },
  'betametasona+cetoconazol+neomicina': { massa: ['cetoconazol', 'neomicina', 'betametasona'] },
  'aminoacidos+cloranfenicol+metionina+retinol': { massa: ['aminoacidos', 'cloranfenicol', 'metionina'], ui: ['retinol'] },
  'cloranfenicol+desoxirribonuclease+fibrinolisina': { massa: ['cloranfenicol'], ui: ['desoxirribonuclease', 'fibrinolisina'] },
  'amoxicilina+claritromicina+esomeprazol': { massa: ['amoxicilina', 'claritromicina', 'esomeprazol'] },
  'amoxicilina+claritromicina+lansoprazol': { massa: ['amoxicilina', 'claritromicina', 'lansoprazol'] },
  'amoxicilina+claritromicina+omeprazol': { massa: ['amoxicilina', 'claritromicina', 'omeprazol'] },
  'amoxicilina+lansoprazol+levofloxacino': { massa: ['amoxicilina', 'levofloxacino', 'lansoprazol'] },
  // Composições conferidas na bula (decisão do prescritor de incluir, 29/9/2026):
  // Oto-Betnovate (Farmoquímica): por mL, clorfenesina 10 mg, cloridrato de tetracaína 5 mg,
  //   valerato de betametasona 1,214 mg (= 1 mg de betametasona).
  'betametasona+clorfenesina+tetracaina': { massa: ['clorfenesina', 'tetracaina', 'betametasona'] },
  // Decadron Nasal (Aché): por mL, cloridrato de fenilefrina 5 mg, neomicina 3,5 mg,
  //   dexametasona fosfato 0,5 mg.
  'dexametasona+fenilefrina+neomicina': { massa: ['fenilefrina', 'neomicina', 'dexametasona'] },
  // Trivagel-N (Marjan) e Dermacerium (Cristália): veja COMPOSICAO_BULA.
  'dexametasona+neomicina+nistatina': { massa: ['neomicina', 'dexametasona'], ui: ['nistatina'] },
  'cerio+sulfadiazina': { massa: ['sulfadiazina', 'cerio'] },
  'insulina degludeca+liraglutida': { massa: ['liraglutida'], ui: ['insulina degludeca'] },
  'insulina glargina+lixisenatida': { massa: ['lixisenatida'], ui: ['insulina glargina'] },
};

// Descrições do SNGPC sem concentração (ou sem unidade): a dose vem da bula e é
// escrita antes da forma farmacêutica. Chave: bases ordenadas.
const COMPOSICAO_BULA = [
  // Trivagel-N creme vaginal (Marjan), bula: "cada 5 g contém: dexametasona (fosfato
  // dissódico) 0,32 mg; nistatina 100.000 UI; sulfato de neomicina 10 mg; tirotricina
  // 2 mg; propionato de sódio 50 mg; ácido bórico 150 mg". O registro (SNGPC/CMED)
  // lista só dexametasona, neomicina e nistatina; o nome e a concentração seguem o registro.
  { bases: 'dexametasona+neomicina+nistatina', de: /^(?=CREM VAG\b)/, para: '(10 MG + 0,32 MG + 100.000 UI)/5 G ' },
  // Dermacerium creme e HS gel (Cristália), bula: "cada 1 g contém sulfadiazina de prata
  // 10 mg e nitrato de cério 4 mg" (1% + 0,4%, como na CMED).
  { bases: 'cerio+sulfadiazina', de: /^1 \+ 0,4 (?=CREM|GEL)/, para: '1% + 0,4% ' },
];
function comComposicaoDaBula(apres, bases) {
  const k = [...bases].sort().join('+');
  const s = normDesc(apres);
  const r = COMPOSICAO_BULA.find((c) => c.bases === k && c.de.test(s));
  return r ? s.replace(r.de, r.para) : apres;
}

// Exclusão "uso exclusivo hospitalar" (CMED "RESTRIÇÃO HOSPITALAR = Sim") que NÃO
// se aplica, por decisão do prescritor: kit IM ceftriaxona + diluente de
// lidocaína, usado no tratamento ambulatorial da gonorreia.
const HOSPITALAR_LIBERADO = [{ bases: 'ceftriaxona+lidocaina', via: /intramuscular/ }];

// ---------------------------------------------------------------------------
// Leitura de DS_DESCRICAO_APRESENTACAO (abreviações do Vocabulário Controlado)
// ---------------------------------------------------------------------------

function normDesc(desc) {
  return espacos(semAcento(desc.toUpperCase()))
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
  ['COM DISP', 'comprimido para suspensão', 'oral'],
  ['COM DISPERS', 'comprimido para suspensão', 'oral'],
  ['COM SUS', 'comprimido para suspensão', 'oral'],
  ['COM EFEV', 'comprimido efervescente', 'oral'],
  ['COM SOL', 'comprimido para solução', 'oral'],
  ['COM MAST', 'comprimido mastigável', 'oral'],
  ['COM VAG', 'comprimido vaginal', 'vaginal'],
  ['COM', 'comprimido', 'oral'],
  ['DRG', 'comprimido revestido', 'oral'],
  ['CAP DURA LIB PROL', 'cápsula dura de liberação prolongada', 'oral'],
  ['CAP DURA LIB RETARD', 'cápsula dura de liberação retardada', 'oral'],
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
].map(([abr, forma, via]) => ({ tokens: abr.split(' '), forma, via }))
  .sort((a, b) => b.tokens.length - a.tokens.length);

const VIAS = {
  OR: 'oral', OFT: 'oftálmica', OTO: 'otológica', VAG: 'vaginal', GINEC: 'vaginal', DERM: 'dermatológica', TOP: 'dermatológica',
  NAS: 'nasal', IM: 'intramuscular', IV: 'intravenosa', SC: 'subcutânea', INAL: 'inalatória', RET: 'retal', EPI: 'epidural', IT: 'intratecal',
  SUBL: 'sublingual', BUC: 'bucal', IA: 'intra-articular', ID: 'intradérmica',
};
const USO_DA_VIA = { oftálmica: 'oftalmico', otológica: 'otologico', vaginal: 'vaginal', dermatológica: 'topico', nasal: 'topico' };
const ADJETIVO = { oral: 'oral', oftálmica: 'oftálmica', otológica: 'otológica', vaginal: 'vaginal', nasal: 'nasal' };
const EMBALAGEM = new Set(['CT', 'CX', 'EMB', 'EST', 'BL', 'STR', 'STRIP', 'FR', 'FA', 'AMP', 'ENV', 'ENVOL', 'BG', 'TB', 'BOLS', 'SER', 'CAR', 'CARP', 'FLAC', 'PT', 'SACH', 'KIT', 'X', 'DISP', '+']);
const RECIPIENTES = [
  ['AMP', 'ampola', 'ampolas'], ['FA', 'frasco-ampola', 'frascos-ampola'], ['SER', 'seringa preenchida', 'seringas preenchidas'],
  ['CARP?', 'carpule', 'carpules'], ['BOLS', 'bolsa', 'bolsas'], ['FLAC', 'flaconete', 'flaconetes'], ['FR', 'frasco', 'frascos'],
  ['BG', 'bisnaga', 'bisnagas'], ['TB', 'tubo', 'tubos'], ['PT', 'pote', 'potes'], ['ENV', 'envelope', 'envelopes'], ['SACH', 'sachê', 'sachês'],
];
const CONTAVEIS = [[/^comprimido/, 'comprimidos'], [/^cápsula/, 'cápsulas'], [/^óvulo/, 'óvulos']];

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
  while (tokens.length && tokens[0].split('/').every((t) => VIAS[t])) rotas.push(...tokens.shift().split('/'));
  let sufixo = '';
  let base = f.forma;
  if (tokens[0] === 'SPR' && base === 'solução') { tokens = tokens.slice(1); base = 'solução spray'; }
  if (tokens[0] === 'LIB' && tokens[1] === 'PROL') { tokens = tokens.slice(2); sufixo = ' de liberação prolongada'; }
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
  if (doses.length !== bases.length) return null;
  const regra = ASSOCIACOES[[...bases].sort().join('+')];
  const iguais = doses.every((d) => d.u === doses[0].u && d.den === doses[0].den && valor(d.n) === valor(doses[0].n));
  if (iguais) return doses;
  if (!regra) return null;
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
// GLP-1: dose por aplicação, nº de doses e dispositivo. Derivados do texto do
// registro (CMED/SNGPC) e das bulas:
// - seringa preenchida em caneta aplicadora (Mounjaro, Trulicity) e frasco-
//   ampola (Mounjaro FA): dose única = concentração x volume;
// - Mounjaro multidose (KwikPen, 2,4 mL): 4 doses fixas de 0,6 mL;
// - semaglutida em caneta: "(DOSES 0,25MG E 0,5 MG)" ou 6 agulhas = caneta de
//   0,25/0,5 mg (Ozempic, Extensior, Ozivy); demais canetas = 4 doses fixas
//   de (conteúdo total / 4) (Wegovy, Poviztra; Ozempic, Extensior e Ozivy 1 mg);
// - liraglutida e associações com insulina: dose ajustável (faixa da bula).
// ---------------------------------------------------------------------------
const DOSE_AJUSTAVEL = {
  victoza: '0,6 mg, 1,2 mg ou 1,8 mg', lirux: '0,6 mg, 1,2 mg ou 1,8 mg',
  saxenda: '0,6 mg a 3 mg', olire: '0,6 mg a 3 mg',
  xultophy: '1 a 50 U + 0,036 a 1,8 mg',
};

function glp1(desc, marca, bases) {
  const s = normDesc(desc);
  const ld = lerDoses(s);
  if (!ld) return { erro: 'concentração' };
  const r = ld.resto;
  const d0 = ld.doses[0];
  if (/^COM\b/.test(r)) {
    const n = Number((r.match(/\bX\s*(\d+)\s*$/) || [])[1]);
    if (!n) return { erro: 'quantidade' };
    return { concentracao: fmtDose(d0), forma: 'comprimido', via: 'oral', unidade: 'comprimidos', quantidade: n, dose: fmtDose(d0), doses: n };
  }
  if (!/^SOL INJ\b/.test(r)) return { erro: 'forma farmacêutica' };
  const cont = r.match(/\b(SER PREENC|FA|CARP?)\b/);
  if (!cont) return { erro: 'recipiente' };
  const qtd = Number((r.match(/\bCT\s+(?:X\s*)?(\d+)\s+(?:SER|FA|CARP?)\b/) || [])[1] || 1);
  const vol = (r.match(/\bX\s*(\d+(?:,\d+)?)\s*ML\b/) || [])[1];
  if (!vol) return { erro: 'volume' };
  const v = valor(vol);
  const base = { forma: 'solução injetável', via: 'subcutânea' };
  const mg = (x) => `${fmtNum(String(Math.round(x * 100) / 100).replace('.', ','))} mg`;
  if (cont[1] === 'SER PREENC' || cont[1] === 'FA') {
    // "1,5 MG ... X 0,5 ML" (dose por seringa) ou "5 MG/ML ... X 0,5 ML" (concentração)
    const porDose = d0.den ? valor(d0.n) * v : valor(d0.n);
    const seringa = cont[1] === 'SER PREENC';
    return {
      ...base,
      concentracao: `${mg(porDose)}/${fmtNum(vol)} mL`,
      unidade: seringa ? (qtd > 1 ? 'seringas preenchidas' : 'seringa preenchida') : (qtd > 1 ? 'frascos-ampola' : 'frasco-ampola'),
      quantidade: qtd,
      dose: mg(porDose),
      doses: qtd,
      dispositivo: seringa ? (/CAN APLIC/.test(r) ? 'caneta de dose única (seringa preenchida)' : 'seringa preenchida de dose única') : 'frasco-ampola de dose única',
    };
  }
  // Canetas multidose (carpule + sistema/caneta aplicadora)
  const unidade = `${qtd > 1 ? 'canetas' : 'caneta'} de ${fmtNum(vol)} mL`;
  const atribuidas = atribuirDoses(ld.doses, bases);
  if (!atribuidas) return { erro: 'associação sem regra de doses' };
  const concentracao = fmtConcentracao(atribuidas);
  const m = chave(marca || '').split(' ')[0];
  if (bases.includes('tirzepatida')) {
    if (Math.abs(v - 2.4) > 0.01) return { erro: 'caneta de tirzepatida com volume desconhecido' };
    const bruta = (valor(d0.n) * v) / 4;
    const dose = Math.round(bruta / 2.5) * 2.5; // doses de tirzepatida: múltiplos de 2,5 mg
    if (Math.abs(bruta - dose) / dose > 0.02) return { erro: `tirzepatida: dose por aplicação desconhecida (${bruta} mg)` };
    return { ...base, concentracao: `${mg(dose)}/0,6 mL`, unidade, quantidade: qtd, dose: mg(dose), doses: 4 * qtd, dispositivo: 'caneta multidose (4 doses fixas)' };
  }
  if (bases.length === 1 && bases[0] === 'semaglutida') {
    const agulhas = Number((r.match(/\+\s*(\d+)\s*AGU/) || [])[1] || 0);
    if (/DOSES 0,25 ?MG E 0,5 ?MG/.test(r) || agulhas / qtd === 6 || agulhas === 10) {
      return { ...base, concentracao, unidade, quantidade: qtd, dose: '0,25 mg ou 0,5 mg', dispositivo: 'caneta multidose (dose selecionável)' };
    }
    const total = valor(d0.n) * v;
    const dose = [0.25, 0.5, 1, 1.7, 2, 2.4].find((x) => Math.abs(total / 4 - x) / x < 0.05);
    if (!dose) return { erro: `semaglutida: dose por aplicação desconhecida (${total} mg)` };
    return { ...base, concentracao, unidade, quantidade: qtd, dose: mg(dose), doses: 4 * qtd, dispositivo: 'caneta multidose (4 doses fixas)' };
  }
  if (bases.includes('lixisenatida')) {
    const lixi = ld.doses.find((d) => !eUI(d));
    const faixa = lixi && valor(lixi.n) >= 0.045 ? '10 a 40 U + 5 a 20 mcg' : '30 a 60 U + 10 a 20 mcg';
    return { ...base, concentracao, unidade, quantidade: qtd, dose: faixa, dispositivo: 'caneta multidose (dose ajustável)' };
  }
  const dose = DOSE_AJUSTAVEL[m];
  if (!dose) return { erro: `dose ajustável sem marca conhecida (${marca || 'sem CMED'})` };
  return { ...base, concentracao, unidade, quantidade: qtd, dose, dispositivo: 'caneta multidose (dose ajustável)' };
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
  // A mesma base pode vir duas vezes com sais diferentes; mantém a primeira.
  const porBase = new Map();
  for (const x of comps) if (!porBase.has(x.base)) porBase.set(x.base, x);
  return [...porBase.values()];
}

function ordenar(comps, classe) {
  if (classe === 'glp1') return comps; // SNGPC já traz "insulina ... + GLP-1" em ordem alfabética
  const peso = (x) => (x.listado ? (INIBIDORES.has(x.base) ? 1 : 0) : 2);
  return [...comps].sort((a, b) => peso(a) - peso(b) || a.base.localeCompare(b.base));
}

function sentenca(s) {
  s = s.charAt(0).toUpperCase() + s.slice(1);
  return s.replace(/\b(polimixina|anfotericina|penicilina|vitamina) ([bgv])\b/g, (_, a, b) => `${a} ${b.toUpperCase()}`).replace(/\b([Rr]ifamicina) sv\b/g, '$1 SV');
}

// Nome impresso: a grafia mais vendida; entre grafias que só diferem em acentos,
// a acentuada.
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
const nomeDe = (pa, g) => {
  const porBase = new Map(componentes(pa).map((x) => [x.base, x.exib]));
  return g.bases.map((b) => porBase.get(b)).filter(Boolean).join(' + ');
};

function montar(agregados, cmed) {
  // Índice CMED por texto de apresentação.
  const porApres = new Map();
  for (const l of cmed.linhas) {
    const k = chaveApres(l.apres);
    if (!porApres.has(k)) porApres.set(k, []);
    porApres.get(k).push(l);
  }
  const casarCmed = (bases, apres) => {
    const cand = porApres.get(chaveApres(apres)) || [];
    const alvo = new Set(bases);
    const comBase = (l) => l.comps.map((c) => listado(c)?.base || baseDe(c));
    const exatos = cand.filter((l) => { const b = comBase(l); return b.length === alvo.size && b.every((x) => alvo.has(x)); });
    return exatos.length ? exatos : cand.filter((l) => comBase(l).some((x) => alvo.has(x)));
  };

  const grupos = new Map();
  const fora = new Map();
  const totalEscopo = { v: 0 };
  const cacheComp = new Map();
  for (const row of agregados) {
    let info = cacheComp.get(row.pa);
    if (info === undefined) {
      const comps = componentes(row.pa);
      const alvo = comps.filter((x) => x.listado);
      if (!alvo.length) info = null;
      else {
        const classe = alvo.some((x) => x.listado.classe === 'glp1') ? 'glp1' : 'antimicrobiano';
        info = { classe, comps: ordenar(comps, classe), foraDaLista: alvo.every((x) => x.listado.foraDaLista) };
        info.bases = info.comps.map((x) => x.base);
      }
      cacheComp.set(row.pa, info);
    }
    if (!info) {
      if (row.tp === CODIGO) fora.set(row.pa || '(vazio)', (fora.get(row.pa || '(vazio)') || 0) + row.qt);
      continue;
    }
    if (row.tp === CODIGO) totalEscopo.v += row.qt;
    const k = info.bases.join('+');
    let g = grupos.get(k);
    if (!g) grupos.set(k, (g = { ...info, nomes: new Map(), linhas: [] }));
    const nome = info.comps.map((x) => x.exib).join(' + ');
    g.nomes.set(nome, (g.nomes.get(nome) || 0) + row.qt);
    g.linhas.push(row);
  }

  const pend = { naoLidas: [], semCmed: new Map(), isentas: new Map(), hospitalares: new Map(), hospitalaresLiberadas: new Map(), semVia: [], glp1: [] };
  const substancias = [];

  for (const g of grupos.values()) {
    const notif = g.linhas.filter((r) => r.tp === CODIGO);
    const usadas = soma(notif, (r) => r.qt) > 0 ? notif : g.linhas;
    const nome = escolherNome(g.nomes);
    const chaveG = g.bases.map(semAcento).join('+');
    const buscaBase = [...new Set(g.bases.flatMap((b) => [b, ...(b.includes(' ') ? [] : [])]))];

    // Agrega por descrição (guardando as grafias do princípio ativo, para o nome)
    const porDesc = new Map();
    const nomesDesc = new Map();
    for (const r of usadas) {
      porDesc.set(r.apres, (porDesc.get(r.apres) || 0) + r.qt);
      if (!nomesDesc.has(r.apres)) nomesDesc.set(r.apres, new Map());
      const n = g.comps.length ? nomeDe(r.pa, g) : r.pa;
      nomesDesc.get(r.apres).set(n, (nomesDesc.get(r.apres).get(n) || 0) + r.qt);
    }

    if (g.classe === 'glp1') {
      const saida = new Map();
      const adicionar = (a, marcas, generico, vendas, linhasCmed = []) => {
        const { erro, ...campos } = a;
        const k = JSON.stringify({ ...campos, generico });
        const e = saida.get(k) || { ...campos, vendas: 0, marcas: new Map(), generico, cmed2025: false };
        e.vendas += vendas;
        e.cmed2025 ||= linhasCmed.some((l) => l?.comercializado);
        for (const [m, v] of marcas) e.marcas.set(m, (e.marcas.get(m) || 0) + v);
        saida.set(k, e);
      };
      const vistasCmed = new Set();
      for (const [apres, qt] of porDesc) {
        const linhasCmed = casarCmed(g.bases, apres);
        linhasCmed.forEach((l) => vistasCmed.add(l));
        if (!linhasCmed.length) pend.semCmed.set(`${nome} | ${apres}`, qt);
        const alvos = (linhasCmed.length ? linhasCmed : [null]).map((l) => ({ l, a: glp1(apres, l?.produto, g.bases) }));
        const erro = alvos.find((x) => x.a.erro);
        if (erro) { pend.naoLidas.push({ nome, apres, vendas: qt, motivo: erro.a.erro }); continue; }
        // Uma descrição pode corresponder a marcas com doses diferentes (Lirux e Olire): divide.
        const distintos = new Map();
        for (const x of alvos) {
          const k = JSON.stringify(x.a);
          if (!distintos.has(k)) distintos.set(k, { a: x.a, linhas: [] });
          distintos.get(k).linhas.push(x.l);
        }
        const partes = [...distintos.values()];
        partes.forEach((p, i) => {
          const parte = Math.floor(qt / partes.length) + (i === 0 ? qt % partes.length : 0);
          const marcas = new Map(p.linhas.filter((l) => l && l.tipo !== 'Genérico').map((l) => [marcaExibida(l.produto), parte]));
          adicionar(p.a, marcas, p.linhas.some((l) => l?.tipo === 'Genérico'), parte, p.linhas);
        });
      }
      // Apresentações com preço CMED e sem venda no período: vendas 0.
      for (const l of cmed.linhas) {
        if (vistasCmed.has(l)) continue;
        const b = l.comps.map((c) => listado(c)?.base || baseDe(c));
        if (b.length !== g.bases.length || !b.every((x) => g.bases.includes(x))) continue;
        const a = glp1(l.apres, l.produto, g.bases);
        if (a.erro) { pend.naoLidas.push({ nome, apres: `${l.apres} [CMED ${l.produto}]`, vendas: 0, motivo: a.erro }); continue; }
        adicionar(a, new Map(l.tipo !== 'Genérico' ? [[marcaExibida(l.produto), 0]] : []), l.tipo === 'Genérico', 0, [l]);
      }
      const ordenadas = [...saida.values()]
        .map((e) => ({ ...e, marcas: [...e.marcas].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([m]) => m) }))
        .sort((a, b) => b.vendas - a.vendas || a.marcas.join().localeCompare(b.marcas.join()) || valor(a.dose.split(' ')[0]) - valor(b.dose.split(' ')[0]) || a.quantidade - b.quantidade);
      for (const e of ordenadas) pend.glp1.push({ nome, ...ordemCampos(e), cmed2025: e.cmed2025 });
      const apresentacoes = ordenadas.map(ordemCampos);
      if (!apresentacoes.length) continue;
      const busca = [...new Set([...buscaBase, ...apresentacoes.flatMap((p) => p.marcas.map((m) => semAcento(m.toLowerCase())))])];
      substancias.push({ nome, chave: chaveG, classe: 'glp1', uso: 'sistemico', busca, vendas: soma(apresentacoes, (p) => p.vendas), apresentacoes });
      continue;
    }

    // Antimicrobianos: agrupa por uso (sistêmico, oftálmico, otológico, tópico, vaginal).
    const porUso = new Map();
    const semVia = [];
    for (const [apres, qt] of porDesc) {
      const descBula = comComposicaoDaBula(apres, g.bases);
      const a = lerApresentacao(descBula);
      if (!a.erro) {
        let d = atribuirDoses(a.doses, g.bases);
        // Kit IM com diluente de lidocaína ("1 G PO SOL INJ IM ... + DIL ..."): a dose
        // do diluente só entra se estiver na descrição ("DIL 10 MG/ML").
        if (!d && g.bases.includes('lidocaina') && /\bDIL\b/.test(normDesc(apres)) && a.doses.length === g.bases.length - 1) {
          const lido = normDesc(apres).match(/(\d+(?:,\d+)?) MG\/ML (?:SOL INJ )?(?:DIL|AMP)|DIL (\d+(?:,\d+)?) MG\/ML/);
          const outros = g.bases.filter((b) => b !== 'lidocaina');
          const principal = atribuirDoses(a.doses, outros);
          if (principal) d = g.bases.map((b) => (b === 'lidocaina' ? (lido ? { n: lido[1] || lido[2], u: 'MG', den: '/ML' } : null) : principal[outros.indexOf(b)])).filter(Boolean);
        }
        if (!d) a.erro = g.bases.length > 1 ? 'associação sem regra de doses' : 'nº de doses';
        else a.doses = d;
      }
      if (a.erro) { pend.naoLidas.push({ nome, apres, vendas: qt, motivo: a.erro }); continue; }
      let linhasCmed = casarCmed(g.bases, apres);
      if (!linhasCmed.length && descBula !== apres) linhasCmed = casarCmed(g.bases, descBula); // "1 + 0,4" -> "1% + 0,4%"
      if (!linhasCmed.length) pend.semCmed.set(`${nome} | ${apres}`, qt);
      else if (linhasCmed.every((l) => l.semTarja)) { pend.isentas.set(`${nome} | ${apres}`, qt); continue; }
      else if (linhasCmed.every((l) => l.hosp)) {
        const liberado = HOSPITALAR_LIBERADO.some((h) => h.bases === [...g.bases].sort().join('+') && h.via.test(a.via || ''));
        if (!liberado) { pend.hospitalares.set(`${nome} | ${apres}`, qt); continue; }
        pend.hospitalaresLiberadas.set(`${nome} | ${apres}`, qt);
      }
      const item = { a, qt, linhasCmed, apres, nomes: nomesDesc.get(apres) };
      if (!a.via) { semVia.push(item); continue; }
      const uso = USO_DA_VIA[a.via.split(' ou ')[0]] || 'sistemico';
      if (!porUso.has(uso)) porUso.set(uso, []);
      porUso.get(uso).push(item);
    }
    // Descrições sem via: injetáveis herdam a via injetável mais vendida do grupo
    // (senão "injetável"); soluções/suspensões sem via herdam a via mais vendida
    // do grupo para a mesma forma (ex.: gotas otológicas sem "OTO").
    const todos = [...porUso.values()].flat();
    const maisVendida = (xs) => {
      const m = new Map();
      for (const x of xs) m.set(x.a.via, (m.get(x.a.via) || 0) + x.qt);
      return [...m].sort((a, b) => b[1] - a[1])[0]?.[0];
    };
    for (const item of semVia) {
      const injetavel = /injet|infus/.test(item.a.forma);
      if (injetavel) item.a.via = maisVendida(todos.filter((x) => /injet|infus/.test(x.a.forma))) || 'injetável';
      else {
        const via = maisVendida(todos.filter((x) => x.a.forma.split(' ')[0] === item.a.forma));
        if (!via) { pend.semVia.push({ nome, apres: item.apres, vendas: item.qt }); continue; }
        item.a.via = via;
        if (ADJETIVO[via]) item.a.forma += ` ${ADJETIVO[via]}`;
      }
      const uso = USO_DA_VIA[item.a.via.split(' ou ')[0]] || 'sistemico';
      if (!porUso.has(uso)) porUso.set(uso, []);
      porUso.get(uso).push(item);
    }
    for (const [uso, itens] of porUso) {
      const pres = new Map();
      for (const { a, qt, linhasCmed } of itens) {
        const concentracao = fmtConcentracao(a.doses);
        const k = `${concentracao}\t${a.forma}\t${a.via}`;
        const p = pres.get(k) || { concentracao, forma: a.forma, via: a.via, vendas: 0, pacotes: new Map(), marcas: new Map(), generico: false };
        p.vendas += qt;
        if (a.quantidade >= 1 && a.quantidade <= 999) {
          const kp = `${a.unidade}\t${a.quantidade}`;
          p.pacotes.set(kp, (p.pacotes.get(kp) || 0) + qt);
        }
        const tokensBase = g.bases.flatMap((b) => b.split(' '));
        for (const l of linhasCmed) {
          if (l.tipo === 'Genérico') { p.generico = true; continue; }
          const tk = chave(l.produto).split(' ');
          if (g.comps.some((x) => x.listado && contem(tk, x.base.split(' '))) || tokensBase.every((t) => tk.includes(t))) continue; // "similar" com nome genérico
          const m = marcaExibida(l.produto);
          p.marcas.set(m, (p.marcas.get(m) || 0) + qt / linhasCmed.length);
        }
        pres.set(k, p);
      }
      const apresentacoes = [...pres.values()]
        .filter((p) => p.pacotes.size)
        .sort((a, b) => b.vendas - a.vendas || a.concentracao.localeCompare(b.concentracao))
        .slice(0, 8)
        .map((p) => {
          const [unidade, q] = [...p.pacotes].sort((a, b) => b[1] - a[1])[0][0].split('\t');
          const marcas = [...p.marcas].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 8).map(([m]) => m);
          return ordemCampos({ concentracao: p.concentracao, forma: p.forma, via: p.via, unidade, quantidade: Number(q), vendas: p.vendas, marcas, generico: p.generico });
        });
      if (!apresentacoes.length) continue;
      const vendas = soma(itens, (x) => x.qt);
      const nomesUso = new Map();
      for (const x of itens) for (const [n, v] of x.nomes) nomesUso.set(n, (nomesUso.get(n) || 0) + v);
      const nome = escolherNome(nomesUso);
      const marcasBusca = [...new Map(apresentacoes.flatMap((p) => p.marcas.map((m) => [semAcento(m.toLowerCase()), p.vendas]))).keys()].slice(0, 12);
      substancias.push({ nome, chave: chaveG, classe: 'antimicrobiano', uso, ...(g.foraDaLista ? { fora_da_lista: true } : {}), busca: [...new Set([...buscaBase, ...marcasBusca])], vendas, apresentacoes });
    }
  }
  const ordemClasse = ['glp1', 'antimicrobiano'];
  substancias.sort((a, b) => ordemClasse.indexOf(a.classe) - ordemClasse.indexOf(b.classe) || b.vendas - a.vendas || a.nome.localeCompare(b.nome) || a.uso.localeCompare(b.uso));
  return { substancias, pend, fora, totalEscopo: totalEscopo.v };
}

function ordemCampos(p) {
  const o = { concentracao: p.concentracao, forma: p.forma, via: p.via, unidade: p.unidade, quantidade: p.quantidade, vendas: p.vendas, marcas: p.marcas, generico: p.generico };
  if (p.dose !== undefined) o.dose = p.dose;
  if (p.doses !== undefined) o.doses = p.doses;
  if (p.dispositivo !== undefined) o.dispositivo = p.dispositivo;
  return o;
}

// ---------------------------------------------------------------------------
// Validação (falha alto antes de gravar)
// ---------------------------------------------------------------------------

const PERMITIDOS = /^[A-Za-zÀ-ÖØ-öø-ÿ0-9 .,;:()\/\-'"ªº°%+&#*!?]*$/;
const USOS = new Set(['sistemico', 'oftalmico', 'otologico', 'topico', 'vaginal']);
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
    const onde = `substancias[${i}] (${s.nome}, ${s.uso})`;
    max(s.nome, 120, `${onde}.nome`);
    if (!/^[a-z0-9 ]+(\+[a-z0-9 ]+)*$/.test(s.chave)) erros.push(`${onde}: chave inválida ${s.chave}`);
    if (!['glp1', 'antimicrobiano'].includes(s.classe)) erros.push(`${onde}: classe inválida`);
    if (!USOS.has(s.uso)) erros.push(`${onde}: uso inválido`);
    if (s.classe === 'glp1' && s.uso !== 'sistemico') erros.push(`${onde}: GLP-1 deve ser sistêmico`);
    if ('fora_da_lista' in s && (s.fora_da_lista !== true || !s.chave.split('+').every((b) => FORA_DA_LISTA.includes(b) || !listado(b)?.foraDaLista))) erros.push(`${onde}: fora_da_lista inválido`);
    if (!('fora_da_lista' in s) && s.chave.split('+').some((b) => FORA_DA_LISTA.includes(b)) && s.chave.split('+').every((b) => FORA_DA_LISTA.includes(b) || !listado(b))) erros.push(`${onde}: falta fora_da_lista`);
    const k = `${s.chave}|${s.uso}`;
    if (vistos.has(k)) erros.push(`${onde}: (chave, uso) repetido`);
    vistos.add(k);
    if (!Array.isArray(s.busca) || s.busca.some((b) => !/^[a-z0-9 .\-+&\/]+$/.test(b))) erros.push(`${onde}: busca inválida ${JSON.stringify(s.busca)}`);
    for (const b of s.chave.split('+')) if (!s.busca.includes(b)) erros.push(`${onde}: busca sem a base ${b}`);
    if (!Number.isInteger(s.vendas) || s.vendas < 0) erros.push(`${onde}: vendas inválidas`);
    if (anterior && (anterior.classe === s.classe ? anterior.vendas < s.vendas : anterior.classe === 'antimicrobiano')) erros.push(`${onde}: fora de ordem`);
    anterior = s;
    const limite = s.classe === 'glp1' ? Infinity : 8;
    if (!Array.isArray(s.apresentacoes) || !s.apresentacoes.length || s.apresentacoes.length > limite) erros.push(`${onde}: apresentacoes inválidas`);
    const chaves = new Set();
    let somaV = 0;
    s.apresentacoes.forEach((p, j) => {
      const o = `${onde}.apresentacoes[${j}]`;
      max(p.concentracao, 40, `${o}.concentracao`);
      max(p.forma, 60, `${o}.forma`);
      max(p.via, 40, `${o}.via`);
      max(p.unidade, 40, `${o}.unidade`);
      if (p.forma !== p.forma.toLowerCase()) erros.push(`${o}: forma deve ser minúscula`);
      if (/µ/.test(p.concentracao)) erros.push(`${o}: use mcg`);
      if (!Number.isInteger(p.quantidade) || p.quantidade < 1 || p.quantidade > 999) erros.push(`${o}: quantidade ${p.quantidade}`);
      if (!Number.isInteger(p.vendas) || p.vendas < (s.classe === 'glp1' ? 0 : 1)) erros.push(`${o}: vendas ${p.vendas}`);
      if (!Array.isArray(p.marcas) || p.marcas.some((m) => typeof m !== 'string' || !m || m.length > 60)) erros.push(`${o}: marcas inválidas`);
      if (typeof p.generico !== 'boolean') erros.push(`${o}: generico deve ser booleano`);
      if (s.classe === 'glp1') {
        max(p.dose, 40, `${o}.dose`);
        if (p.doses !== undefined && (!Number.isInteger(p.doses) || p.doses < 1 || p.doses > 999)) erros.push(`${o}: doses ${p.doses}`);
        if (p.forma !== 'comprimido') max(p.dispositivo, 60, `${o}.dispositivo`);
      } else if (p.dose !== undefined || p.doses !== undefined || p.dispositivo !== undefined) erros.push(`${o}: dose/doses/dispositivo só para GLP-1`);
      const kp = JSON.stringify({ ...p, vendas: 0, marcas: [] });
      if (chaves.has(kp)) erros.push(`${o}: apresentação repetida`);
      chaves.add(kp);
      if (j && s.apresentacoes[j - 1].vendas < p.vendas) erros.push(`${o}: fora de ordem`);
      somaV += p.vendas;
    });
    if (somaV > s.vendas) erros.push(`${onde}: soma das apresentações maior que vendas`);
  });
  if (erros.length) throw new Error(`validação falhou (${erros.length}):\n  ${erros.slice(0, 60).join('\n  ')}`);
}

// ---------------------------------------------------------------------------
// Execução
// ---------------------------------------------------------------------------

const agregados = await carregarAgregados();
const cmed = await carregarCmed();
const { substancias, pend, fora, totalEscopo } = montar(agregados, cmed);
const d = new Date();
const hoje = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const mes = (m) => `${m.slice(0, 4)}-${m.slice(4)}`;
const saida = {
  gerado: args.data || hoje,
  fontes: {
    ...FONTES,
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

// Relatório
const conta = (f) => substancias.reduce((a, s) => { const k = f(s); a[k] = (a[k] || 0) + 1; return a; }, {});
const totalMap = (m) => [...m.values()].reduce((a, b) => a + b, 0);
log(`\ngravado ${SAIDA} (${(Buffer.byteLength(json) / 1024).toFixed(1)} KB)`);
log(`período: ${saida.fontes.sngpc.periodo}; por classe: ${JSON.stringify(conta((s) => s.classe))}; por uso: ${JSON.stringify(conta((s) => `${s.classe}/${s.uso}`))}`);
log(`descrições não lidas: ${pend.naoLidas.length} (${soma(pend.naoLidas, (n) => n.vendas)} embalagens); sem par na CMED: ${pend.semCmed.size} (${totalMap(pend.semCmed)}); isentas de prescrição (CMED sem tarja): ${pend.isentas.size} (${totalMap(pend.isentas)}); uso hospitalar (CMED): ${pend.hospitalares.size} (${totalMap(pend.hospitalares)}); hospitalar liberado: ${pend.hospitalaresLiberadas.size} (${totalMap(pend.hospitalaresLiberadas)})`);
log(`cobertura: ${soma(substancias, (s) => s.vendas)} de ${totalEscopo} embalagens com código 5 em escopo (${((100 * soma(substancias, (s) => s.vendas)) / totalEscopo).toFixed(1)}%)`);
log(`fora do escopo com código 5: ${fora.size} princípios ativos, ${totalMap(fora)} embalagens; sem via: ${pend.semVia.length}`);
if (args.relatorio) {
  log('\n== GLP-1 (vendas | marcas | concentração | dose | doses | embalagem | dispositivo | comercializado em 2025 segundo a CMED)');
  for (const s of substancias.filter((x) => x.classe === 'glp1')) {
    log(`${s.nome} [${s.chave}] ${s.vendas}`);
    for (const p of pend.glp1.filter((x) => x.nome === s.nome)) log(`   ${String(p.vendas).padStart(7)} | ${p.marcas.join('/') || '(sem CMED)'} | ${p.concentracao} | ${p.dose} | ${p.doses ?? '-'} | ${p.quantidade} ${p.unidade} | ${p.dispositivo || p.forma} | ${p.cmed2025 ? 'sim' : 'NÃO'}`);
  }
  log('\n== antimicrobianos: top 20');
  for (const s of substancias.filter((x) => x.classe === 'antimicrobiano').slice(0, 20)) {
    const p = s.apresentacoes[0];
    log(`  ${s.vendas} ${s.nome} (${s.uso}) | ${p.concentracao} ${p.forma}, ${p.quantidade} ${p.unidade} | ${p.marcas.slice(0, 4).join(', ')}${p.generico ? ' + genéricos' : ''}`);
  }
  const top = (m, n) => [...m].sort((a, b) => b[1] - a[1]).slice(0, n);
  log('\n== não lidas'); for (const n of pend.naoLidas.sort((a, b) => b.vendas - a.vendas).slice(0, 60)) log(`  ${n.vendas}\t${n.motivo}\t${n.nome} | ${n.apres}`);
  log('\n== sem par na CMED'); for (const [k, v] of top(pend.semCmed, 40)) log(`  ${v}\t${k}`);
  log('\n== isentas de prescrição (excluídas)'); for (const [k, v] of top(pend.isentas, 20)) log(`  ${v}\t${k}`);
  log('\n== uso hospitalar (excluídas), por substância');
  const porSub = new Map();
  for (const [k, v] of pend.hospitalares) { const n = k.split(' | ')[0]; const e = porSub.get(n) || { v: 0, itens: [] }; e.v += v; e.itens.push([k.split(' | ')[1], v]); porSub.set(n, e); }
  for (const [n, e] of [...porSub].sort((a, b) => b[1].v - a[1].v)) {
    log(`  ${e.v}\t${n} (${e.itens.length} descrições)`);
    for (const [d, v] of e.itens.sort((a, b) => b[1] - a[1])) log(`      ${v}\t${d}`);
  }
  log('\n== uso hospitalar liberado por decisão do prescritor'); for (const [k, v] of top(pend.hospitalaresLiberadas, 20)) log(`  ${v}\t${k}`);
  log('\n== fora do escopo (código 5)'); for (const [k, v] of top(fora, 30)) log(`  ${v}\t${k}`);
}
