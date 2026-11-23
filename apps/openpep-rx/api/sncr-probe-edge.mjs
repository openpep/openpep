// Edge twin of GET /api/sncr/sondar. Some upstream networks treat Node and Edge egress differently; this checks
// whether the Anvisa production Cloudflare does the same before the token exchange is moved.
import {makeStore} from './store.mjs';
import {ORIGIN, probeGateways} from './sncr-probe.mjs';
const headers = {'Cache-Control':'no-store, max-age=0','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff','X-Robots-Tag':'noindex, nofollow, noarchive','Content-Type':'application/json; charset=utf-8'};
const json = (status, data) => new Response(JSON.stringify(data), {status, headers});
// Region codes from x-vercel-id ("gru1::iad1::…"), the last one being where this function ran.
export function regionOf(request) {
  const parts = (request.headers.get('x-vercel-id') || '').split('::').filter(p => /^[a-z]{3}\d$/.test(p));
  return process.env.VERCEL_REGION || parts.at(-1) || null;
}
export function createEdgeProbe({store = makeStore(process.env, fetch, {namespace:'crx:sncr:sondar:v1', ttl:900}), probe = () => probeGateways(fetch), now = Date.now} = {}) {
  return async request => {
    const url = new URL(request.url);
    if ((request.headers.get('host') || url.host) !== new URL(ORIGIN).host) return json(403, {error:'Use o domínio de homologação .br.'});
    if (request.method !== 'GET') return json(405, {error:'Método não permitido.'});
    if (url.search) return json(400, {error:'Parâmetros não permitidos.'});
    try { if (!await store.allow('sondar-edge', 20)) return json(429, {error:'Limite de sondagens atingido. Aguarde até 15 minutos.'}); }
    catch { return json(503, {error:'Sondagem indisponível. Tente novamente.'}); }
    try { return json(200, {runtime:'edge', regiao: regionOf(request), em: new Date(now()).toISOString(), ...(await probe())}); }
    catch { return json(503, {error:'Sondagem indisponível. Tente novamente.'}); }
  };
}
export default createEdgeProbe();
