import test from 'node:test';
import assert from 'node:assert/strict';
import {loadPrescriptionModule, modulePath} from '../openpep-module.mjs';
import {ssoSettings} from '../api/entry-oidc.mjs';

test('reader mounts the module launcher and its local assets under one prefix', async () => {
  const {assets, entry} = await loadPrescriptionModule();
  assert.equal(entry, modulePath);
  const html = assets.get(entry).content.toString();
  assert.match(html, /OpenPEP-Rx/);
  for (const match of html.matchAll(/(?:src|href)="([^"#:/]+\.(?:js|css|png))"/g)) {
    assert.ok(assets.has(modulePath + match[1]), match[1]);
  }
  assert.ok(assets.has(modulePath + 'domain.js'));
  assert.equal(assets.size, 15);
});

test('optional institutional launch has a fixed path and carries no session or patient data', async () => {
  const module = await loadPrescriptionModule('https://prescricao.example.org');
  assert.equal(module.entry, 'https://prescricao.example.org/');
  for (const origin of ['http://example.org', 'https://example.org/elsewhere', 'https://example.org/?q=1', 'https://a:b@example.org']) {
    await assert.rejects(loadPrescriptionModule(origin));
  }
});

test('a self-hosted OIDC deployment pins token and userinfo to its configured realm', () => {
  const issuer = 'https://login.example.org/realms/clinica';
  const env = {SSO_ISSUER: issuer, SSO_URL_TOKEN: issuer + '/protocol/openid-connect/token',
    SSO_URL_INFO: issuer + '/protocol/openid-connect/userinfo', SSO_CLIENT_ID: 'client', SSO_CLIENT_SECRET: 'example'};
  assert.equal(ssoSettings(env).issuer, issuer);
  assert.throws(() => ssoSettings({...env, SSO_ISSUER: issuer + '2'}));
  assert.throws(() => ssoSettings({...env, SSO_ISSUER: undefined}));
  assert.throws(() => ssoSettings({...env, SSO_ISSUER: '  '}));
  assert.throws(() => ssoSettings({...env, SSO_URL_INFO: 'https://login.example.org/realms/outra/protocol/openid-connect/userinfo'}));
});
