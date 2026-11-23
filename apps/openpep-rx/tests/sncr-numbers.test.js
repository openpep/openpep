import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, readdir} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {createHandler, ORIGIN, BASE, LOGIN} from '../api/sncr.mjs';
import {makeLedger} from '../api/ledger.mjs';
import {numbersRequest, postNumbers} from '../api/sncr-numbers.mjs';

// Synthetic prescriber and SNCR; real Postgres (PGlite) with the production migrations.
const TIME = 1800000000000, ENTRY = 'e'.repeat(64), CPF = '52998224725', TOKEN = 'SYNTHETIC_BEARER_TOKEN', CNPJ = '12345678000195';
const nr = (from, count, prefix = '2411.1-00.') => Array.from({length: count}, (_, i) => `${prefix}${String(from + i).padStart(7, '0')}`);
async function database() {
  const db = new PGlite(), dir = new URL('../db/migrations/', import.meta.url);
  for (const f of (await readdir(dir)).filter(f => f.endsWith('.sql')).sort()) await db.exec(await readFile(new URL(f, dir), 'utf8'));
  return db;
}
function memory() {
  const rows = new Map();
  return {rows, allow: async () => true, get: async k => structuredClone(rows.get(k)), create: async (k, v) => { if (rows.has(k)) return false; rows.set(k, structuredClone(v)); return true; },
    swap: async (k, r, v) => { if (rows.get(k)?.revision !== r) return false; rows.set(k, structuredClone(v)); return true; }};
}
async function setup({reply = () => Response.json({numeroReceita: nr(1, 10), saldoReceitas: 40}), retrieve, status = 'certificate_required', identity = {}, cnpj, ledgerOverride} = {}) {
  const db = await database(), store = memory(), entryStore = memory(), rescueStore = memory(), sncrCalls = [];
  let n = 0;
  entryStore.rows.set(ENTRY, {mode: 'institutional', status, expiresAt: TIME + 1800000,
    identity: {issuer: 'https://sso.example.org/realms/test', subject: 'SYNTHETIC-SUBJECT', name: 'Profissional Fictício', fullName: 'Profissional Fictício da Silva', cpf: CPF, crm: '12345', uf: 'SP', ...identity}});
  const ledger = ledgerOverride ? ledgerOverride(makeLedger((q, p) => db.query(q, p))) : makeLedger((q, p) => db.query(q, p));
  const handler = createHandler({defaultEnvironment:'hmg',now: () => TIME, random: () => String(++n).padStart(64, 'a').slice(-64).replace(/[^a-f0-9]/g, 'a'), store, entryStore, rescueStore, ledger, cnpj, pause: async () => {},
    retrieve: retrieve || (async () => ({outcome: 'token-received', token: TOKEN})),
    fetcher: async (url, init) => { sncrCalls.push({url, init, body: JSON.parse(init.body)}); return reply(url, init); }});
  let attemptCookie = '';
  async function request(url, {method = 'GET', body, cookie = `__Host-crx-entry=${ENTRY}`, origin = ORIGIN} = {}) {
    let out = ''; const headers = {};
    const res = {statusCode: 200, setHeader(k, v) { headers[k] = v; }, end(v = '') { out += v; }};
    await handler({url, method, body, headers: {host: new URL(ORIGIN).host, origin, cookie: [cookie, attemptCookie].filter(Boolean).join('; ')}}, res);
    const set = headers['Set-Cookie']; if (set?.startsWith('__Host-crx-sncr-attempt=')) attemptCookie = set.split(';')[0];
    return {status: res.statusCode, headers, json: () => JSON.parse(out), body: out};
  }
  const start = (body = {tipo: 'NRB', quantidade: 10}, opts) => request('/api/sncr/login', {method: 'POST', body, ...opts});
  async function roundTrip(body, opts) {
    const s = await start(body, opts); assert.equal(s.status, 200, s.body);
    const state = new URL(s.json().url).searchParams.get('state');
    return request(`/api/sncr/callback?session_id=SYNTHETIC_SESSION&state=${state}`);
  }
  const all = async sql => (await db.query(sql)).rows;
  return {db, store, entryStore, rescueStore, sncrCalls, request, start, roundTrip, all, ledger};
}
const secretsIn = (...things) => JSON.stringify(things).match(/SYNTHETIC_BEARER_TOKEN|SYNTHETIC_SESSION/g);

