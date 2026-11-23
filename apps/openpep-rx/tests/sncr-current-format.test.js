import test from 'node:test';
import assert from 'node:assert/strict';
import {expandRangeResponse, parseNotificationResponse} from '../api/ledger.mjs';
import {createHandler, ORIGIN, BASE_PRD} from '../api/sncr.mjs';

test('SNCR preserves 14 and 16 digits, including zeroes and numbers above JS safe integer', () => {
  for (const value of ['2611.1-35.0000001', '2611.1-35.000000001', '0011135000000001', '9911135999999999']) {
    const parsed = parseNotificationResponse({numeracoesReceita: [value]}, 10);
    assert.deepEqual(parsed.numbers, [value]);
    assert.ok(Number.isSafeInteger(parsed.sequences[0]));
  }
  const first = '9911135999999000', last = '9911135999999999';
  const range = expandRangeResponse({inicio: first, fim: last, quantidade: 1000});
  assert.equal(range.numbers[0], first);
  assert.equal(range.numbers.at(-1), last);
  assert.equal(new Set(range.numbers).size, 1000);
  const masked = expandRangeResponse({inicio: '2611.6-35.000000001', fim: '2611.6-35.000001000', quantidade: 1000});
  assert.equal(masked.numbers.at(-1), '2611.6-35.000001000');
});

test('invalid formats, mixed widths, duplicate identities and numeric JSON values stay quarantined', () => {
  for (const value of [9911135999999999, '2.611e15', '261113500000001', '2611.1-35.00000001', ' 2611135000000001']) {
    assert.ok(parseNotificationResponse({numeroReceita: [value]}, 10).error);
  }
  assert.ok(parseNotificationResponse({numeroReceita: ['2611.1-35.000000001', '2611135000000001']}, 10).error);
  for (const body of [
    {inicio: '2611.6-35.0000001', fim: '2611.6-35.000001000', quantidade: 1000},
    {inicio: '2611.6-35.000000001', fim: '2611.6-36.000001000', quantidade: 1000},
    {inicio: '2611.6-35.000000001', fim: '2611.6-35.000000999', quantidade: 1000},
  ]) assert.ok(expandRangeResponse(body).error);
});

test('new login defaults to production without calling any provider or requesting numbers', async () => {
  const rows = [];
  const handler = createHandler({store: {allow: async () => true, create: async (id, row) => { rows.push(row); return true; }}});
  let body; const headers = {};
  const res = {statusCode: 200, setHeader: (key, value) => { headers[key] = value; }, end: value => { body = value; }};
  await handler({method: 'POST', url: '/api/sncr/login', headers: {host: new URL(ORIGIN).host, origin: ORIGIN}}, res);
  assert.equal(res.statusCode, 200);
  const url = new URL(JSON.parse(body).url);
  assert.equal(url.origin + url.pathname, BASE_PRD + 'auth/login');
  assert.equal(rows[0].env, 'prd');
  assert.equal(rows[0].intent, undefined);
  assert.match(headers['Set-Cookie'], /HttpOnly; Secure; SameSite=Lax/);
});
