// Pedido de números ao SNCR (manual Ed.3, 2.3). Uma chamada por pedido, nunca repetida: o token vale 30 s e o
// pedido não é idempotente. Classifica o resultado para o registro (docs/SNCR-NUMEROS-FLUXO.md, fluxo A).
// Só fetch: roda no Node (homologação) e na Edge (produção).
import {NR_TYPES, RANGE_TYPES} from './ledger.mjs';

export function numbersRequest({tipo, quantidade, conselho = 'CRM', uf, documento, cnpj}) {
  if (NR_TYPES.includes(tipo)) return {path: 'numeracoes/notificacao-receita', body: {receita: tipo, conselho, uf, documento, quantidade}};
  if (RANGE_TYPES.includes(tipo)) return {path: 'numeracoes/receita-especial-retencao', body: {conselho, tipo, documento, uf, cnpj}};
  throw Error('tipo');
}

// Texto curto da mensagem do SNCR para o médico; o corpo inteiro fica no registro.
export function sncrMessage(body) {
  for (const key of ['mensagem', 'message', 'error', 'erro', 'detail']) if (typeof body?.[key] === 'string' && body[key].trim()) return body[key].trim().slice(0, 300);
  return null;
}

// -> {kind: 'success' | 'refused' | 'ambiguous', http, body, message}
export async function postNumbers({base, origin, token, request, fetcher = fetch, timeout = 20000}) {
  const {path, body} = numbersRequest(request);
  let response;
  try {
    response = await fetcher(new URL(path, base).href, {
      method: 'POST', redirect: 'manual', cache: 'no-store', signal: AbortSignal.timeout(timeout),
      headers: {Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json', Origin: origin},
      body: JSON.stringify(body),
    });
  } catch {
    // Timeout ou rede: o SNCR pode ter atendido.
    return {kind: 'ambiguous', http: null, body: null, message: 'sem resposta do SNCR'};
  }
  const http = response.status;
  let data = null;
  try {
    const text = await response.text();
    data = text && text.length <= 262144 ? JSON.parse(text) : null;
  } catch {
    data = null;
  }
  // 204 (Swagger HML): no numbers available for the prescriber; nothing was issued.
  if (http === 204) return {kind: 'refused', http, body: data, message: sncrMessage(data) || 'Nenhuma numeração de receita disponível (HTTP 204).'};
  if (http >= 200 && http < 300) {
    // Sucesso sem JSON legível: pode haver números emitidos; o registro põe em quarentena.
    return {kind: 'success', http, body: data, message: sncrMessage(data)};
  }
  if (http >= 500) return {kind: 'ambiguous', http, body: data, message: sncrMessage(data) || `SNCR respondeu HTTP ${http}`};
  return {kind: 'refused', http, body: data, message: sncrMessage(data) || `SNCR recusou (HTTP ${http})`};
}
