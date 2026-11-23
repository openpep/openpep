import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, readdir} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {createHandler, ORIGIN, BASE, BASE_PRD} from '../api/sncr.mjs';
import {createEdgeCallback} from '../api/sncr-callback-edge.mjs';
import {makeLedger} from '../api/ledger.mjs';

// Production numbers (migration 0008): Node prepares and marks the send, Edge sends once and keeps the answer in the
// rescue area, Node records it. Synthetic prescriber, SNCR and numbers; real Postgres (PGlite).
const TIME = Date.now(), ENTRY = 'e'.repeat(64), CPF = '52998224725', TOKEN = 'SYNTHETIC_BEARER_TOKEN', CNPJ = '12345678000195';
const HOST = new URL(ORIGIN).host;
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
async function setup({reply = () => Response.json({inicio: '2610.3-35.0000001', fim: '2610.3-35.0001000', quantidade: 1000, mensagem: 'ok'}, {status: 201}),
  token = {outcome: 'token-received', token: TOKEN, http: 200}, authorize = true, rescueStore = memory(), logs = []} = {}) {
  const db = await database(), store = memory(), entryStore = memory(), sncrCalls = [];
  if (authorize) await db.query(`insert into cockpit_rx.producao_autorizado (cpf, uf, inscricao) values ($1, 'SP', '12345')`, [CPF]);
  entryStore.rows.set(ENTRY, {mode: 'institutional', status: 'active', expiresAt: TIME + 1800000,
    identity: {issuer: 'https://sso.example.org/realms/test', subject: 'SYNTHETIC-SUBJECT', name: 'Profissional Fictício', fullName: 'Profissional Fictício da Silva', cpf: CPF, crm: '12345', uf: 'SP'}});
  const ledger = makeLedger((q, p) => db.query(q, p));
  let n = 0;
  const node = createHandler({now: () => TIME, random: () => String(++n).padStart(64, 'b'), store, entryStore, rescueStore, ledger, cnpj: CNPJ, pause: async () => {},
    retrieve: async () => { throw Error('Node must not exchange production tokens'); }, fetcher: async () => { throw Error('Node must not call the production gateway'); }});
  const edge = createEdgeCallback({store, rescueStore, now: () => TIME, log: e => logs.push(e), retrieve: async () => structuredClone(token),
    fetcher: async (url, init) => { sncrCalls.push({url, init, body: JSON.parse(init.body)}); return reply(url, init); }});
  let attemptCookie = '';
  const cookies = () => [`__Host-crx-entry=${ENTRY}`, attemptCookie].filter(Boolean).join('; ');
  async function request(url, {method = 'GET', body} = {}) {
    let out = ''; const headers = {};
    const res = {statusCode: 200, setHeader(k, v) { headers[k] = v; }, end(v = '') { out += v; }};
    await node({url, method, body: body && JSON.stringify(body), headers: {host: HOST, origin: ORIGIN, cookie: cookies()}}, res);
    const set = headers['Set-Cookie']; if (set?.startsWith('__Host-crx-sncr-attempt=')) attemptCookie = set.split(';')[0];
    return {status: res.statusCode, headers, body: out, json: () => JSON.parse(out)};
  }
  const viaEdge = async location => { const r = await edge(new Request(`${ORIGIN}${location}`, {headers: {host: HOST, cookie: cookies()}})); return {status: r.status, location: r.headers.get('location')}; };
  // gov.br round trip: Node callback -> Edge -> Node concluir-prd.
  async function roundTrip(body) {
    const s = await request('/api/sncr/login', {method: 'POST', body}); assert.equal(s.status, 200, s.body);
    const login = new URL(s.json().url); assert.equal(login.origin + login.pathname, BASE_PRD + 'auth/login');
    const back = await request(`/api/sncr/callback?session_id=SYNTHETIC_SESSION&state=${login.searchParams.get('state')}`);
    assert.equal(back.status, 303); assert.match(back.headers.Location, /^\/api\/sncr\/callback-edge\?/);
    const e = await viaEdge(back.headers.Location);
    if (e.location !== '/api/sncr/concluir-prd') return {edge: e};
    const done = await request('/api/sncr/concluir-prd');
    return {edge: e, done};
  }
  const rows = async () => (await db.query('select * from cockpit_rx.producao_solicitacao order by criada_em')).rows;
  return {db, store, rescueStore, sncrCalls, logs, request, roundTrip, rows, viaEdge};
}
const secret = x => /SYNTHETIC_BEARER_TOKEN|SYNTHETIC_SESSION/.test(JSON.stringify(x));

