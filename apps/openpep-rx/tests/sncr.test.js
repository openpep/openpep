import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler, exchangeToken, probeGateways, ORIGIN, CALLBACK, LOGIN, BASE, BASE_PRD } from '../api/sncr.mjs';
import { readFile } from 'node:fs/promises';
const time=1800000000000,nonce='a'.repeat(64),attempt=`${nonce}.${time/1000}`;
const cookie=`__Host-crx-sncr-attempt=${attempt}`;
function memory(){
 const rows=new Map();return {rows,allow:async()=>true,create:async(k,v)=>{if(rows.has(k))return false;rows.set(k,structuredClone(v));return true;},get:async k=>structuredClone(rows.get(k)),swap:async(k,r,v)=>{if(rows.get(k)?.revision!==r)return false;rows.set(k,structuredClone(v));return true;}};
}
function setup(overrides={}){
 const store=overrides.store||memory(),calls=[];
 const handler=createHandler({defaultEnvironment:'hmg',now:()=>time,random:()=>nonce,store,exchange:async id=>{calls.push(id);return 'token-received';},...overrides});
 const request=async(url,opts={})=>{let body='';const headers={};const res={statusCode:200,setHeader(k,v){headers[k]=v;},end(v=''){body+=v;}};await handler({url,method:opts.method||'GET',headers:{host:new URL(ORIGIN).host,...opts.headers}},res);return {status:res.statusCode,headers,body};};
 const start=()=>request('/api/sncr/login',{method:'POST',headers:{origin:ORIGIN}});
 const callback=(query=`session_id=SYNTHETIC_SECRET&state=${attempt}`)=>request('/api/sncr/callback?'+query,{headers:{cookie}});
 return {store,calls,request,start,callback};
}
test('SNCR Ed3 uses canonical HML gateway, fixed callback and protected short cookie',async()=>{
 const s=setup(),res=await s.start();assert.equal(res.status,200);const u=new URL(JSON.parse(res.body).url);
 assert.equal(u.origin+u.pathname,BASE+'auth/login');assert.equal(u.searchParams.get('client_url'),CALLBACK);assert.equal(u.searchParams.get('state'),attempt);
 assert.match(res.headers['Set-Cookie'],/Path=\/; HttpOnly; Secure; SameSite=Lax; Max-Age=300$/);assert.equal(res.headers['Cache-Control'],'no-store, max-age=0');
 assert.equal(s.store.rows.get(attempt).status,'pending');
});
test('SNCR rejects method, origin, host, overrides, unavailable storage and start budget',async()=>{
 const s=setup();assert.equal((await s.request('/api/sncr/login')).status,405);
 for(const headers of [{},{origin:'https://evil.invalid'},{origin:ORIGIN,host:'outro-deploy.example.invalid'}])assert.equal((await s.request('/api/sncr/login',{method:'POST',headers})).status,403);
 assert.equal((await s.request('/api/sncr/login?client_url=https://evil.invalid',{method:'POST',headers:{origin:ORIGIN}})).status,400);
 const denied=memory();denied.allow=async()=>false;assert.equal((await setup({store:denied}).start()).status,429);
 const down=memory();down.create=async()=>{throw Error('SECRET');};const res=await setup({store:down}).start();assert.equal(res.status,503);assert.ok(!res.body.includes('SECRET'));
});
test('SNCR callback exchanges once, redirects without identifiers and stores only category',async()=>{
 const s=setup();await s.start();const res=await s.callback();assert.equal(res.status,303);assert.equal(res.headers.Location,'/sncr.html');assert.equal(res.body,'');
 assert.deepEqual(s.calls,['SYNTHETIC_SECRET']);assert.equal(s.store.rows.get(attempt).status,'token-received');assert.ok(!JSON.stringify([...s.store.rows]).includes('SYNTHETIC_SECRET'));
 const status=await s.request('/api/sncr/status',{headers:{cookie}});assert.deepEqual(JSON.parse(status.body),{status:'token-received'});
 assert.deepEqual(JSON.parse((await s.request('/api/sncr/status')).body),{status:'idle'});
 assert.equal((await s.callback()).headers.Location,'/sncr.html?result=already-used');assert.equal(s.calls.length,1);
 assert.equal((await s.request('/api/sncr/status?result=token-received')).status,400);
});
test('SNCR concurrent callbacks cannot reuse the upstream exchange',async()=>{
 let finish,calls=0;const s=setup({exchange:async()=>{calls++;return new Promise(resolve=>{finish=resolve;});}});await s.start();
 const first=s.callback();await new Promise(setImmediate);const second=await s.callback();assert.equal(second.headers.Location,'/sncr.html?result=already-used');
 assert.deepEqual(JSON.parse((await s.request('/api/sncr/status',{headers:{cookie}})).body),{status:'exchanging'});
 finish('token-received');await first;assert.equal(calls,1);
});
test('SNCR invalid callback never calls token service',async()=>{
 const cases=[['session_id=X','return-unverified'],['','missing-session'],['session_id=X&session_id=Y','missing-session'],['session_id=X&state=wrong','state-mismatch'],['session_id=X&state='+encodeURIComponent('é'.repeat(attempt.length)),'state-mismatch'],['session_id=X&state='+attempt+'&state='+attempt,'state-mismatch'],['error=access_denied&error_description=SECRET','provider-error']];
 for(const [query,result]of cases){const s=setup();await s.start();const res=await s.callback(query);assert.equal(res.headers.Location,`/sncr.html?result=${result}`);assert.match(res.headers['Set-Cookie'],/Max-Age=0$/);assert.equal(s.calls.length,0);assert.ok(!JSON.stringify(res).includes('SECRET'));}
 for(const [value,result]of [[time+301000,'expired'],[time-1000,'expired']]){const s=setup({now:()=>value});const res=await s.callback();assert.equal(res.headers.Location,`/sncr.html?result=${result}`);assert.equal(s.calls.length,0);}
 const s=setup();assert.equal((await s.request('/api/sncr/callback?session_id=X',{headers:{cookie:`${cookie}; ${cookie}`}})).headers.Location,'/sncr.html?result=invalid-attempt');
 assert.equal((await s.request('/api/sncr/callback',{method:'POST'})).status,405);assert.equal((await s.request('/api/sncr/callback?'+'x'.repeat(8192))).status,400);
});
test('SNCR failures and ambiguous exchange are terminal; no secret errors leak',async()=>{
 for(const outcome of ['token-rejected','token-invalid-response','token-unavailable']){
 let calls=0;const s=setup({exchange:async()=>{calls++;if(outcome==='token-unavailable')throw Error('SECRET');return outcome;}});await s.start();const res=await s.callback();assert.equal(res.headers.Location,'/sncr.html');
 assert.equal(s.store.rows.get(attempt).status,outcome);await s.callback();assert.equal(calls,1);assert.ok(!JSON.stringify([...s.store.rows]).includes('SECRET'));
 }
});
test('SNCR token service matches documented query and Origin, returns category only',async()=>{
 let count=0;const fetcher=async(url,options)=>{count++;const u=new URL(url);assert.equal(u.origin+u.pathname,BASE+'auth/token');assert.equal(u.searchParams.get('session_id'),'SESSION/+');assert.equal(options.method,'GET');assert.equal(options.headers.Origin,ORIGIN);assert.equal(options.headers.Authorization,undefined);assert.equal(options.headers.Cookie,undefined);assert.equal(options.redirect,'error');assert.equal(options.cache,'no-store');assert.ok(options.signal);return Response.json({access_token:'SYNTHETIC_ACCESS_SECRET',token_type:'Bearer'});};
 assert.deepEqual(await exchangeToken('SESSION/+',fetcher),{outcome:'token-received',http:200,bloqueio:false,campos:['access_token','token_type']});assert.equal(count,1);
});
test('SNCR rejects bad content types, oversized payloads, missing Bearer and transport failures without retry',async()=>{
 const cases=[
 [()=>new Response('SECRET',{status:403}),'token-rejected'],
 [()=>new Response('SECRET',{headers:{'Content-Type':'text/html'}}),'token-invalid-response'],
 [()=>Response.json({access_token:'SECRET',token_type:'Basic'}),'token-invalid-response'],
 [()=>Response.json({access_token:'',token_type:'Bearer'}),'token-invalid-response'],
 [()=>Response.json({access_token:'SECRET',token_type:'Bearer',error:'SECRET'}),'token-invalid-response'],
 [()=>Response.json({access_token:'X'.repeat(70000),token_type:'Bearer'}),'token-unavailable'],
 [()=>{throw Error('SECRET');},'token-unavailable']
 ];for(const [response,expected]of cases){let calls=0;const got=await exchangeToken('SYNTHETIC',async()=>{calls++;return response();});assert.equal(got.outcome,expected);assert.ok(!JSON.stringify(got).includes('SECRET'));assert.equal(calls,1);}
});
test('SNCR build packages the handler with the numbers registry and no static credentials',async()=>{
 const config=JSON.parse(await readFile('.vercel/output/config.json','utf8'));
 for(const route of ['login','callback','status','numeros','sondar']){assert.ok(config.routes.some(r=>r.src===`/api/sncr/${route}`));for(const f of ['http-utils.mjs','ledger.mjs','db.mjs','sncr-numbers.mjs','node_modules/postgres/package.json'])await readFile(`.vercel/output/functions/api/sncr/${route}.func/${f}`);}
 const {createHandler:packaged}=await import('../.vercel/output/functions/api/sncr/login.func/index.mjs');assert.equal(typeof packaged,'function');
 for(const f of ['index.mjs','db.mjs','ledger.mjs','sncr-numbers.mjs']){const code=await readFile(`.vercel/output/functions/api/sncr/login.func/${f}`,'utf8');assert.ok(!/postgres(?:ql)?:\/\/[^'"`\s]*@/.test(code),f);assert.ok(!/\b\d{14}\b/.test(code.replace(/SUPABASE_ROOT_2021 = `[^`]*`/,'')),f);}
 const ui=await readFile('.vercel/output/static/sncr.js','utf8');assert.ok(ui.includes(new URL(BASE).origin));assert.ok(ui.includes(new URL(BASE_PRD).origin));assert.ok(!ui.includes('localStorage'));assert.ok(!ui.includes('access_token'));
 const html=await readFile('.vercel/output/static/sncr.html','utf8');assert.ok(html.includes('descartado'));await assert.rejects(readFile('.vercel/output/static/api/sncr.mjs'));
});
test('root return strips callback before HTML and never returns identifier to JavaScript',async()=>{
 const {default:landing}=await import('../.vercel/output/functions/index.func/index.mjs');
 async function invoke(url){let body='';const headers={};const res={statusCode:200,setHeader(k,v){headers[k]=v;},end(v=''){body+=v;}};await landing({url,method:'GET',headers:{host:new URL(ORIGIN).host}},res);return {status:res.statusCode,headers,body};}
 const home=await invoke('/');assert.equal(home.status,200);assert.ok(home.body.includes('OpenPEP-Rx'));
 const ret=await invoke('/?session_id=SYNTHETIC_SECRET');assert.equal(ret.status,303);assert.equal(ret.headers.Location,'/sncr.html?result=invalid-attempt');assert.ok(!JSON.stringify(ret).includes('SYNTHETIC_SECRET'));assert.equal(ret.body,'');
});

const PRD_HOST=new URL(BASE_PRD).origin;
function setupPrd(overrides={}){
 const store=overrides.store||memory(),calls=[];
 const handler=createHandler({defaultEnvironment:'hmg',now:()=>time,random:()=>nonce,store,exchange:async(id,base)=>{calls.push([id,base]);return {outcome:'token-received',http:200,bloqueio:false,campos:['access_token','token_type','expires_in']};},...overrides});
 const call=async(url,opts={})=>{let body='';const headers={};const res={statusCode:200,setHeader(k,v){headers[k]=v;},end(v=''){body+=v;}};await handler({url,method:opts.method||'GET',headers:{host:new URL(ORIGIN).host,...opts.headers},body:opts.body},res);return {status:res.statusCode,headers,body};};
 const start=(body={ambiente:'prd'})=>call('/api/sncr/login',{method:'POST',headers:{origin:ORIGIN},body:JSON.stringify(body)});
 return {store,calls,call,start};
}
test('SNCR production login-only: prd gateway, same root callback, exchange against prd, diagnostics in status',async()=>{
 const s=setupPrd();const res=await s.start();assert.equal(res.status,200);const u=new URL(JSON.parse(res.body).url);
 assert.equal(u.origin+u.pathname,BASE_PRD+'auth/login');assert.equal(u.searchParams.get('client_url'),CALLBACK);assert.equal(u.searchParams.get('state'),attempt);
 assert.equal(s.store.rows.get(attempt).env,'prd');assert.equal(s.store.rows.get(attempt).mode,undefined);
 // Node validates and hands the unclaimed attempt to the Edge exchange (the production gateway does not accept Node egress).
 const back=await s.call(`/api/sncr/callback?session_id=SYNTHETIC_SECRET&state=${attempt}`,{headers:{cookie}});assert.equal(back.status,303);
 assert.equal(back.headers.Location,`/api/sncr/callback-edge?session_id=SYNTHETIC_SECRET&state=${attempt}`);assert.equal(back.headers['Set-Cookie'],undefined);
 assert.deepEqual(s.calls,[]);assert.equal(s.store.rows.get(attempt).status,'pending');assert.equal(s.store.rows.get(attempt).revision,0);
 assert.equal((await s.call(`/api/sncr/callback?session_id=X&state=wrong`,{headers:{cookie}})).headers.Location,'/sncr.html?result=state-mismatch');
});
test('SNCR production Edge exchange: re-validates, claims once, stores diagnostics only, refuses non-production rows',async()=>{
 const {createEdgeCallback,exchangeTokenEdge}=await import('../api/sncr-callback-edge.mjs');
 const store=memory();const calls=[];
 const edge=createEdgeCallback({store,now:()=>time,exchange:async id=>{calls.push(id);return {outcome:'token-received',http:200,bloqueio:false,campos:['access_token','token_type'],token:'SECRET_TOKEN'};}});
 const req=(query,c=cookie)=>new Request('https://rx-hml.openpep.com.br/api/sncr/callback-edge'+query,{headers:{host:'rx-hml.openpep.com.br',...(c?{cookie:c}:{})}});
 store.rows.set(attempt,{revision:0,status:'pending',createdAt:time,env:'prd'});
 const ok=await edge(req(`?session_id=SYNTHETIC_SECRET&state=${attempt}`));assert.equal(ok.status,303);assert.equal(ok.headers.get('location'),'/sncr.html');
 assert.deepEqual(calls,['SYNTHETIC_SECRET']);const row=store.rows.get(attempt);assert.equal(row.status,'token-received');assert.equal(row.revision,2);
 assert.deepEqual(row.diagnostico,{runtime:'edge',http:200,campos:['access_token','token_type']});assert.ok(!JSON.stringify(row).includes('SECRET'));
 assert.equal((await edge(req(`?session_id=SYNTHETIC_SECRET&state=${attempt}`))).headers.get('location'),'/sncr.html?result=already-used');assert.equal(calls.length,1);
 for(const [query,c,result] of [[`?session_id=X&state=wrong`,cookie,'state-mismatch'],[`?state=${attempt}`,cookie,'missing-session'],[`?session_id=X&session_id=Y&state=${attempt}`,cookie,'missing-session'],[`?session_id=X&state=${attempt}`,'','invalid-attempt'],[`?session_id=X&state=${attempt}`,`${cookie}; ${cookie}`,'invalid-attempt']]){
  const r=await edge(req(query,c));assert.equal(r.headers.get('location'),`/sncr.html?result=${result}`);assert.match(r.headers.get('set-cookie'),/Max-Age=0/);}
 for(const other of [{revision:0,status:'pending',createdAt:time},{revision:0,status:'pending',createdAt:time,env:'hmg'},{revision:0,status:'pending',createdAt:time,env:'prd',mode:'numbers'},{revision:0,status:'pending',createdAt:time-400000,env:'prd'}]){
  store.rows.set(attempt,other);assert.equal((await edge(req(`?session_id=X&state=${attempt}`))).headers.get('location'),'/sncr.html?result=already-used');}
 assert.equal(calls.length,1);
 const late=createEdgeCallback({store,now:()=>time+301000,exchange:async()=>{throw Error();}});assert.equal((await late(req(`?session_id=X&state=${attempt}`))).headers.get('location'),'/sncr.html?result=expired');
 assert.equal((await edge(new Request('https://outro-deploy.example.invalid/api/sncr/callback-edge'))).status,403);
 assert.equal((await edge(new Request('https://rx-hml.openpep.com.br/api/sncr/callback-edge',{method:'POST',headers:{host:'rx-hml.openpep.com.br'}}))).status,405);
 let seen;const got=await exchangeTokenEdge('SESSION/+',async(u,o)=>{seen={u,o};return Response.json({access_token:'SECRET',token_type:'Bearer',expires_in:300});});
 assert.equal(new URL(seen.u).origin+new URL(seen.u).pathname,BASE_PRD+'auth/token');assert.equal(new URL(seen.u).searchParams.get('session_id'),'SESSION/+');assert.equal(seen.o.headers.Origin,ORIGIN);assert.equal(seen.o.headers.Authorization,undefined);assert.equal(seen.o.redirect,'manual');
 assert.deepEqual(got,{outcome:'token-received',http:200,bloqueio:false,campos:['access_token','token_type','expires_in']});
 assert.deepEqual(await exchangeTokenEdge('X',async()=>new Response('<html>SECRET</html>',{status:403,headers:{server:'cloudflare','content-type':'text/html'}})),{outcome:'token-rejected',http:403,bloqueio:true});
 assert.equal((await exchangeTokenEdge('X',async()=>new Response('',{status:302,headers:{location:'https://x/'}}))).outcome,'token-rejected');
 assert.equal((await exchangeTokenEdge('X',async()=>Response.json({access_token:'X'.repeat(70000),token_type:'Bearer'}))).outcome,'token-unavailable');
 assert.equal((await exchangeTokenEdge('X',async()=>{throw Error('SECRET');})).outcome,'token-unavailable');
});
test('SNCR production Edge callback bundle is self-contained, routed and only ever requests numbers from the production gateway',async()=>{
 const config=JSON.parse(await readFile('.vercel/output/config.json','utf8'));for(const r of ['/api/sncr/callback-edge','/api/sncr/concluir-prd'])assert.ok(config.routes.some(x=>x.src===r),r);
 assert.equal(JSON.parse(await readFile('.vercel/output/functions/api/sncr/callback-edge.func/.vc-config.json','utf8')).runtime,'edge');
 const code=await readFile('.vercel/output/functions/api/sncr/callback-edge.func/index.js','utf8');assert.ok(!/from ?["']node:/.test(code));
 const src=await readFile('api/sncr-callback-edge.mjs','utf8');assert.equal((src.match(/postNumbers\(/g)||[]).length,1);assert.match(src,/postNumbers\(\{base: BASE_PRD,/);assert.ok(!/\bBASE\b(?!_PRD)/.test(src.replace(/BASE_PRD/g,'')));
});
test('SNCR production numbers need a signed-in prescriber; unconfigured ranges and unknown environments are refused; nothing is prepared',async()=>{
 let sent=0;const s=setupPrd({fetcher:async()=>{sent++;throw Error('no network');},entryStore:memory()});
 for(const [body,code] of [[{ambiente:'prd',tipo:'RET',quantidade:1000},503],[{ambiente:'prd',tipo:'NRB',quantidade:10},403],[{ambiente:'prd',tipo:'RCE',quantidade:1000},503],[{ambiente:'producao'},400],[{ambiente:'__proto__'},400],[{ambiente:'toString'},400]]){const res=await s.start(body);assert.equal(res.status,code,JSON.stringify(body));}
 assert.equal(s.store.rows.size,0);assert.equal(sent,0);
 const hml=await setupPrd().start({});assert.equal(new URL(JSON.parse(hml.body).url).origin+new URL(JSON.parse(hml.body).url).pathname,BASE+'auth/login');
 const code=await readFile('api/sncr.mjs','utf8');assert.match(code,/postNumbers\(\{base: BASE,/);assert.equal((code.match(/postNumbers\(/g)||[]).length,1);
});
test('SNCR production exchange reports Cloudflare block and server errors without bodies',async()=>{
 const block=async()=>new Response('<html>SECRET Sorry, you have been blocked</html>',{status:403,headers:{server:'cloudflare','content-type':'text/html; charset=UTF-8'}});
 assert.deepEqual(await exchangeToken('X',block,BASE_PRD),{outcome:'token-rejected',http:403,bloqueio:true});
 const whitelabel=async()=>new Response('Whitelabel SECRET',{status:500,headers:{server:'cloudflare','content-type':'text/html'}});
 assert.deepEqual(await exchangeToken('X',whitelabel,BASE_PRD),{outcome:'token-rejected',http:500,bloqueio:false});
 let seen;await exchangeToken('X',async u=>{seen=u;return new Response('',{status:401});},BASE_PRD);assert.ok(seen.startsWith(BASE_PRD+'auth/token?'));
 // Full production round trip: Node start, Node hand-off, Edge exchange on the same store, Node status.
 const {createEdgeCallback}=await import('../api/sncr-callback-edge.mjs');
 const s=setupPrd();await s.start();const hop=await s.call(`/api/sncr/callback?session_id=X&state=${attempt}`,{headers:{cookie}});
 const edge=createEdgeCallback({store:s.store,now:()=>time,exchange:async()=>({outcome:'token-rejected',http:403,bloqueio:true,token:'SECRET'})});
 assert.equal((await edge(new Request('https://rx-hml.openpep.com.br'+hop.headers.Location,{headers:{host:'rx-hml.openpep.com.br',cookie}}))).headers.get('location'),'/sncr.html');
 assert.deepEqual(JSON.parse((await s.call('/api/sncr/status',{headers:{cookie}})).body),{status:'token-rejected',ambiente:'prd',http:403,bloqueio:true});assert.ok(!JSON.stringify([...s.store.rows]).includes('SECRET'));
});
test('SNCR probe: unauthenticated first hop to both gateways, redirect hostname only, rate limited',async()=>{
 const seen=[];const fetcher=async(url,options)=>{seen.push(url);assert.equal(options.headers.Authorization,undefined);assert.equal(options.headers.Cookie,undefined);assert.equal(options.redirect,'manual');
  const u=new URL(url);
  if(u.origin===PRD_HOST&&u.pathname.endsWith('/auth/login'))return new Response('',{status:302,headers:{location:'https://sso.acesso.gov.br/authorize?state=SECRET_STATE&nonce=SECRET'}});
  if(u.origin===PRD_HOST)return new Response('<html>blocked</html>',{status:403,headers:{server:'cloudflare','content-type':'text/html'}});
  if(u.pathname.endsWith('/auth/login'))return Response.json({message:'Domínio não autorizado'},{status:403});
  return Response.json({error:'Não autorizado',message:'Token ausente ou expirado.'},{status:401});};
 const out=await probeGateways(fetcher);
 assert.deepEqual(out,{hmg:{raiz:{http:401,bloqueio:false,mensagem:'Token ausente ou expirado.'},login:{http:403,bloqueio:false,mensagem:'Domínio não autorizado'}},prd:{raiz:{http:403,bloqueio:true},login:{http:302,bloqueio:false,destino:'sso.acesso.gov.br'}}});
 assert.equal(seen.length,4);for(const u of seen.filter(u=>u.includes('auth/login')))assert.equal(new URL(u).searchParams.get('client_url'),CALLBACK);
 assert.ok(!JSON.stringify(out).includes('SECRET'));
 const s=setupPrd({probe:async()=>out,region:'gru1'});const res=await s.call('/api/sncr/sondar');assert.equal(res.status,200);const data=JSON.parse(res.body);assert.equal(data.regiao,'gru1');assert.deepEqual(data.prd,out.prd);
 assert.equal((await s.call('/api/sncr/sondar',{method:'POST'})).status,405);assert.equal((await s.call('/api/sncr/sondar?x=1')).status,400);
 const denied=memory();denied.allow=async()=>false;assert.equal((await setupPrd({store:denied,probe:async()=>out}).call('/api/sncr/sondar')).status,429);
 assert.deepEqual(await probeGateways(async()=>{throw Error('SECRET');}),{hmg:{raiz:{http:null,erro:'sem resposta'},login:{http:null,erro:'sem resposta'}},prd:{raiz:{http:null,erro:'sem resposta'},login:{http:null,erro:'sem resposta'}}});
});
test('SNCR Edge probe: same shared probe, host and method checks, rate limit, region from x-vercel-id',async()=>{
 const {createEdgeProbe,regionOf}=await import('../api/sncr-probe-edge.mjs');
 const out={prd:{raiz:{http:403,bloqueio:true},login:{http:403,bloqueio:true}}};
 const rows=memory();const probe=createEdgeProbe({store:rows,probe:async()=>out,now:()=>time});
 const req=(path,init={})=>new Request('https://rx-hml.openpep.com.br'+path,{...init,headers:{host:'rx-hml.openpep.com.br','x-vercel-id':'gru1::gru1::abc-123',...init.headers}});
 const ok=await probe(req('/api/sncr/sondar-edge'));assert.equal(ok.status,200);const data=await ok.json();assert.equal(data.runtime,'edge');assert.equal(data.regiao,'gru1');assert.deepEqual(data.prd,out.prd);
 assert.equal((await probe(req('/api/sncr/sondar-edge',{method:'POST'}))).status,405);assert.equal((await probe(req('/api/sncr/sondar-edge?x=1'))).status,400);
 assert.equal((await probe(new Request('https://outro-deploy.example.invalid/api/sncr/sondar-edge'))).status,403);
 const denied=memory();denied.allow=async()=>false;assert.equal((await createEdgeProbe({store:denied,probe:async()=>out})(req('/api/sncr/sondar-edge'))).status,429);
 const broken=memory();broken.allow=async()=>{throw Error('SECRET');};const b=await createEdgeProbe({store:broken,probe:async()=>out})(req('/api/sncr/sondar-edge'));assert.equal(b.status,503);assert.ok(!(await b.text()).includes('SECRET'));
 assert.equal(regionOf(new Request('https://x/',{headers:{'x-vercel-id':'nothing'}})),process.env.VERCEL_REGION||null);
});
test('SNCR Edge probe bundle is self-contained and routed',async()=>{
 const config=JSON.parse(await readFile('.vercel/output/config.json','utf8'));assert.ok(config.routes.some(r=>r.src==='/api/sncr/sondar-edge'));
 const vc=JSON.parse(await readFile('.vercel/output/functions/api/sncr/sondar-edge.func/.vc-config.json','utf8'));assert.equal(vc.runtime,'edge');
 const code=await readFile('.vercel/output/functions/api/sncr/sondar-edge.func/index.js','utf8');assert.ok(!/from ?["']node:/.test(code));assert.ok(!/postgres/.test(code));assert.ok(code.includes('api-gateway.prd.apps.anvisa.gov.br'));
 const ui=await readFile('.vercel/output/static/sncr.js','utf8');assert.ok(ui.includes('/api/sncr/sondar-edge'));
});
