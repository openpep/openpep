// SPDX-License-Identifier: AGPL-3.0-or-later
// Runs in the sanitized Site checkout. Source assets never contain local data.
import {readFile,writeFile,mkdir,rm,readdir,cp} from 'node:fs/promises';
import {join,extname} from 'node:path';
import {gzipSync} from 'node:zlib';
import {build} from 'esbuild';
const types={'.html':'text/html; charset=utf-8','.js':'text/javascript','.mjs':'text/javascript','.css':'text/css','.json':'application/json','.png':'image/png','.webp':'image/webp','.ttf':'font/ttf','.pdf':'application/pdf','.wasm':'application/wasm'};
const assets={};
async function walk(dir,prefix=''){
  for(const entry of await readdir(dir,{withFileTypes:true})){
    const path=join(dir,entry.name),relative=prefix+'/'+entry.name;
    if(entry.isDirectory())await walk(path,relative);
    else{let bytes=await readFile(path);if(entry.name.endsWith('.html'))bytes=Buffer.from(bytes.toString().replace('<html lang="pt-BR"','<html lang="pt-BR" data-local="true" data-web="true"').replace('</header>','<a href="/signout-with-chatgpt?return_to=/" target="_top">Sair</a></header>'));assets[relative]={type:types[extname(path)]||'application/octet-stream',data:gzipSync(bytes).toString('base64')};}
  }
}
await walk('public');await mkdir('src',{recursive:true});await writeFile('src/asset-map.mjs','export default '+JSON.stringify(assets)+';');
await rm('dist',{recursive:true,force:true});await mkdir('dist/server',{recursive:true});
await build({entryPoints:['src/worker.mjs'],outfile:'dist/server/index.js',bundle:true,format:'esm',platform:'browser',target:'es2022',minify:true,define:{'process.env.CRX_ORIGIN':'undefined'},logLevel:'error'});
await mkdir('dist/.openai',{recursive:true});await cp('.openai/hosting.json','dist/.openai/hosting.json');await cp('drizzle','dist/.openai/drizzle',{recursive:true});
console.log('OpenPEP-Rx web: '+Object.keys(assets).length+' assets, Worker e migrações preparados.');
