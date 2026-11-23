import { randomBytes, timingSafeEqual } from 'node:crypto';
import {makeStore} from './store.mjs';
import {bounded} from './http-utils.mjs';
import { sha256 } from './store.mjs';
import { makeLedger, LedgerError, NR_TYPES, RANGE_TYPES } from './ledger.mjs';
import { databaseClient } from './db.mjs';
import { postNumbers } from './sncr-numbers.mjs';

// Gateways, Cloudflare detection and the unauthenticated probe live in sncr-probe.mjs (shared with the Edge probe).
// Produção é o padrão. Homologação exige ambiente explícito e mantém seu registro separado.
import { ORIGIN, CALLBACK, BASE, BASE_PRD, GATEWAYS, blockedByCloudflare, probeGateways } from './sncr-probe.mjs';
export { ORIGIN, CALLBACK, BASE, BASE_PRD, GATEWAYS, blockedByCloudflare, probeGateways };
export const LOGIN = `${BASE_PRD}auth/login`;
const COOKIE = '__Host-crx-sncr-attempt';
const TTL = 300;
const RESULTS = new Set(['token-received', 'token-rejected', 'token-unavailable', 'token-invalid-response',
  'numbers-received', 'numbers-quarantine', 'numbers-refused', 'numbers-ambiguous', 'numbers-unrecorded', 'numbers-unavailable']);
