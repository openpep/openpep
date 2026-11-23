import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, readdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';
import {makeLedger, parseNotificationResponse, expandRangeResponse, LedgerError} from '../api/ledger.mjs';

// Real Postgres (PGlite) with the same migration applied to Supabase; synthetic prescribers and numbers only.
const db = new PGlite();
const migrations = new URL('../db/migrations/', import.meta.url);
for (const file of (await readdir(migrations)).filter(f => f.endsWith('.sql')).sort()) await db.exec(await readFile(new URL(file, migrations), 'utf8'));
const ledger = makeLedger((sql, params) => db.query(sql, params));
const CNPJ = '12345678000195';
let seq = 0;
async function prescriber() {
  const n = ++seq, id = randomUUID();
  await db.query(`insert into cockpit_rx.prescritor (id, conta_hash, cpf, nome, uf, inscricao) values ($1, $2, $3, 'Profissional Fictício', 'SP', $4)`,
    [id, String(n).padStart(64, 'a'), String(n).padStart(11, '9'), String(100000 + n)]);
  return id;
}
const nr = (prefix, from, count) => Array.from({length: count}, (_, i) => `${prefix}${String(from + i).padStart(7, '0')}`);
async function received(p, tipo, body, quantidade = tipo === 'RCE' || tipo === 'RET' ? 1000 : 10) {
  const s = await ledger.prepare({prescritorId: p, tipo, quantidade, cnpj: ['RCE', 'RET'].includes(tipo) ? CNPJ : null, chave: randomUUID()});
  assert.equal(await ledger.startSend(s.id), true);
  return {s, r: await ledger.recordSuccess(s, tipo === 'RCE' || tipo === 'RET' ? 201 : 200, body)};
}
const stateOf = async n => (await db.query('select * from cockpit_rx.numero where numero = $1', [n])).rows[0];

test('SNCR responses are parsed strictly; anything unexpected is rejected for quarantine', () => {
  const ok = parseNotificationResponse({numeroReceita: ['2411.1-00.0000001', '2411.1-00.0000002'], saldoReceitas: 48, mensagem: 'Saldo inferior a 50 receitas disponíveis.'}, 10);
  assert.deepEqual(ok.sequences, [1, 2]);assert.equal(ok.saldo, 48);
  assert.deepEqual(parseNotificationResponse({numeracoesReceita: '[2411.1-00.0000001, 2411.1-00.0000002]', saldoReceitas: 49}, 10).numbers, ['2411.1-00.0000001', '2411.1-00.0000002']);
  for (const body of [{}, {numeroReceita: []}, {numeroReceita: ['2411.1-00.000001']}, {numeroReceita: ['2411.1-00.0000001 ; DROP']}, {numeroReceita: nr('2411.1-00.', 1, 11)}])
    assert.ok(parseNotificationResponse(body, 10).error, JSON.stringify(body));
  const range = expandRangeResponse({inicio: '2602.6-53.0000001', fim: '2602.6-53.0001000', quantidade: 1000});
  assert.equal(range.numbers.length, 1000);assert.equal(range.numbers[999], '2602.6-53.0001000');assert.equal(new Set(range.numbers).size, 1000);
  for (const body of [{inicio: '2602.6-53.0000001', fim: '2602.6-54.0001000', quantidade: 1000}, {inicio: '2602.6-53.0000001', fim: '2602.6-53.0000999', quantidade: 1000},
    {inicio: '2602.6-53.0000001', fim: '2602.6-53.0001000', quantidade: 999}, {inicio: 'x', fim: '2602.6-53.0001000', quantidade: 1000}])
    assert.ok(expandRangeResponse(body).error, JSON.stringify(body));
});

test('a request is prepared once per key, sent at most once, and its exact response is kept with the numbers', async () => {
  const p = await prescriber(), chave = randomUUID();
  const s = await ledger.prepare({prescritorId: p, tipo: 'NRB', quantidade: 10, chave});
  assert.equal((await ledger.prepare({prescritorId: p, tipo: 'NRB', quantidade: 10, chave})).id, s.id);
  await assert.rejects(ledger.prepare({prescritorId: p, tipo: 'NRB', quantidade: 20, chave}), LedgerError);
  assert.equal(await ledger.startSend(s.id), true);assert.equal(await ledger.startSend(s.id), false);
  const body = {numeracoesReceita: `[${nr('2411.1-00.', 1, 10).join(', ')}]`, saldoReceitas: 40, mensagem: 'Saldo inferior a 50 receitas disponíveis.'};
  assert.deepEqual(await ledger.recordSuccess(s, 200, body), {estado: 'recebida', quantidade: 10, saldo: 40, mensagem: body.mensagem});
  const row = (await db.query('select * from cockpit_rx.solicitacao where id = $1', [s.id])).rows[0];
  assert.equal(row.estado, 'recebida');assert.deepEqual(row.resposta, body);assert.equal(row.saldo_sncr, 40);
  assert.deepEqual(await ledger.stock(p), [{tipo: 'NRB', disponiveis: 10, reservados: 0, usados: 0, inutilizados: 0}]);
  await assert.rejects(ledger.recordSuccess(s, 200, body), /não está em envio/);
});

