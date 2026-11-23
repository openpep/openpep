// SPDX-License-Identifier: AGPL-3.0-or-later
import {NR_TYPES, RANGE_TYPES, parseNotificationResponse, expandRangeResponse} from '../api/ledger.mjs';
export const LOT_FORMAT='openpep-rx.sncr-lote', DEST_FORMAT='openpep-rx.estoque';
export const MAX_LOT_BYTES=400000;
export const crm=value=>String(value||'').replace(/^0+(?=\d)/,'');
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const ufs='AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO'.split(' ');
const encode=bytes=>btoa(Array.from(bytes,b=>String.fromCharCode(b)).join('')).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
function decode(value,max){
  if(typeof value!=='string'||value.length>max||!/^[A-Za-z0-9_-]+$/.test(value))throw Error('Arquivo de lote inválido.');
  const bytes=Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')),c=>c.charCodeAt(0));
  if(encode(bytes)!==value)throw Error('Arquivo de lote inválido.');
  return bytes;
}
export function destination(value){
  if(value?.format!==DEST_FORMAT||value.version!==1||!/^\d{1,10}$/.test(value.crm||'')||!ufs.includes(value.uf)||!/^[a-f0-9]{64}$/.test(value.stock||''))throw Error('Selecione a identificação do estoque baixada no OpenPEP-Rx local.');
  return {format:DEST_FORMAT,version:1,stock:value.stock,crm:crm(value.crm),uf:value.uf};
}
export function numbersRequest(value){
  const r=value||{},range=RANGE_TYPES.includes(r.tipo);
  if((!range&&!NR_TYPES.includes(r.tipo))||r.conselho!=='CRM'||!/^\d{1,10}$/.test(r.documento||'')||!ufs.includes(r.uf)||!Number.isInteger(r.quantidade)||(range?r.quantidade!==1000||!/^\d{14}$/.test(r.cnpj||''):r.quantidade<10||r.quantidade>50))throw Error('Confira tipo, quantidade, CRM/UF e CNPJ da plataforma.');
  return {tipo:r.tipo,quantidade:r.quantidade,conselho:'CRM',uf:r.uf,documento:crm(r.documento),...(range?{cnpj:r.cnpj}:{})};
}
export function lotPayload(value){
  const d=destination(value?.destination),r=numbersRequest(value?.request);
  if(value.version!==1||!uuid.test(value.id||'')||!['prd','hmg'].includes(value.environment)||d.crm!==r.documento||d.uf!==r.uf||!Number.isSafeInteger(value.issuedAt)||value.issuedAt<=0)throw Error('Dados do lote inválidos.');
  if(value.result?.kind!=='success'||!Number.isInteger(value.result.http)||value.result.http<200||value.result.http>=300||value.result.http===204)throw Error('Este pedido não tem numeração confirmada para importação.');
  const parsed=RANGE_TYPES.includes(r.tipo)?expandRangeResponse(value.result.body,r.quantidade):parseNotificationResponse(value.result.body,r.quantidade);
  if(parsed.error)throw Error('Numeração em conferência: '+parsed.error+'. Não repita a solicitação.');
  return {payload:value,numbers:parsed.numbers,request:r,destination:d};
}
export async function sealLot(payload,{keyId,privateJwk}){
  lotPayload(payload);
  if(!/^[a-zA-Z0-9_-]{8,80}$/.test(keyId||''))throw Error('Chave de exportação não configurada.');
  const bytes=new TextEncoder().encode(JSON.stringify(payload));
  if(bytes.length>280000)throw Error('Lote acima do limite.');
  const key=await crypto.subtle.importKey('jwk',privateJwk,{name:'ECDSA',namedCurve:'P-256'},false,['sign']);
  const signature=await crypto.subtle.sign({name:'ECDSA',hash:'SHA-256'},key,bytes);
  return {format:LOT_FORMAT,version:1,keyId,payload:encode(bytes),signature:encode(new Uint8Array(signature))};
}
export async function verifyLot(bundle,trustedKeys){
  if(!bundle||JSON.stringify(bundle).length>MAX_LOT_BYTES||bundle.format!==LOT_FORMAT||bundle.version!==1)throw Error('Selecione um lote assinado pelo portal do seu provedor.');
  const trust=trustedKeys.find(k=>k.keyId===bundle.keyId);
  if(!trust)throw Error('Chave do portal não reconhecida. Confira o provedor configurado nesta instalação.');
  const bytes=decode(bundle.payload,380000),signature=decode(bundle.signature,100);
  const key=await crypto.subtle.importKey('jwk',trust.publicJwk,{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
  if(signature.length!==64||!await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},key,signature,bytes))throw Error('Assinatura do lote inválida. O arquivo foi alterado ou não veio do portal configurado.');
  const value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  if(value.issuer!==trust.issuer)throw Error('Este lote pertence a outro provedor.');
  const checked=lotPayload(value);
  const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
  return {...checked,digest,keyId:bundle.keyId};
}