const ENTRY_COOKIE = '__Host-crx-entry';
// Sessão do OpenPEP que pode pedir números: SSO institucional com CRM/UF/CPF confirmados. O SNCR recusa a inscrição
// que não for do CPF autenticado no gov.br; o uso do número numa receita continua exigindo o certificado.
const CAN_REQUEST = new Set(['certificate_required', 'certificate_creating', 'certificate_awaiting', 'certificate_returned', 'active', 'signing', 'complete']);
const RESCUE_TTL = 30 * 24 * 3600;
function json(res, status, data) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.end(JSON.stringify(data));
}
function cookie(res, value, maxAge) {
  res.setHeader('Set-Cookie', `${COOKIE}=${value}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}`);
}
function equal(a, b) {
  const left = Buffer.from(a), right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
}
function readAttempt(req) {
  const entries = (req.headers.cookie || '').split(';').map(x => x.trim()).filter(x => x.startsWith(`${COOKIE}=`));
  return entries.length === 1 ? entries[0].slice(COOKIE.length + 1) : '';
}
function validAge(attempt, now) {
  const match = /^([a-f0-9]{64})\.(\d{10})$/.exec(attempt);
  if (!match) return 'invalid-attempt';
  const age = Math.floor(now / 1000) - Number(match[2]);
  return age < 0 || age > TTL ? 'expired' : null;
}
function redirect(res, result, page = '/sncr.html') {
  res.statusCode = 303;
  res.setHeader('Location', result ? `${page}?result=${result}` : page);
  return res.end();
}
async function readJson(req) {
  let raw = req.body;
  if (raw === undefined) {
    if (typeof req[Symbol.asyncIterator] !== 'function') return null;
    const chunks = []; let size = 0;
    for await (const chunk of req) { size += chunk.length; if (size > 2048) throw Error('body'); chunks.push(Buffer.from(chunk)); }
    raw = Buffer.concat(chunks).toString();
  }
  if (Buffer.isBuffer(raw)) raw = raw.toString();
  if (typeof raw === 'string') { if (raw.length > 2048) throw Error('body'); return raw ? JSON.parse(raw) : null; }
  return raw ?? null;
}
// The token is returned only to the caller in memory; it is never stored, logged or sent to the browser.
// `http`, `bloqueio` and `campos` (top-level field names of the token response, never values) are diagnostics.
export async function retrieveToken(sessionId, fetcher = fetch, base = BASE) {
  const url = new URL('auth/token', base);
  url.searchParams.set('session_id', sessionId);
  let response;
  try {
    response = await fetcher(url.href, {method:'GET', headers:{Accept:'application/json', Origin:ORIGIN}, redirect:'error', cache:'no-store', signal:AbortSignal.timeout(10000)});
  } catch { return {outcome: 'token-unavailable'}; }
  const http = response.status, bloqueio = blockedByCloudflare(response);
  try {
    if (!response.ok) { await response.body?.cancel(); return {outcome: 'token-rejected', http, bloqueio}; }
    if (!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type') || '')) { await response.body?.cancel(); return {outcome: 'token-invalid-response', http, bloqueio}; }
    const data = JSON.parse((await bounded(response, 65536)).toString());
    const campos = data && typeof data === 'object' && !Array.isArray(data) ? Object.keys(data).filter(k => /^[A-Za-z_]{1,40}$/.test(k)).slice(0, 20) : [];
    if (data?.error || data?.token_type !== 'Bearer' || typeof data.access_token !== 'string' || !/^[\x21-\x7e]{1,32768}$/.test(data.access_token)) return {outcome: 'token-invalid-response', http, bloqueio, campos};
    return {outcome: 'token-received', token: data.access_token, http, bloqueio, campos};
  } catch { return {outcome: 'token-unavailable', http, bloqueio}; }
}
// Diagnostic exchange: only the category and its diagnostics leave this function; the credential is discarded.
export async function exchangeToken(sessionId, fetcher = fetch, base = BASE) {
  const {token, ...result} = await retrieveToken(sessionId, fetcher, base);
  return result;
}
export function createHandler({now = Date.now, random = () => randomBytes(32).toString('hex'), store = makeStore(process.env, fetch, {namespace:'crx:sncr:auth:v1',ttl:TTL}), exchange = exchangeToken,
  retrieve = retrieveToken, entryStore = makeStore(process.env, fetch, {namespace:'crx:entry:v1', ttl:1800}), rescueStore = makeStore(process.env, fetch, {namespace:'crx:sncr:resgate:v1', ttl:RESCUE_TTL}),
  ledger, fetcher = fetch, cnpj = process.env.SNCR_PLATFORM_CNPJ, pause = ms => new Promise(r => setTimeout(r, ms)), probe = () => probeGateways(fetcher),
  region = process.env.VERCEL_REGION || null, defaultEnvironment = 'prd'} = {}) {
  if (!Object.hasOwn(GATEWAYS, defaultEnvironment)) throw Error('Ambiente SNCR inválido.');
  // Created on first use, so the diagnostic routes work without DATABASE_URL.
  let registry = ledger;
  const getLedger = () => registry ??= makeLedger((text, params) => databaseClient().query(text, params));
  async function entrySession(req) {
    const all = (req.headers.cookie || '').split(';').map(x => x.trim()).filter(x => x.startsWith(ENTRY_COOKIE + '='));
    const id = all.length === 1 ? all[0].slice(ENTRY_COOKIE.length + 1) : '';
    if (!/^[a-f0-9]{64}$/.test(id)) return null;
    const row = await entryStore.get(id);
    const i = row?.identity;
    if (!row || row.mode !== 'institutional' || !i?.issuer || !i?.subject || !(row.expiresAt > now())) return null;
    return {row, identity: i, canRequest: CAN_REQUEST.has(row.status) && Boolean(i.cpf && i.crm && i.uf), contaHash: await sha256(i.issuer + '|' + i.subject)};
  }
  // Intent prepared but never sent (login failed or abandoned): close it so it does not linger.
  async function discardIntent(row) {
    if (row?.mode === 'numbers') { try { await getLedger().discard(row.intent.solicitacaoId); } catch {} }
    if (row?.mode === 'numbers-prd') { try { await getLedger().prdDiscard(row.intent.solicitacaoId); } catch {} }
  }
  const numbersMode = row => row?.mode === 'numbers' || row?.mode === 'numbers-prd';
  // Production request finished on Edge: its full result waits in the rescue area (key = request id). Recording is
  // idempotent (only from 'enviando'), so the return route and the panel can both call it.
  async function settleProduction(l, request) {
    const saved = await rescueStore.get(request.id);
    if (!saved || saved.env !== 'prd' || saved.solicitacaoId !== request.id) return null;
    return l.prdRecord({id: request.id, tipo: saved.tipo, quantidade: saved.quantidade}, saved);
  }
  // Send once, then record. If the database fails after the SNCR answered, the response goes to a rescue area.
  async function sendNumbers(intent, token) {
    const l = getLedger();
    let started;
    try { started = await l.startSend(intent.solicitacaoId); } catch { return 'numbers-unavailable'; }
    if (!started) return 'already-used';
    const result = await postNumbers({base: BASE, origin: ORIGIN, token, request: intent, fetcher});
    const solicitacao = {id: intent.solicitacaoId, tipo: intent.tipo, quantidade: intent.quantidade};
    for (let tentativa = 0; tentativa < 3; tentativa++) {
      try {
        if (result.kind === 'success') return (await l.recordSuccess(solicitacao, result.http, result.body)).estado === 'recebida' ? 'numbers-received' : 'numbers-quarantine';
        await l.recordFailure(intent.solicitacaoId, result.kind === 'refused' ? 'recusada' : 'ambigua', result.http, result.body, result.message);
        return result.kind === 'refused' ? 'numbers-refused' : 'numbers-ambiguous';
      } catch (e) {
        if (e instanceof LedgerError && e.message !== 'registro indisponível') break;
        await pause(300 * (tentativa + 1));
      }
    }
    try { await rescueStore.create(intent.solicitacaoId, {solicitacaoId: intent.solicitacaoId, kind: result.kind, http: result.http, body: result.body, at: now()}); } catch {}
    return 'numbers-unrecorded';
  }
  return async (req, res) => {
    res.setHeader('Cache-Control', 'no-store, max-age=0');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Robots-Tag', 'noindex, nofollow, noarchive');
    if (req.headers.host !== new URL(ORIGIN).host) return json(res, 403, { error: 'Use o domínio configurado do OpenPEP-Rx.' });
    if ((req.url || '').length > 8192) return json(res, 400, { error: 'Retorno inválido.' });
    const url = new URL(req.url, ORIGIN);
    if (url.pathname === '/api/sncr/login') {
      if (req.method !== 'POST') return json(res, 405, { error: 'Método não permitido.' });
      if (req.headers.origin !== ORIGIN) return json(res, 403, { error: 'Origem não autorizada.' });
      if (url.search) return json(res, 400, { error: 'Parâmetros não permitidos.' });
      let body;
      try { body = await readJson(req); } catch { return json(res, 400, { error: 'Pedido inválido.' }); }
      const wantsNumbers = body && typeof body === 'object' && body.tipo !== undefined;
      const env = body && typeof body === 'object' && body.ambiente !== undefined ? body.ambiente : defaultEnvironment;
      if (!Object.hasOwn(GATEWAYS, env)) return json(res, 400, { error: 'Ambiente inválido.' });
      // Production numbers: notifications, RCE and RET, for prescribers released
      // in cockpit_rx.producao_autorizado; recorded apart from the homologation registry.
      let entry = null;
      if (wantsNumbers) {
        const {tipo, quantidade} = body;
        if (![...NR_TYPES, ...RANGE_TYPES].includes(tipo)) return json(res, 400, { error: 'Tipo de receita inválido.' });
        if (NR_TYPES.includes(tipo) ? !(Number.isInteger(quantidade) && quantidade >= 10 && quantidade <= 50) : quantidade !== 1000) return json(res, 400, { error: 'Quantidade inválida: 10 a 50 para notificações; 1000 para RCE/RET.' });
        if (RANGE_TYPES.includes(tipo) && !/^\d{14}$/.test(cnpj || '')) return json(res, 503, { error: 'CNPJ da plataforma não configurado para RCE/RET.' });
        try { entry = await entrySession(req); } catch { return json(res, 503, { error: 'Sessão indisponível. Tente novamente.' }); }
        if (!entry?.canRequest) return json(res, 403, { error: 'Entre no OpenPEP e confirme nome, CRM/UF e CPF antes de solicitar números.' });
      }
      try {
        if (!await store.allow('start',10)) return json(res,429,{error:'Limite temporário de testes atingido. Tente mais tarde.'});
        let intent;
        if (wantsNumbers) {
          const i = entry.identity, l = getLedger();
          try {
            const prescritorId = await l.ensurePrescriber({contaHash: entry.contaHash, cpf: i.cpf, nome: i.fullName || i.name, uf: i.uf, inscricao: i.crm});
            const withCnpj = RANGE_TYPES.includes(body.tipo) ? cnpj : null;
            const s = env === 'prd'
              ? {id: await l.prdPrepare({prescritorId, tipo: body.tipo, quantidade: body.quantidade, cnpj: withCnpj, chave: random()}), tipo: body.tipo, quantidade: body.quantidade, cnpj: withCnpj}
              : await l.prepare({prescritorId, tipo: body.tipo, quantidade: body.quantidade, cnpj: withCnpj, chave: random()});
            // Only what the SNCR request needs; no CPF in the attempt.
            intent = {solicitacaoId: s.id, tipo: s.tipo, quantidade: s.quantidade, conselho: 'CRM', uf: i.uf, documento: i.crm, ...(s.cnpj ? {cnpj: s.cnpj} : {})};
          } catch (e) {
            if (e instanceof LedgerError && e.message !== 'registro indisponível') return json(res, 409, { error: e.message });
            return json(res, 503, { error: 'Registro de números indisponível. Nada foi solicitado.' });
          }
        }
        const attempt = `${random()}.${Math.floor(now() / 1000)}`;
        if (!await store.create(attempt,{revision:0,status:'pending',createdAt:now(),...(intent?{mode:env==='prd'?'numbers-prd':'numbers',intent}:{}),...(env!=='hmg'?{env}:{})})) throw Error();
        cookie(res, attempt, TTL);
        const login = new URL('auth/login', GATEWAYS[env]);
        login.searchParams.set('client_url', CALLBACK);
        login.searchParams.set('state', attempt);
        return json(res, 200, { url: login.href });
      } catch { return json(res,503,{error:'Não foi possível preparar o teste. Tente novamente.'}); }
    }
    if (url.pathname === '/api/sncr/status') {
      if (req.method !== 'GET') return json(res,405,{error:'Método não permitido.'});
      if (url.search) return json(res,400,{error:'Parâmetros não permitidos.'});
      const attempt=readAttempt(req);
      if(validAge(attempt,now())) return json(res,200,{status:'idle'});
      try {
        const row=await store.get(attempt);
        const status=row && (RESULTS.has(row.status)||['pending','exchanging','numbers-sent'].includes(row.status)) ? row.status : 'idle';
        if (status === 'idle' || !row.env) return json(res,200,{status});
        const {http, bloqueio, campos} = row.diagnostico || {};
        return json(res,200,{status, ambiente: row.env, ...(http !== undefined ? {http} : {}), ...(bloqueio ? {bloqueio} : {}), ...(campos ? {campos} : {})});
      } catch { return json(res,503,{error:'Resultado temporariamente indisponível.'}); }
    }
    if (url.pathname === '/api/sncr/callback') {
      if (req.method !== 'GET') return json(res, 405, { error: 'Método não permitido.' });
      const attempt=readAttempt(req);
      let result=validAge(attempt,now());
      if (!result) {
        if (url.searchParams.has('error')) result='provider-error';
        else if(url.searchParams.getAll('session_id').length!==1 || !/^[\x21-\x7e]{1,4096}$/.test(url.searchParams.get('session_id')||'')) result='missing-session';
        else if(!url.searchParams.has('state')) result='return-unverified';
        else if(url.searchParams.getAll('state').length!==1 || !equal(url.searchParams.get('state'),attempt)) result='state-mismatch';
      }
      if(result) {
        cookie(res,'',0);
        let page='/sncr.html';
        if(result!=='invalid-attempt'&&result!=='expired'){ try{ const row=await store.get(attempt); if(numbersMode(row)){ page='/numeros.html'; if(row.status==='pending') await discardIntent(row); } }catch{} }
        return redirect(res,result,page);
      }
      let page='/sncr.html';
      try {
        const row=await store.get(attempt);
        if(numbersMode(row)) page='/numeros.html';
        if(!row || row.status!=='pending' || now()-row.createdAt>TTL*1000 || now()<row.createdAt) return redirect(res,'already-used',page);
        // Production: the exchange runs in the Edge function, whose egress the gateway accepts.
        // Unclaimed here; it re-validates cookie, state and row and claims the attempt itself. A numbers request is
        // marked as being sent first, so nothing can reach the SNCR without a durable trace.
        if(row.env==='prd'){
          if(row.mode==='numbers-prd'){
            let marked;
            try { marked=await getLedger().prdStartSend(row.intent.solicitacaoId); } catch { await discardIntent(row); return redirect(res,'numbers-unavailable',page); }
            if(!marked) return redirect(res,'already-used',page);
          } else if(row.mode) return redirect(res,'already-used',page);
          res.statusCode=303; res.setHeader('Location',`/api/sncr/callback-edge${url.search}`); return res.end();
        }
        const claimed={...row,revision:1,status:'exchanging'};
        if(!await store.swap(attempt,0,claimed)) return redirect(res,'already-used',page);
        if(row.mode==='numbers'){
          let got;
          try { got=await retrieve(url.searchParams.get('session_id')); } catch { got={outcome:'token-unavailable'}; }
          let final;
          if(got?.outcome!=='token-received'||typeof got.token!=='string'){ await discardIntent(row); final=RESULTS.has(got?.outcome)?got.outcome:'token-invalid-response'; }
          else final=await sendNumbers(row.intent,got.token);
          got=null;
          if(!await store.swap(attempt,1,{...claimed,revision:2,status:final})) return redirect(res,'result-unavailable',page);
          return redirect(res,final,page);
        }
        let got;
        try { got=await exchange(url.searchParams.get('session_id'), GATEWAYS[row.env] || BASE); } catch { got='token-unavailable'; }
        if (typeof got === 'string') got = {outcome: got};
        const outcome = RESULTS.has(got?.outcome) ? got.outcome : 'token-invalid-response';
        const diagnostico = {...(Number.isInteger(got?.http) ? {http: got.http} : {}), ...(got?.bloqueio === true ? {bloqueio: true} : {}),
          ...(Array.isArray(got?.campos) ? {campos: got.campos.filter(k => typeof k === 'string').slice(0, 20)} : {})};
        got = null;
        if(!await store.swap(attempt,1,{...claimed,revision:2,status:outcome,...(row.env?{diagnostico}:{})})) return redirect(res,'result-unavailable');
        return redirect(res);
      } catch { return redirect(res,'result-unavailable',page); }
    }
    if (url.pathname === '/api/sncr/sondar') {
      if (req.method !== 'GET') return json(res, 405, { error: 'Método não permitido.' });
      if (url.search) return json(res, 400, { error: 'Parâmetros não permitidos.' });
      try { if (!await store.allow('sondar', 20)) return json(res, 429, { error: 'Limite de sondagens atingido. Aguarde até 15 minutos.' }); }
      catch { return json(res, 503, { error: 'Sondagem indisponível. Tente novamente.' }); }
      try { return json(res, 200, { regiao: region, em: new Date(now()).toISOString(), ...(await probe()) }); }
      catch { return json(res, 503, { error: 'Sondagem indisponível. Tente novamente.' }); }
    }
    // Return from the Edge production request: record its result from the rescue area, then show it.
    if (url.pathname === '/api/sncr/concluir-prd') {
      if (req.method !== 'GET') return json(res, 405, { error: 'Método não permitido.' });
      if (url.search) return json(res, 400, { error: 'Parâmetros não permitidos.' });
      const attempt = readAttempt(req);
      if (validAge(attempt, now())) return redirect(res, 'invalid-attempt', '/numeros.html');
      try {
        const row = await store.get(attempt);
        if (row?.mode !== 'numbers-prd' || row.env !== 'prd') return redirect(res, 'invalid-attempt', '/numeros.html');
        if (row.status === 'numbers-unrecorded') return redirect(res, 'prd-unrecorded', '/numeros.html');
        const estado = await settleProduction(getLedger(), {id: row.intent.solicitacaoId});
        const result = {recebida: 'prd-received', quarentena: 'prd-quarantine', recusada: 'prd-refused', ambigua: 'prd-ambiguous',
          descartada: RESULTS.has(row.status) && row.status.startsWith('token-') ? row.status : 'token-unavailable'}[estado] || 'result-unavailable';
        cookie(res, '', 0);
        return redirect(res, result, '/numeros.html');
      } catch { return redirect(res, 'result-unavailable', '/numeros.html'); }
    }
    if (url.pathname === '/api/sncr/numeros') {
      if (req.method !== 'GET') return json(res, 405, { error: 'Método não permitido.' });
      if (url.search) return json(res, 400, { error: 'Parâmetros não permitidos.' });
      let entry;
      try { entry = await entrySession(req); } catch { return json(res, 503, { error: 'Sessão indisponível.' }); }
      if (!entry) return json(res, 200, { entrou: false });
      const i = entry.identity;
      const base = { entrou: true, nome: i.fullName || i.name || null, crm: i.crm || null, uf: i.uf || null, podeSolicitar: entry.canRequest, sessaoBloqueada: ['failed', 'uncertain', 'closed'].includes(entry.row.status), cnpjConfigurado: /^\d{14}$/.test(cnpj || ''), cnpjPlataforma: /^\d{14}$/.test(cnpj || '') ? cnpj : null };
      try {
        const l = getLedger(), id = await l.prescriberByAccount(entry.contaHash);
        if (!id) return json(res, 200, { ...base, painel: null, producao: null });
        // Production requests still marked as being sent are settled from the rescue area, if their result is there.
        for (const pending of await l.prdSending(id)) { try { await settleProduction(l, {id: pending}); } catch {} }
        return json(res, 200, { ...base, painel: await l.panel(id), producao: await l.prdPanel(id) });
      } catch { return json(res, 503, { ...base, error: 'Registro de números indisponível.' }); }
    }
    return json(res, 404, { error: 'Rota não encontrada.' });
  };
}
export default createHandler();
