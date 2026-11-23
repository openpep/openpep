// Local synthetic QA only. Not included in build.mjs or deployment.
import http from 'node:http';
import {readFile} from 'node:fs/promises';
import {createHandler, ORIGIN, LOGIN} from '../api/sncr.mjs';
const LOCAL='http://127.0.0.1:4198',rows=new Map();
const store={allow:async()=>true,create:async(k,v)=>{if(rows.has(k))return false;rows.set(k,structuredClone(v));return true;},get:async k=>structuredClone(rows.get(k)),swap:async(k,r,v)=>{if(rows.get(k)?.revision!==r)return false;rows.set(k,structuredClone(v));return true;}};
const handler=createHandler({store,exchange:async()=> 'token-received'});
const files=new Set(['sncr.html','sncr.js','sncr.css','acesso.css','entrada.html','entrada.css','entrada.js','openpep-mark.png','openpep.css']);
http.createServer(async(req,res)=>{try{
 const u=new URL(req.url,LOCAL);
 if(u.pathname==='/api-sncr/api/v1/auth/login') {res.statusCode=302;res.setHeader('Location','/?session_id=SYNTHETIC_QA&state='+encodeURIComponent(u.searchParams.get('state')));return res.end();}
 if(u.pathname==='/'&&u.searchParams.has('session_id'))req.url='/api/sncr/callback'+u.search;
 if(req.url.startsWith('/api/sncr/')){
  req.headers.host=new URL(ORIGIN).host;if(req.headers.origin===LOCAL)req.headers.origin=ORIGIN;
  req.headers.cookie=(req.headers.cookie||'').replaceAll('qa-sncr=','__Host-crx-sncr-attempt=');
  const set=res.setHeader.bind(res);res.setHeader=(k,v)=>set(k,k.toLowerCase()==='set-cookie'?v.replace('__Host-crx-sncr-attempt=','qa-sncr=').replace('; Secure',''):v);
  const end=res.end.bind(res);res.end=v=>end(typeof v==='string'?v.replace(LOGIN,LOCAL+'/api-sncr/api/v1/auth/login'):v);
  return await handler(req,res);
 }
 const name=u.pathname==='/'?'entrada.html':u.pathname.slice(1);if(!files.has(name)){res.statusCode=404;return res.end();}
 let bytes=await readFile(new URL('../.vercel/output/static/'+name,import.meta.url));
 if(name==='sncr.js')bytes=Buffer.from(bytes.toString().replaceAll(ORIGIN,LOCAL).replaceAll('https://api-gateway.hmg.apps.anvisa.gov.br',LOCAL));
 res.setHeader('Content-Type',name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':name.endsWith('.png')?'image/png':'text/html; charset=utf-8');res.end(bytes);
 }catch{res.statusCode=500;res.end('QA failure');}}).listen(4198,'127.0.0.1',()=>console.log('Synthetic SNCR QA http://127.0.0.1:4198/sncr.html'));
