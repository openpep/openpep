// SPDX-License-Identifier: AGPL-3.0-or-later
// Explicit operator utility. Private key is never printed or put in a source checkout.
import {generateKeyPairSync,createHash} from 'node:crypto';
import {writeFile,realpath} from 'node:fs/promises';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const [issuer,directory]=process.argv.slice(2),url=new URL(issuer||'about:blank');
if(!directory||url.protocol!=='https:'||!url.hostname.endsWith('.br')||url.origin!==issuer)throw Error('Uso: node scripts/gerar-chave-portal.mjs https://rx.seu-provedor.com.br /pasta-privada-fora-do-repositorio');
const root=await realpath(resolve(dirname(fileURLToPath(import.meta.url)),'..')),out=await realpath(directory);
if(out===root||out.startsWith(root+'/'))throw Error('Escolha uma pasta privada fora do repositório.');
const {publicKey,privateKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'}),publicJwk=publicKey.export({format:'jwk'}),privateJwk=privateKey.export({format:'jwk'});
const keyId=createHash('sha256').update(JSON.stringify(publicJwk)).digest('hex').slice(0,24);
await writeFile(resolve(out,'sncr-private-jwk.json'),JSON.stringify(privateJwk),{flag:'wx',mode:0o600});
await writeFile(resolve(out,'sncr-public-keys.json'),JSON.stringify([{issuer,keyId,publicJwk}],null,2)+'\n',{flag:'wx',mode:0o600});
console.log('Chaves criadas. Configure SNCR_EXPORT_PRIVATE_JWK como segredo no servidor. Distribua somente sncr-public-keys.json. Key ID: '+keyId);