test('NRB request: one SNCR call with the documented body, numbers stored, token never stored or returned', async () => {
  const t = await setup();
  const res = await t.roundTrip({tipo: 'NRB', quantidade: 10});
  assert.equal(res.status, 303);assert.equal(res.headers.Location, '/numeros.html?result=numbers-received');
  assert.equal(t.sncrCalls.length, 1);
  const [call] = t.sncrCalls;
  assert.equal(call.url, new URL('numeracoes/notificacao-receita', BASE).href);
  assert.deepEqual(call.body, {receita: 'NRB', conselho: 'CRM', uf: 'SP', documento: '12345', quantidade: 10});
  assert.equal(call.init.headers.Authorization, `Bearer ${TOKEN}`);assert.equal(call.init.headers.Origin, ORIGIN);assert.equal(call.init.method, 'POST');
  const [s] = await t.all('select * from cockpit_rx.solicitacao');
  assert.equal(s.estado, 'recebida');assert.equal(s.saldo_sncr, 40);assert.equal(s.cnpj, null);
  assert.equal((await t.all(`select count(*)::int as n from cockpit_rx.numero where estado = 'disponivel'`))[0].n, 10);
  const [p] = await t.all('select * from cockpit_rx.prescritor');
  assert.deepEqual([p.cpf, p.uf, p.inscricao, p.nome], [CPF, 'SP', '12345', 'Profissional Fictício da Silva']);
  const attemptRow = [...t.store.rows.values()][0];
  assert.equal(attemptRow.status, 'numbers-received');assert.ok(!JSON.stringify(attemptRow).includes(CPF));
  assert.equal(secretsIn([...t.store.rows], await t.all('select * from cockpit_rx.evento'), await t.all('select * from cockpit_rx.solicitacao'), res), null);
  const panel = (await t.request('/api/sncr/numeros')).json();
  assert.equal(panel.podeSolicitar, true);assert.equal(panel.crm, '12345');
  assert.deepEqual(panel.painel.estoque, [{tipo: 'NRB', disponiveis: 10, reservados: 0, usados: 0, inutilizados: 0}]);
  assert.deepEqual(panel.painel.limites.NRB, {usado: 10, maximo: 50, periodo: 'dia'});assert.equal(panel.painel.saldoSncr.NRB.saldo, 40);
  assert.equal(panel.painel.solicitacoes[0].estado, 'recebida');assert.ok(!JSON.stringify(panel).includes(CPF));
  // Replaying the return never sends again.
  const state = [...t.store.rows.keys()][0];
  assert.equal((await t.request(`/api/sncr/callback?session_id=SYNTHETIC_SESSION&state=${state}`)).headers.Location, '/numeros.html?result=already-used');
  assert.equal(t.sncrCalls.length, 1);
});

test('RCE needs the configured platform CNPJ and stores the 1000-number range', async () => {
  let t = await setup();
  assert.equal((await t.start({tipo: 'RCE', quantidade: 1000})).status, 503);
  t = await setup({cnpj: CNPJ, reply: () => Response.json({inicio: '2602.6-53.0000001', fim: '2602.6-53.0001000', quantidade: 1000, mensagem: 'Numeração gerada com sucesso.'}, {status: 201})});
  const res = await t.roundTrip({tipo: 'RCE', quantidade: 1000});
  assert.equal(res.headers.Location, '/numeros.html?result=numbers-received');
  assert.equal(t.sncrCalls[0].url, new URL('numeracoes/receita-especial-retencao', BASE).href);
  assert.deepEqual(t.sncrCalls[0].body, {conselho: 'CRM', tipo: 'RCE', documento: '12345', uf: 'SP', cnpj: CNPJ});
  assert.equal((await t.all(`select count(*)::int as n from cockpit_rx.numero where tipo = 'RCE'`))[0].n, 1000);
});

test('refusal, server error, network failure and malformed success never add stock; uncertain requests count in the limit', async () => {
  const cases = [
    [() => Response.json({message: 'Limite diário de 50 receitas atingido.'}, {status: 400}), 'numbers-refused', 'recusada'],
    [() => new Response('upstream', {status: 502}), 'numbers-ambiguous', 'ambigua'],
    [() => { throw new TypeError('fetch failed'); }, 'numbers-ambiguous', 'ambigua'],
    [() => Response.json({numeroReceita: ['formato-estranho']}), 'numbers-quarantine', 'quarentena'],
    [() => new Response('<html>', {status: 200}), 'numbers-quarantine', 'quarentena'],
    [() => new Response(null, {status: 302, headers: {Location: 'https://evil.invalid'}}), 'numbers-refused', 'recusada'],
    [() => new Response(null, {status: 204}), 'numbers-refused', 'recusada'],
  ];
  for (const [reply, result, estado] of cases) {
    const t = await setup({reply});
    const res = await t.roundTrip({tipo: 'NRB', quantidade: 30});
    assert.equal(res.headers.Location, `/numeros.html?result=${result}`, result);
    const [s] = await t.all('select * from cockpit_rx.solicitacao');assert.equal(s.estado, estado);
    assert.equal((await t.all('select count(*)::int as n from cockpit_rx.numero'))[0].n, 0);
    if (estado === 'recusada' && s.http_status === 400) assert.equal(s.mensagem, 'Limite diário de 50 receitas atingido.');
    if (estado === 'ambigua') assert.equal((await t.start({tipo: 'NRB', quantidade: 30})).status, 409); // 30 uncertain + 30 > 50
  }
});

