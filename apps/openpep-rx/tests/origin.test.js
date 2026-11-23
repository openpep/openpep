import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile} from 'node:fs/promises';
import {originFrom, DEFAULT_ORIGIN, ORIGIN} from '../api/origin.mjs';

test('CRX_ORIGIN: default is the current domain; only a bare https origin is accepted', () => {
  assert.equal(originFrom(undefined), DEFAULT_ORIGIN);assert.equal(originFrom(''), DEFAULT_ORIGIN);
  assert.equal(originFrom('https://rx.example.org'), 'https://rx.example.org');assert.equal(originFrom('https://rx.example.org/'), 'https://rx.example.org');
  for (const bad of ['http://rx.example.org', 'https://rx.example.org/app', 'https://rx.example.org:8443', 'https://u:p@rx.example.org', 'https://rx.example.org/?x=1', 'rx.example.org']) assert.throws(() => originFrom(bad), bad);
});
test('CRX_ORIGIN reaches every server-side use: callbacks, host checks and the address printed on the prescription', () => {
  const code = `
    const o = await import('./api/origin.mjs'), p = await import('./api/sncr-probe.mjs'), s = await import('./api/sncr.mjs'), oidc = await import('./api/entry-oidc.mjs'), r = await import('./api/receita.mjs');
    console.log(JSON.stringify({origin: o.ORIGIN, host: o.HOST, callback: p.CALLBACK, sncr: s.ORIGIN, sso: oidc.SSO_CALLBACK, link: r.accessLink('00000000-0000-4000-8000-000000000001', '123456')}));`;
  const out = JSON.parse(execFileSync(process.execPath, ['--input-type=module', '-e', code], {env: {...process.env, CRX_ORIGIN: 'https://rx.example.org'}, encoding: 'utf8'}));
  assert.deepEqual({...out, link: out.link.replace(/\/r\/.*#/, '/r/…#')}, {origin: 'https://rx.example.org', host: 'rx.example.org', callback: 'https://rx.example.org/', sncr: 'https://rx.example.org', sso: 'https://rx.example.org/api/entrada/callback', link: 'https://rx.example.org/r/…#123456'});
  assert.throws(() => execFileSync(process.execPath, ['--input-type=module', '-e', "await import('./api/origin.mjs')"], {env: {...process.env, CRX_ORIGIN: 'http://inseguro.br'}, stdio: 'pipe'}));
});
test('no hard-coded domain left outside api/origin.mjs; the build writes the configured origin into pages and edge bundles read it at runtime', async () => {
  for (const f of ['api/entry-oidc.mjs', 'api/receita.mjs', 'api/receita-doc.mjs', 'api/sncr-probe.mjs', 'api/sncr-return.mjs', 'api/sncr.mjs', 'api/sncr-callback-edge.mjs', 'api/sncr-probe-edge.mjs'])
    assert.ok(!(await readFile(f, 'utf8')).includes('rx-hml.openpep.com.br'), f);
  assert.ok((await readFile('.vercel/output/static/sncr.js', 'utf8')).includes(ORIGIN));
  for (const f of ['api/sncr/callback-edge.func', 'api/sncr/sondar-edge.func']) assert.ok(JSON.parse(await readFile(`.vercel/output/functions/${f}/.vc-config.json`, 'utf8')).envVarsInUse.includes('CRX_ORIGIN'), f);
  for (const f of ['api/sncr/login.func', 'index.func']) await readFile(`.vercel/output/functions/${f}/origin.mjs`);
});
