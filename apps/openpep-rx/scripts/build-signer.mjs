// SPDX-License-Identifier: AGPL-3.0-or-later
import {mkdir, mkdtemp, rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
if (process.platform !== 'darwin') throw Error('O auxiliar nativo desta versão requer macOS e Xcode Command Line Tools.');
const root = fileURLToPath(new URL('../', import.meta.url));
await mkdir(join(root, 'local/bin'), {recursive: true});
const cache = await mkdtemp(join(tmpdir(), 'openpep-rx-swift-'));
try {
  execFileSync('xcrun', ['swiftc', '-swift-version', '6', '-O', '-module-cache-path', cache,
    join(root, 'local/VIDaaSSigner.swift'), '-o', join(root, 'local/bin/vidaas-signer')], {stdio: 'inherit'});
  // Pure byte-range and token filter checks; never consults or uses a real certificate.
  execFileSync(join(root, 'local/bin/vidaas-signer'), ['self-test'], {stdio: 'inherit'});
} finally { await rm(cache, {recursive: true, force: true}); }
