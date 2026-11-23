#!/usr/bin/env node
// Gera data/medicamentos-rce.json: medicamentos prescritos em RECEITA DE CONTROLE
// ESPECIAL (RCE, 2 vias) pela Portaria SVS/MS 344/1998, Anexo I na redação da
// RDC nº 1.036/2026:
//   - listas C1 (outras substâncias sujeitas a controle especial) e C5 (anabolizantes);
//   - preparações das listas A1, A2, A3 e B1 que os adendos mandam para a RCE
//     (tramadol e codeína até 100 mg por unidade, buprenorfina em adesivo,
//     oxicodona LP até 40 mg, fenobarbital, perampanel, produtos de Cannabis com
//     THC até 0,2%...).
// Ranking pelas dispensações do SNGPC com TP_RECEITUARIO 1 (Receita de Controle
// Especial); marcas e genéricos pela lista de preços CMED.
// Veja data/PROVENANCE.md (seção "Receita de Controle Especial").
//
// Uso:
//   node scripts/medicamentos/gerar-rce.mjs [opções]
//     --meses=202606,202607,202608   meses do SNGPC (AAAAMM)
//     --cache=DIR                    mesmo cache de gerar.mjs ($MEDICAMENTOS_CACHE
//                                    ou <tmpdir>/cockpit-rx-medicamentos)
//     --refazer                      ignora o cache e baixa tudo de novo
//     --relatorio                    imprime top 30, exclusões e pendências
//     --data=AAAA-MM-DD              valor de "gerado" (padrão: hoje)
//     --saida=ARQUIVO                caminho do JSON (padrão: data/medicamentos-rce.json)
//
// Não importa gerar.mjs nem gerar-retencao.mjs (ambos executam ao ser
// carregados); as funções comuns foram copiadas e usam o mesmo cache.

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
const SAIDA = resolve(args.saida || join(RAIZ, 'data', 'medicamentos-rce.json'));

