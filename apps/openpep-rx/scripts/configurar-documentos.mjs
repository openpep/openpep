// SPDX-License-Identifier: AGPL-3.0-or-later
// Stores the upload secret locally; prints only its server-side hash for provisioning.
import {readFile,writeFile,rename,chmod} from 'node:fs/promises';
import {randomBytes,createHash} from 'node:crypto';
const origin=process.argv[2],u=new URL(origin);
if(u.origin!==origin||u.protocol!=='https:'||u.username||u.password)throw Error('Informe a origem HTTPS do portal, sem caminho nem barra final.');
let env=await readFile('.env','utf8').catch(e=>{if(e.code==='ENOENT')return '';throw e;});
if(/^OPENPEP_RX_DOCUMENTS_TOKEN=.+$/m.test(env))throw Error('Já existe uma credencial de publicação. Preserve-a; siga a documentação para trocar o provedor.');
const token=randomBytes(32).toString('hex'),id=randomBytes(12).toString('hex');
for(const[key,value]of Object.entries({OPENPEP_RX_DOCUMENTS_URL:origin,OPENPEP_RX_DOCUMENTS_TOKEN:token})){
 const line=key+'='+value,pattern=new RegExp('^'+key+'=.*$','m');env=pattern.test(env)?env.replace(pattern,line):env.replace(/\n?$/,'\n')+line+'\n';
}
await writeFile('.env.documents.tmp',env,{mode:0o600});await chmod('.env.documents.tmp',0o600);await rename('.env.documents.tmp','.env');
console.log(JSON.stringify([{id,tokenHash:createHash('sha256').update(token).digest('hex')} ]));
