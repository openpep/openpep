import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readdir} from 'node:fs/promises';

// Browser scripts are not imported by the server tests; a syntax error would only show up in the browser.
test('every published browser script parses', async () => {
  const scripts = (await readdir(new URL('../.vercel/output/static/', import.meta.url))).filter(f => f.endsWith('.js'));
  assert.ok(scripts.includes('assinatura.js') && scripts.includes('receita.js'));
  for (const file of scripts) assert.doesNotThrow(() => execFileSync(process.execPath, ['--check', new URL(`../.vercel/output/static/${file}`, import.meta.url).pathname], {stdio: 'pipe'}), file);
});
