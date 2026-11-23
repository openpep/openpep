// SPDX-License-Identifier: AGPL-3.0-or-later
import {randomBytes} from 'node:crypto';
import {sha} from './database.mjs';
import {shortId} from '../api/receita-doc.mjs';
export function createPublications({db,fetcher=fetch,origin=process.env.OPENPEP_RX_DOCUMENTS_URL||'',token=process.env.OPENPEP_RX_DOCUMENTS_TOKEN||'',previousOrigins=process.env.OPENPEP_RX_DOCUMENTS_PREVIOUS_ORIGINS||'',allowLoopback=false}={}){
  const configured=Boolean(origin&&token);
  if(configured){const u=new URL(origin);if(u.origin!==origin||u.username||u.password||(!(u.protocol==='https:')&&!(allowLoopback&&u.hostname==='127.0.0.1'&&u.protocol==='http:'))||!/^[a-f0-9]{64}$/.test(token))throw Error('Confira a configuração do portal de documentos.');}
  const aliases=new Set(previousOrigins.split(',').map(s=>s.trim()).filter(Boolean));
  for(const alias of aliases){const u=new URL(alias);if(u.origin!==alias||u.protocol!=='https:'||u.username||u.password)throw Error('Confira os domínios anteriores do portal.');}
  const samePortal=r=>r.origin===origin||aliases.has(r.origin);
  const row=id=>db.get('SELECT * FROM rx_publications WHERE document_id=?',id);
  const url=(r,canonical=false)=>(canonical&&configured&&samePortal(r)?origin:r.origin)+'/r/'+shortId(r.document_id)+'#'+r.link_token;
  function reserve(id){
    if(!configured)throw Error('O portal de documentos ainda não foi configurado neste computador.');
    let record=row(id);
    if(record){if(!samePortal(record))throw Error('Este documento pertence ao portal configurado na sua criação.');if(record.status==='revogado')throw Error('O link deste documento foi revogado.');return record;}
    db.run("INSERT INTO rx_publications(document_id,origin,link_token,status,updated_at) VALUES(?,?,?,'pendente',?)",id,origin,randomBytes(16).toString('hex').toUpperCase(),Date.now());return row(id);
  }
  function info(id){const r=row(id);return {configured,origin:origin||null,status:r?.status||'local',url:r?.status==='publicado'?url(r,true):null,error:r?.last_error||null};}
  async function request(path,options){return fetcher(origin+path,{...options,headers:{...options.headers,Authorization:'Bearer '+token},redirect:'error',signal:AbortSignal.timeout(30000)});}
  return {config:()=>({configured,origin:origin||null}),info,
    plan(id){return url(reserve(id));},
    async publish(id,pdf,confirm){
      if(confirm!==true)throw Error('Confirme a publicação deste PDF no portal.');
      const r=reserve(id),hash=sha(pdf);
      if(r.pdf_hash&&r.pdf_hash!==hash)throw Error('O conteúdo deste documento mudou. A publicação não pode substituir um PDF.');
      if(r.status==='publicado')return info(id);
      // Bind the exact signed bytes before the first network attempt; retries are idempotent.
      db.run('UPDATE rx_publications SET pdf_hash=?,last_error=NULL,updated_at=? WHERE document_id=?',hash,Date.now(),id);
      try{
        const response=await request('/api/documents/'+shortId(id),{method:'POST',headers:{'Content-Type':'application/pdf','X-Document-Access-Hash':sha(r.link_token)},body:pdf});
        const answer=await response.json();if(!response.ok||answer.hash!==hash||answer.published!==true)throw Error('publish');
        db.run("UPDATE rx_publications SET status='publicado',last_error=NULL,updated_at=? WHERE document_id=?",Date.now(),id);
      }catch{
        db.run("UPDATE rx_publications SET last_error=?,updated_at=? WHERE document_id=?",'O PDF está assinado e salvo localmente. A publicação não foi confirmada; tente publicar novamente sem assinar outra vez.',Date.now(),id);
      }
      return info(id);
    },
    async revoke(id,confirm){
      if(confirm!==true)throw Error('Confirme a desativação deste link.');
      const r=row(id);if(!r||!configured||!samePortal(r))throw Error('Publicação indisponível.');
      const response=await request('/api/documents/'+shortId(id)+'/revoke',{method:'POST'});
      if(!response.ok)throw Error('Não foi possível confirmar a desativação. Tente novamente.');
      db.run("UPDATE rx_publications SET status='revogado',last_error=NULL,updated_at=? WHERE document_id=?",Date.now(),id);return info(id);
    }
  };
}
