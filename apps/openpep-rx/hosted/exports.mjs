// SPDX-License-Identifier: AGPL-3.0-or-later
import {lotPayload,sealLot} from '../integracao/sncr-lote.mjs';
export async function signingConfig(env){
  try{
    if(!/^[a-zA-Z0-9_-]{8,80}$/.test(env.SNCR_EXPORT_KEY_ID||''))throw Error('key');
    const privateJwk=JSON.parse(env.SNCR_EXPORT_PRIVATE_JWK||'null');
    await crypto.subtle.importKey('jwk',privateJwk,{name:'ECDSA',namedCurve:'P-256'},false,['sign']);
    return {keyId:env.SNCR_EXPORT_KEY_ID,privateJwk};
  }catch{throw Error('O provedor precisa configurar uma chave válida para assinar os lotes.');}
}
export function portalOrigin(env){
  const value=env.SNCR_PORTAL_ORIGIN||'https://rx.openpep.com.br',url=new URL(value);
  if(url.protocol!=='https:'||!url.hostname.endsWith('.br')||url.origin!==value)throw Error('Configure o domínio HTTPS .br do portal.');
  return value;
}
export async function exportLot(row,db,env){
  const intent=JSON.parse(row.intent);
  if(intent.mode!=='portal')throw Error('Este pedido pertence ao fluxo anterior e deve ser recuperado no banco local original.');
  if(row.status!=='concluido'||!row.result)throw Error('O pedido ainda não tem resultado confirmado. Confira o histórico antes de solicitar novamente.');
  const existing=await db.prepare('SELECT package FROM rx_exports WHERE id=?').bind(row.id).first();
  if(existing)return JSON.parse(existing.package);
  const payload={version:1,issuer:portalOrigin(env),id:row.id,destination:intent.destination,environment:intent.environment,request:intent.request,issuedAt:row.completed_at,result:JSON.parse(row.result)};
  const {numbers}=lotPayload(payload);
  const bundle=await sealLot(payload,await signingConfig(env));
  try{
    // D1 batch is transactional. No file is released before its destination and
    // every canonical number are durably registered. Redownload uses exact bytes.
    await db.batch([
      db.prepare('INSERT INTO rx_exports(id,destination,package,created_at) VALUES(?,?,?,?)').bind(row.id,intent.destination.stock,JSON.stringify(bundle),Date.now()),
      db.prepare("INSERT INTO rx_export_numbers(environment,canonical,export_id) SELECT ?,replace(replace(value,'.',''),'-',''),? FROM json_each(?)").bind(row.environment,row.id,JSON.stringify(numbers))
    ]);
  }catch{
    const saved=await db.prepare('SELECT package FROM rx_exports WHERE id=?').bind(row.id).first();
    if(saved)return JSON.parse(saved.package);
    throw Error('Não foi possível registrar a entrega: pode haver numeração repetida. O resultado foi preservado; não repita o pedido ao SNCR.');
  }
  return bundle;
}
