// SPDX-License-Identifier: AGPL-3.0-or-later
import assets from './asset-map.mjs';
import {createRelay} from './relay.mjs';
const relay=createRelay();
const policy="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self' blob: data:; worker-src 'self'; connect-src 'self' http://127.0.0.1:*; frame-src blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'";
export default {async fetch(request,env){
  const url=new URL(request.url);
  if(url.pathname.startsWith('/api/relay/')||url.pathname==='/sncr/retorno')return relay(request,env);
  if(url.pathname.startsWith('/api/'))return new Response(JSON.stringify({error:'Conecte o auxiliar local do OpenPEP-Rx.'}),{status:404,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
  if(!['GET','HEAD'].includes(request.method))return new Response('Método não permitido.',{status:405});
  const path=url.pathname==='/'?'/portal-sncr.html':/^\/r\/[a-z2-7]{26}$/i.test(url.pathname)?'/verificar.html':url.pathname;
  const asset=assets[path];if(!asset)return new Response('Página não encontrada.',{status:404});
  // Sites owns transport compression. Return decoded bytes so that a proxy
  // cannot strip Content-Encoding while forwarding compressed application data.
  const body=request.method==='HEAD'?null:new Blob([Uint8Array.from(atob(asset.data),c=>c.charCodeAt(0))]).stream().pipeThrough(new DecompressionStream('gzip'));
  return new Response(body,{headers:{'Content-Type':asset.type,'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff','X-Robots-Tag':'noindex, nofollow, noarchive','Content-Security-Policy':policy}});
}};
