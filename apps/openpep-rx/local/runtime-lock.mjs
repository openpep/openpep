// SPDX-License-Identifier: AGPL-3.0-or-later
import {openSync, closeSync, readFileSync, writeFileSync, unlinkSync} from 'node:fs';
import {join} from 'node:path';
export function lockRuntime(directory) {
  const path = join(directory, 'openpep-rx.runtime.lock');
  try {
    const pid = Number(readFileSync(path, 'utf8'));
    if (!Number.isInteger(pid) || pid < 1) throw Error('Confira o arquivo de trava do serviço local.');
    let alive = true;
    try { process.kill(pid, 0); } catch (error) { if (error.code === 'ESRCH') alive = false; }
    if (alive) throw Error('Esta pasta já está em uso por outro serviço OpenPEP-Rx. Abra o serviço existente.');
    unlinkSync(path);
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const fd = openSync(path, 'wx', 0o600); writeFileSync(fd, String(process.pid)); closeSync(fd);
  return () => { try { if (readFileSync(path, 'utf8') === String(process.pid)) unlinkSync(path); } catch {} };
}
