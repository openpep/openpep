// Web-standard (fetch only) so the Node handler and the Edge probe share it. Unauthenticated first hop to each SNCR
// gateway: is Cloudflare letting this egress through, and does the gateway accept our callback domain? Only status
// codes, the redirect hostname and a short SNCR message leave; the redirect URL carries the gateway's state and is dropped.
import {ORIGIN} from './origin.mjs';
export {ORIGIN};
export const CALLBACK = `${ORIGIN}/`;
export const BASE = 'https://api-gateway.hmg.apps.anvisa.gov.br/api-sncr/api/v1/';
// Gateway de produção confirmado no manual publicado pela Anvisa (sncr_manual_api_v5.pdf).
export const BASE_PRD = 'https://api-gateway.prd.apps.anvisa.gov.br/api-sncr/api/v1/';
export const GATEWAYS = {hmg: BASE, prd: BASE_PRD};

// Cloudflare block or challenge page in front of the Anvisa gateway, told apart from an answer of the SNCR itself.
export function blockedByCloudflare(response) {
  const h = response.headers;
  return Boolean(h.get('cf-mitigated')) || (/cloudflare/i.test(h.get('server') || '') && /^text\/html/i.test(h.get('content-type') || '') && [403, 429, 503].includes(response.status));
}
function message(body) {
  for (const key of ['mensagem', 'message', 'error', 'erro', 'detail']) if (typeof body?.[key] === 'string' && body[key].trim()) return body[key].trim().slice(0, 120);
  return null;
}
export async function probeGateways(fetcher = fetch) {
  async function hit(href) {
    try {
      const response = await fetcher(href, {method:'GET', headers:{Accept:'application/json, text/html;q=0.5', Origin:ORIGIN}, redirect:'manual', cache:'no-store', signal:AbortSignal.timeout(10000)});
      const out = {http: response.status, bloqueio: blockedByCloudflare(response)};
      const location = response.headers.get('location');
      if (location) { try { out.destino = new URL(location, href).hostname; } catch { out.destino = 'inválido'; } }
      if (!out.bloqueio && response.status >= 400 && /json/i.test(response.headers.get('content-type') || '')) {
        try { const text = await response.text(); const m = text.length <= 8192 ? message(JSON.parse(text)) : null; if (m) out.mensagem = m; } catch {}
      } else await response.body?.cancel().catch(() => {});
      return out;
    } catch { return {http: null, erro: 'sem resposta'}; }
  }
  const result = {};
  for (const [env, base] of Object.entries(GATEWAYS)) {
    const login = new URL('auth/login', base);
    login.searchParams.set('client_url', CALLBACK);
    const [raiz, entrada] = await Promise.all([hit(base), hit(login.href)]);
    result[env] = {raiz, login: entrada};
  }
  return result;
}
