// SPDX-License-Identifier: AGPL-3.0-or-later
import {GATEWAYS,blockedByCloudflare} from '../api/sncr-probe.mjs';
import {NR_TYPES,RANGE_TYPES} from '../api/ledger.mjs';
import {postNumbers} from '../api/sncr-numbers.mjs';
import {destination,numbersRequest,lotPayload} from '../integracao/sncr-lote.mjs';
import {exportLot,portalOrigin,signingConfig} from './exports.mjs';
const TTL=300000,COOKIE='__Host-openpep-rx-sncr';
// Each signed-in account may open at most START_LIMIT SNCR logins per START_WINDOW.
export const START_LIMIT=10,START_WINDOW=3600_000;
const hex=()=>Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
const hash=async text=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text))),b=>b.toString(16).padStart(2,'0')).join('');
const equal=(a,b)=>typeof a==='string'&&typeof b==='string'&&a.length===b.length&&[...a].reduce((d,c,i)=>d|(c.charCodeAt(0)^b.charCodeAt(i)),0)===0;
const headers={'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'};
const json=(data,status=200,extra={})=>new Response(JSON.stringify(data),{status,headers:{...headers,'Content-Type':'application/json; charset=utf-8',...extra}});
const cookie=request=>{const entries=(request.headers.get('cookie')||'').split(';').map(s=>s.trim()).filter(s=>s.startsWith(COOKIE+'='));return entries.length===1?entries[0].slice(COOKIE.length+1):'';};
async function bounded(response,max){let size=0,out='';const reader=response.body?.getReader();if(!reader)return '';const decoder=new TextDecoder();try{while(true){const {value,done}=await reader.read();if(done)break;size+=value.byteLength;if(size>max)throw Error('Resposta acima do limite.');out+=decoder.decode(value,{stream:true});}return out+decoder.decode();}finally{await reader.cancel().catch(()=>{});}}
function checked(body){
  if(!/^[a-f0-9-]{36}$/.test(body.id||'')||!/^[a-f0-9]{64}$/.test(body.receipt||'')||!['hmg','prd'].includes(body.environment))throw Error('Pedido local inválido.');
  const r=body.request||{},range=RANGE_TYPES.includes(r.tipo);
  if((!range&&!NR_TYPES.includes(r.tipo))||r.conselho!=='CRM'||!/^\d{1,10}$/.test(r.documento||'')||!'AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO'.split(' ').includes(r.uf)||!Number.isInteger(r.quantidade)|| (range ? r.quantidade!==1000||!/^\d{14}$/.test(r.cnpj||'') : r.quantidade<10||r.quantidade>50))throw Error('Confira o pedido de numeração.');
  return {id:body.id,receipt:body.receipt,environment:body.environment,request:{tipo:r.tipo,quantidade:r.quantidade,conselho:'CRM',uf:r.uf,documento:r.documento,...(range?{cnpj:r.cnpj}:{})}};
}
export function createRelay({fetcher=fetch,now=Date.now}={}){
  return async(request,env)=>{
    const url=new URL(request.url),user=request.headers.get('oai-authenticated-user-id'),origin=url.origin,db=env.DB;
    if(!user)return json({error:'Entre com sua conta do ChatGPT.'},401);
    if(request.method==='POST'&&(request.headers.get('origin')!==origin||request.headers.get('content-type')!=='application/json'))return json({error:'Origem ou formato inválido.'},403);
    try{
    if(url.pathname==='/api/relay/meta')return json({enabled:origin===portalOrigin(env),origin,canonical:portalOrigin(env),exportReady:Boolean(env.SNCR_EXPORT_PRIVATE_JWK&&env.SNCR_EXPORT_KEY_ID)});
      if(['/api/relay/start','/api/relay/portal/start'].includes(url.pathname)&&request.method==='POST'){
        if(url.protocol!=='https:'||!url.hostname.endsWith('.br'))return json({error:'Abra o domínio HTTPS .br configurado pelo seu provedor para usar o SNCR.'},422);
        const body=JSON.parse(await bounded(request,8192)),intent=checked(body);
        if(url.pathname==='/api/relay/portal/start'){
          if(origin!==portalOrigin(env)||!env.SNCR_EXPORT_PRIVATE_JWK||!env.SNCR_EXPORT_KEY_ID)throw Error('O portal ainda não está configurado para exportar lotes.');
          await signingConfig(env);
          intent.mode='portal';intent.destination=destination(body.destination);intent.request=numbersRequest(body.request);
          if(intent.destination.crm!==intent.request.documento||intent.destination.uf!==intent.request.uf)throw Error('O CRM/UF deve corresponder ao estoque de destino.');
        }
        if(body.confirm!==true||(intent.environment==='prd'&&body.confirmProduction!==true))throw Error('Confirme o pedido e o ambiente de produção.');
        const time=now(),day=new Date(time).toLocaleDateString('en-CA',{timeZone:'America/Sao_Paulo'}),range=RANGE_TYPES.includes(intent.request.tipo),period=range?day.slice(0,7):day;
        const existing=await db.prepare('SELECT id,status,intent FROM rx_relay WHERE local_id=? AND user_id=?').bind(intent.id,user).first();
        if(existing){if(JSON.stringify(intent)!==existing.intent)throw Error('Pedido já registrado com outros dados.');return json({id:existing.id,pending:true});}
        await db.prepare("UPDATE rx_relay SET status='concluido',result_kind='not-sent',result=? WHERE status='aguardando' AND created_at<?").bind(JSON.stringify({kind:'not-sent',http:null,body:null,message:'Login expirado; nenhum pedido de números foi enviado.'}),time-TTL).run();
        const id=crypto.randomUUID(),state=hex(),prescriber=await hash(intent.request.documento+'|'+intent.request.uf),stateHash=await hash(state);
        // One atomic conditional INSERT enforces the quota across concurrent requests.
        const added=await db.prepare(`INSERT INTO rx_relay (id,local_id,user_id,prescriber,environment,type,quantity,period,intent,state_hash,status,created_at)
          SELECT ?,?,?,?,?,?,?,?,?,?,'aguardando',? WHERE (SELECT ${range?'COUNT(*)':'COALESCE(SUM(quantity),0)'} FROM rx_relay WHERE prescriber=? AND environment=? AND type=? AND period=? AND (result_kind IS NULL OR result_kind NOT IN ('not-sent','refused'))) < ? AND NOT EXISTS (SELECT 1 FROM rx_relay WHERE local_id=?) AND (SELECT COUNT(*) FROM rx_relay WHERE user_id=? AND created_at>?) < ?`).bind(id,intent.id,user,prescriber,intent.environment,intent.request.tipo,intent.request.quantidade,period,JSON.stringify(intent),stateHash,time,prescriber,intent.environment,intent.request.tipo,period,range?3:51-intent.request.quantidade,intent.id,user,time-START_WINDOW,START_LIMIT).run();
        if(added.meta.changes!==1){
          const recent=await db.prepare('SELECT COUNT(*) AS n FROM rx_relay WHERE user_id=? AND created_at>?').bind(user,time-START_WINDOW).first();
          if(recent.n>=START_LIMIT)return json({error:'Muitos pedidos iniciados nesta conta na última hora. Aguarde e confira o histórico antes de tentar novamente.'},429,{'Retry-After':'3600'});
          throw Error('Há um pedido pendente ou o limite deste período foi atingido. Confira o histórico.');
        }
        const login=new URL('auth/login',GATEWAYS[intent.environment]);login.searchParams.set('client_url',origin+'/sncr/retorno');login.searchParams.set('state',state);
        return json({id,url:login.href},200,{'Set-Cookie':`${COOKIE}=${state}; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=300`});
      }
      if(url.pathname==='/sncr/retorno'&&request.method==='GET'){
        const state=url.searchParams.get('state'),session=url.searchParams.get('session_id');
        if(!/^[a-f0-9]{64}$/.test(state||'')||!equal(state,cookie(request))||url.searchParams.getAll('state').length!==1||url.searchParams.getAll('session_id').length!==1||!/^[\x21-\x7e]{1,4096}$/.test(session||'')||url.searchParams.has('error'))throw Error('Retorno do SNCR inválido. Confira o histórico antes de tentar novamente.');
        const row=await db.prepare("UPDATE rx_relay SET status='autenticando',state_hash=NULL WHERE state_hash=? AND user_id=? AND status='aguardando' AND created_at>=? AND created_at<=? RETURNING *").bind(await hash(state),user,now()-TTL,now()).first();
        if(!row)throw Error('Retorno expirado ou já utilizado. Confira o histórico.');
        const intent=JSON.parse(row.intent);let result,http=null,sending=false;
        try{
          const tokenURL=new URL('auth/token',GATEWAYS[intent.environment]);tokenURL.searchParams.set('session_id',session);
          const r=await fetcher(tokenURL,{headers:{Accept:'application/json',Origin:origin},redirect:'manual',signal:AbortSignal.timeout(10000)});http=r.status;
          if(!r.ok||!/^application\/json\b/i.test(r.headers.get('content-type')||'')){
            result={kind:'not-sent',http,body:null,message:(blockedByCloudflare(r)?'A proteção de rede do SNCR bloqueou a autenticação.':`Autenticação recusada (HTTP ${http}).`)+' Nenhum pedido de números foi enviado.'};await r.body?.cancel();
          }else{
            const token=JSON.parse(await bounded(r,65536));
            if(token.token_type!=='Bearer'||!/^[\x21-\x7e]{1,32768}$/.test(token.access_token||''))throw Error('token');
            sending=true;result=await postNumbers({base:GATEWAYS[intent.environment],origin,token:token.access_token,request:intent.request,fetcher});token.access_token=null;
          }
        }catch{result=sending?{kind:'ambiguous',http,body:null,message:'Não foi possível confirmar o resultado. Não repita o pedido antes de conferir o registro.'}:{kind:'not-sent',http,body:null,message:'A autenticação não foi concluída. Nenhum pedido de números foi enviado.'};}
        result.message=String(result.message|| (result.kind==='success'?'Resposta do SNCR recebida.':'Confira o resultado antes de tentar novamente.')).slice(0,600);
        const receipt={...intent,result};let stored=false;
        for(let attempt=0;attempt<3&&!stored;attempt++)try{await db.prepare("UPDATE rx_relay SET status='concluido',result_kind=?,result=?,completed_at=? WHERE id=?").bind(result.kind,JSON.stringify(result),now(),row.id).run();stored=true;}catch{}
        if(!stored)return json(receipt,200,{'Content-Disposition':'attachment; filename="openpep-rx-recuperacao.json"'});
        return new Response(null,{status:303,headers:{...headers,Location:(intent.mode==='portal'?'/portal-sncr.html':'/dados-locais.html')+'?relay='+row.id,'Set-Cookie':`${COOKIE}=; Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=0`}});
      }
      if(url.pathname==='/api/relay/portal/download'&&request.method==='POST'){
        const body=JSON.parse(await bounded(request,1024));
        const row=await db.prepare('SELECT * FROM rx_relay WHERE id=? AND user_id=?').bind(body.id||'',user).first();
        if(!row)return json({error:'Pedido não encontrado.'},404);
        return json(await exportLot(row,db,env),200,{'Content-Disposition':`attachment; filename="openpep-rx-lote-${row.id}.json"`});
      }
      if(url.pathname==='/api/relay/portal/history'&&request.method==='GET'){
        await db.prepare("UPDATE rx_relay SET status='concluido',result_kind='not-sent',result=? WHERE user_id=? AND status='aguardando' AND created_at<?").bind(JSON.stringify({kind:'not-sent',http:null,body:null,message:'Login expirado. Nenhum pedido foi enviado; você pode preparar um novo pedido.'}),user,now()-TTL).run();
        const rows=await db.prepare('SELECT * FROM rx_relay WHERE user_id=? ORDER BY created_at DESC LIMIT 100').bind(user).all();
        return json({requests:rows.results.filter(r=>JSON.parse(r.intent).mode==='portal').map(r=>{
          const intent=JSON.parse(r.intent),result=r.result?JSON.parse(r.result):null;let count=0,message=result?.message||'';
          if(result?.kind==='success')try{count=lotPayload({version:1,id:r.id,destination:intent.destination,environment:r.environment,request:intent.request,issuedAt:r.completed_at,result}).numbers.length;}catch(error){message=error.message;}
          return {id:r.id,clientId:r.local_id,environment:r.environment,type:r.type,quantity:r.quantity,createdAt:r.created_at,status:r.status,resultKind:r.result_kind,destination:intent.destination,count,message};
        })});
      }
      if(url.pathname==='/api/relay/result'&&request.method==='GET'){
        const row=await db.prepare('SELECT * FROM rx_relay WHERE id=? AND user_id=?').bind(url.searchParams.get('id'),user).first();
        if(!row)return json({error:'Pedido não encontrado.'},404);
        return json({id:row.id,status:row.status,...(row.result?{receipt:{...JSON.parse(row.intent),result:JSON.parse(row.result)}}:{})});
      }
      if(url.pathname==='/api/relay/history'&&request.method==='GET'){
        const rows=await db.prepare('SELECT id,local_id,environment,type,quantity,status,result_kind,created_at FROM rx_relay WHERE user_id=? ORDER BY created_at DESC LIMIT 100').bind(user).all();return json({requests:rows.results});
      }
      return json({error:'Operação indisponível.'},404);
    }catch(error){return json({error:error.message && !/SQL|D1|database|constraint/i.test(error.message) ? error.message : 'Não foi possível registrar o pedido. Confira o histórico antes de tentar novamente.'},422);}
  };
}
