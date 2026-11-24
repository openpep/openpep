import test from 'node:test';
import assert from 'node:assert/strict';
import {Readable} from 'node:stream';
import {readFile, readdir} from 'node:fs/promises';
import {randomUUID, createHash} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';
import {PDFDocument} from 'pdf-lib';
import {makeLedger} from '../api/ledger.mjs';
import {sha256} from '../api/store.mjs';
import {createReceitaHandler, RECEITA_ROUTES, loadFonts, ACCESS_ATTEMPTS, lookupCEP} from '../api/receita.mjs';
import {prescriptionContent, inWords, shortId, fromShortId, ageAt} from '../api/receita-doc.mjs';
import {SESSION_SIGNATURES} from '../api/entry-proof.mjs';

// Real Postgres (PGlite) with every migration; synthetic prescriber, numbers and patients only.
const db = new PGlite();
const migrations = new URL('../db/migrations/', import.meta.url);
for (const file of (await readdir(migrations)).filter(f => f.endsWith('.sql')).sort()) await db.exec(await readFile(new URL(file, migrations), 'utf8'));
const ledger = makeLedger((sql, params) => db.query(sql, params));
const ORIGIN = 'https://rx-hml.openpep.com.br', TIME = Date.parse('2026-09-29T17:00:00Z');
const FONTS = await loadFonts(new URL('../assets/fonts/pdf/', import.meta.url));
const sha = b => createHash('sha256').update(b).digest('hex');
const body = (over = {}) => ({tipo: 'NRB',
  emitente: {endereco: 'Av. Exemplo, 100 - Sala 1', cidade: 'São Paulo', uf: 'SP', telefone: '(11) 0000-0000'},
  paciente: {nome: 'Paciente Fictício da Silva', documento: '529.982.247-25', endereco: 'Rua Fictícia, 10', cidade: 'São Paulo', uf: 'SP'},
  medicamento: {nome: 'Zolpidem, hemitartarato', concentracao: '10 mg', forma: 'comprimido revestido', quantidade: 30, unidade: 'comprimidos', posologia: 'Tomar 1 comprimido ao deitar.'},
  ...over});
let accounts = 0;
const prefix = n => `2411.1-${String(n).padStart(2, '0')}.`;
// Fictitious CPF with valid check digits (the certificate check refuses malformed ones).
function syntheticCPF(base) {
  const digit = digits => { const sum = [...digits].reduce((acc, d, i) => acc + Number(d) * (digits.length + 1 - i), 0), r = (sum * 10) % 11; return r === 10 ? 0 : r; };
  const first = base + digit(base);return first + digit(first);
}