test('local limits: 50 NR per type per day and 3 RCE/RET requests per month, counting uncertain requests', async () => {
  const p = await prescriber();
  const first = await ledger.prepare({prescritorId: p, tipo: 'NRA', quantidade: 40, chave: randomUUID()});
  await ledger.startSend(first.id);await ledger.recordFailure(first.id, 'ambigua', null, null, 'timeout');
  await assert.rejects(ledger.prepare({prescritorId: p, tipo: 'NRA', quantidade: 20, chave: randomUUID()}), /limite diário/);
  assert.ok(await ledger.prepare({prescritorId: p, tipo: 'NRA', quantidade: 10, chave: randomUUID()}));
  assert.ok(await ledger.prepare({prescritorId: p, tipo: 'NRB', quantidade: 50, chave: randomUUID()}));
  for (let i = 0; i < 3; i++) await received(p, 'RCE', {inicio: `2602.6-5${i}.0000001`, fim: `2602.6-5${i}.0001000`, quantidade: 1000});
  await assert.rejects(ledger.prepare({prescritorId: p, tipo: 'RCE', quantidade: 1000, cnpj: CNPJ, chave: randomUUID()}), /limite mensal/);
  assert.ok(await ledger.prepare({prescritorId: p, tipo: 'RET', quantidade: 1000, cnpj: CNPJ, chave: randomUUID()}));
  await assert.rejects(ledger.prepare({prescritorId: p, tipo: 'RCE', quantidade: 500, cnpj: CNPJ, chave: randomUUID()}), LedgerError);
  await assert.rejects(ledger.prepare({prescritorId: p, tipo: 'NRB', quantidade: 5, chave: randomUUID()}), LedgerError);
});

test('invalid, inconsistent or already registered responses go to quarantine and never reach the stock', async () => {
  const p = await prescriber();
  let {r} = await received(p, 'RCE', {inicio: '2602.6-60.0000001', fim: '2602.6-60.0000999', quantidade: 1000});
  assert.equal(r.estado, 'quarentena');
  ({r} = await received(p, 'NRB', {numeroReceita: nr('2411.1-01.', 1, 10)}));assert.equal(r.estado, 'recebida');
  ({r} = await received(p, 'NRB', {numeroReceita: nr('2411.1-01.', 5, 10)})); // 5 overlap the previous lot
  assert.equal(r.estado, 'quarentena');
  assert.deepEqual(await ledger.stock(p), [{tipo: 'NRB', disponiveis: 10, reservados: 0, usados: 0, inutilizados: 0}]);
  const other = await prescriber();
  ({r} = await received(other, 'NRB', {numeroReceita: nr('2411.1-01.', 1, 10)})); // same numbers, another prescriber
  assert.equal(r.estado, 'quarentena');assert.deepEqual(await ledger.stock(other), []);
});

test('refused and uncertain requests are closed without stock; unsent intents can be discarded', async () => {
  const p = await prescriber();
  const refused = await ledger.prepare({prescritorId: p, tipo: 'NRT', quantidade: 10, chave: randomUUID()});
  await ledger.startSend(refused.id);await ledger.recordFailure(refused.id, 'recusada', 400, {message: 'Prescritor não possui saldo disponível.'}, 'sem saldo');
  await assert.rejects(ledger.recordFailure(refused.id, 'ambigua', null, null, null), /não está em envio/);
  const idle = await ledger.prepare({prescritorId: p, tipo: 'NRT', quantidade: 10, chave: randomUUID()});
  assert.equal(await ledger.discard(idle.id), true);assert.equal(await ledger.startSend(idle.id), false);
  await assert.rejects(ledger.recordFailure(idle.id, 'recebida', 200, null, null), /estado final inválido/);
  assert.deepEqual(await ledger.stock(p), []);
});