const SNGPC_URL = process.env.SNGPC_URL || 'https://dados.anvisa.gov.br/dados/SNGPC/Industrializados/';
const CMED_URL = 'https://dados.anvisa.gov.br/dados/TA_PRECO_MEDICAMENTO.csv';
const CODIGO = '1'; // TP_RECEITUARIO 1 = Receita de Controle Especial em 2 vias
const FONTE_LISTAS = {
  ato: 'RDC nº 1.036/2026 (Anexo I da Portaria SVS/MS nº 344/1998, listas C1 e C5 e adendos das listas A1, A2, A3 e B1)',
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
// Listas do Anexo I da Portaria SVS/MS 344/1998 na redação da RDC nº 1.036, de
// 9/7/2026 (DOU 13/7/2026). A1 a B2 copiadas de gerar.mjs (conferidas com o
// texto oficial por --verificar-listas); C1, C2, C3 e C5 copiadas do mesmo texto.
// Não há lista C4 (antirretrovirais) nesta redação do Anexo I.
// ---------------------------------------------------------------------------

const LISTAS = {
  A1: ['Acetilmetadol', 'Alfacetilmetadol', 'Alfameprodina', 'Alfametadol', 'Alfaprodina', 'Alfentanila', 'Alilprodina', 'Anileridina', 'Bezitramida', 'Benzetidina', 'Benzilmorfina', 'Benzoilmorfina', 'Betacetilmetadol', 'Betameprodina', 'Betametadol', 'Betaprodina', 'Buprenorfina', 'Butorfanol', 'Clonitazeno', 'Codoxima', 'Concentrado de palha de dormideira', 'Dextromoramida', 'Diampromida', 'Dietiltiambuteno', 'Difenoxilato', 'Difenoxina', 'Diidromorfina', 'Dimefeptanol (metadol)', 'Dimenoxadol', 'Dimetiltiambuteno', 'Dioxafetila', 'Dipipanona', 'Drotebanol', 'Etilmetiltiambuteno', 'Etonitazeno', 'Etoxeridina', 'Fenadoxona', 'Fenampromida', 'Fenazocina', 'Fenomorfano', 'Fenoperidina', 'Fentanila', 'Furetidina', 'Hidrocodona', 'Hidromorfinol', 'Hidromorfona', 'Hidroxipetidina', 'Intermediário da metadona (4-ciano-2-dimetilamina-4,4-difenilbutano)', 'Intermediário da moramida (ácido 2-metil-3-morfolina-1,1-difenilpropano carboxílico)', 'Intermediário "a" da petidina (4-ciano-1-metil-4-fenilpiperidina)', 'Intermediário "b" da petidina (éster etílico do ácido 4-fenilpiperidina-4-carboxilíco)', 'Intermediário "c" da petidina (ácido-1-metil-4-fenilpiperidina-4-carboxílico)', 'Isometadona', 'Levofenacilmorfano', 'Levometorfano', 'Levomoramida', 'Levorfanol', 'Metadona', 'Metazocina', 'Metildesorfina', 'Metildiidromorfina', 'Metopona', 'Mirofina', 'Morferidina', 'Morfina', 'Morinamida', 'Nicomorfina', 'Noracimetadol', 'Norlevorfanol', 'Normetadona', 'Normorfina', 'Norpipanona', 'N-oxicodeína', 'N-oximorfina', 'Ópio', 'Oripavina', 'Oxicodona', 'Oximorfona', 'Petidina', 'Piminodina', 'Piritramida', 'Proeptazina', 'Properidina', 'Racemetorfano', 'Racemoramida', 'Racemorfano', 'Remifentanila', 'Sufentanila', 'Tapentadol', 'Tebacona', 'Tebaína', 'Tilidina', 'Trimeperidina', 'Viminol'],
  A2: ['Acetildiidrocodeina', 'Codeína', 'Dextropropoxifeno', 'Diidrocodeína', 'Etilmorfina', 'Folcodina', 'Nalbufina', 'Nalorfina', 'Nicocodina', 'Nicodicodina', 'Norcodeína', 'Propiram', 'Tramadol'],
  A3: ['Anfetamina', 'Catina', 'Clorfentermina', 'Dexanfetamina', 'Dronabinol', 'Femetrazina', 'Fenciclidina', 'Fenetilina', 'Fenfluramina', 'Levanfetamina', 'Lisdexanfetamina', 'Metilfenidato', 'Metilsinefrina', 'Tanfetamina'],
  B1: ['Alfaxalona', 'Alobarbital', 'Alprazolam', 'Amineptina', 'Amobarbital', 'Aprobarbital', 'Armodafinila', 'Barbexaclona', 'Barbital', 'Bromazepam', 'Bromazolam', 'Brotizolam', 'Butabarbital', 'Butalbital', 'Camazepam', 'Carisoprodol', 'Cetamina', 'Cetazolam', 'Ciclobarbital', 'Clobazam', 'Clonazepam', 'Clonazolam', 'Clorazepam', 'Clorazepato', 'Clordiazepóxido', 'Cloreto de etila', 'Cloreto de metileno/diclorometano', 'Clotiazepam', 'Cloxazolam', 'Delorazepam', 'Diazepam', 'Diclazepam', 'Escetamina', 'Estazolam', 'Eszopiclona', 'Etclorvinol', 'Etilanfetamina (N-etilanfetamina)', 'Etinamato', 'Etizolam', 'Fenazepam', 'Fenobarbital', 'Flualprazolam', 'Flubromazolam', 'Fludiazepam', 'Flunitrazepam', 'Flunitrazolam', 'Flurazepam', 'GBL', 'GHB - (ácido gama - hidroxibutírico)', 'Glutetimida', 'Halazepam', 'Haloxazolam', 'Lefetamina', 'Lemborexante', 'Loflazepato de etila', 'Loprazolam', 'Lorazepam', 'Lormetazepam', 'Medazepam', 'Meprobamato', 'Mesocarbo', 'Metilfenobarbital (prominal)', 'Metiprilona', 'Midazolam', 'Modafinila', 'Nimetazepam', 'Nitrazepam', 'Norcanfano (fencanfamina)', 'Nordazepam', 'Oxazepam', 'Oxazolam', 'Pemolina', 'Pentazocina', 'Pentobarbital', 'Perampanel', 'Pinazepam', 'Pipradrol', 'Pirovalerona', 'Prazepam', 'Prolintano', 'Propilexedrina', 'Remimazolam', 'Secbutabarbital', 'Secobarbital', 'Temazepam', 'Tetrazepam', 'Tiamilal', 'Tiopental', 'Triazolam', 'Tricloroetileno', 'Triexifenidil', 'Vinilbital', 'Zaleplona', 'Zolpidem', 'Zopiclona'],
  B2: ['Aminorex', 'Anfepramona', 'Femproporex', 'Fendimetrazina', 'Fentermina', 'Mazindol', 'Mefenorex', 'Sibutramina'],
  C1: ['Acepromazina', 'Ácido valpróico', 'Agomelatina', 'Amantadina', 'Amissulprida', 'Amitriptilina', 'Amoxapina', 'Aripiprazol', 'Asenapina', 'Atomoxetina', 'Azaciclonol', 'Beclamida', 'Benactizina', 'Benfluorex', 'Benzidamina', 'Benzoctamina', 'Benzoquinamida', 'Biperideno', 'Brexpiprazol', 'Brivaracetam', 'Bupropiona', 'Buspirona', 'Butaperazina', 'Butriptilina', 'Canabidiol (CBD)', 'Captodiamo', 'Carbamazepina', 'Caroxazona', 'Celecoxibe', 'Cenobamato', 'Ciclarbamato', 'Ciclexedrina', 'Ciclopentolato', 'Cisaprida', 'Citalopram', 'Clomacrano', 'Clometiazol', 'Clomipramina', 'Clorexadol', 'Clorpromazina', 'Clorprotixeno', 'Clotiapina', 'Clozapina', 'Dapoxetina', 'Desflurano', 'Desipramina', 'Desvenlafaxina', 'Deutetrabenazina', 'Dexetimida', 'Dexmedetomidina', 'Dibenzepina', 'Dimetracrina', 'Disopiramida', 'Dissulfiram', 'Divalproato de sódio', 'Dixirazina', 'Donepezila', 'Doxepina', 'Droperidol', 'Duloxetina', 'Ectiluréia', 'Emilcamato', 'Enflurano', 'Entacapona', 'Escitalopram', 'Estiripentol', 'Etomidato', 'Etoricoxibe', 'Etossuximida', 'Facetoperano', 'Femprobamato', 'Fenaglicodol', 'Fenelzina', 'Feniprazina', 'Fenitoina', 'Flufenazina', 'Flumazenil', 'Fluoxetina', 'Flupentixol', 'Fluvoxamina', 'Gabapentina', 'Galantamina', 'Haloperidol', 'Halotano', 'Hidrato de cloral', 'Hidroclorbezetilamina', 'Hidroxidiona', 'Homofenazina', 'Imicloprazina', 'Imipramina', 'Imipraminóxido', 'Iproclozida', 'Isocarboxazida', 'Isoflurano', 'Isopropil-crotonil-uréia', 'Lacosamida', 'Lamotrigina', 'Leflunomida', 'Levetiracetam', 'Levomepromazina', 'Levomilnaciprana', 'Lisurida', 'Lítio', 'Loperamida', 'Loxapina', 'Lumiracoxibe', 'Lurasidona', 'Mavacanteno', 'Maprotilina', 'Meclofenoxato', 'Mefenoxalona', 'Mefexamida', 'Memantina', 'Mepazina', 'Mesoridazina', 'Metilnaltrexona', 'Metilpentinol', 'Metisergida', 'Metixeno', 'Metopromazina', 'Metoxiflurano', 'Mianserina', 'Milnaciprana', 'Miltefosina', 'Minaprina', 'Mirtazapina', 'Misoprostol', 'Moclobemida', 'Molnupiravir', 'Moperona', 'Naloxona', 'Naltrexona', 'Nefazodona', 'Nialamida', 'Nitrito de isobutila', 'Nitrito de isopentila', 'Nitrito de isopropila', 'Nomifensina', 'Nortriptilina', 'Noxiptilina', 'Olanzapina', 'Opipramol', 'Oxcarbazepina', 'Oxibuprocaína (benoxinato)', 'Oxifenamato', 'Oxipertina', 'Paliperidona', 'Parecoxibe', 'Paroxetina', 'Penfluridol', 'Perfenazina', 'Pergolida', 'Periciazina (propericiazina)', 'Pimozida', 'Pipamperona', 'Pipotiazina', 'Pramipexol', 'Pregabalina', 'Primidona', 'Proclorperazina', 'Promazina', 'Propanidina', 'Propiomazina', 'Propofol', 'Protipendil', 'Protriptilina', 'Proximetacaina', 'Quetiapina', 'Ramelteona', 'Rasagilina', 'Reboxetina', 'Ribavirina', 'Rimonabanto', 'Risperidona', 'Rivastigmina', 'Rofecoxibe', 'Ropinirol', 'Rotigotina', 'Rufinamida', 'Selegilina', 'Sertralina', 'Sevoflurano', 'Sulpirida', 'Sultoprida', 'Tacrina', 'Teriflunomida', 'Tetrabenazina', 'Tetracaína', 'Tiagabina', 'Tianeptina', 'Tiaprida', 'Tioproperazina', 'Tioridazina', 'Tiotixeno', 'Tolcapona', 'Topiramato', 'Tranilcipromina', 'Trazodona', 'Triclofós', 'Trifluoperazina', 'Trifluperidol', 'Trimipramina', 'Troglitazona', 'Valdecoxibe', 'Valproato sódico', 'Venlafaxina', 'Veraliprida', 'Vigabatrina', 'Vilazodona', 'Vortioxetina', 'Ziprasidona', 'Zotepina', 'Zuclopentixol'],
  C2: ['Acitretina', 'Adapaleno', 'Bexaroteno', 'Isotretinoína', 'Tretinoína'],
  C3: ['Ftalimidoglutarimida (talidomida)', 'Lenalidomida', 'Pomalidomida'],
  C5: ['Androstanolona', 'Bolasterona', 'Boldenona', 'Cloroxomesterona', 'Clostebol', 'Deidroclormetiltestosterona', 'Drostanolona', 'Estanolona', 'Estanozolol', 'Etilestrenol', 'Fluoximesterona ou fluoximetiltestosterona', 'Formebolona', 'Gestrinona', 'Mesterolona', 'Metandienona ou metandrostenolona', 'Metandranona', 'Metandriol', 'Metenolona', 'Metiltestosterona', 'Mibolerona', 'Nandrolona', 'Noretandrolona', 'Oxandrolona', 'Oximesterona', 'Oximetolona', 'Prasterona (deidroepiandrosterona - DHEA)', 'Somapacitana', 'Somatrogona', 'Somatropina (hormônio do crescimento humano)', 'Testosterona', 'Trembolona'],
};

// Grafias equivalentes (SNGPC/DCB) de nomes das listas.
const SINONIMOS_LISTA = { 'valproato sodico': ['valproato de sodio'] };
// Base impressa/"chave" quando a grafia da DCB difere da lista.
const BASE_CANONICA = { 'valproato sodico': 'valproato de sodio' };
// Ésteres de depósito das listas C têm produtos e posologias próprios: o éster
// fica na base/"chave" ("cipionato de testosterona", "decanoato de haloperidol",
// "palmitato de paliperidona"), separado da forma não esterificada.
const ESTER = /^(?:decanoato|enantato|palmitato|undecilato|cipionato|fempropionato|isocaproato|propionato|fenilpropionato) de /;
const comEster = (c, e) => Boolean(e && /^C/.test(e.lista) && ESTER.test(c));
// Ordem impressa consagrada, quando difere da regra geral.
const ORDEM_NOME = { 'carbidopa+entacapona+levodopa': ['levodopa', 'carbidopa', 'entacapona'] };

const INDICE = [];
for (const [lista, nomes] of Object.entries(LISTAS)) {
  for (const nome of nomes) {
    const semPar = nome.replace(/\(.*\)/, '');
    const partes = semPar.split(/ ou /).map(chave);
    const principal = partes[0];
    const variantes = [...partes, ...(SINONIMOS_LISTA[principal] || [])];
    const par = nome.match(/\(([^)]*)\)/);
    if (par && !/\d/.test(par[1])) variantes.push(chave(par[1].split(' - ')[0]));
    const base = BASE_CANONICA[principal] || principal;
    for (const v of variantes) if (v) INDICE.push({ tokens: v.split(' '), lista, base });
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
const CANNABIS = /\b(?:cannabis|canabidiol|tetra?h?idrocann?abinol)\b/;

// Conferências: se alguma falhar, as listas embutidas estão erradas.
for (const [lista, nomes] of Object.entries({
  C1: ['sertralina', 'quetiapina', 'pregabalina', 'carbonato de litio', 'valproato de sodio', 'divalproato de sodio', 'acido valproico', 'celecoxibe', 'tetracaina', 'naloxona'],
  C5: ['cipionato de testosterona', 'decanoato de nandrolona', 'somatropina', 'oxandrolona'],
  C2: ['isotretinoina', 'tretinoina'], C3: ['talidomida'], A2: ['tramadol', 'codeina'], B1: ['fenobarbital', 'perampanel'],
})) {
  for (const n of nomes) if (listado(n)?.lista !== lista) throw new Error(`conferência de listas falhou: ${n} deveria ser ${lista}, está ${listado(n)?.lista}`);
}

// Adendos das listas A1, A2, A3 e B1 que mandam preparações para a RCE.
// max: dose máxima em mg do componente por unidade posológica (lida como o
// primeiro número em mg da concentração, como em gerar.mjs: 100 mg/mL de
// tramadol em gotas conta como 100); maxPct: concentração máxima (% p/v) em
// formas indivisíveis; forma: formas farmacêuticas abrangidas.
const ADENDOS = {
  difenoxilato: { ref: 'A1, adendo 2', max: 2.5, requer: 'atropina' },
  opio: { ref: 'A1, adendo 3', max: 50 },
  oxicodona: { ref: 'A1, adendo 5', max: 40, forma: /^comprimido.*liberação (prolongada|controlada)/, formaTexto: 'comprimido de liberação controlada' },
  buprenorfina: { ref: 'A1, adendo 8', forma: /^adesivo/, formaTexto: 'adesivo transdérmico' },
  acetildiidrocodeina: { ref: 'A2, adendo 2', max: 100, maxPct: 2.5 },
  codeina: { ref: 'A2, adendo 2', max: 100, maxPct: 2.5 },
  diidrocodeina: { ref: 'A2, adendo 2', max: 100, maxPct: 2.5 },
  etilmorfina: { ref: 'A2, adendo 2', max: 100, maxPct: 2.5 },
  folcodina: { ref: 'A2, adendo 2', max: 100, maxPct: 2.5 },
  nicodicodina: { ref: 'A2, adendo 2', max: 100, maxPct: 2.5 },
  norcodeina: { ref: 'A2, adendo 2', max: 100, maxPct: 2.5 },
  tramadol: { ref: 'A2, adendo 3', max: 100 },
  dextropropoxifeno: { ref: 'A2, adendo 4', max: 100, maxPct: 2.5 },
  nalbufina: { ref: 'A2, adendo 5', max: 10 },
  propiram: { ref: 'A2, adendo 6', max: 100 },
  fenobarbital: { ref: 'B1, adendo 2' },
  metilfenobarbital: { ref: 'B1, adendo 2' },
  barbital: { ref: 'B1, adendo 2' },
  barbexaclona: { ref: 'B1, adendo 2' },
  perampanel: { ref: 'B1, adendo 9' },
};
// Produtos de Cannabis (A3, adendos 10 e 12) com THC até 0,2%: RCE. O SNGPC não
// traz o teor de THC; entram as descrições dispensadas majoritariamente (> 50%)
// fora da Notificação A (o complemento da regra de gerar.mjs).

// Exclusões pelos adendos das listas C.
const FORA_POR_ADENDO = {
  loperamida: 'C1, adendo 2: loperamida é venda sob prescrição sem retenção',
  misoprostol: 'C1, adendo 4: misoprostol só em estabelecimento hospitalar',
  carisoprodol: 'B1, adendo 16: carisoprodol é venda sob prescrição sem retenção',
};

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

// ---------------------------------------------------------------------------
// Doses de associações. A ordem das doses na descrição do SNGPC não segue a
// ordem (alfabética) dos princípios ativos (ex.: "FOSFATO DE CODEÍNA +
// PARACETAMOL | 500MG + 30MG"). Por associação, conforme a composição da bula:
//   massa: componentes do de MAIOR para o de menor dose em massa
//   ui: componentes dosados em UI/U
//   posicional: as doses seguem a ordem alfabética das bases (quando a
//     magnitude não serve, ex.: kit de titulação donepezila 10 + memantina 5)
//   doseTotal: o registro traz uma dose só para o produto (ex.: ácido valproico
//     + valproato de sódio "500 MG", Depakine Chrono)
// Associação com doses diferentes fora da tabela é descartada e aparece no relatório.
// ---------------------------------------------------------------------------
const ASSOCIACOES = {
  'codeina+paracetamol': { massa: ['paracetamol', 'codeina'] },
  // Oto-Betnovate (entra na tabela só para ser lido e excluído: tetracaína otológica, C1 adendo 5).
  'betametasona+clorfenesina+tetracaina': { massa: ['clorfenesina', 'tetracaina', 'betametasona'] },
  'paracetamol+tramadol': { massa: ['paracetamol', 'tramadol'] },
  'naloxona+oxicodona': { massa: ['oxicodona', 'naloxona'] },
  'bupropiona+naltrexona': { massa: ['bupropiona', 'naltrexona'] },
  'donepezila+memantina': { posicional: true },
  'acido valproico+valproato de sodio': { doseTotal: true, massa: ['valproato de sodio', 'acido valproico'] },
  'carbidopa+entacapona+levodopa': { massa: ['entacapona', 'levodopa', 'carbidopa'] },
  // Durateston: por ampola de 1 mL, decanoato 100 mg, fempropionato 60 mg,
  // isocaproato 60 mg e propionato 30 mg de testosterona.
  'decanoato de testosterona+fempropionato de testosterona+isocaproato de testosterona+propionato de testosterona': {
    massa: ['decanoato de testosterona', 'fempropionato de testosterona', 'isocaproato de testosterona', 'propionato de testosterona'],
  },
};

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

function componentes(pa) {
  const vistos = new Set();
  const comps = [];
  for (const bruto of pa.split(/\s+\+\s+|;/)) {
    const c = chave(bruto);
    if (!c || vistos.has(c) || EXCIPIENTES.has(c)) continue;
    vistos.add(c);
    const e = listado(c);
    const cannabis = CANNABIS.test(c);
    let base = cannabis ? c.replace(/ l$/, '') : e ? e.base : baseDe(c);
    if (comEster(c, e)) base = c;
    comps.push({ chave: c, exib: exibicao(bruto), listado: e, cannabis, base, pai: comEster(c, e) ? e.base : null });
  }
  // A mesma base pode vir duas vezes com sais diferentes; mantém a primeira.
  const porBase = new Map();
  for (const x of comps) if (!porBase.has(x.base)) porBase.set(x.base, x);
  return [...porBase.values()];
}

// Ordem impressa: componentes das listas A/B (adendo) e Cannabis, depois C1/C5,
// depois os demais; em cada grupo, ordem alfabética da base.
function ordenar(comps) {
  const fixa = ORDEM_NOME[comps.map((x) => x.base).sort().join('+')];
  if (fixa) return fixa.map((b) => comps.find((x) => x.base === b));
  const peso = (x) => (x.cannabis || (x.listado && /^[AB]/.test(x.listado.lista)) ? 0 : x.listado && /^C/.test(x.listado.lista) ? 1 : 2);
  return [...comps].sort((a, b) => peso(a) - peso(b) || a.base.localeCompare(b.base));
}

// Classificação do produto: { classe, adendos } ou { fora: motivo } ou null (fora das listas).
function classificar(comps) {
  const lista = (x) => x.listado?.lista;
  if (comps.some((x) => lista(x) === 'C3')) return { fora: 'C3 (talidomida e análogos): Notificação de Receita Especial própria' };
  if (comps.some((x) => lista(x) === 'C2')) return { fora: 'C2 (retinoides): sistêmicos em Notificação de Receita Especial; tópicos sem retenção (adendo 2)' };
  for (const x of comps) if (FORA_POR_ADENDO[x.base]) return { fora: FORA_POR_ADENDO[x.base] };
  const ab = comps.filter((x) => !x.cannabis && /^[AB]/.test(lista(x) || ''));
  for (const x of ab) if (!ADENDOS[x.base]) return { fora: `lista ${lista(x)} sem adendo para a RCE (vai em notificação)` };
  if (ab.length) {
    const r = ab.map((x) => ADENDOS[x.base]).find((a) => a.requer);
    if (r && !comps.some((x) => x.base === r.requer)) return { fora: `${r.ref}: só em associação com ${r.requer}` };
    return { classe: `${lista(ab[0])}-adendo`, adendos: ab.map((x) => x.base) };
  }
  if (comps.some((x) => x.cannabis)) return { classe: 'A3-adendo', cannabis: true };
  const c = comps.filter((x) => /^C[15]$/.test(lista(x) || ''));
  if (!c.length) return null;
  return { classe: lista(c[0]) };
}

// Condições dos adendos e das listas C por apresentação; devolve o motivo da exclusão ou null.
function motivoFora(g, a, uso) {
  for (const b of g.adendos || []) {
    const r = ADENDOS[b];
    if (r.forma && !r.forma.test(a.forma)) return `${r.ref}: só ${r.formaTexto}`;
    if (r.max !== undefined) {
      const d = a.doses[g.bases.indexOf(b)];
      const mg = d ? emMassa(d) : null;
      if (mg === null) return `${r.ref}: dose não verificável`;
      if (mg > r.max) return `${r.ref}: acima de ${fmtNum(String(r.max).replace('.', ','))} mg por unidade`;
      if (r.maxPct !== undefined && d.den && /ML|G/.test(d.den)) {
        const por = valor((d.den.match(/\d+(?:,\d+)?/) || ['1'])[0]);
        if (mg / por / 10 > r.maxPct) return `${r.ref}: acima de ${fmtNum(String(r.maxPct).replace('.', ','))}%`;
      }
    }
  }
  if (g.bases.includes('tetracaina') && !/^oftálmica/.test(a.via || '')) return 'C1, adendo 5: tetracaína só retém receita em uso oftálmico';
  if (g.bases.includes('benzidamina') && /^pó para|ginecol|spray|pastilha|colutório|pasta|^gel/.test(a.forma)) return 'C1, adendo 7: benzidamina nesta forma está fora do controle';
  if (g.classe === 'C5' && uso === 'topico') return 'C5, adendo 2: anabolizante de uso tópico é venda sob prescrição sem retenção';
  return null;
}

function sentenca(s) {
  s = s.charAt(0).toUpperCase() + s.slice(1);
  return s.replace(/\bsativa l\.?$/, 'sativa L.');
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
  const baseCmed = (c) => {
    const e = listado(c);
    if (CANNABIS.test(c)) return c.replace(/ l$/, '');
    if (comEster(c, e)) return c;
    return e ? e.base : baseDe(c);
  };
  const casarCmed = (bases, apres) => {
    const cand = porApres.get(chaveApres(apres)) || [];
    const alvo = new Set(bases);
    const exatos = cand.filter((l) => { const b = l.comps.map(baseCmed); return b.length === alvo.size && b.every((x) => alvo.has(x)); });
    return exatos.length ? exatos : cand.filter((l) => l.comps.map(baseCmed).some((x) => alvo.has(x)));
  };

  const grupos = new Map();
  const excluidas = new Map(); // motivo -> Map(nome -> embalagens com código 1)
  const excluir = (motivo, nome, qt) => {
    if (!excluidas.has(motivo)) excluidas.set(motivo, new Map());
    const m = excluidas.get(motivo);
    m.set(nome, (m.get(nome) || 0) + qt);
  };
  const cacheComp = new Map();
  let totalEscopo = 0;
  for (const row of agregados) {
    let info = cacheComp.get(row.pa);
    if (info === undefined) {
      const comps = componentes(row.pa);
      const cl = classificar(comps);
      info = cl && !cl.fora ? { ...cl, comps: ordenar(comps) } : cl;
      if (info && !info.fora) info.bases = info.comps.map((x) => x.base);
      cacheComp.set(row.pa, info);
    }
    if (!info) { if (row.tp === CODIGO) excluir('fora das listas C1/C5 e sem adendo (código 1 trocado na origem)', row.pa || '(vazio)', row.qt); continue; }
    if (info.fora) { if (row.tp === CODIGO) excluir(info.fora, row.pa, row.qt); continue; }
    const k = info.bases.join('+');
    let g = grupos.get(k);
    if (!g) grupos.set(k, (g = { ...info, linhas: [] }));
    g.linhas.push(row);
  }

  const pend = { naoLidas: [], semCmed: new Map(), semVia: [] };
  const substancias = [];

  for (const g of grupos.values()) {
    let linhas = g.linhas;
    if (g.cannabis) {
      const porApresT = new Map();
      for (const r of linhas) {
        const e = porApresT.get(r.apres) || { a: 0, t: 0 };
        e.t += r.qt;
        if (r.tp === '4') e.a += r.qt;
        porApresT.set(r.apres, e);
      }
      for (const r of linhas) if (r.tp === CODIGO && porApresT.get(r.apres).a / porApresT.get(r.apres).t > 0.5) excluir('A3, adendo 12: produto de Cannabis dispensado majoritariamente com Notificação A (THC acima de 0,2%)', r.pa, r.qt);
      linhas = linhas.filter((r) => { const e = porApresT.get(r.apres); return e.a / e.t <= 0.5; });
    }
    const notif = linhas.filter((r) => r.tp === CODIGO);
    const usadas = soma(notif, (r) => r.qt) > 0 ? notif : linhas;
    if (!usadas.length) continue;
    totalEscopo += soma(notif, (r) => r.qt);
    const chaveG = g.bases.map(semAcento).join('+');
    const pais = [...new Set(g.comps.map((x) => x.pai).filter(Boolean))];
    const buscaBase = [...new Set([...g.bases.map(semAcento), ...pais])];

    const porDesc = new Map();
    const nomesDesc = new Map();
    for (const r of usadas) {
      porDesc.set(r.apres, (porDesc.get(r.apres) || 0) + r.qt);
      if (!nomesDesc.has(r.apres)) nomesDesc.set(r.apres, new Map());
      const n = nomeDe(r.pa, g);
      nomesDesc.get(r.apres).set(n, (nomesDesc.get(r.apres).get(n) || 0) + r.qt);
    }
    const nomeGrupo = escolherNome(new Map([...nomesDesc.values()].flatMap((m) => [...m])));

    const porUso = new Map();
    const semVia = [];
    for (const [apres, qt] of porDesc) {
      const a = lerApresentacao(apres);
      if (!a.erro) {
        const d = atribuirDoses(a.doses, g.bases);
        if (!d) a.erro = g.bases.length > 1 ? 'associação sem regra de doses' : 'nº de doses';
        else a.doses = d;
      }
      if (a.erro) { pend.naoLidas.push({ nome: nomeGrupo, apres, vendas: qt, motivo: a.erro }); excluir('descrição não lida', `${nomeGrupo} | ${apres}`, qt); continue; }
      const linhasCmed = casarCmed(g.bases, apres);
      if (!linhasCmed.length) pend.semCmed.set(`${nomeGrupo} | ${apres}`, qt);
      else if (linhasCmed.every((l) => l.semTarja)) { excluir('isento de prescrição (CMED "Tarja Sem Tarja")', `${nomeGrupo} | ${apres}`, qt); continue; }
      else if (linhasCmed.every((l) => l.hosp)) { excluir('uso restrito a hospitais (CMED "RESTRIÇÃO HOSPITALAR = Sim")', `${nomeGrupo} | ${apres}`, qt); continue; }
      const item = { a, qt, linhasCmed, apres, nomes: nomesDesc.get(apres) };
      if (!a.via) { semVia.push(item); continue; }
      const uso = USO_DA_VIA[a.via.split(' ou ')[0]] || 'sistemico';
      const motivo = motivoFora(g, a, uso);
      if (motivo) { excluir(motivo, `${nomeGrupo} | ${apres}`, qt); continue; }
      if (!porUso.has(uso)) porUso.set(uso, []);
      porUso.get(uso).push(item);
    }
    // Descrições sem via: injetáveis herdam a via injetável mais vendida do grupo
    // (senão "injetável"); as demais herdam a via mais vendida da mesma forma.
    const todos = [...porUso.values()].flat();
    const maisVendida = (xs) => {
      const m = new Map();
      for (const x of xs) m.set(x.a.via, (m.get(x.a.via) || 0) + x.qt);
      return [...m].sort((a, b) => b[1] - a[1])[0]?.[0];
    };
    for (const item of semVia) {
      if (/injet|infus/.test(item.a.forma)) item.a.via = maisVendida(todos.filter((x) => /injet|infus/.test(x.a.forma))) || 'injetável';
      else {
        const via = maisVendida(todos.filter((x) => x.a.forma.split(' ')[0] === item.a.forma));
        if (!via) { pend.semVia.push({ nome: nomeGrupo, apres: item.apres, vendas: item.qt }); excluir('descrição sem via', `${nomeGrupo} | ${item.apres}`, item.qt); continue; }
        item.a.via = via;
        if (ADJETIVO[via]) item.a.forma += ` ${ADJETIVO[via]}`;
      }
      const uso = USO_DA_VIA[item.a.via.split(' ou ')[0]] || 'sistemico';
      const motivo = motivoFora(g, item.a, uso);
      if (motivo) { excluir(motivo, `${nomeGrupo} | ${item.apres}`, item.qt); continue; }
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
          if (g.comps.some((x) => (x.listado || x.cannabis) && contem(tk, (x.pai || x.base).split(' '))) || tokensBase.every((t) => tk.includes(t))) continue; // "similar" com nome genérico
          const m = marcaExibida(l.produto);
          p.marcas.set(m, (p.marcas.get(m) || 0) + qt / linhasCmed.length);
        }
        pres.set(k, p);
      }
      const apresentacoes = [...pres.values()]
        .filter((p) => p.pacotes.size)
        .sort((a, b) => b.vendas - a.vendas || a.concentracao.localeCompare(b.concentracao))
        .slice(0, 6)
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
      substancias.push({ nome, chave: chaveG, classe: g.classe, uso, busca: [...new Set([...buscaBase, ...marcasBusca])], vendas, apresentacoes });
    }
  }
  substancias.sort((a, b) => b.vendas - a.vendas || a.nome.localeCompare(b.nome) || a.uso.localeCompare(b.uso));
  return { substancias, pend, excluidas, totalEscopo };
}