function report(nonce, cpf, serial = 'TEST-SERIAL') {
  return [{nonce, generalStatus: 'VALID', signatureFormat: 'PADES', signatureStatus: {verificationReference: new Date(TIME).toISOString(), chainStatus: {status: 'VALID',
    certificateStatusList: [{'@type': 'FinalCertificate', status: 'VALID', pkiBrazil: true, cpf, certificateInfo: {serial, hash: 'TEST-PROVIDER-HASH', validity: {notBefore: '2026-01-01T00:00:00Z', notAfter: '2027-01-01T00:00:00Z'}}}]}}}];
}
// One SSO account with a confirmed certificate and its own NRB stock.
async function setup({stock = 10, options = {}} = {}) {
  const n = ++accounts, cpf = syntheticCPF(String(100000000 + n * 7919)), crm = String(200000 + n);
  const identity = {issuer: 'https://sso.test/realms/test', subject: 'SUBJECT-' + n, cpf, fullName: 'Profissional Fictício ' + 'ABCDEFGHIJ'[n % 10], crm, uf: 'SP', linked: true};
  const prescritorId = await ledger.ensurePrescriber({contaHash: await sha256(identity.issuer + '|' + identity.subject), cpf, nome: identity.fullName, uf: 'SP', inscricao: crm});
  if (stock) {
    const s = await ledger.prepare({prescritorId, tipo: 'NRB', quantidade: 10, chave: randomUUID()});await ledger.startSend(s.id);
    const numbers = Array.from({length: stock}, (_, i) => `${prefix(n)}${String(i + 1).padStart(7, '0')}`);
    await ledger.recordSuccess(s, 200, {numeroReceita: numbers, saldoReceitas: 0});
  }
  const rows = new Map(), cookieId = 'c'.repeat(62) + String(n).padStart(2, '0'), logs = [];
  rows.set(cookieId, {revision: 0, status: 'active', mode: 'institutional', expiresAt: TIME + 1800000, identity, kmsToken: 'SERVER-KMS',
    certificate: {serial: 'TEST-SERIAL', providerHash: 'TEST-PROVIDER-HASH'}, signaturesUsed: 1, documents: []});
  const store = {get: async k => structuredClone(rows.get(k) ?? null), swap: async (k, rev, next) => { if (rows.get(k)?.revision !== rev) return false; rows.set(k, structuredClone(next)); return true; }};
  let signatures = 0, failSign = false, codes = 0;
  const attempts = new Map(), limits = {allow: async (bucket, limit) => { const n = (attempts.get(bucket) || 0) + 1; attempts.set(bucket, n); return n <= limit; }};
  const services = {jwt: async () => 'SERVER-JWT',
    sign: async (t, k, pdf) => { signatures++; if (failSign) throw Error('sign'); return Buffer.concat([pdf, Buffer.from('\n/ByteRange [0 1 2 3] /Contents <SIGNED-' + signatures + '>')]); },
    verify: async (t, pdf, nonce) => report(nonce, cpf)};
  const handler = createReceitaHandler({store, limits, code: () => String(100000 + ++codes), services, ledger, now: () => TIME, random: () => 'a'.repeat(64), fonts: async () => FONTS, homologation: true, log: e => logs.push(e), ...options});
  async function req(route, {method = 'GET', body: payload, cookie = `__Host-crx-entry=${cookieId}`, origin = ORIGIN} = {}) {
    const request = Readable.from(payload === undefined ? [] : [Buffer.from(JSON.stringify(payload))]);
    Object.assign(request, {url: '/api/receita/' + route, method, headers: {cookie, host: new URL(ORIGIN).host, origin}});
    let data; const headers = {};
    const response = {statusCode: 200, setHeader(k, v) { headers[k] = v; }, end(v = '') { data = Buffer.isBuffer(v) ? v : Buffer.from(v); }};
    await handler(request, response);
    return {code: response.statusCode, headers, bytes: data, json: () => JSON.parse(data.toString())};
  }
  const draft = async (over, id = randomUUID()) => { const r = await req('rascunho', {method: 'POST', body: {id, ...body(over)}}); return {id, ...r, hash: r.code === 200 ? r.json().hash : null}; };
  const emit = (id, hash) => req('emitir', {method: 'POST', body: {id, hash, confirm: true}});
  const session = () => rows.get(cookieId);
  return {req, draft, emit, session, rows, cookieId, prescritorId, logs, cpf, get signatures() { return signatures; }, fail(v = true) { failSign = v; },
    renew() { const r = rows.get(cookieId); rows.set(cookieId, {...r, revision: r.revision + 1, status: 'active', kmsToken: 'SERVER-KMS-2', signaturesUsed: 1, message: undefined}); }};
}
const numero = async id => (await db.query('select numero, estado from cockpit_rx.receita where id = $1', [id])).rows[0];
const numberState = async n => (await db.query('select estado, liberado, pdf_sha256 from cockpit_rx.numero where numero = $1', [n])).rows[0];

test('prescription content is validated, canonical and limited to what the PDF font can print', () => {
  const a = prescriptionContent(body()), b = prescriptionContent(body({paciente: {...body().paciente, nome: '  Paciente   Fictício da Silva '}}));
  assert.equal(a.sha256, b.sha256);assert.equal(a.conteudo.medicamento.quantidade, 30);
  assert.equal(a.conteudo.paciente.documento, '52998224725');
  assert.equal(prescriptionContent(body({paciente: {...body().paciente, documento: 'ab 123456'}})).conteudo.paciente.documento, 'AB123456');
  // 11 digits are a CPF and must carry valid check digits; repeated digits are refused.
  for (const cpf of ['529.982.247-24', '111.111.111-11', '52998224735']) assert.match(prescriptionContent(body({paciente: {...body().paciente, documento: cpf}})).error, /CPF do paciente inválido/);
  for (const [over, message] of [[{tipo: 'RCX'}, /tipo/], [{tipo: 'NRX'}, /tipo/], [{paciente: {...body().paciente, documento: '123'}}, /CPF .* passaporte/], [{paciente: {...body().paciente, nome: 'Emoji 😀'}}, /caracteres/], [{medicamento: {...body().medicamento, quantidade: 0}}, /quantidade/],
    [{emitente: {...body().emitente, uf: 'XX'}}, /UF do emitente/], [{medicamento: {...body().medicamento, posologia: ''}}, /posologia/]])
    assert.match(prescriptionContent(body(over)).error, message);
  assert.deepEqual([1, 16, 21, 100, 101, 999].map(inWords), ['um', 'dezesseis', 'vinte e um', 'cem', 'cento e um', 'novecentos e noventa e nove']);
});

test('only a session whose certificate was confirmed reaches prescriptions', async () => {
  const t = await setup();
  assert.equal((await t.req('estado', {cookie: ''})).code, 401);
  t.rows.set(t.cookieId, {...t.session(), certificate: undefined});
  assert.equal((await t.req('estado')).code, 403);
  const o = await setup();assert.equal((await o.req('rascunho', {method: 'POST', body: {id: randomUUID(), ...body()}, origin: 'https://evil.invalid'})).code, 403);
  assert.equal((await o.req('estado?x=1')).code, 400);assert.equal((await o.req('previa?id=nope')).code, 400);
  const state = (await o.req('estado')).json();
  assert.equal(state.estoque.NRB, 10);assert.equal(state.podeAssinar, true);assert.equal(state.assinaturasRestantes, SESSION_SIGNATURES - 1);
  assert.ok(!JSON.stringify(state).includes(o.cpf));
});

