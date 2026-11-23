import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { ORIGIN, DEFAULT_ORIGIN } from './api/origin.mjs';

const root = path.dirname(fileURLToPath(import.meta.url));
const output = path.join(root, '.vercel/output');
const staticDir = path.join(output, 'static');
const functionDir = path.join(output, 'functions/api/documento.func');
const pdfSource = path.join(root, 'fixtures/documento.pdf');
const logoSource = path.join(root, 'assets/openpep-mark.png');
const staticFiles = ['cep.js', 'contato.js','compartilhar-documento.js','compartilhar-documento.css','portal-sncr.html', 'portal-sncr.css', 'portal-sncr.js', 'local-client.js', 'conectar.html', 'conectar.js', 'inicio.css', 'inicio.js', 'pdf-preview.js', 'dados-locais.html', 'dados-locais.css', 'dados-locais.js', 'index.html', 'app.js', 'domain.js', 'styles.css', 'openpep.css', 'assinatura.html', 'assinatura.js', 'assinatura.css', 'sncr.html', 'sncr.css', 'sncr.js', 'numeros.html', 'numeros.css', 'numeros.js', 'receita.html', 'receita.css', 'receita.js', 'acesso.css', 'verificar.html', 'verificar.css', 'verificar.js', 'transicao.css', 'transicao.js', 'medicamentos.js'];

for (const source of [pdfSource, logoSource]) {
  try { await access(source, fsConstants.R_OK); } catch { throw new Error(`Arquivo obrigatório indisponível: ${source}`); }
}
await rm(output, { recursive: true, force: true });
await mkdir(staticDir, { recursive: true });
await mkdir(functionDir, { recursive: true });
// Pages and scripts carry the public address (CRX_ORIGIN, api/origin.mjs) as a literal; it is set here at build time.
for (const file of staticFiles) {
  if (/\.(html|js)$/.test(file)) await writeFile(path.join(staticDir, file), (await readFile(path.join(root, file), 'utf8')).replaceAll(DEFAULT_ORIGIN, ORIGIN));
  else await cp(path.join(root, file), path.join(staticDir, file));
}
await cp(logoSource, path.join(staticDir, 'openpep-mark.png'));
await cp(path.join(root, 'fixtures/assinatura-local.pdf'), path.join(staticDir, 'assinatura-local.pdf'));
await cp(path.join(root, 'assets/fonts'), path.join(staticDir, 'fonts'), { recursive: true });
// PDF.js renders the exact prepared bytes in the local browser; all assets stay on this origin.
const pdfjs = path.join(root, 'node_modules/pdfjs-dist');
await mkdir(path.join(staticDir, 'vendor/pdfjs'), {recursive: true});
for (const file of ['pdf.mjs', 'pdf.worker.mjs']) await cp(path.join(pdfjs, 'build', file), path.join(staticDir, 'vendor/pdfjs', file));
for (const dir of ['standard_fonts', 'cmaps', 'wasm']) await cp(path.join(pdfjs, dir), path.join(staticDir, 'vendor/pdfjs', dir), {recursive: true});
await cp(path.join(pdfjs, 'LICENSE'), path.join(staticDir, 'vendor/pdfjs/LICENSE'));