test('OpenPEP-Rx: production RET receives a 16-digit range once and remains separate from homologation', async () => {
  const t = await setup({reply: () => Response.json({inicio: '2611.7-35.000000001', fim: '2611.7-35.000001000', quantidade: 1000}, {status: 201})});
  const {done} = await t.roundTrip({tipo: 'RET', quantidade: 1000});
  assert.equal(done.headers.Location, '/numeros.html?result=prd-received');
  assert.equal(t.sncrCalls.length, 1);
  assert.equal(t.sncrCalls[0].body.tipo, 'RET');
  const [row] = await t.rows();
  assert.equal(row.numeros.length, 1000);
  assert.equal(row.numeros.at(-1), '2611.7-35.000001000');
  assert.equal((await t.request('/api/sncr/numeros')).json().producao.retNoMes, 1);
  assert.equal((await t.db.query('select count(*)::int as n from cockpit_rx.numero')).rows[0].n, 0);
  assert.ok(!secret(await t.rows()));
});

test('production NR daily limit includes uncertain requests and refuses excess before login', async () => {
  const t = await setup({reply: () => new Response('temporarily unavailable', {status: 503})});
  await t.roundTrip({ambiente: 'prd', tipo: 'NRB', quantidade: 50});
  const excess = await t.request('/api/sncr/login', {method: 'POST', body: {ambiente: 'prd', tipo: 'NRB', quantidade: 10}});
  assert.equal(excess.status, 409);
  assert.match(excess.json().error, /limite diário/);
  assert.equal(t.sncrCalls.length, 1);
});

test('RCE in production: marked before sending, one POST to the production gateway with the platform CNPJ, range recorded apart from homologation stock', async () => {
  const t = await setup();
  const {edge, done} = await t.roundTrip({ambiente: 'prd', tipo: 'RCE', quantidade: 1000});
  assert.equal(edge.location, '/api/sncr/concluir-prd'); assert.equal(done.headers.Location, '/numeros.html?result=prd-received');
  assert.equal(t.sncrCalls.length, 1);
  const [call] = t.sncrCalls;
  assert.equal(call.url, BASE_PRD + 'numeracoes/receita-especial-retencao');
  assert.deepEqual(call.body, {conselho: 'CRM', tipo: 'RCE', documento: '12345', uf: 'SP', cnpj: CNPJ});
  assert.equal(call.init.headers.Authorization, `Bearer ${TOKEN}`);
  const [r] = await t.rows();
  assert.equal(r.estado, 'recebida'); assert.equal(r.http, 201); assert.equal(r.numeros.length, 1000); assert.equal(r.numeros[999], '2610.3-35.0001000');
  // Homologation registry untouched: no request, no numbers, no stock.
  assert.equal((await t.db.query('select count(*)::int as n from cockpit_rx.solicitacao')).rows[0].n, 0);
  assert.equal((await t.db.query('select count(*)::int as n from cockpit_rx.numero')).rows[0].n, 0);
  const panel = (await t.request('/api/sncr/numeros')).json();
  assert.equal(panel.producao.liberado, true); assert.equal(panel.producao.rceNoMes, 1);
  assert.deepEqual({...panel.producao.solicitacoes[0], id: undefined, criada_em: undefined, concluida_em: undefined},
    {id: undefined, tipo: 'RCE', quantidade: 1000, estado: 'recebida', http: 201, mensagem: 'ok', motivo: null, criada_em: undefined, concluida_em: undefined, primeiro: '2610.3-35.0000001', ultimo: '2610.3-35.0001000', recebidos: 1000});
  assert.ok(!secret([...t.store.rows, ...t.rescueStore.rows, await t.rows()]));
  // concluir-prd cleared the attempt: the same return cannot send again.
  assert.equal((await t.viaEdge(`/api/sncr/callback-edge?session_id=SYNTHETIC_SESSION&state=x`)).location, '/sncr.html?result=invalid-attempt');
  assert.equal(t.sncrCalls.length, 1);
});

