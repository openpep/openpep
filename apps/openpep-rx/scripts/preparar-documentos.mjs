// SPDX-License-Identifier: AGPL-3.0-or-later
// Source allowlist only: no local settings, credentials, numbers or patient files.
import {cp,mkdir,readFile,writeFile} from 'node:fs/promises';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const root=resolve(dirname(fileURLToPath(import.meta.url)),'..'),out=resolve(process.argv[2]||'');
if(!process.argv[2]||out===root||root.startsWith(out+'/'))throw Error('Informe uma pasta separada para o portal de documentos.');
const mapping={'documentos/worker.mjs':'src/worker.mjs','hosted/documents.mjs':'src/documents.mjs','documentos/build-site.mjs':'build.mjs','documentos/db-schema.ts':'db/schema.ts','pdf-preview.js':'public/pdf-preview.js','documentos/index.html':'public/index.html','documentos/documentos.js':'public/documentos.js','documentos/documentos.css':'public/documentos.css','openpep.css':'public/openpep.css','assets/openpep-mark.png':'public/openpep-mark.png','LICENSE':'LICENSE','NOTICE':'NOTICE'};
for(const[from,to]of Object.entries(mapping)){await mkdir(dirname(join(out,to)),{recursive:true});await cp(join(root,from),join(out,to));}
await cp(join(root,'LICENSES'),join(out,'LICENSES'),{recursive:true});
await cp(join(root,'assets/fonts'),join(out,'public/fonts'),{recursive:true});
await writeFile(join(out,'package.json'),JSON.stringify({name:'openpep-rx-documentos',private:true,type:'module',version:'0.1.0',scripts:{build:'node build.mjs','db:generate':'drizzle-kit generate'},dependencies:{'pdfjs-dist':'6.5.438'},devDependencies:{'drizzle-kit':'0.31.10','drizzle-orm':'0.45.2',esbuild:'0.28.2'}},null,2)+'\n');
await writeFile(join(out,'drizzle.config.ts'),"import {defineConfig} from 'drizzle-kit';\nexport default defineConfig({out:'./drizzle',schema:'./db/schema.ts',dialect:'sqlite'});\n");
try{await readFile(join(out,'.gitignore'));}catch{await writeFile(join(out,'.gitignore'),'node_modules/\ndist/\nsrc/asset-map.mjs\npublic/vendor/\n.env*\n*.sqlite*\n');}
console.log('Portal de documentos preparado em '+out+'. Declare DB e BUCKET na hospedagem e configure DOCUMENT_PUBLISHERS.');
