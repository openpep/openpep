// SPDX-FileCopyrightText: 2026 Carlos Pedrotti
// SPDX-License-Identifier: Apache-2.0
import {build} from 'esbuild';
import {writeFile, readFile} from 'node:fs/promises';
import './build-medications.mjs';
const root = new URL('../../apps/macos/OpenPEP/Resources/CockpitPDF/', import.meta.url);
const output = await build({entryPoints: [new URL('src/renderer.mjs', import.meta.url).pathname], bundle:true,
  format:'iife', globalName:'OpenPEPCockpitPDF', platform:'browser', target:'safari17', minify:true,
  legalComments:'inline', write:false, outfile:new URL('renderer.js',root).pathname});
const notices = ['@pdf-lib/fontkit\n' + await readFile(new URL('licenses/fontkit.txt',import.meta.url),'utf8')];
for (const [name,file] of [['pdf-lib','LICENSE.md'],['qrcode','license'],['dijkstrajs','LICENSE.md'],['pako','LICENSE'],['@pdf-lib/standard-fonts','LICENSE.md'],['@pdf-lib/upng','LICENSE']]) {
  notices.push(name + '\n' + await readFile(new URL(`node_modules/${name}/${file}`,import.meta.url),'utf8'));
}
for (const [name, bytes] of [['renderer.js', output.outputFiles[0].contents], ['THIRD-PARTY-NOTICES.txt', Buffer.from(notices.join('\n\n'))]]) {
  const path = new URL(name, root);
  if (process.argv.includes('--check')) {
    if (!(await readFile(path)).equals(Buffer.from(bytes))) throw Error(`${name} está desatualizado; execute npm run build --prefix tools/cockpit-pdf.`);
  } else await writeFile(path, bytes);
}
