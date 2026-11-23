// Edge leg of the production login-only diagnostic. The production gateway does not accept Node egress from this host
// but lets Edge (gru1) through, so the Node callback validates the gov.br return and hands production attempts here;
// this function re-checks everything, claims the attempt once and exchanges session_id for a token on the production
// gateway. The token is discarded: only the category, HTTP status, Cloudflare flag and field names are stored.
// Production numbers requests (mode 'numbers-prd': notifications or RCE, prescribers released in the database) are
// sent here too, once, after the Node callback marked them as being sent. The full result goes to the rescue area
// (30 days) before anything else, and the Node route /api/sncr/concluir-prd records it in the database.
import {makeStore} from './store.mjs';
import {ORIGIN, BASE_PRD, blockedByCloudflare} from './sncr-probe.mjs';
import {postNumbers} from './sncr-numbers.mjs';
import {expandRangeResponse} from './ledger.mjs';
export const COOKIE = '__Host-crx-sncr-attempt';
const TTL = 300;
const RESULTS = new Set(['token-received', 'token-rejected', 'token-unavailable', 'token-invalid-response']);
const RESCUE_TTL = 30 * 24 * 3600;
const baseHeaders = {'Cache-Control':'no-store, max-age=0','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff','X-Robots-Tag':'noindex, nofollow, noarchive'};

