// SPDX-License-Identifier: AGPL-3.0-or-later
import {readFileSync} from 'node:fs';
import {randomBytes} from 'node:crypto';
import {DEST_FORMAT,destination,verifyLot,crm} from '../integracao/sncr-lote.mjs';
import {ownerOf} from './database.mjs';
import {RANGE_TYPES} from '../api/ledger.mjs';
const defaultKeys=JSON.parse(readFileSync(process.env.OPENPEP_RX_SNCR_TRUST_FILE||new URL('../integracao/sncr-portal-keys.json',import.meta.url),'utf8'));
export function createLotImporter({db,trustedKeys=defaultKeys,portal=process.env.OPENPEP_RX_SNCR_PORTAL||'https://rx.openpep.com.br'}={}){
  const portalURL=new URL(portal);
  if(portalURL.protocol!=='https:'||portalURL.origin!==portal||!portalURL.hostname.endsWith('.br'))throw Error('OPENPEP_RX_SNCR_PORTAL exige a origem HTTPS .br exata do provedor.');
  function registration(){const p=db.profile();if(!p)throw Error('Cadastre o emitente antes de transferir numeração.');return p;}
  function stockId(){
    return db.transaction(()=>{
      if(!db.setting('sncr-stock-id'))db.setSetting('sncr-stock-id',randomBytes(32).toString('hex'));
      return db.setting('sncr-stock-id');
    });
  }
  function target(){
    const p=registration();
    if(!trustedKeys.some(k=>k.issuer===portal))throw Error('Configure a chave pública do portal do seu provedor antes de obter números.');
    return destination({format:DEST_FORMAT,version:1,stock:stockId(),crm:p.crm,uf:p.uf});
  }
  async function inspect(bundle){
    const verified=await verifyLot(bundle,trustedKeys),p=registration(),{payload,request,destination:d}=verified;
    if(payload.issuer!==portal)throw Error('Este lote pertence a outro portal. Confira a configuração do provedor.');
    if(d.stock!==db.setting('sncr-stock-id'))throw Error('Este lote foi destinado a outro banco local. Use o computador e a pasta que geraram a identificação do estoque.');
    if(d.crm!==crm(p.crm)||d.uf!==p.uf)throw Error('O CRM/UF do lote não corresponde ao emitente local.');
    return {...verified,owner:ownerOf(p),summary:{id:payload.id,environment:payload.environment,type:request.tipo,quantity:verified.numbers.length,crm:d.crm,uf:d.uf,issuer:payload.issuer,issuedAt:payload.issuedAt}};
  }
  return {
    portal,
    target,
    async inspect(bundle){return (await inspect(bundle)).summary;},
    async import({bundle,confirm,confirmProduction}){
      const v=await inspect(bundle),{payload,request,numbers,digest,owner}=v;
      if(confirm!==true||(payload.environment==='prd'&&confirmProduction!==true))throw Error('Confira o lote e confirme a importação e o ambiente de produção.');
      // Signature/profile validation precedes one all-or-nothing transaction.
      return db.transaction(()=>{
        const existing=db.get('SELECT * FROM rx_requests WHERE id=?',payload.id);
        if(existing){
          if(existing.owner!==owner||existing.environment!==payload.environment||JSON.parse(existing.request)._portal?.digest!==digest)throw Error('Já existe um registro diferente para este lote. Nenhum número foi importado.');
          return {...v.summary,alreadyImported:true,status:existing.status};
        }
        if(numbers.some(n=>db.get('SELECT 1 FROM rx_numbers WHERE environment=? AND canonical=?',payload.environment,n.replace(/[.-]/g,''))))throw Error('Este lote contém números já existentes no estoque. Nenhum número foi importado.');
        const day=new Date(payload.issuedAt).toLocaleDateString('en-CA',{timeZone:'America/Sao_Paulo'}),period=RANGE_TYPES.includes(request.tipo)?day.slice(0,7):day;
        const stored={...request,_portal:{issuer:payload.issuer,destination:payload.destination.stock,keyId:v.keyId,digest}};
        db.run("INSERT INTO rx_requests(id,owner,environment,type,quantity,request,status,period,created_at,response,http,message) VALUES(?,?,?,?,?,?,'recebido',?,?,?,?,?)",payload.id,owner,payload.environment,request.tipo,request.quantidade,JSON.stringify(stored),period,payload.issuedAt,JSON.stringify(payload.result.body),payload.result.http,'Lote conferido e importado do portal.');
        for(const number of numbers)db.run("INSERT INTO rx_numbers(environment,number,canonical,type,owner,request_id,status,received_at) VALUES(?,?,?,?,?,?,'disponivel',?)",payload.environment,number,number.replace(/[.-]/g,''),request.tipo,owner,payload.id,payload.issuedAt);
        return {...v.summary,alreadyImported:false,status:'recebido'};
      });
    }
  };
}
