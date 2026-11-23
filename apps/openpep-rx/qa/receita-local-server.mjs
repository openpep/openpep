// Local synthetic browser QA for /receita.html only. Never packaged by build.mjs.
// Real registry rules (PGlite + migrations), a confirmed synthetic session and an injected synthetic signer.
import http from 'node:http';
import {readFile, readdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';
import {makeLedger} from '../api/ledger.mjs';
import {sha256} from '../api/store.mjs';
import {createReceitaHandler, loadFonts} from '../api/receita.mjs';
const ORIGIN = 'https://rx-hml.openpep.com.br', LOCAL = 'http://127.0.0.1:4198';
const db = new PGlite(), migrations = new URL('../db/migrations/', import.meta.url);
for (const f of (await readdir(migrations)).filter(f => f.endsWith('.sql')).sort()) await db.exec(await readFile(new URL(f, migrations), 'utf8'));
const ledger = makeLedger((sql, params) => db.query(sql, params));
const identity = {issuer: 'https://sso.example.org/realms/qa', subject: 'QA-SUBJECT', cpf: '52998224725', fullName: 'Profissional Fictício da Silva', crm: '12345', uf: 'SP', linked: true};
const prescritorId = await ledger.ensurePrescriber({contaHash: await sha256(identity.issuer + '|' + identity.subject), cpf: identity.cpf, nome: identity.fullName, uf: 'SP', inscricao: '12345'});
const s = await ledger.prepare({prescritorId, tipo: 'NRB', quantidade: 10, chave: randomUUID()});await ledger.startSend(s.id);
await ledger.recordSuccess(s, 200, {numeroReceita: Array.from({length: 10}, (_, i) => `2411.1-00.${String(i + 1).padStart(7, '0')}`), saldoReceitas: 0});
// RCE and RET come in SNCR ranges of 1000 (synthetic platform CNPJ).
for (const [tipo, prefix] of [['RCE', '2609.1-35.'], ['RET', '2609.2-35.']]) {
  const r = await ledger.prepare({prescritorId, tipo, quantidade: 1000, cnpj: '12345678000195', chave: randomUUID()});await ledger.startSend(r.id);
  await ledger.recordSuccess(r, 201, {inicio: `${prefix}0000001`, fim: `${prefix}0001000`, quantidade: 1000});
}
// Special notifications (retinoids, thalidomide): NR stock like the others.
for (const [tipo, prefix] of [['NRR', '2411.1-04.'], ['NRT', '2411.1-05.']]) {
  const r = await ledger.prepare({prescritorId, tipo, quantidade: 10, chave: randomUUID()});await ledger.startSend(r.id);
  await ledger.recordSuccess(r, 200, {numeroReceita: Array.from({length: 10}, (_, i) => `${prefix}${String(i + 1).padStart(7, '0')}`), saldoReceitas: 0});
}
// A short NRA stock shows the low-stock state.
const a = await ledger.prepare({prescritorId, tipo: 'NRA', quantidade: 10, chave: randomUUID()});await ledger.startSend(a.id);
await ledger.recordSuccess(a, 200, {numeroReceita: Array.from({length: 3}, (_, i) => `2411.1-01.${String(i + 1).padStart(7, '0')}`), saldoReceitas: 0});
const COOKIE = 'e'.repeat(64), rows = new Map([[COOKIE, {revision: 0, status: 'active', mode: 'institutional', expiresAt: Date.now() + 43200000, identity, kmsToken: 'SYNTHETIC',
  certificate: {serial: 'QA-SERIAL', providerHash: 'QA-HASH'}, signaturesUsed: 1, documents: []}]]);
const store = {get: async k => structuredClone(rows.get(k) ?? null), swap: async (k, r, v) => { if (rows.get(k)?.revision !== r) return false; rows.set(k, structuredClone(v)); return true; }};
const services = {jwt: async () => 'SYNTHETIC', sign: async (t, k, pdf) => { await new Promise(r => setTimeout(r, 900)); return Buffer.concat([pdf, Buffer.from('\n/ByteRange [0 1 2 3] /Contents <QA>')]); },
  verify: async (t, p, nonce) => [{nonce, generalStatus: 'VALID', signatureFormat: 'PADES', signatureStatus: {verificationReference: new Date().toISOString(), chainStatus: {status: 'VALID',
    certificateStatusList: [{'@type': 'FinalCertificate', status: 'VALID', pkiBrazil: true, cpf: identity.cpf, certificateInfo: {serial: 'QA-SERIAL', hash: 'QA-HASH', validity: {notBefore: '2026-01-01T00:00:00Z', notAfter: '2027-01-01T00:00:00Z'}}}]}}}]};
const counts = new Map(), limits = {allow: async (b, n) => { counts.set(b, (counts.get(b) || 0) + 1); return counts.get(b) <= n; }};
// Demonstration addresses are resolved locally.
const CEPS = {'01001000': {cep: '01001-000', logradouro: 'Praça da Sé', bairro: 'Sé', cidade: 'São Paulo', uf: 'SP'}, '01310100': {cep: '01310-100', logradouro: 'Avenida Paulista', bairro: 'Bela Vista', cidade: 'São Paulo', uf: 'SP'}};
const handler = createReceitaHandler({store, limits, services, ledger, homologation: true, cep: async c => CEPS[c] || null, fonts: () => loadFonts(new URL('../assets/fonts/pdf/', import.meta.url))});
const names = new Set(['medicamentos.js', 'medicamentos.json', 'medicamentos-retencao.json', 'posologias-retencao.json', 'medicamentos-rce.json', 'posologias-rce.json', 'medicamentos-especiais.json', 'posologias-especiais.json', 'telefone.js', 'vendor/intl-tel-input/utils.js', 'vendor/intl-tel-input/css/intlTelInput.min.css', 'vendor/intl-tel-input/img/flags.webp', 'vendor/intl-tel-input/img/flags@2x.webp', 'transicao.css', 'transicao.js', 'receita.html', 'receita.js', 'receita.css', 'acesso.css', 'openpep-mark.png','openpep.css', 'verificar.html', 'verificar.js', 'verificar.css']);
// Same response headers as production (CSP included), so the preview iframe is tested under the real policy.
const HEADERS = JSON.parse(await readFile(new URL('../.vercel/output/config.json', import.meta.url), 'utf8')).routes[0].headers;
http.createServer(async (req, res) => { try {
  for (const [k, v] of Object.entries(HEADERS)) res.setHeader(k, v);
  const u = new URL(req.url, LOCAL);
  if (u.pathname.startsWith('/api/receita/')) {
    req.headers.host = new URL(ORIGIN).host; req.headers.origin = req.headers.origin === LOCAL ? ORIGIN : req.headers.origin;
    req.headers.cookie = `__Host-crx-entry=${COOKIE}`;
    return await handler(req, res);
  }
  const name = u.pathname === '/' ? 'receita.html' : /^\/[rR]\/[A-Za-z2-7]{26}$/.test(u.pathname) ? 'verificar.html' : u.pathname.slice(1);
  if (!names.has(name)) { res.statusCode = 404; return res.end(); }
  let bytes = await readFile(new URL('../.vercel/output/static/' + name, import.meta.url));
  if (name === 'receita.html') bytes = Buffer.from(bytes.toString().replace('<main', '<p role="status">Demonstração: dados fictícios, estoque e assinatura simulados. Nenhum certificado real é usado.</p><main'));
  if (name === 'receita.js') bytes = Buffer.from(bytes.toString().replace("const canonical = 'https://rx-hml.openpep.com.br';", `const canonical = ${JSON.stringify(LOCAL)};`));
  res.setHeader('Content-Type', name.endsWith('.js') ? 'text/javascript' : name.endsWith('.json') ? 'application/json' : name.endsWith('.css') ? 'text/css' : name.endsWith('.png') ? 'image/png' : name.endsWith('.webp') ? 'image/webp' : 'text/html; charset=utf-8'); res.end(bytes);
} catch { res.statusCode = 500; res.end('QA error'); } }).listen(4198, '127.0.0.1', () => console.log('Synthetic prescription QA at ' + LOCAL + '/receita.html'));