test('reservation follows lot order, is idempotent per prescription and never hands one number to two prescriptions', async () => {
  const p = await prescriber();
  await received(p, 'NRB', {numeroReceita: nr('2411.1-02.', 11, 10)});
  await received(p, 'NRB', {numeroReceita: nr('2411.1-03.', 1, 10)});
  const a = randomUUID(), b = randomUUID();
  assert.equal(await ledger.reserve(p, 'NRB', a), '2411.1-02.0000011');
  assert.equal(await ledger.reserve(p, 'NRB', a), '2411.1-02.0000011');
  assert.equal(await ledger.reserve(p, 'NRB', b), '2411.1-02.0000012');
  const same = randomUUID(), many = Array.from({length: 25}, () => randomUUID());
  const results = await Promise.all([...Array(5)].map(() => ledger.reserve(p, 'NRB', same)).concat(many.map(r => ledger.reserve(p, 'NRB', r))));
  assert.equal(new Set(results.slice(0, 5)).size, 1);
  const handed = results.slice(5).filter(Boolean);
  assert.equal(handed.length, 17);assert.equal(results.slice(5).filter(x => x === null).length, 8);
  assert.equal(new Set([...handed, results[0], '2411.1-02.0000011', '2411.1-02.0000012']).size, 20);
  assert.equal(await ledger.reserve(p, 'NRA', randomUUID()), null);
  assert.equal(await ledger.reserve(await prescriber(), 'NRB', randomUUID()), null); // another prescriber's stock is not shared
});

test('a number returns to stock only if its PDF never left the server; after that it is used or voided, never reused', async () => {
  const p = await prescriber();
  await received(p, 'NRB', {numeroReceita: nr('2411.1-04.', 1, 10)});
  const draft = randomUUID(), n1 = await ledger.reserve(p, 'NRB', draft);
  assert.equal(await ledger.giveBack(draft, 'NRB'), true);
  assert.equal((await stateOf(n1)).estado, 'disponivel');
  const rx = randomUUID(), n2 = await ledger.reserve(p, 'NRB', rx);
  assert.equal(n2, n1); // the untouched number is reused first
  assert.equal(await ledger.release(rx, 'NRB'), n2);
  assert.equal(await ledger.giveBack(rx, 'NRB'), false);
  assert.equal(await ledger.reserve(p, 'NRB', rx), n2); // retrying the signature keeps the same number
  const hash = 'b'.repeat(64);
  assert.equal(await ledger.confirmUse(rx, 'NRB', hash), n2);
  const used = await stateOf(n2);assert.equal(used.estado, 'usado');assert.equal(used.pdf_sha256, hash);assert.equal(used.liberado, true);
  await assert.rejects(ledger.void(n2, 'receita cancelada'), /não pode ser inutilizado/);
  const failed = randomUUID(), n3 = await ledger.reserve(p, 'NRB', failed);
  await ledger.release(failed, 'NRB');await ledger.void(n3, 'assinatura com resultado incerto');
  assert.equal((await stateOf(n3)).estado, 'inutilizado');
  await assert.rejects(ledger.void(n3, 'x'), LedgerError);
  const next = await ledger.reserve(p, 'NRB', randomUUID());assert.ok(![n1, n3].includes(next));
  assert.deepEqual(await ledger.stock(p), [{tipo: 'NRB', disponiveis: 7, reservados: 1, usados: 1, inutilizados: 1}]);
});

test('the database itself refuses reversals, identity changes, deletions and audit tampering', async () => {
  const p = await prescriber();
  await received(p, 'NRR', {numeroReceita: nr('2411.1-05.', 1, 10)});
  const rx = randomUUID(), n = await ledger.reserve(p, 'NRR', rx);await ledger.confirmUse(rx, 'NRR', 'c'.repeat(64));
  for (const sql of [
    `update cockpit_rx.numero set estado = 'disponivel', receita_id = null where numero = '${n}'`,
    `update cockpit_rx.numero set pdf_sha256 = '${'d'.repeat(64)}' where numero = '${n}'`,
    `update cockpit_rx.numero set sequencia = 99 where numero = '2411.1-05.0000002'`,
    `update cockpit_rx.numero set liberado = true where numero = '2411.1-05.0000003'`,
    `delete from cockpit_rx.numero where numero = '2411.1-05.0000004'`,
    `delete from cockpit_rx.solicitacao`,
    `update cockpit_rx.evento set acao = 'x'`,
    `delete from cockpit_rx.evento`,
  ]) await assert.rejects(db.query(sql), undefined, sql);
  // A second prescription can never take a used number, even by direct update.
  await assert.rejects(db.query(`update cockpit_rx.numero set receita_id = $1 where numero = $2`, [randomUUID(), n]));
  const trail = (await db.query(`select acao, depois->>'estado' as estado from cockpit_rx.evento where entidade = 'numero' and chave = $1 order by id`, [n])).rows;
  assert.deepEqual(trail.map(e => `${e.acao}:${e.estado}`), ['insert:disponivel', 'update:reservado', 'update:usado']);
});
