import assets from './asset-map.mjs';
import {createDocuments} from './documents.mjs';
const documents=createDocuments();
export default {async fetch(request,env){
  const url=new URL(request.url);
  if(url.pathname.startsWith('/api/'))return documents(request,env);
  if(!['GET','HEAD'].includes(request.method))return new Response(null,{status:405});
  const path=url.pathname==='/'||/^\/r\/[A-Z2-7]{26}$/i.test(url.pathname)?'/index.html':url.pathname;
  const asset=assets[path];if(!asset)return new Response('Página não encontrada.',{status:404});
  const body=request.method==='HEAD'?null:new Blob([Uint8Array.from(atob(asset.data),c=>c.charCodeAt(0))]).stream().pipeThrough(new DecompressionStream('gzip'));
  return new Response(body,{headers:{'Content-Type':asset.type,'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff','X-Robots-Tag':'noindex, nofollow, noarchive','Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self'; font-src 'self' blob: data:; worker-src 'self'; img-src 'self'; connect-src 'self'; frame-src blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"}});
}};
