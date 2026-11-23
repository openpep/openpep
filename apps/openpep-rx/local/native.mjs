// SPDX-License-Identifier: AGPL-3.0-or-later
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const binary = fileURLToPath(new URL('./bin/vidaas-signer', import.meta.url));

export function native(command, input) {
  if (process.platform !== 'darwin') return Promise.reject(Error('A assinatura local desta versão requer macOS e VIDaaS Connect.'));
  return new Promise((resolve, reject) => {
    const child = spawn(binary, [command], {stdio: ['pipe', 'pipe', 'ignore'], shell: false});
    const chunks = []; let size = 0, settled = false;
    const finish = (error, result) => {
      if (settled) return; settled = true; clearTimeout(timer);
      error ? reject(error) : resolve(result);
    };
    const fail = () => finish(Error('Não foi possível concluir com o VIDaaS Connect. Confira a instalação e a autorização. Não houve nova tentativa.'));
    const timer = setTimeout(() => { child.kill('SIGKILL'); fail(); }, 120_000);
    child.on('error', fail);
    child.stdin.on('error', fail);
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size > 36 * 1024 * 1024) { child.kill('SIGKILL'); fail(); } else chunks.push(chunk);
    });
    child.on('close', code => {
      if (code !== 0) return fail();
      try { finish(null, JSON.parse(Buffer.concat(chunks).toString())); } catch { fail(); }
    });
    child.stdin.end(input ? JSON.stringify(input) : undefined);
  });
}