test('draft, preview without number, then issue: the first NRB is used, signed and stored with its hash', async () => {
  const t = await setup(), d = await t.draft();
  assert.equal(d.code, 200);
  const preview = await t.req(`previa?id=${d.id}`);
  assert.equal(preview.code, 200);assert.equal(preview.headers['Content-Type'], 'application/pdf');
  assert.match((await PDFDocument.load(preview.bytes)).getTitle(), /prévia/);
  assert.ok(!preview.bytes.includes(Buffer.from('/ByteRange')), 'a preview is never a signed PDF');
  assert.equal((await t.req('estado')).json().estoque.NRB, 10, 'preview reserves nothing');
  const r = await t.emit(d.id, d.hash);
  assert.equal(r.code, 200, r.bytes.toString());assert.equal(r.json().numero, prefix(accounts) + '0000001');
  const signed = await t.req(`pdf?id=${d.id}`);
  assert.equal(signed.code, 200);assert.match(signed.headers['Content-Disposition'], /attachment; filename="receita-NRB-2411/);
  assert.match((await PDFDocument.load(signed.bytes)).getTitle(), new RegExp(r.json().numero.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  const n = await numberState(r.json().numero);
  assert.deepEqual(n, {estado: 'usado', liberado: true, pdf_sha256: sha(signed.bytes)});
  const state = (await t.req('estado')).json();
  assert.equal(state.estoque.NRB, 9);assert.equal(state.receitas[0].estado, 'emitida');assert.equal(state.receitas[0].numero, r.json().numero);
  assert.equal(state.emitente.endereco, 'Av. Exemplo, 100 - Sala 1');
  assert.equal(t.session().signaturesUsed, 2);assert.equal(t.session().status, 'active');
  // Repeating the issue, or editing afterwards, never spends another number.
  assert.equal((await t.emit(d.id, d.hash)).code, 409);assert.equal(t.signatures, 1);
  assert.match((await t.draft({}, d.id)).json().error, /já foi enviada/);
  const second = await t.draft({paciente: {...body().paciente, nome: 'Outra Pessoa Fictícia'}});
  assert.equal((await t.emit(second.id, second.hash)).json().numero, prefix(accounts) + '0000002');
});

test('the reviewed content is what gets signed; a change after the preview needs a new review', async () => {
  const t = await setup(), d = await t.draft();
  await t.draft({medicamento: {...body().medicamento, quantidade: 60}}, d.id);
  const r = await t.emit(d.id, d.hash);
  assert.equal(r.code, 409);assert.match(r.json().error, /mudou depois da prévia/);assert.equal(t.signatures, 0);
  assert.equal((await t.req('estado')).json().estoque.NRB, 10);
});

test('a failure before the PDF leaves the server gives the number back; after it, the prescription keeps it', async () => {
  // The draft renders its preview (fonts load); the failure comes at issue.
  let fontCalls = 0;
  const a = await setup({options: {fonts: async () => { if (fontCalls++) throw Error('fonts'); return FONTS; }}}), d = await a.draft();
  const early = await a.emit(d.id, d.hash);
  assert.equal(early.code, 502);assert.equal(early.json().estado, 'rascunho');assert.equal(a.signatures, 0);
  assert.deepEqual(await numero(d.id), {numero: null, estado: 'rascunho'});
  assert.equal((await a.req('estado')).json().estoque.NRB, 10);assert.equal(a.session().status, 'active');

  const b = await setup(), e = await b.draft();b.fail();
  const late = await b.emit(e.id, e.hash);
  assert.equal(late.code, 502);assert.equal(late.json().estado, 'pendente');
  const kept = late.json().numero;assert.equal((await numberState(kept)).liberado, true);
  assert.equal(b.session().status, 'uncertain');assert.equal(b.session().kmsToken, undefined);
  assert.equal((await b.emit(e.id, e.hash)).code, 409, 'no automatic retry in the closed session');
  assert.equal(b.logs[0].event, 'prescription_issue_failed');assert.equal(b.logs[0].step, 'sign');assert.ok(!JSON.stringify(b.logs).includes(b.cpf));
  // New entry (new VIDaaS authorization): the retry signs with the same number.
  b.renew();b.fail(false);
  const retry = await b.emit(e.id, e.hash);
  assert.equal(retry.code, 200);assert.equal(retry.json().numero, kept);
  assert.equal((await b.req('estado')).json().estoque.NRB, 9);
});

test('no stock, exhausted signatures and another prescriber are refused without spending anything', async () => {
  const empty = await setup({stock: 0}), d = await empty.draft(), r = await empty.emit(d.id, d.hash);
  assert.equal(r.code, 409);assert.match(r.json().error, /Sem números NRB disponíveis/);assert.equal(empty.session().status, 'active');
  const full = await setup(), f = await full.draft();full.rows.set(full.cookieId, {...full.session(), signaturesUsed: SESSION_SIGNATURES});
  assert.match((await full.emit(f.id, f.hash)).json().error, /assinaturas desta autorização/);
  const owner = await setup(), mine = await owner.draft();await owner.emit(mine.id, mine.hash);
  const other = await setup();
  assert.equal((await other.req(`pdf?id=${mine.id}`)).code, 404);assert.equal((await other.req(`previa?id=${mine.id}`)).code, 404);
  assert.equal((await other.emit(mine.id, mine.hash)).code, 404);
});

test('cancelling a pending prescription voids its number; the registry keeps every step', async () => {
  const t = await setup(), d = await t.draft();t.fail();
  const kept = (await t.emit(d.id, d.hash)).json().numero;t.renew();
  assert.equal((await t.req('cancelar', {method: 'POST', body: {id: d.id, motivo: 'ok'}})).code, 400);
  const c = await t.req('cancelar', {method: 'POST', body: {id: d.id, motivo: 'Teste de cancelamento'}});
  assert.equal(c.json().estado, 'cancelada');assert.equal((await numberState(kept)).estado, 'inutilizado');
  assert.equal((await t.emit(d.id, d.hash)).code, 409);
  await assert.rejects(db.query('delete from cockpit_rx.receita where id = $1', [d.id]), /não permitido/);
  await assert.rejects(db.query(`update cockpit_rx.receita set conteudo = '{}' where id = $1`, [d.id]), /estado final/);
  const events = (await db.query(`select acao, depois ->> 'estado' as estado, depois ? 'pdf_assinado' as pdf from cockpit_rx.evento where entidade = 'receita' and chave = $1 order by id`, [d.id])).rows;
  assert.deepEqual(events.map(e => e.estado), ['rascunho', 'emitindo', 'pendente', 'cancelada']);assert.ok(events.every(e => !e.pdf));
});

test('the access QR and the WhatsApp link open the signed PDF with the printed patient code', async () => {
  const u = '12345678-aaaa-4bbb-8ccc-1234567890ab';
  assert.equal(shortId(u).length, 26);assert.equal(fromShortId(shortId(u).toLowerCase()), u);assert.equal(fromShortId('not-an-id'), null);
  const t = await setup(), d = await t.draft(), issued = (await t.emit(d.id, d.hash)).json();
  assert.match(issued.codigo, /^\d{6}$/);
  const signed = (await t.req(`pdf?id=${d.id}`)).bytes;
  const open = (id, codigo) => t.req('acesso', {method: 'POST', cookie: '', body: {id, codigo}});
  const ok = await open(shortId(d.id), issued.codigo);
  assert.equal(ok.code, 200);assert.equal(ok.json().numero, issued.numero);assert.ok(Buffer.from(ok.json().pdf, 'base64').equals(signed));
  assert.equal(ok.json().prescritor.inscricao, t.session().identity.crm);assert.ok(!JSON.stringify(ok.json()).includes(t.cpf));
  assert.equal((await open(d.id, issued.codigo)).code, 200, 'the UUID works too');
  const wrong = await open(shortId(d.id), '000000');
  assert.equal(wrong.code, 404);assert.equal(wrong.json().error, (await open(shortId(randomUUID()), issued.codigo)).json().error, 'same answer for unknown id');
  for (let i = 0; i < ACCESS_ATTEMPTS; i++) await open(shortId(d.id), '000000');
  assert.equal((await open(shortId(d.id), issued.codigo)).code, 429);
  // The code is printed on the PDF: the "codigo" route returns that same code and link, and it can never change.
  assert.equal(issued.link, `https://rx-hml.openpep.com.br/r/${shortId(d.id)}#${issued.codigo}`);
  const again = await t.req('codigo', {method: 'POST', body: {id: d.id}});
  assert.equal(again.json().codigo, issued.codigo);assert.equal(again.json().link, issued.link);
  assert.equal((await t.req('estado')).json().receitas.find(r => r.id === d.id).link, issued.link);
  await assert.rejects(db.query(`update cockpit_rx.receita set acesso_codigo = '999999' where id = $1`, [d.id]), /impresso no PDF/);
  await assert.rejects(db.query(`update cockpit_rx.receita set conteudo = '{}' where id = $1`, [d.id]), /estado final/);
  const stored = (await db.query('select acesso_hash, acesso_codigo from cockpit_rx.receita where id = $1', [d.id])).rows[0];
  assert.equal(stored.acesso_codigo, issued.codigo);assert.match(stored.acesso_hash, /^[a-f0-9]{64}$/);
  // Issued before the code was printed (no code yet): the first request makes one, later requests return it.
  const old = await setup(), o = await old.draft();
  await ledger.startIssue(o.id, old.prescritorId, o.hash);await ledger.release(o.id, 'NRB');
  const pdf = Buffer.from('%PDF-1.7 synthetic /ByteRange /Contents');
  await ledger.finishIssue(o.id, old.prescritorId, pdf, createHash('sha256').update(pdf).digest('hex'), 'TEST-SERIAL');
  const made = (await old.req('codigo', {method: 'POST', body: {id: o.id}})).json();
  assert.match(made.codigo, /^\d{6}$/);assert.equal((await old.req('codigo', {method: 'POST', body: {id: o.id}})).json().codigo, made.codigo);
  assert.equal((await old.req('acesso', {method: 'POST', cookie: '', body: {id: shortId(o.id), codigo: made.codigo}})).code, 200);
  // Only the prescriber of an issued prescription.
  assert.equal((await t.req('codigo', {method: 'POST', body: {id: o.id}})).code, 409);
  const draftOnly = await old.draft();assert.equal((await old.req('codigo', {method: 'POST', body: {id: draftOnly.id}})).code, 409);
});

test('public build includes prescription demo assets but no hosted prescription signing endpoints', async () => {
  const dir = new URL('../.vercel/output/functions/api/receita/', import.meta.url);
  await assert.rejects(readdir(dir), {code: 'ENOENT'});
  const config = JSON.parse(await readFile(new URL('../.vercel/output/config.json', import.meta.url), 'utf8'));
  assert.ok(!config.routes.some(r => r.src?.startsWith('/api/receita/')));
  for (const page of ['receita.html', 'receita.js', 'receita.css', 'verificar.html', 'verificar.js', 'verificar.css', 'telefone.js', 'transicao.js', 'transicao.css',
    'vendor/intl-tel-input/utils.js', 'vendor/intl-tel-input/css/intlTelInput.min.css', 'vendor/intl-tel-input/img/flags.webp', 'vendor/intl-tel-input/img/flags@2x.webp']) await readFile(new URL(`../.vercel/output/static/${page}`, import.meta.url));
  // The preview dialog frames the prescription PDFs: framing allowed from this origin only.
  assert.match(config.routes[0].headers['Content-Security-Policy'], /frame-ancestors 'self'/);
  assert.ok(config.routes.some(r => r.dest === '/verificar.html' && new RegExp(r.src).test('/R/' + shortId(randomUUID()))));
});

test('CEP lookup: session only, strict query, rate limited, and ViaCEP with BrasilAPI as fallback', async () => {
  const seen = [];
  const t = await setup({stock: 0, options: {cep: async c => { seen.push(c); return c === '01001000' ? {cep: '01001-000', logradouro: 'Praça da Sé', bairro: 'Sé', cidade: 'São Paulo', uf: 'SP'} : null; }}});
  const ok = await t.req('cep?cep=01001000');assert.equal(ok.code, 200);assert.equal(ok.json().cidade, 'São Paulo');
  assert.equal((await t.req('cep?cep=01000000')).code, 404);
  for (const q of ['cep', 'cep?cep=0100100', 'cep?cep=01001-000', 'cep?cep=01001000&x=1', 'cep?cep=01001000&cep=01001000', 'cep?id=' + randomUUID()]) assert.equal((await t.req(q)).code, 400, q);
  assert.equal((await t.req('cep?cep=01001000', {cookie: ''})).code, 401);
  assert.deepEqual(seen, ['01001000', '01000000']);
  for (let i = 0; i < 120; i++) await t.req('cep?cep=01001000');
  assert.equal((await t.req('cep?cep=01001000')).code, 429);
  const broken = await setup({stock: 0, options: {cep: async () => { throw Error('down'); }}});assert.equal((await broken.req('cep?cep=01001000')).code, 503);
  // lookupCEP: ViaCEP answer, ViaCEP "erro", then the BrasilAPI fallback when ViaCEP fails.
  const reply = (status, json) => ({ok: status < 300, status, json: async () => json});
  const via = {cep: '01001-000', logradouro: 'Praça da Sé', bairro: 'Sé', localidade: 'São Paulo', uf: 'SP'};
  assert.deepEqual(await lookupCEP('01001000', async () => reply(200, via)), {cep: '01001-000', logradouro: 'Praça da Sé', bairro: 'Sé', cidade: 'São Paulo', uf: 'SP'});
  assert.equal(await lookupCEP('00000000', async () => reply(200, {erro: 'true'})), null);
  const urls = [], fallback = await lookupCEP('01001000', async u => { urls.push(new URL(u).host); if (u.includes('viacep')) return reply(502, {}); return reply(200, {cep:'01001000', street: 'Praça da Sé', neighborhood: 'Sé', city: 'São Paulo', state: 'SP'}); });
  assert.deepEqual(urls, ['viacep.com.br', 'brasilapi.com.br']);assert.equal(fallback.bairro, 'Sé');
});

test('the signed PDF can be shown inline in the page; other query parameters are refused', async () => {
  const t = await setup(), d = await t.draft();
  assert.equal((await t.emit(d.id, d.hash)).code, 200);
  assert.match((await t.req(`pdf?id=${d.id}`)).headers['Content-Disposition'], /^attachment/);
  assert.match((await t.req(`pdf?id=${d.id}&inline=1`)).headers['Content-Disposition'], /^inline/);
  for (const q of [`pdf?id=${d.id}&inline=0`, `pdf?id=${d.id}&inline=1&inline=1`, `pdf?id=${d.id}&x=1`, `previa?id=${d.id}&inline=1`, 'estado?x=1']) assert.equal((await t.req(q)).code, 400, q);
});

// RCE and RET stock comes in SNCR ranges of 1000 numbers (numeracoes/receita-especial-retencao).
async function rangeStock(prescritorId, tipo, prefix) {
  const s = await ledger.prepare({prescritorId, tipo, quantidade: 1000, cnpj: '12345678000195', chave: randomUUID()});await ledger.startSend(s.id);
  const r = await ledger.recordSuccess(s, 201, {inicio: `${prefix}0000001`, fim: `${prefix}0001000`, quantidade: 1000});
  assert.equal(r.quantidade, 1000);
}
test('RET needs the patient sex and birth date (RDC 471/2021); they enter the hash and the PDF prints the age', () => {
  const ret = over => prescriptionContent(body({tipo: 'RET', paciente: {...body().paciente, sexo: 'F', nascimento: '1990-03-12', ...over}}), TIME);
  assert.equal(ret().conteudo.paciente.sexo, 'F');assert.equal(ret().conteudo.paciente.nascimento, '1990-03-12');
  assert.notEqual(ret().sha256, ret({sexo: 'M'}).sha256);assert.notEqual(ret().sha256, ret({nascimento: '1990-03-13'}).sha256);
  for (const [over, message] of [[{sexo: undefined}, /sexo/], [{sexo: 'X'}, /sexo/], [{nascimento: undefined}, /nascimento/], [{nascimento: '1990-02-30'}, /nascimento/], [{nascimento: '2027-01-01'}, /nascimento/], [{nascimento: '12/03/1990'}, /nascimento/]])
    assert.match(ret(over).error, message, JSON.stringify(over));
  // Notifications and RCE ignore those fields: their content and hash stay as before.
  const rce = prescriptionContent(body({tipo: 'RCE', paciente: {...body().paciente, sexo: 'F', nascimento: '1990-03-12'}}), TIME);
  assert.equal(rce.conteudo.paciente.sexo, undefined);assert.equal(prescriptionContent(body(), TIME).sha256, prescriptionContent(body({paciente: {...body().paciente, sexo: 'F'}}), TIME).sha256);
  assert.deepEqual(['2024-09-29', '2025-03-30', '2026-08-29', '2026-09-28', '1990-09-29', '1990-09-30'].map(d => ageAt(d, TIME)), ['2 anos', '17 meses', '1 mês', '1 dia', '36 anos', '35 anos']);
});
test('RCE and RET are issued from their 1000-number ranges, each with its own stock', async () => {
  const t = await setup({stock: 0});
  await rangeStock(t.prescritorId, 'RCE', `2609.1-${String(accounts).padStart(2, '0')}.`);await rangeStock(t.prescritorId, 'RET', `2609.2-${String(accounts).padStart(2, '0')}.`);
  const state = (await t.req('estado')).json();assert.equal(state.estoque.RCE, 1000);assert.equal(state.estoque.RET, 1000);assert.equal(state.estoque.NRB, 0);
  const rce = await t.draft({tipo: 'RCE', medicamento: {...body().medicamento, nome: 'Cloridrato de tramadol', concentracao: '50 mg', forma: 'cápsula dura', unidade: 'cápsulas'}});
  assert.equal(rce.code, 200);const a = await t.emit(rce.id, rce.hash);assert.equal(a.code, 200, a.json().error);assert.match(a.json().numero, /^2609\.1-\d{2}\.0000001$/);
  const ret = await t.draft({tipo: 'RET', paciente: {...body().paciente, sexo: 'M', nascimento: '2019-05-01'}, medicamento: {...body().medicamento, nome: 'Amoxicilina', concentracao: '50 mg/mL', forma: 'pó para suspensão oral', quantidade: 1, unidade: 'frasco de 150 mL', posologia: 'Tomar 5 mL por via oral de 8 em 8 horas por 10 dias.'}});
  assert.equal(ret.code, 200, ret.json().error);const b = await t.emit(ret.id, ret.hash);assert.equal(b.code, 200, b.json().error);assert.match(b.json().numero, /^2609\.2-\d{2}\.0000001$/);
  const pdf = await PDFDocument.load((await t.req(`pdf?id=${ret.id}`)).bytes);assert.match(pdf.getTitle(), /^Receita Sujeita a Retenção 2609\.2/);
  const after = (await t.req('estado')).json();assert.equal(after.estoque.RCE, 999);assert.equal(after.estoque.RET, 999);
  // A RET draft without the patient's sex and birth date is refused before anything is reserved.
  assert.equal((await t.draft({tipo: 'RET'})).code, 400);
});

// RCE and RET carry up to 3 medications (conteudo.medicamentos); notifications keep one (conteudo.medicamento).
const item = (nome, posologia = 'Tomar 1 comprimido por via oral uma vez ao dia.') => ({nome, concentracao: '50 mg', forma: 'comprimido', quantidade: 30, unidade: 'comprimidos', posologia});
test('RCE and RET take up to 3 medications, in order; notifications take one', () => {
  const rce = list => prescriptionContent(body({tipo: 'RCE', medicamento: undefined, medicamentos: list}), TIME);
  const three = rce([item('Cloridrato de sertralina'), item('Hemifumarato de quetiapina'), item('Pregabalina')]);
  assert.equal(three.conteudo.medicamentos.length, 3);assert.equal(three.conteudo.medicamento, undefined);
  assert.notEqual(three.sha256, rce([item('Hemifumarato de quetiapina'), item('Cloridrato de sertralina'), item('Pregabalina')]).sha256);
  assert.match(rce([item('A1 x'), item('B1 x'), item('C1 x'), item('D1 x')]).error, /Até 3/);
  assert.match(rce([]).error, /Preencha o medicamento/);
  assert.match(rce([item('Cloridrato de sertralina'), {...item('Pregabalina'), posologia: ''}]).error, /^Medicamento 2: .*posologia/);
  // A single medication sent the old way is wrapped; notifications refuse a list.
  assert.equal(prescriptionContent(body({tipo: 'RET', paciente: {...body().paciente, sexo: 'F', nascimento: '1990-03-12'}}), TIME).conteudo.medicamentos.length, 1);
  assert.match(prescriptionContent(body({medicamentos: [item('Diazepam')]}), TIME).error, /um medicamento só/);
  // Notification hashes are unchanged by the new shape.
  assert.equal(prescriptionContent(body(), TIME).conteudo.medicamentos, undefined);
});
test('a 3-medication RCE is issued on one number; the history shows the first and how many more', async () => {
  const t = await setup({stock: 0});
  await rangeStock(t.prescritorId, 'RCE', `2609.3-${String(accounts).padStart(2, '0')}.`);
  const d = await t.draft({tipo: 'RCE', medicamento: undefined, medicamentos: [item('Cloridrato de sertralina'), item('Hemifumarato de quetiapina'), item('Pregabalina')]});
  assert.equal(d.code, 200, d.json().error);
  const r = await t.emit(d.id, d.hash);assert.equal(r.code, 200, r.json().error);
  assert.equal((await t.req('estado')).json().estoque.RCE, 999);
  const listed = (await t.req('estado')).json().receitas.find(x => x.id === d.id);assert.equal(listed.medicamento, 'Cloridrato de sertralina + 2');
  const pdf = await PDFDocument.load((await t.req(`pdf?id=${d.id}`)).bytes);assert.equal(pdf.getPageCount(), 1);
  // Posologies that cannot fit the block are refused at the draft: nothing saved, nothing reserved.
  const huge = 'Tomar 1 comprimido por via oral à noite.\n'.repeat(14).trim();
  const big = await t.draft({tipo: 'RCE', medicamento: undefined, medicamentos: [item('Cloridrato de sertralina', huge), item('Hemifumarato de quetiapina', huge), item('Pregabalina', huge)]});
  assert.equal(big.code, 400);assert.match(big.json().error, /não cabe na receita/);
  assert.equal(await numero(big.id), undefined);assert.equal((await t.req('estado')).json().estoque.RCE, 999);
});

// NRR (systemic retinoids) and NRT (thalidomide) follow their Anvisa models.
const nrrBody = over => body({tipo: 'NRR', paciente: {...body().paciente, sexo: 'F', nascimento: '1998-03-12'},
  medicamento: {nome: 'Isotretinoína', concentracao: '20 mg', forma: 'cápsula mole', quantidade: 30, unidade: 'cápsulas', posologia: 'Tomar 1 cápsula por via oral uma vez ao dia, com uma refeição.'}, ...over});
const nrtBody = over => body({tipo: 'NRT', emitente: {...body().emitente, especialidade: 'Dermatologia', cadastro: 'SP-12345'},
  paciente: {...body().paciente, sexo: 'M', nascimento: '1980-01-01', cid: 'a30.5'},
  medicamento: {nome: 'Talidomida', concentracao: '100 mg', forma: 'comprimido', quantidade: 30, unidade: 'comprimidos', posologia: 'Tomar 1 comprimido por via oral à noite.', tempo: '30 dias'}, ...over});
test('NRR needs birth date and sex; NRT also specialty, registry, CID and treatment time, with an optional guardian', () => {
  assert.equal(prescriptionContent(nrrBody(), TIME).conteudo.paciente.sexo, 'F');
  assert.match(prescriptionContent(nrrBody({paciente: {...body().paciente}}), TIME).error, /sexo/);
  const nrt = prescriptionContent(nrtBody(), TIME);
  assert.equal(nrt.error, undefined);assert.equal(nrt.conteudo.paciente.cid, 'A30.5');assert.equal(nrt.conteudo.medicamento.tempo, '30 dias');assert.equal(nrt.conteudo.responsavel, undefined);
  for (const [over, message] of [[{emitente: body().emitente}, /especialidade/], [{paciente: {...nrtBody().paciente, cid: 'XX'}}, /CID/],
    [{medicamento: {...nrtBody().medicamento, tempo: ''}}, /tempo de tratamento/], [{responsavel: {nome: 'Responsável Fictício', documento: '123', endereco: 'Rua Fictícia, 10'}}, /responsável/]])
    assert.match(prescriptionContent(nrtBody(over), TIME).error, message, JSON.stringify(over));
  const guardian = prescriptionContent(nrtBody({responsavel: {nome: 'Responsável Fictício', documento: '111.444.777-35', endereco: 'Rua Fictícia, 10'}}), TIME);
  assert.equal(guardian.conteudo.responsavel.documento, '11144477735');assert.notEqual(guardian.sha256, nrt.sha256);
});
test('NRR and NRT are issued from their notification stock, with their model titles', async () => {
  const t = await setup({stock: 0});
  for (const [tipo, n] of [['NRR', 4], ['NRT', 5]]) {
    const s = await ledger.prepare({prescritorId: t.prescritorId, tipo, quantidade: 10, chave: randomUUID()});await ledger.startSend(s.id);
    await ledger.recordSuccess(s, 200, {numeroReceita: Array.from({length: 10}, (_, i) => `2411.${n}-${String(accounts).padStart(2, '0')}.${String(i + 1).padStart(7, '0')}`), saldoReceitas: 0});
  }
  for (const [tipo, make, title] of [['NRR', nrrBody, /^Notificação de Receita Especial \(retinoides\)/], ['NRT', nrtBody, /^Notificação de Receita de Talidomida/]]) {
    const d = await t.draft(make());assert.equal(d.code, 200, d.json().error);
    const r = await t.emit(d.id, d.hash);assert.equal(r.code, 200, r.json().error);
    const pdf = await PDFDocument.load((await t.req(`pdf?id=${d.id}`)).bytes);assert.match(pdf.getTitle(), title);
    assert.equal((await t.req('estado')).json().estoque[tipo], 9);
  }
});
test('NRR and NRT drafts, pending and issued prescriptions open their filled-in consent form; other types have none', async () => {
  const t = await setup({stock: 0});
  const s = await ledger.prepare({prescritorId: t.prescritorId, tipo: 'NRR', quantidade: 10, chave: randomUUID()});await ledger.startSend(s.id);
  await ledger.recordSuccess(s, 200, {numeroReceita: Array.from({length: 10}, (_, i) => `2411.4-${String(accounts).padStart(2, '0')}.${String(i + 1).padStart(7, '0')}`), saldoReceitas: 0});
  const d = await t.draft(nrrBody());assert.equal(d.code, 200, d.json().error);
  const draftTerm = await t.req(`termo?id=${d.id}`);
  assert.equal(draftTerm.code, 200);assert.equal(draftTerm.headers['Content-Type'], 'application/pdf');assert.match(draftTerm.headers['Content-Disposition'], /^attachment; filename="termo-NRR\.pdf"$/);
  // Woman under 55: Anexo XV; the physician's CPF never goes on the form.
  const pdf = await PDFDocument.load(draftTerm.bytes);assert.match(pdf.getTitle(), /Anexo XV —/);assert.equal(pdf.getPageCount(), 1);
  const r = await t.emit(d.id, d.hash);assert.equal(r.code, 200, r.json().error);
  const issued = await t.req(`termo?id=${d.id}&inline=1`);
  assert.equal(issued.code, 200);assert.match(issued.headers['Content-Disposition'], new RegExp(`^inline; filename="termo-NRR-${r.json().numero}\\.pdf"$`));
  // Other types, unknown ids and extra parameters are refused; without a session, nothing.
  const other = await setup();const nrb = await other.draft();
  assert.equal((await other.req(`termo?id=${nrb.id}`)).code, 404);
  assert.equal((await other.req(`termo?id=${d.id}`)).code, 404);
  assert.equal((await t.req(`termo?id=${d.id}&x=1`)).code, 400);
  assert.equal((await t.req(`termo?id=${d.id}`, {cookie: ''})).code, 401);
});
