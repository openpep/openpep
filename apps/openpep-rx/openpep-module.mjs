// SPDX-License-Identifier: AGPL-3.0-or-later
import { readFile } from 'node:fs/promises';

export const modulePath = '/modulos/prescricao/';

// The reader mounts the launcher; the configured local origin opens the complete prescription flow.
const editorFiles = [
  ['local-client.js', 'local-client.js', 'text/javascript; charset=utf-8'],
  ['inicio.css', 'inicio.css', 'text/css; charset=utf-8'],
  ['inicio.js', 'inicio.js', 'text/javascript; charset=utf-8'],
  ['index.html', 'index.html', 'text/html; charset=utf-8'],
  ['assinatura.html', 'assinatura.html', 'text/html; charset=utf-8'],
  ['assinatura-local.pdf', 'fixtures/assinatura-local.pdf', 'application/pdf'],
  ['assinatura.js', 'assinatura.js', 'text/javascript; charset=utf-8'],
  ['assinatura.css', 'assinatura.css', 'text/css; charset=utf-8'],
  ['app.js', 'app.js', 'text/javascript; charset=utf-8'],
  ['domain.js', 'domain.js', 'text/javascript; charset=utf-8'],
  ['pdf-preview.js', 'pdf-preview.js', 'text/javascript; charset=utf-8'],
  ['styles.css', 'styles.css', 'text/css; charset=utf-8'],
  ['openpep.css', 'openpep.css', 'text/css; charset=utf-8'],
  ['openpep-mark.png', 'assets/openpep-mark.png', 'image/png'],
];

export async function loadPrescriptionModule(institutionalOrigin) {
  let entry = modulePath;
  if (institutionalOrigin) {
    const url = new URL(institutionalOrigin);
    if ((url.protocol !== 'https:' && !(url.protocol === 'http:' && url.hostname === '127.0.0.1')) || url.username || url.password || url.href !== url.origin + '/') {
      throw new Error('OPENPEP_RX_ORIGIN deve conter uma origem HTTPS ou HTTP em 127.0.0.1 para o módulo local.');
    }
    entry = url.origin + '/';
  }
  const assets = new Map();
  for (const [name, file, type] of editorFiles) {
    const content = await readFile(new URL(file, import.meta.url));
    assets.set(modulePath + name, {content, type});
  }
  assets.set(modulePath, assets.get(modulePath + 'index.html'));
  return {assets, entry};
}