function ordemCampos(p) {
  return { concentracao: p.concentracao, forma: p.forma, via: p.via, unidade: p.unidade, quantidade: p.quantidade, vendas: p.vendas, marcas: p.marcas, generico: p.generico };
}

// ---------------------------------------------------------------------------
// Validação (falha alto antes de gravar)
// ---------------------------------------------------------------------------

const PERMITIDOS = /^[A-Za-zÀ-ÖØ-öø-ÿ0-9 .,;:()\/\-'"ªº°%+&#*!?]*$/;
const USOS = new Set(['sistemico', 'oftalmico', 'otologico', 'topico', 'vaginal']);
const CLASSES = new Set(['C1', 'C5', 'A1-adendo', 'A2-adendo', 'A3-adendo', 'B1-adendo']);
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
    const chaves = Object.keys(s).join(',');
    if (chaves !== 'nome,chave,classe,uso,busca,vendas,apresentacoes') erros.push(`${onde}: campos inesperados ${chaves}`);
    max(s.nome, 120, `${onde}.nome`);
    if (!/^[a-z0-9 ]+(\+[a-z0-9 ]+)*$/.test(s.chave)) erros.push(`${onde}: chave inválida ${s.chave}`);
    if (!CLASSES.has(s.classe)) erros.push(`${onde}: classe inválida ${s.classe}`);
    if (!USOS.has(s.uso)) erros.push(`${onde}: uso inválido`);
    const k = `${s.chave}|${s.uso}`;
    if (vistos.has(k)) erros.push(`${onde}: (chave, uso) repetido`);
    vistos.add(k);
    if (!Array.isArray(s.busca) || s.busca.some((b) => !/^[a-z0-9 .\-+&\/]+$/.test(b))) erros.push(`${onde}: busca inválida ${JSON.stringify(s.busca)}`);
    for (const b of s.chave.split('+')) if (!s.busca.includes(b)) erros.push(`${onde}: busca sem a base ${b}`);
    if (!Number.isInteger(s.vendas) || s.vendas < 1) erros.push(`${onde}: vendas inválidas`);
    if (anterior && anterior.vendas < s.vendas) erros.push(`${onde}: fora de ordem`);
    anterior = s;
    if (!Array.isArray(s.apresentacoes) || !s.apresentacoes.length || s.apresentacoes.length > 6) erros.push(`${onde}: apresentacoes inválidas`);
    const chavesP = new Set();
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
      if (!Number.isInteger(p.vendas) || p.vendas < 1) erros.push(`${o}: vendas ${p.vendas}`);
      if (!Array.isArray(p.marcas) || p.marcas.some((m) => typeof m !== 'string' || !m || m.length > 60)) erros.push(`${o}: marcas inválidas`);
      if (typeof p.generico !== 'boolean') erros.push(`${o}: generico deve ser booleano`);
      const kp = `${p.concentracao}|${p.forma}|${p.via}`;
      if (chavesP.has(kp)) erros.push(`${o}: apresentação repetida`);
      chavesP.add(kp);
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
const { substancias, pend, excluidas, totalEscopo } = montar(agregados, cmed);
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

// Relatório
const conta = (f) => substancias.reduce((a, s) => { const k = f(s); a[k] = (a[k] || 0) + 1; return a; }, {});
const totalMap = (m) => [...m.values()].reduce((a, b) => a + b, 0);
const incluidas = soma(substancias, (s) => s.vendas);
log(`\ngravado ${SAIDA} (${(Buffer.byteLength(json) / 1024).toFixed(1)} KB)`);
log(`período: ${saida.fontes.sngpc.periodo}; substâncias: ${substancias.length}; por classe: ${JSON.stringify(conta((s) => s.classe))}; por uso: ${JSON.stringify(conta((s) => s.uso))}`);
log(`embalagens com código 1 no arquivo: ${incluidas} (${((100 * incluidas) / totalEscopo).toFixed(2)}% das substâncias em escopo); descrições não lidas: ${pend.naoLidas.length}; sem par na CMED: ${pend.semCmed.size} (${totalMap(pend.semCmed)})`);
log('exclusões (embalagens com código 1):');
for (const [motivo, m] of [...excluidas].sort((a, b) => totalMap(b[1]) - totalMap(a[1]))) log(`  ${String(totalMap(m)).padStart(9)}  ${motivo} (${m.size})`);
if (args.relatorio) {
  log('\n== top 30');
  substancias.slice(0, 30).forEach((s, i) => {
    const p = s.apresentacoes[0];
    log(`  ${String(i + 1).padStart(2)}. ${s.vendas} ${s.nome} [${s.classe}, ${s.uso}] | ${p.concentracao} ${p.forma}, ${p.quantidade} ${p.unidade} | ${p.marcas.slice(0, 4).join(', ')}${p.generico ? ' + genéricos' : ''}`);
  });
  for (const [motivo, m] of [...excluidas].sort((a, b) => totalMap(b[1]) - totalMap(a[1]))) {
    log(`\n== excluídas: ${motivo} (${totalMap(m)})`);
    // A exclusão hospitalar sai completa, para revisão; as demais, as 25 maiores.
    for (const [n, v] of [...m].sort((a, b) => b[1] - a[1]).slice(0, /hospitais/.test(motivo) ? Infinity : 25)) log(`  ${v}\t${n}`);
  }
  log('\n== sem par na CMED'); for (const [k, v] of [...pend.semCmed].sort((a, b) => b[1] - a[1]).slice(0, 25)) log(`  ${v}\t${k}`);
}
