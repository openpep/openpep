// Registro de números SNCR (docs/SNCR-NUMERACAO-PLANO.md). As regras de estado e unicidade ficam no banco
// (db/migrations/0001_cockpit_rx_ledger.sql); aqui só se valida a resposta do SNCR e se chamam as funções.
// query(text, params) -> {rows}: compatível com pg.Pool e PGlite.

export const NR_TYPES = ['NRA', 'NRB', 'NRB2', 'NRR', 'NRT'];
export const RANGE_TYPES = ['RCE', 'RET'];
// Anvisa, atualização de 19/10/2026: 16 dígitos; os 14 anteriores continuam válidos.
// Nunca converter o identificador inteiro em Number (16 dígitos podem perder precisão).
// Aceita a máscara do manual e a representação só com dígitos, preservando a resposta.
function numberParts(value) {
  if (typeof value !== 'string') return null;
  const masked = /^(\d{4}\.\d-\d{2}\.)(\d{7}|\d{9})$/.exec(value);
  const plain = /^(\d{7})(\d{7}|\d{9})$/.exec(value);
  const match = masked || plain;
  return match ? {prefix: match[1], sequence: match[2], key: value.replace(/[.-]/g, '')} : null;
}

export class LedgerError extends Error {}

// Notificação de Receita: o manual mostra o campo como lista e também como texto "[a, b]".
export function parseNotificationResponse(body, requested) {
  const raw = body?.numeroReceita ?? body?.numerosReceita ?? body?.numeracoesReceita;
  let items;
  if (Array.isArray(raw)) items = raw;
  else if (typeof raw === 'string') items = raw.trim().replace(/^\[/, '').replace(/\]$/, '').split(',').map(s => s.trim().replace(/^["']|["']$/g, '')).filter(Boolean);
  else return {error: 'resposta sem lista de números'};
  if (!items.length || items.length > requested) return {error: `quantidade inesperada de números (${items.length})`};
  const numbers = [], sequences = [];
  for (const item of items) {
    const m = numberParts(item);
    if (!m) return {error: 'número em formato não reconhecido'};
    numbers.push(item);
    sequences.push(Number(m.sequence));
  }
  if (new Set(numbers.map(n => numberParts(n).key)).size !== numbers.length) return {error: 'resposta contém números duplicados'};
  const saldo = Number.isInteger(body.saldoReceitas) ? body.saldoReceitas : null;
  return {numbers, sequences, saldo, message: typeof body.mensagem === 'string' ? body.mensagem.slice(0, 300) : null};
}

// RCE/RET: faixa início–fim de 1000 números com o mesmo prefixo.
export function expandRangeResponse(body, expected = 1000) {
  const a = numberParts(body?.inicio), b = numberParts(body?.fim);
  if (!a || !b) return {error: 'início ou fim em formato não reconhecido'};
  if (a.prefix !== b.prefix || a.sequence.length !== b.sequence.length) return {error: 'início e fim com prefixos diferentes'};
  if (!Number.isInteger(expected) || expected < 1 || expected > 1000) return {error: 'quantidade inválida'};
  const first = Number(a.sequence), last = Number(b.sequence);
  if (body.quantidade !== expected || last - first + 1 !== expected) return {error: 'faixa não corresponde à quantidade'};
  const numbers = [], sequences = [];
  for (let n = first; n <= last; n++) { numbers.push(a.prefix + String(n).padStart(a.sequence.length, '0')); sequences.push(n); }
  return {numbers, sequences, saldo: null, message: typeof body.mensagem === 'string' ? body.mensagem.slice(0, 300) : null};
}

export function makeLedger(query) {
  async function call(sql, params) {
    try { return (await query(sql, params)).rows; }
    catch (e) {
      // Regras do banco (P0001) têm mensagens próprias; outros erros não saem com detalhes.
      if (e?.code === 'P0001') throw new LedgerError(e.message);
      throw new LedgerError('registro indisponível');
    }
  }
  const one = async (sql, params) => (await call(sql, params))[0];
  return {
    ensurePrescriber: async ({contaHash, cpf, nome, uf, inscricao}) =>
      (await one('select cockpit_rx.garantir_prescritor($1, $2, $3, $4, $5) as id', [contaHash, cpf, nome, uf, inscricao])).id,
    prescriberByAccount: async contaHash => (await one('select cockpit_rx.prescritor_por_conta($1) as id', [contaHash])).id,
    panel: async prescritorId => (await one('select cockpit_rx.painel($1) as painel', [prescritorId])).painel,
    prepare: ({prescritorId, tipo, quantidade, cnpj = null, chave}) =>
      one('select * from cockpit_rx.preparar_solicitacao($1, $2, $3, $4, $5)', [prescritorId, tipo, quantidade, cnpj, chave]),
    startSend: async id => (await one('select cockpit_rx.iniciar_envio($1) as ok', [id])).ok,
    // Sucesso HTTP do SNCR: valida e grava na mesma chamada; resposta inválida vai para quarentena.
    async recordSuccess(solicitacao, http, body) {
      const parsed = RANGE_TYPES.includes(solicitacao.tipo) ? expandRangeResponse(body, solicitacao.quantidade) : parseNotificationResponse(body, solicitacao.quantidade);
      if (parsed.error) {
        await one('select cockpit_rx.registrar_quarentena($1, $2, $3, $4)', [solicitacao.id, http, body ?? null, parsed.error]);
        return {estado: 'quarentena', motivo: parsed.error};
      }
      const r = await one('select cockpit_rx.registrar_recebimento($1, $2, $3, $4, $5, $6, $7) as estado',
        [solicitacao.id, http, body, parsed.numbers, parsed.sequences, parsed.saldo, parsed.message]);
      return {estado: r.estado, quantidade: parsed.numbers.length, saldo: parsed.saldo, mensagem: parsed.message};
    },
    // Recusa (4xx) ou resultado incerto (timeout, 5xx, rede depois do envio). Nunca há repetição automática.
    recordFailure: (id, estado, http, body, mensagem) =>
      one('select cockpit_rx.encerrar_envio($1, $2, $3, $4, $5)', [id, estado, http ?? null, body ?? null, mensagem ?? null]),
    discard: async id => (await one('select cockpit_rx.descartar_solicitacao($1) as ok', [id])).ok,
    reserve: async (prescritorId, tipo, receitaId) => (await one('select cockpit_rx.reservar_numero($1, $2, $3) as numero', [prescritorId, tipo, receitaId])).numero,
    release: async (receitaId, tipo) => (await one('select cockpit_rx.liberar_numero($1, $2) as numero', [receitaId, tipo])).numero,
    giveBack: async (receitaId, tipo) => (await one('select cockpit_rx.devolver_numero($1, $2) as ok', [receitaId, tipo])).ok,
    confirmUse: async (receitaId, tipo, pdfSha256) => (await one('select cockpit_rx.confirmar_uso($1, $2, $3) as numero', [receitaId, tipo, pdfSha256])).numero,
    void: (numero, motivo) => one('select cockpit_rx.inutilizar_numero($1, $2)', [numero, motivo]),
    stock: prescritorId => call('select * from cockpit_rx.estoque($1)', [prescritorId]),
    // Receitas (etapa 3). O PDF assinado trafega em base64 para funcionar igual no driver postgres e no PGlite.
    saveDraft: async (id, prescritorId, tipo, conteudo, sha) =>
      (await one('select cockpit_rx.salvar_rascunho($1, $2, $3, $4, $5) as estado', [id, prescritorId, tipo, conteudo, sha])).estado,
    startIssue: async (id, prescritorId, sha) => (await one('select cockpit_rx.iniciar_emissao($1, $2, $3) as numero', [id, prescritorId, sha])).numero,
    failIssue: async (id, prescritorId) => (await one('select cockpit_rx.falhar_emissao($1, $2) as estado', [id, prescritorId])).estado,
    finishIssue: async (id, prescritorId, pdf, sha, serial) =>
      (await one('select cockpit_rx.concluir_emissao($1, $2, $3, $4, $5) as numero', [id, prescritorId, Buffer.from(pdf).toString('base64'), sha, serial])).numero,
    cancelPrescription: async (id, prescritorId, motivo) =>
      (await one('select cockpit_rx.cancelar_receita($1, $2, $3) as estado', [id, prescritorId, motivo])).estado,
    prescription: async (id, prescritorId) => (await one('select cockpit_rx.receita_do_prescritor($1, $2) as receita', [id, prescritorId])).receita,
    signedPdf: async (id, prescritorId) => {
      const b64 = (await one('select cockpit_rx.receita_pdf($1, $2) as pdf', [id, prescritorId])).pdf;
      return b64 ? Buffer.from(b64, 'base64') : null;
    },
    prescriptions: async prescritorId => (await one('select cockpit_rx.receitas($1) as receitas', [prescritorId])).receitas,
    // Acesso pelo QR da plataforma: só o hash do código do paciente trafega e fica gravado.
    // The patient code is printed on the PDF (migration 0006): stored with the signed PDF, never replaced.
    finishIssueWithAccess: async (id, prescritorId, pdf, sha, serial, codigo, hash) =>
      (await one('select cockpit_rx.concluir_emissao_com_acesso($1, $2, $3, $4, $5, $6, $7) as numero', [id, prescritorId, Buffer.from(pdf).toString('base64'), sha, serial, codigo, hash])).numero,
    accessCode: async (id, prescritorId, codigo, hash) => (await one('select cockpit_rx.codigo_acesso($1, $2, $3, $4) as codigo', [id, prescritorId, codigo, hash])).codigo,
    // Produção (migration 0008): tabela própria, sem estoque; só pedido e resposta preservada.
    prdPrepare: async ({prescritorId, tipo, quantidade, cnpj = null, chave}) =>
      (await one('select cockpit_rx.producao_preparar($1, $2, $3, $4, $5) as id', [prescritorId, tipo, quantidade, cnpj, chave])).id,
    prdStartSend: async id => (await one('select cockpit_rx.producao_iniciar_envio($1) as ok', [id])).ok,
    prdDiscard: async id => (await one('select cockpit_rx.producao_descartar($1) as ok', [id])).ok,
    // result: {kind: 'success' | 'refused' | 'ambiguous' | 'not-sent', http, body, message}. Sucesso é conferido como no HML.
    async prdRecord({id, tipo, quantidade}, result) {
      let estado, numeros = null, motivo = null;
      if (result.kind === 'success') {
        const parsed = RANGE_TYPES.includes(tipo) ? expandRangeResponse(result.body, quantidade) : parseNotificationResponse(result.body, quantidade);
        if (parsed.error) { estado = 'quarentena'; motivo = parsed.error; } else { estado = 'recebida'; numeros = parsed.numbers; }
      } else estado = {refused: 'recusada', ambiguous: 'ambigua', 'not-sent': 'descartada'}[result.kind] || 'ambigua';
      if (result.kind === 'not-sent') motivo = result.message || 'pedido não enviado';
      return (await one('select cockpit_rx.producao_registrar($1, $2, $3, $4, $5, $6, $7) as estado',
        [id, estado, result.http ?? null, result.body ?? null, result.message ?? null, numeros, motivo])).estado;
    },
    prdPanel: async prescritorId => (await one('select cockpit_rx.producao_painel($1) as painel', [prescritorId])).painel,
    prdSending: async prescritorId => (await call('select cockpit_rx.producao_em_envio($1) as id', [prescritorId])).map(r => r.id),
    byAccess: async (id, hash) => {
      const r = (await one('select cockpit_rx.receita_por_acesso($1, $2) as receita', [id, hash])).receita;
      return r ? {...r, pdf: Buffer.from(r.pdf, 'base64')} : null;
    },
  };
}
