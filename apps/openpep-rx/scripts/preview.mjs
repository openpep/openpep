// Generate a portable preview of the same offline module for opening without a server.
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';

const root = new URL('../', import.meta.url);
const read = (name, encoding = 'utf8') => readFile(new URL(name, root), encoding);
const script = await build({entryPoints: [fileURLToPath(new URL('inicio.js', root))], bundle: true, write: false, format: 'iife'});
const mark = 'data:image/png;base64,' + await read('assets/openpep-mark.png', 'base64');
let html = await read('index.html');
html = html.replaceAll('href="assinatura.html"', 'href="http://127.0.0.1:4197/assinatura.html"');
html = html.replaceAll('="openpep-mark.png"', '="' + mark + '"');
for (const name of ['inicio.css', 'openpep.css']) {
  html = html.replace('<link rel="stylesheet" href="' + name + '">', '<style>' + await read(name) + '</style>');
}
html = html.replace('<script type="module" src="inicio.js"></script>', () => '<script>' + script.outputFiles[0].text + '</script>');
await mkdir(new URL('dist/', root), {recursive: true});
await writeFile(new URL('dist/openpep-rx.html', root), html);