// Controlled-substance catalog for the prescription form (scripts/medicamentos/gerar.mjs).
await cp(path.join(root, 'data/medicamentos-controlados.json'), path.join(staticDir, 'medicamentos.json'));
// Retention (RET): antimicrobials and GLP-1, with the bula posologies (scripts/medicamentos/gerar-retencao.mjs).
for (const file of ['medicamentos-retencao.json', 'posologias-retencao.json', 'medicamentos-rce.json', 'posologias-rce.json', 'medicamentos-especiais.json', 'posologias-especiais.json']) await cp(path.join(root, 'data', file), path.join(staticDir, file));
// Phone field (intl-tel-input, MIT): our wrapper bundled with the library and its Portuguese strings; the validation
// metadata (utils.js) loads on demand. CSS and flag sprites keep the package layout (css/ -> ../img/).
const iti = path.join(root, 'node_modules/intl-tel-input/dist');
await build({ entryPoints: [path.join(root, 'telefone.mjs')], outfile: path.join(staticDir, 'telefone.js'), bundle: true, format: 'esm', platform: 'browser', target: 'es2022', minify: true, legalComments: 'eof', external: ['/vendor/*'], logLevel: 'error' });
await mkdir(path.join(staticDir, 'vendor/intl-tel-input/css'), { recursive: true });
await cp(path.join(iti, 'js/utils.js'), path.join(staticDir, 'vendor/intl-tel-input/utils.js'));
await cp(path.join(iti, 'css/intlTelInput.min.css'), path.join(staticDir, 'vendor/intl-tel-input/css/intlTelInput.min.css'));
for (const file of ['flags.webp', 'flags@2x.webp']) await cp(path.join(iti, 'img', file), path.join(staticDir, 'vendor/intl-tel-input/img', file));
await cp(path.join(root, 'node_modules/intl-tel-input/LICENSE'), path.join(staticDir, 'vendor/intl-tel-input/LICENSE.txt'));
await cp(path.join(root, 'api/documento.mjs'), path.join(functionDir, 'index.mjs'));
await cp(pdfSource, path.join(functionDir, 'documento.pdf'));
await writeFile(path.join(functionDir, '.vc-config.json'), JSON.stringify({ runtime: 'nodejs24.x', handler: 'index.mjs', launcherType: 'Nodejs', shouldAddHelpers: true }, null, 2));
// SNCR functions: numbers registry (Postgres via the dependency-free "postgres" driver) next to the handler.
const sncrModules = ['http-utils.mjs', 'store.mjs', 'ledger.mjs', 'db.mjs', 'sncr-numbers.mjs', 'sncr-probe.mjs', 'origin.mjs'];
async function copySncrModules(dir) {
  for (const file of sncrModules) await cp(path.join(root, 'api', file), path.join(dir, file));
  await cp(path.join(root, 'node_modules/postgres'), path.join(dir, 'node_modules/postgres'), { recursive: true });
}
for (const route of ['login', 'callback', 'status', 'numeros', 'sondar', 'concluir-prd']) {
const sncrDir = path.join(output, `functions/api/sncr/${route}.func`);
await mkdir(sncrDir, { recursive: true });
await cp(path.join(root, 'api/sncr.mjs'), path.join(sncrDir, 'index.mjs'));
await copySncrModules(sncrDir);
await writeFile(path.join(sncrDir, '.vc-config.json'), JSON.stringify({ runtime: 'nodejs24.x', handler: 'index.mjs', launcherType: 'Nodejs', shouldAddHelpers: true }));
}
const landingDir = path.join(output, 'functions/index.func');
await mkdir(landingDir, { recursive: true });
await cp(path.join(root, 'api/sncr-return.mjs'), path.join(landingDir, 'index.mjs'));
await cp(path.join(root, 'api/sncr.mjs'), path.join(landingDir, 'sncr.mjs'));
await copySncrModules(landingDir);
await writeFile(path.join(landingDir, 'home.html'), (await readFile(path.join(root, 'index.html'), 'utf8')).replaceAll(DEFAULT_ORIGIN, ORIGIN));
await writeFile(path.join(landingDir, '.vc-config.json'), JSON.stringify({ runtime: 'nodejs24.x', handler: 'index.mjs', launcherType: 'Nodejs', shouldAddHelpers: true }));
const prdCallbackDir=path.join(output,'functions/api/sncr/callback-edge.func');
await build({entryPoints:[path.join(root,'api/sncr-callback-edge.mjs')],outfile:path.join(prdCallbackDir,'index.js'),bundle:true,format:'esm',platform:'browser',target:'es2022',conditions:['worker','browser'],legalComments:'none',logLevel:'error'});
await writeFile(path.join(prdCallbackDir,'.vc-config.json'),JSON.stringify({runtime:'edge',entrypoint:'index.js',envVarsInUse:['CRX_ORIGIN','KV_REST_API_URL','KV_REST_API_TOKEN','UPSTASH_REDIS_REST_URL','UPSTASH_REDIS_REST_TOKEN']}));
// Edge twin of /api/sncr/sondar: compares Edge egress with the Node adapter when diagnosing production connectivity.
const probeEdgeDir=path.join(output,'functions/api/sncr/sondar-edge.func');
await build({entryPoints:[path.join(root,'api/sncr-probe-edge.mjs')],outfile:path.join(probeEdgeDir,'index.js'),bundle:true,format:'esm',platform:'browser',target:'es2022',conditions:['worker','browser'],legalComments:'none',logLevel:'error'});
await writeFile(path.join(probeEdgeDir,'.vc-config.json'),JSON.stringify({runtime:'edge',entrypoint:'index.js',envVarsInUse:['CRX_ORIGIN','KV_REST_API_URL','KV_REST_API_TOKEN','UPSTASH_REDIS_REST_URL','UPSTASH_REDIS_REST_TOKEN']}));
await writeFile(path.join(output, 'config.json'), JSON.stringify({ version: 3, routes: [
  { src: '/(.*)', headers: { 'Cache-Control': 'no-store, max-age=0', 'X-Robots-Tag': 'noindex, nofollow, noarchive', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'" }, continue: true },
  { src: '/', dest: '/index' },
  // Platform link printed on the prescription (and its QR): /r/<26-character base32 id>, any case.
  { src: '^/[rR]/([A-Za-z2-7]{26})$', dest: '/verificar.html' },
  { src: '/api/sncr/status', dest: '/api/sncr/status' },
  { src: '/api/sncr/login', dest: '/api/sncr/login' },
  { src: '/api/sncr/callback', dest: '/api/sncr/callback' },
  { src: '/api/sncr/numeros', dest: '/api/sncr/numeros' },
  { src: '/api/sncr/sondar', dest: '/api/sncr/sondar' },
  { src: '/api/sncr/sondar-edge', dest: '/api/sncr/sondar-edge' },
  { src: '/api/sncr/callback-edge', dest: '/api/sncr/callback-edge' },
  { src: '/api/sncr/concluir-prd', dest: '/api/sncr/concluir-prd' },
  { src: '/api/documento', dest: '/api/documento' },
  { handle: 'filesystem' }
] }, null, 2));
