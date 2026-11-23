// SPDX-License-Identifier: AGPL-3.0-or-later
const MAX=20*1024*1024,ID=/^[A-Z2-7]{26}$/,HASH=/^[a-f0-9]{64}$/,KEY=/^[A-F0-9]{32}$/;
const headers={'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff','X-Robots-Tag':'noindex, nofollow, noarchive','Content-Security-Policy':"default-src 'none'; frame-ancestors 'self'; sandbox"};
const json=(value,status=200)=>new Response(JSON.stringify(value),{status,headers:{...headers,'Content-Type':'application/json'}});
const sha=async bytes=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
async function read(request,max){const chunks=[];let length=0;const reader=request.body?.getReader();if(!reader)return new Uint8Array();try{while(true){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>max)throw Error('size');chunks.push(value);}const bytes=new Uint8Array(length);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}return bytes;}finally{await reader.cancel().catch(()=>{});}}
export function createDocuments({now=Date.now}={}){return async(request,env)=>{
  const url=new URL(request.url),match=/^\/api\/documents\/([A-Z2-7]{26})(?:\/(access|revoke|validation))?$/.exec(url.pathname),temporary=/^\/api\/validation\/([a-f0-9]{64})\.pdf$/.exec(url.pathname);
  const db=env.DB;
  try{
    async function original(row){
      const object=await env.BUCKET.get(row.object_key);if(!object)return json({error:'Documento temporariamente indisponível.'},503);
      const pdf=new Uint8Array(await object.arrayBuffer());if(await sha(pdf)!==row.pdf_hash)return json({error:'Documento temporariamente indisponível.'},503);
      return new Response(request.method==='HEAD'?null:pdf,{headers:{...headers,'Content-Type':'application/pdf','Content-Length':String(pdf.length),'Content-Disposition':'inline; filename="openpep-rx-assinado.pdf"','X-Document-SHA256':row.pdf_hash}});
    }
    if(temporary&&['GET','HEAD'].includes(request.method)&&!url.search){
      const row=await db.prepare('SELECT d.* FROM documents d JOIN document_validations v ON v.document_id=d.id WHERE v.token_hash=? AND v.expires_at>? AND d.revoked_at IS NULL').bind(await sha(new TextEncoder().encode(temporary[1])),now()).first();
      return row?await original(row):json({error:'Link expirado ou indisponível. Gere outro link na página do documento.'},404);
    }
    if(!match||request.method!=='POST'||url.search)return json({error:'Documento indisponível.'},404);
    const [,id,operation]=match;
    if(operation==='access'||operation==='validation'){
      if(request.headers.get('origin')!==url.origin||request.headers.get('content-type')!=='application/json')return json({error:'Documento indisponível.'},404);
      const body=JSON.parse(new TextDecoder().decode(await read(request,512)));if(!KEY.test(body.token||''))return json({error:'Documento indisponível.'},404);
      const keyHash=await sha(new TextEncoder().encode(body.token));
      const row=await db.prepare('SELECT * FROM documents WHERE id=? AND access_hash=? AND revoked_at IS NULL').bind(id,keyHash).first();
      if(!row)return json({error:'Documento indisponível. Confira o link completo ou solicite orientação ao emitente.'},404);
      if(operation==='validation'){
        const code=Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join(''),expires=now()+15*60*1000;
        // One temporary capability per document bounds storage. Only its hash is retained.
        await db.prepare('INSERT INTO document_validations(document_id,token_hash,expires_at) VALUES(?,?,?) ON CONFLICT(document_id) DO UPDATE SET token_hash=excluded.token_hash,expires_at=excluded.expires_at').bind(id,await sha(new TextEncoder().encode(code)),expires).run();
        return json({url:url.origin+'/api/validation/'+code+'.pdf',expiresAt:expires});
      }
      return await original(row);
    }
    // Publisher credentials are sent only by the local server, never by browser code.
    const bearer=request.headers.get('authorization')||'';if(!/^Bearer [a-f0-9]{64}$/.test(bearer))return json({error:'Publicação não autorizada.'},401);
    const tokenHash=await sha(new TextEncoder().encode(bearer.slice(7))),publishers=JSON.parse(env.DOCUMENT_PUBLISHERS||'[]');
    const publisher=publishers.find(p=>HASH.test(p.tokenHash||'')&&p.tokenHash===tokenHash&&/^[a-zA-Z0-9_-]{8,80}$/.test(p.id||''));
    if(!publisher)return json({error:'Publicação não autorizada.'},401);
    const existing=await db.prepare('SELECT * FROM documents WHERE id=?').bind(id).first();
    if(operation==='revoke'){
      if(!existing||existing.publisher!==publisher.id)return json({error:'Documento indisponível.'},404);
      await db.prepare('UPDATE documents SET revoked_at=COALESCE(revoked_at,?) WHERE id=? AND publisher=?').bind(Date.now(),id,publisher.id).run();
      return json({id,revoked:true});
    }
    const accessHash=request.headers.get('x-document-access-hash');
    if(!HASH.test(accessHash||'')||request.headers.get('content-type')!=='application/pdf')return json({error:'Confira o arquivo de publicação.'},422);
    const pdf=await read(request,MAX),pdfHash=await sha(pdf);
    if(new TextDecoder().decode(pdf.subarray(0,5))!=='%PDF-')return json({error:'Confira o arquivo PDF.'},422);
    const matches=row=>row&&row.publisher===publisher.id&&row.access_hash===accessHash&&row.pdf_hash===pdfHash&&!row.revoked_at;
    if(existing)return matches(existing)?json({id,hash:pdfHash,published:true}):json({error:'Este identificador já pertence a outro conteúdo ou foi revogado.'},409);
    const objectKey='documents/'+crypto.randomUUID();
    await env.BUCKET.put(objectKey,pdf,{httpMetadata:{contentType:'application/pdf'}});
    try{
      await db.prepare('INSERT INTO documents(id,publisher,access_hash,pdf_hash,object_key,bytes,created_at) VALUES(?,?,?,?,?,?,?)').bind(id,publisher.id,accessHash,pdfHash,objectKey,pdf.length,Date.now()).run();
    }catch{
      const saved=await db.prepare('SELECT * FROM documents WHERE id=?').bind(id).first();
      if(saved?.object_key!==objectKey)await env.BUCKET.delete(objectKey);
      return matches(saved)?json({id,hash:pdfHash,published:true}):json({error:'Publicação não confirmada. Tente novamente o mesmo documento.'},409);
    }
    return json({id,hash:pdfHash,published:true},201);
  }catch{return json({error:'Não foi possível concluir. Tente novamente o mesmo documento.'},503);}
};}