test('NRB in production without approved balance: refusal recorded with the SNCR message, nothing received', async () => {
  const t = await setup({reply: () => Response.json({mensagem: 'Prescritor não possui saldo disponível para o tipo de receita informado.'}, {status: 400})});
  const {done} = await t.roundTrip({ambiente: 'prd', tipo: 'NRB', quantidade: 10});
  assert.equal(done.headers.Location, '/numeros.html?result=prd-refused');
  assert.equal(t.sncrCalls[0].url, BASE_PRD + 'numeracoes/notificacao-receita');
  assert.deepEqual(t.sncrCalls[0].body, {receita: 'NRB', conselho: 'CRM', uf: 'SP', documento: '12345', quantidade: 10});
  const [r] = await t.rows();
  assert.equal(r.estado, 'recusada'); assert.equal(r.http, 400); assert.match(r.mensagem, /não possui saldo/); assert.equal(r.numeros, null);
});

test('production: unexpected success goes to quarantine with the body kept; 5xx is uncertain; failed login sends nothing', async () => {
  const q = await setup({reply: () => Response.json({faixa: 'formato novo'}, {status: 201})});
  assert.equal((await q.roundTrip({ambiente: 'prd', tipo: 'RCE', quantidade: 1000})).done.headers.Location, '/numeros.html?result=prd-quarantine');
  const [qr] = await q.rows(); assert.equal(qr.estado, 'quarentena'); assert.deepEqual(qr.corpo, {faixa: 'formato novo'}); assert.ok(qr.motivo);

  const a = await setup({reply: () => new Response('erro', {status: 502})});
  assert.equal((await a.roundTrip({ambiente: 'prd', tipo: 'NRB', quantidade: 10})).done.headers.Location, '/numeros.html?result=prd-ambiguous');
  assert.equal((await a.rows())[0].estado, 'ambigua');

  const l = await setup({token: {outcome: 'token-rejected', http: 403}});
  assert.equal((await l.roundTrip({ambiente: 'prd', tipo: 'RCE', quantidade: 1000})).done.headers.Location, '/numeros.html?result=token-rejected');
  assert.equal(l.sncrCalls.length, 0); assert.equal((await l.rows())[0].estado, 'descartada');
  // A discarded or refused request does not count toward the monthly RCE limit.
  assert.equal((await l.request('/api/sncr/numeros')).json().producao.rceNoMes, 0);
});

test('production: only released prescribers; one request at a time; RCE limited to 3 per month', async () => {
  const blocked = await setup({authorize: false});
  const r = await blocked.request('/api/sncr/login', {method: 'POST', body: {ambiente: 'prd', tipo: 'RCE', quantidade: 1000}});
  assert.equal(r.status, 409); assert.match(r.json().error, /não liberado/); assert.equal((await blocked.rows()).length, 0);

  const t = await setup();
  assert.equal((await t.request('/api/sncr/login', {method: 'POST', body: {ambiente: 'prd', tipo: 'RCE', quantidade: 1000}})).status, 200);
  const again = await t.request('/api/sncr/login', {method: 'POST', body: {ambiente: 'prd', tipo: 'NRB', quantidade: 10}});
  assert.equal(again.status, 409); assert.match(again.json().error, /em andamento/);
  for (const bad of [{ambiente: 'prd', tipo: 'RCE', quantidade: 10}, {ambiente: 'prd', tipo: 'NRB', quantidade: 51}])
    assert.equal((await t.request('/api/sncr/login', {method: 'POST', body: bad})).status, 400, JSON.stringify(bad));

  const m = await setup();
  for (let i = 0; i < 3; i++) assert.equal((await m.roundTrip({ambiente: 'prd', tipo: 'RCE', quantidade: 1000})).done.headers.Location, '/numeros.html?result=prd-received');
  const fourth = await m.request('/api/sncr/login', {method: 'POST', body: {ambiente: 'prd', tipo: 'RCE', quantidade: 1000}});
  assert.equal(fourth.status, 409); assert.match(fourth.json().error, /3 pedidos de RCE/);
  await assert.rejects(m.db.query('delete from cockpit_rx.producao_solicitacao'), /não permitido/);
  await assert.rejects(m.db.query(`update cockpit_rx.producao_solicitacao set estado = 'descartada'`), /encerrado/);
});