test('login failures send nothing and close the prepared intent', async () => {
  for (const outcome of ['token-rejected', 'token-unavailable', 'token-invalid-response']) {
    const t = await setup({retrieve: async () => ({outcome})});
    assert.equal((await t.roundTrip()).headers.Location, `/numeros.html?result=${outcome}`);
    assert.equal(t.sncrCalls.length, 0);assert.equal((await t.all('select estado from cockpit_rx.solicitacao'))[0].estado, 'descartada');
  }
  const t = await setup();const s = await t.start();
  assert.equal((await t.request('/api/sncr/callback?session_id=X&state=' + 'b'.repeat(64) + '.1800000000')).headers.Location, '/numeros.html?result=state-mismatch');
  assert.equal(t.sncrCalls.length, 0);assert.equal((await t.all('select estado from cockpit_rx.solicitacao'))[0].estado, 'descartada');
  assert.ok(s.status === 200);
});

test('if the registry fails after the SNCR answered, the response is preserved in the rescue area', async () => {
  const t = await setup({ledgerOverride: l => ({...l, recordSuccess: async () => { throw Object.assign(new Error('registro indisponível'), {}); }})});
  // LedgerError-like failure that is not a business rule: retried, then rescued.
  const {LedgerError} = await import('../api/ledger.mjs');
  const t2 = await setup({ledgerOverride: l => ({...l, recordSuccess: async () => { throw new LedgerError('registro indisponível'); }})});
  for (const x of [t, t2]) {
    const res = await x.roundTrip();
    assert.equal(res.headers.Location, '/numeros.html?result=numbers-unrecorded');
    const [rescued] = [...x.rescueStore.rows.values()];
    assert.deepEqual(rescued.body.numeroReceita, nr(1, 10));assert.equal(rescued.kind, 'success');
    assert.equal(secretsIn([...x.rescueStore.rows]), null);
    assert.equal((await x.all('select estado from cockpit_rx.solicitacao'))[0].estado, 'enviando'); // visible, counts in the limit
  }
});

test('registry unavailable before sending: nothing goes to the SNCR', async () => {
  const t = await setup({ledgerOverride: l => ({...l, startSend: async () => { throw new Error('down'); }})});
  assert.equal((await t.roundTrip()).headers.Location, '/numeros.html?result=numbers-unavailable');
  assert.equal(t.sncrCalls.length, 0);
});

test('only a signed-in prescriber with confirmed CRM/UF/CPF can request; inputs and conflicts are checked', async () => {
  let t = await setup();
  assert.equal((await t.start({tipo: 'NRB', quantidade: 10}, {cookie: ''})).status, 403);
  assert.equal((await t.start({tipo: 'NRB', quantidade: 10}, {origin: 'https://evil.invalid'})).status, 403);
  for (const body of [{tipo: 'XYZ', quantidade: 10}, {tipo: 'NRB', quantidade: 9}, {tipo: 'NRB', quantidade: 51}, {tipo: 'NRB', quantidade: '10'}, {tipo: 'RCE', quantidade: 999}])
    assert.equal((await t.start(body)).status, 400, JSON.stringify(body));
  assert.equal((await t.request('/api/sncr/login', {method: 'POST', body: 'x'.repeat(3000)})).status, 400);
  for (const status of ['profile_required', 'failed', 'uncertain', 'closed']) {
    t = await setup({status});assert.equal((await t.start()).status, 403, status);
    const panel = (await t.request('/api/sncr/numeros')).json();
    assert.equal(panel.podeSolicitar, false);assert.equal(panel.sessaoBloqueada, status !== 'profile_required', status);
  }
  t = await setup();
  await t.db.query(`insert into cockpit_rx.prescritor (conta_hash, cpf, nome, uf, inscricao) values ($1, '11144477735', 'Outra Pessoa', 'SP', '12345')`, ['c'.repeat(64)]);
  const conflict = await t.start();assert.equal(conflict.status, 409);assert.match(conflict.json().error, /já vinculados a outra conta/);
  assert.deepEqual((await (await setup()).request('/api/sncr/numeros', {cookie: ''})).json(), {entrou: false});
  // Diagnostic mode (no body) is unchanged and needs no session.
  const diag = await (await setup()).request('/api/sncr/login', {method: 'POST', cookie: ''});assert.equal(diag.status, 200);
  assert.equal(new URL(diag.json().url).origin + new URL(diag.json().url).pathname, BASE + 'auth/login');
});

test('numbersRequest and postNumbers follow the manual and never follow redirects', async () => {
  assert.deepEqual(numbersRequest({tipo: 'NRA', quantidade: 20, uf: 'RJ', documento: '1'}), {path: 'numeracoes/notificacao-receita', body: {receita: 'NRA', conselho: 'CRM', uf: 'RJ', documento: '1', quantidade: 20}});
  assert.throws(() => numbersRequest({tipo: 'X'}));
  let seen;const r = await postNumbers({base: BASE, origin: ORIGIN, token: 'T', request: {tipo: 'NRB', quantidade: 10, uf: 'SP', documento: '1'}, fetcher: async (u, i) => { seen = i; return Response.json({ok: true}); }});
  assert.equal(seen.redirect, 'manual');assert.ok(seen.signal);assert.equal(r.kind, 'success');
});
