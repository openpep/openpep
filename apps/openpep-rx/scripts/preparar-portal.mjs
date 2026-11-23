// SPDX-License-Identifier: AGPL-3.0-or-later
// Copies only a source allowlist; never .env, SQLite, keys or clinical documents.
import {cp,mkdir,readFile,writeFile} from 'node:fs/promises';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..'),out=resolve(process.argv[2]||'');
if(!process.argv[2]||out===root||root.startsWith(out+'/'))throw Error('Informe uma pasta separada para o código do portal.');
const mapping={
 'hosted/worker.mjs':'src/worker.mjs','hosted/relay.mjs':'src/relay.mjs','hosted/exports.mjs':'src/exports.mjs','hosted/build-site.mjs':'build.mjs','hosted/db-schema.ts':'db/schema.ts',
 'integracao/sncr-lote.mjs':'integracao/sncr-lote.mjs',
 'api/sncr-probe.mjs':'api/sncr-probe.mjs','api/sncr-numbers.mjs':'api/sncr-numbers.mjs','api/ledger.mjs':'api/ledger.mjs','api/origin.mjs':'api/origin.mjs',
 'portal-sncr.html':'public/portal-sncr.html','portal-sncr.js':'public/portal-sncr.js','portal-sncr.css':'public/portal-sncr.css','openpep.css':'public/openpep.css','assets/openpep-mark.png':'public/openpep-mark.png','LICENSE':'LICENSE','NOTICE':'NOTICE'
};
for(const [from,to]of Object.entries(mapping)){await mkdir(dirname(join(out,to)),{recursive:true});await cp(join(root,from),join(out,to));}
await cp(join(root,'LICENSES'),join(out,'LICENSES'),{recursive:true});
await cp(join(root,'assets/fonts'),join(out,'public/fonts'),{recursive:true});
await writeFile(join(out,'package.json'),JSON.stringify({name:'openpep-rx-sncr-portal',private:true,type:'module',version:'0.1.0',scripts:{build:'node build.mjs','db:generate':'drizzle-kit generate'},devDependencies:{'drizzle-kit':'0.31.10','drizzle-orm':'0.45.2',esbuild:'0.28.2'}},null,2)+'\n');
await writeFile(join(out,'drizzle.config.ts'),"import {defineConfig} from 'drizzle-kit';\nexport default defineConfig({out:'./drizzle',schema:'./db/schema.ts',dialect:'sqlite'});\n");
// The publishing platform owns project_id. Preserve its manifest and immutable migrations.
try{await readFile(join(out,'.gitignore'));}catch{await writeFile(join(out,'.gitignore'),'node_modules/\ndist/\nsrc/asset-map.mjs\n.env*\n*.sqlite*\n');}
console.log('Portal preparado em '+out+'. Configure a hospedagem privada, DB e segredos; gere a migração antes do build.');