test('production: if the rescue area fails the range goes to the log (no token) and the request stays uncertain; a later panel settles a kept result', async () => {
  const broken = memory(); broken.create = async () => { throw Error('redis down'); };
  const t = await setup({rescueStore: broken});
  const {done} = await t.roundTrip({ambiente: 'prd', tipo: 'RCE', quantidade: 1000});
  assert.equal(done.headers.Location, '/numeros.html?result=prd-unrecorded');
  assert.equal((await t.rows())[0].estado, 'enviando');
  assert.deepEqual(t.logs.map(({event, tipo, kind, http, inicio, fim}) => ({event, tipo, kind, http, inicio, fim})),
    [{event: 'sncr_prd_unrecorded', tipo: 'RCE', kind: 'success', http: 201, inicio: '2610.3-35.0000001', fim: '2610.3-35.0001000'}]);
  assert.ok(!secret(t.logs));

  // Browser never reached concluir-prd: the next panel read records it from the rescue area.
  const k = await setup();
  const s = await k.request('/api/sncr/login', {method: 'POST', body: {ambiente: 'prd', tipo: 'RCE', quantidade: 1000}});
  const back = await k.request(`/api/sncr/callback?session_id=SYNTHETIC_SESSION&state=${new URL(s.json().url).searchParams.get('state')}`);
  await k.viaEdge(back.headers.Location);
  assert.equal((await k.rows())[0].estado, 'enviando');
  assert.equal((await k.request('/api/sncr/numeros')).json().producao.solicitacoes[0].estado, 'recebida');
  assert.equal((await k.request('/api/sncr/concluir-prd')).headers.Location, '/numeros.html?result=prd-received');
  assert.equal(k.sncrCalls.length, 1);
});

test('homologation numbers are unchanged: Node sends them to the HML gateway and the Edge refuses them', async () => {
  const src = await readFile('api/sncr.mjs', 'utf8');
  assert.match(src, /postNumbers\(\{base: BASE,/); assert.ok(BASE.includes('.hmg.'));
  const store = memory(), attempt = `${'c'.repeat(64)}.${Math.floor(TIME / 1000)}`;
  store.rows.set(attempt, {revision: 0, status: 'pending', createdAt: TIME, env: 'prd', mode: 'numbers', intent: {}});
  let sent = 0;
  const edge = createEdgeCallback({store, rescueStore: memory(), now: () => TIME, retrieve: async () => ({outcome: 'token-received', token: TOKEN}), fetcher: async () => { sent++; return new Response(''); }});
  const r = await edge(new Request(`${ORIGIN}/api/sncr/callback-edge?session_id=X&state=${attempt}`, {headers: {host: HOST, cookie: `__Host-crx-sncr-attempt=${attempt}`}}));
  assert.equal(r.headers.get('location'), '/sncr.html?result=already-used'); assert.equal(sent, 0);
});

test('production RCE limit counts the month in Brasília time (the last evening of a month belongs to that month)', async () => {
  const t = await setup();
  const [{id}] = (await t.db.query(`select id from cockpit_rx.prescritor where cpf = $1`, [CPF])).rows.length ? (await t.db.query(`select id from cockpit_rx.prescritor where cpf = $1`, [CPF])).rows
    : (await t.db.query(`insert into cockpit_rx.prescritor (conta_hash, cpf, nome, uf, inscricao) values ($1, $2, 'Profissional Fictício', 'SP', '12345') returning id`, ['f'.repeat(64), CPF])).rows;
  // Brasília month start, and one minute before it (previous month in Brasília, possibly the same month in UTC).
  const {rows: [b]} = await t.db.query(`select (date_trunc('month', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo') as inicio`);
  const insert = (offset, n) => t.db.query(`insert into cockpit_rx.producao_solicitacao (chave, prescritor_id, tipo, quantidade, cnpj, estado, criada_em)
    values ($1, $2, 'RCE', 1000, $3, 'ambigua', $4::timestamptz + $5::interval)`, [`chave-${n}-${'x'.repeat(16)}`, id, CNPJ, b.inicio, offset]);
  for (let n = 0; n < 3; n++) await insert('-1 minute', n);
  const panel = async () => (await t.db.query('select cockpit_rx.producao_painel($1) as p', [id])).rows[0].p;
  assert.equal((await panel()).rceNoMes, 0);
  for (let n = 3; n < 6; n++) await insert('1 minute', n);
  assert.equal((await panel()).rceNoMes, 3);
  await assert.rejects(t.db.query(`select cockpit_rx.producao_preparar($1, 'RCE', 1000, $2, $3)`, [id, CNPJ, 'nova-chave-' + 'y'.repeat(16)]), /3 pedidos de RCE/);
});