// Same contract as retrieveToken in api/sncr.mjs, in web-standard form (Edge rejects redirect:'error'; a 3xx is not ok).
// The token is returned only to the caller in memory.
export async function retrieveTokenEdge(sessionId, fetcher = fetch, base = BASE_PRD) {
  const url = new URL('auth/token', base);
  url.searchParams.set('session_id', sessionId);
  let response;
  try {
    response = await fetcher(url.href, {method:'GET', headers:{Accept:'application/json', Origin:ORIGIN}, redirect:'manual', cache:'no-store', signal:AbortSignal.timeout(10000)});
  } catch { return {outcome: 'token-unavailable'}; }
  const http = response.status, bloqueio = blockedByCloudflare(response);
  try {
    if (!response.ok) { await response.body?.cancel(); return {outcome: 'token-rejected', http, bloqueio}; }
    if (!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type') || '')) { await response.body?.cancel(); return {outcome: 'token-invalid-response', http, bloqueio}; }
    const text = await response.text();
    if (text.length > 65536) return {outcome: 'token-unavailable', http, bloqueio};
    const data = JSON.parse(text);
    const campos = data && typeof data === 'object' && !Array.isArray(data) ? Object.keys(data).filter(k => /^[A-Za-z_]{1,40}$/.test(k)).slice(0, 20) : [];
    const ok = !data?.error && data?.token_type === 'Bearer' && typeof data.access_token === 'string' && /^[\x21-\x7e]{1,32768}$/.test(data.access_token);
    return ok ? {outcome: 'token-received', token: data.access_token, http, bloqueio, campos} : {outcome: 'token-invalid-response', http, bloqueio, campos};
  } catch { return {outcome: 'token-unavailable', http, bloqueio}; }
}
// Login-only diagnostic: the credential is discarded here.
export async function exchangeTokenEdge(sessionId, fetcher = fetch, base = BASE_PRD) {
  const {token, ...result} = await retrieveTokenEdge(sessionId, fetcher, base);
  return result;
}
function equal(a, b) {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0; for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}
function readAttempt(request) {
  const entries = (request.headers.get('cookie') || '').split(';').map(x => x.trim()).filter(x => x.startsWith(`${COOKIE}=`));
  return entries.length === 1 ? entries[0].slice(COOKIE.length + 1) : '';
}
function redirect(result, clear, page = '/sncr.html') {
  const headers = new Headers({...baseHeaders, Location: result ? `${page}?result=${result}` : page});
  if (clear) headers.append('Set-Cookie', `${COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`);
  return new Response(null, {status: 303, headers});
}
const moved = location => new Response(null, {status: 303, headers: {...baseHeaders, Location: location}});
export function createEdgeCallback({store = makeStore(process.env, fetch, {namespace:'crx:sncr:auth:v1', ttl:TTL}), exchange = sessionId => exchangeTokenEdge(sessionId),
  retrieve = sessionId => retrieveTokenEdge(sessionId), rescueStore = makeStore(process.env, fetch, {namespace:'crx:sncr:resgate:v1', ttl:RESCUE_TTL}),
  fetcher = fetch, now = Date.now, log = event => console.warn(JSON.stringify(event))} = {}) {
  // Send once and keep the full answer before anything else. create is NX: "already there" on a retry is success.
  async function sendNumbers(intent, sessionId) {
    let got, result;
    try { got = await retrieve(sessionId); } catch { got = {outcome: 'token-unavailable'}; }
    if (got?.outcome !== 'token-received' || typeof got.token !== 'string') result = {kind: 'not-sent', http: got?.http ?? null, body: null, message: RESULTS.has(got?.outcome) ? got.outcome : 'token-invalid-response'};
    else result = await postNumbers({base: BASE_PRD, origin: ORIGIN, token: got.token, request: intent, fetcher});
    got = null;
    const record = {solicitacaoId: intent.solicitacaoId, env: 'prd', tipo: intent.tipo, quantidade: intent.quantidade, ...result, at: now()};
    for (let i = 0; i < 3; i++) {
      try { await rescueStore.create(intent.solicitacaoId, record); return {status: result.kind === 'not-sent' ? result.message : 'numbers-sent'}; } catch {}
    }
    // Last resort, so a range is never lost: the log keeps only what identifies the numbers (never the token).
    const range = result.kind === 'success' && intent.tipo === 'RCE' ? expandRangeResponse(result.body, intent.quantidade) : null;
    try { log({event: 'sncr_prd_unrecorded', solicitacaoId: intent.solicitacaoId, tipo: intent.tipo, kind: result.kind, http: result.http,
      ...(range && !range.error ? {inicio: range.numbers[0], fim: range.numbers.at(-1)} : {}), ...(result.kind === 'success' && !range ? {corpo: JSON.stringify(result.body).slice(0, 4000)} : {})}); } catch {}
    return {status: 'numbers-unrecorded'};
  }
  return async request => {
    const url = new URL(request.url);
    if ((request.headers.get('host') || url.host) !== new URL(ORIGIN).host) return new Response(JSON.stringify({error:'Use o domínio de homologação .br.'}), {status: 403, headers: {...baseHeaders, 'Content-Type':'application/json; charset=utf-8'}});
    if (request.method !== 'GET') return new Response(null, {status: 405, headers: baseHeaders});
    if ((url.pathname + url.search).length > 8192) return redirect('missing-session', true);
    const attempt = readAttempt(request);
    const match = /^([a-f0-9]{64})\.(\d{10})$/.exec(attempt);
    if (!match) return redirect('invalid-attempt', true);
    const age = Math.floor(now() / 1000) - Number(match[2]);
    if (age < 0 || age > TTL) return redirect('expired', true);
    const ids = url.searchParams.getAll('session_id'), states = url.searchParams.getAll('state');
    if (ids.length !== 1 || !/^[\x21-\x7e]{1,4096}$/.test(ids[0])) return redirect('missing-session', true);
    if (states.length !== 1 || !equal(states[0], attempt)) return redirect('state-mismatch', true);
    try {
      const row = await store.get(attempt);
      // Only production attempts (login diagnostic or numbers request), still pending and in time.
      const numbers = row?.mode === 'numbers-prd';
      if (!row || row.env !== 'prd' || (row.mode && !numbers) || row.status !== 'pending' || now() - row.createdAt > TTL * 1000 || now() < row.createdAt)
        return redirect('already-used', false, numbers ? '/numeros.html' : '/sncr.html');
      const claimed = {...row, revision: 1, status: 'exchanging'};
      if (!await store.swap(attempt, 0, claimed)) return redirect('already-used', false, numbers ? '/numeros.html' : '/sncr.html');
      if (numbers) {
        const {status} = await sendNumbers(row.intent, ids[0]);
        await store.swap(attempt, 1, {...claimed, revision: 2, status}).catch(() => false);
        return moved('/api/sncr/concluir-prd');
      }
      let got;
      try { got = await exchange(ids[0]); } catch { got = {outcome: 'token-unavailable'}; }
      const outcome = RESULTS.has(got?.outcome) ? got.outcome : 'token-invalid-response';
      const diagnostico = {runtime: 'edge', ...(Number.isInteger(got?.http) ? {http: got.http} : {}), ...(got?.bloqueio === true ? {bloqueio: true} : {}),
        ...(Array.isArray(got?.campos) ? {campos: got.campos.filter(k => typeof k === 'string').slice(0, 20)} : {})};
      got = null;
      if (!await store.swap(attempt, 1, {...claimed, revision: 2, status: outcome, diagnostico})) return redirect('result-unavailable');
      return redirect();
    } catch { return redirect('result-unavailable'); }
  };
}
export default createEdgeCallback();
