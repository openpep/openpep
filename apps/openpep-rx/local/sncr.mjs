// SPDX-License-Identifier: AGPL-3.0-or-later
import {randomBytes, timingSafeEqual} from 'node:crypto';
import {NR_TYPES, RANGE_TYPES} from '../api/ledger.mjs';
import {GATEWAYS, blockedByCloudflare} from '../api/sncr-probe.mjs';
import {postNumbers} from '../api/sncr-numbers.mjs';
import {bounded} from '../api/http-utils.mjs';
import {ownerOf} from './database.mjs';

const same = (a,b) => /^[a-f0-9]{64}$/.test(a || '') && /^[a-f0-9]{64}$/.test(b || '') && timingSafeEqual(Buffer.from(a), Buffer.from(b));
export function sncrConfig(body) {
  if (!['hmg','prd'].includes(body.environment) || typeof body.enabled !== 'boolean') throw Error('Escolha homologação ou produção.');
  if (body.enabled && body.environment === 'prd' && body.confirmProduction !== true) throw Error('Confirme a ativação do SNCR de produção.');
  const cnpj = String(body.cnpj || '').replace(/\D/g,'');
  if (cnpj && !/^\d{14}$/.test(cnpj)) throw Error('Confira o CNPJ da plataforma.');
  return {enabled:body.enabled, environment:body.environment, cnpj};
}
export function createLocalSNCR({db, fetcher = fetch, now = Date.now}) {
  return {
    start(body, origin) {
      const profile = db.profile(), config = db.config();
      if (!profile || !config.enabled) throw Error('Configure o emitente e ative o SNCR em Dados locais.');
      if (body.confirm !== true || (config.environment === 'prd' && body.confirmProduction !== true)) throw Error('Confirme o pedido de numeração e seu ambiente.');
      const type = body.tipo, range = RANGE_TYPES.includes(type), quantity = range ? 1000 : Number(body.quantidade);
      if (!range && (!NR_TYPES.includes(type) || !Number.isInteger(quantity) || quantity < 10 || quantity > 50)) throw Error('Solicite de 10 a 50 notificações.');
      if (range && !config.cnpj) throw Error('Configure o CNPJ da plataforma para RCE ou RET.');
      const request = {tipo:type, quantidade:quantity, conselho:'CRM', uf:profile.uf, documento:profile.crm, ...(range ? {cnpj:config.cnpj} : {})};
      const state = randomBytes(32).toString('hex');
      db.beginNumbers({owner:ownerOf(profile), environment:config.environment, type, quantity, request, state, now:now()});
      const url = new URL('auth/login', GATEWAYS[config.environment]);
      url.searchParams.set('client_url', origin + '/sncr/retorno'); url.searchParams.set('state', state);
      return {url:url.href, state};
    },
    async finish(url, cookie, origin) {
      const state = url.searchParams.get('state'), session = url.searchParams.get('session_id');
      if (!same(state, cookie) || url.searchParams.getAll('state').length !== 1 || url.searchParams.getAll('session_id').length !== 1 || !/^[\x21-\x7e]{1,4096}$/.test(session || '') || url.searchParams.has('error')) throw Error('Retorno do SNCR inválido ou não confirmado.');
      const row = db.claimNumbers(state, now());
      let token, http = null, failure = 'Não foi possível conectar ao serviço de autenticação do SNCR.';
      try {
        const tokenURL = new URL('auth/token', GATEWAYS[row.environment]); tokenURL.searchParams.set('session_id', session);
        const response = await fetcher(tokenURL, {headers:{Accept:'application/json', Origin:origin}, redirect:'error', cache:'no-store', signal:AbortSignal.timeout(10000)});
        http = response.status;
        failure = blockedByCloudflare(response) ? 'O acesso ao SNCR foi bloqueado pela proteção de rede (Cloudflare).' : !response.ok ? `O SNCR recusou a autenticação (HTTP ${http}). Confira o endereço cadastrado da plataforma e inicie um novo login.` : 'O SNCR retornou uma resposta de autenticação inválida.';
        if (!response.ok || !/^application\/json\b/i.test(response.headers.get('content-type') || '')) throw Error('token');
        const data = JSON.parse((await bounded(response, 65536)).toString());
        if (data.token_type !== 'Bearer' || !/^[\x21-\x7e]{1,32768}$/.test(data.access_token || '')) throw Error('token');
        token = data.access_token;
      } catch {
        return db.recordNumbers(row, {kind:'not-sent', http, body:null, message:failure + ' Nenhum pedido de números foi enviado.'});
      }
      // No retries and no token persistence. The Anvisa endpoint checks that the
      // authenticated professional is entitled to request this council registration.
      const result = await postNumbers({base:GATEWAYS[row.environment], origin, token, request:JSON.parse(row.request), fetcher});
      token = null;
      return db.recordNumbers(row, result);
    },
  };
}
