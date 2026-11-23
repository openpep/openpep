const $ = s => document.querySelector(s);
const canonical = 'https://rx-hml.openpep.com.br', gateway = 'https://api-gateway.hmg.apps.anvisa.gov.br', gatewayPrd = 'https://api-gateway.prd.apps.anvisa.gov.br';
// Production (SNCR real): notifications and RCE, only for prescribers released in the database.
const PRD_TYPES = ['NRB', 'NRA', 'NRB2', 'NRR', 'NRT', 'RCE', 'RET'];
const PRD_STATES = {
  preparada: ['Não enviado (login não concluído)', 'idle'], enviando: ['Enviado; resultado não confirmado. Confira antes de pedir de novo', 'bad'],
  recebida: ['Recebido', 'ok'], quarentena: ['Resposta fora do formato: guardada para conferência', 'warn'], ambigua: ['Resultado incerto: pode ter sido atendido', 'bad'],
  recusada: ['Recusado pelo SNCR', 'bad'], descartada: ['Não enviado', 'idle']};
const TYPES = [['NRA', 'Notificação A (NRA)'], ['NRB', 'Notificação B (NRB)'], ['NRB2', 'Notificação B2 (NRB2)'], ['NRR', 'Notificação de retinoides (NRR)'], ['NRT', 'Notificação de talidomida (NRT)'], ['RCE', 'Receita de controle especial (RCE)'], ['RET', 'Receita sujeita a retenção (RET)']];
const RANGE = ['RCE', 'RET'];
const STATES = {
  preparada: ['Não enviado (login não concluído)', 'idle'], enviando: ['Em envio', 'warn'], recebida: ['Recebido', 'ok'],
  quarentena: ['Em conferência: nada entrou no estoque', 'warn'], ambigua: ['Resultado incerto: pode ter sido atendido', 'bad'],
  recusada: ['Recusado pelo SNCR', 'bad'], descartada: ['Descartado', 'idle'],
};
const RESULTS = {
  'numbers-received': ['Números recebidos e guardados no registro.', 'good'],
  'numbers-quarantine': ['O SNCR respondeu, mas a resposta não passou na conferência. Nada entrou no estoque; a resposta ficou guardada para revisão.', 'bad'],
  'numbers-refused': ['O SNCR recusou o pedido. A mensagem está no histórico.', 'bad'],
  'numbers-no-balance': ['Não há números deste tipo atribuídos a você no SNCR. Em homologação, gere-os em sncr-treinamento.anvisa.gov.br (Requisições de Numeração → Nova Solicitação de Numeração) e peça de novo aqui.', 'bad'],
  'numbers-ambiguous': ['Sem resposta confiável do SNCR: o pedido pode ter sido atendido. Não repita agora; siga o roteiro de conferência.', 'bad'],
  'numbers-unrecorded': ['O SNCR respondeu, mas o registro não gravou. A resposta foi preservada para recuperação. Avise o suporte antes de um novo pedido.', 'bad'],
  'numbers-unavailable': ['O registro estava indisponível; nada foi enviado ao SNCR. Tente novamente.', 'bad'],
  'token-rejected': ['O SNCR recusou a troca do login. Nenhum pedido foi enviado. Tente de novo.', 'bad'],
  'token-unavailable': ['O login não foi confirmado. Nenhum pedido foi enviado. Tente de novo.', 'bad'],
  'token-invalid-response': ['A resposta do login não teve o formato esperado. Nenhum pedido foi enviado.', 'bad'],
  'already-used': ['Este retorno já foi usado. Confira o histórico abaixo.', 'bad'],
  'result-unavailable': ['Não foi possível confirmar o resultado. Confira o histórico antes de pedir de novo.', 'bad'],
  'provider-error': ['O login gov.br foi cancelado ou retornou erro. Nenhum pedido foi enviado.', 'bad'],
  'state-mismatch': ['O retorno não corresponde ao pedido iniciado. Nada foi enviado.', 'bad'],
  'missing-session': ['O retorno não trouxe o identificador do login. Nada foi enviado.', 'bad'],
  'return-unverified': ['O retorno não trouxe a correlação do pedido. Nada foi enviado.', 'bad'],
  'expired': ['O pedido expirou antes do retorno do gov.br. Nada foi enviado.', 'bad'],
  'invalid-attempt': ['Não há um pedido em andamento neste navegador.', 'bad'],
  'prd-received': ['Produção: números recebidos e guardados.', 'good'],
  'prd-refused': ['Produção: o SNCR recusou o pedido. A mensagem está na seção Produção.', 'bad'],
  'prd-no-balance': ['Produção: sem saldo aprovado pela Vigilância Sanitária para este tipo. Nenhum número foi retirado.', 'bad'],
  'prd-quarantine': ['Produção: o SNCR respondeu fora do formato esperado. A resposta foi guardada para conferência.', 'bad'],
  'prd-ambiguous': ['Produção: sem resposta confiável do SNCR; o pedido pode ter sido atendido. Não repita agora.', 'bad'],
  'prd-unrecorded': ['Produção: o SNCR respondeu, mas a resposta não foi gravada. Não repita; avise o suporte (fica registrada nos logs).', 'bad'],
};
let data = null, busy = false;
const params = new URL(location.href).searchParams, result = params.get('result');
if (location.search) history.replaceState(null, '', location.pathname);
if (RESULTS[result]) { $('#result').textContent = RESULTS[result][0]; $('#result').className = RESULTS[result][1]; }
for (const [value, label] of TYPES) $('#type').append(new Option(label, value, false, value === 'NRB'));
for (const t of PRD_TYPES) $('#prd-type').append(new Option(TYPES.find(([v]) => v === t)[1], t, false, t === 'NRB'));

// NR numbers are generated in the SNCR (training site in homologation); the API only hands out that balance.
const noBalance = s => s.http === 204 || /saldo dispon[ií]vel|gerar novos n[uú]meros|nenhuma numera/i.test(s.mensagem || '');
const when = iso => iso ? new Date(iso).toLocaleString('pt-BR', {day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit'}) : '';
function cell(text, zero) { const td = document.createElement('td'); td.textContent = text; if (zero) td.className = 'zero'; return td; }

function render() {
  const last = data?.painel?.solicitacoes?.[0];
  if (result === 'numbers-refused' && last && noBalance(last)) { $('#result').textContent = RESULTS['numbers-no-balance'][0]; $('#result').className = 'bad'; }
  if (!data?.entrou) { $('#professional').textContent = 'Você ainda não entrou no OpenPEP.'; $('#signin').hidden = false; $('#panel').hidden = true; return; }
  $('#signin').hidden = true; $('#panel').hidden = false;
  $('#professional').textContent = data.nome ? `${data.nome}${data.crm ? ` · CRM ${data.crm}/${data.uf}` : ''}` : 'Conta institucional';
  const p = data.painel || {estoque: [], limites: {}, saldoSncr: {}, solicitacoes: []};
  const stock = Object.fromEntries((p.estoque || []).map(e => [e.tipo, e]));
  $('#stock').replaceChildren(...TYPES.map(([t]) => {
    const e = stock[t] || {disponiveis: 0, reservados: 0, usados: 0, inutilizados: 0}, l = p.limites?.[t], sal = p.saldoSncr?.[t];
    const tr = document.createElement('tr');
    const available = cell(e.disponiveis); if (e.disponiveis < 5) available.className = 'low'; // fewer than 5 numbers: red, as on the prescription page
    tr.append(cell(t), available, cell(e.reservados, !e.reservados), cell(e.usados, !e.usados), cell(e.inutilizados, !e.inutilizados),
      cell(l ? `${l.usado}/${l.maximo} ${l.periodo === 'mes' ? 'pedidos no mês' : 'hoje'}` : '—'), cell(sal ? `${sal.saldo} em ${when(sal.em)}` : '—', !sal));
    return tr;
  }));
  const items = (p.solicitacoes || []).map(s => {
    const li = document.createElement('li'), head = document.createElement('div'), state = document.createElement('span'), meta = document.createElement('span');
    const [label, tone] = STATES[s.estado] || [s.estado, 'idle'];
    head.className = 'head'; state.className = `state ${tone}`; state.textContent = label;
    meta.textContent = `${s.tipo} · ${s.quantidade} · ${when(s.criadaEm)}${s.http ? ` · HTTP ${s.http}` : ''}`;
    head.append(meta, state); li.append(head);
    if (s.mensagem) { const m = document.createElement('span'); m.className = 'msg'; m.textContent = s.mensagem; li.append(m); }
    if (s.estado === 'recusada' && noBalance(s)) { const h = document.createElement('span'); h.className = 'msg'; h.textContent = 'Gere os números no SNCR de treinamento (Requisições de Numeração → Nova Solicitação de Numeração) e peça de novo aqui.'; li.append(h); }
    return li;
  });
  $('#history').replaceChildren(...items); $('#history-empty').hidden = items.length > 0;
  renderProduction();
  $('#blocked').hidden = data.podeSolicitar;
  $('#blocked').textContent = data.podeSolicitar ? '' : data.sessaoBloqueada
    ? 'Esta sessão não permite pedir números (a conferência do certificado falhou ou a sessão acabou). Use "Entrar de novo" na tela de receitas.'
    : 'Confirme nome, CRM/UF e CPF na entrada do OpenPEP para solicitar números.';
  updateForm();
}
function updateForm() {
  const t = $('#type').value, range = RANGE.includes(t), l = data?.painel?.limites?.[t];
  $('#quantity').disabled = range; if (range) $('#quantity').value = 1000; else if (Number($('#quantity').value) > 50) $('#quantity').value = 10;
  const left = l ? l.maximo - l.usado : null;
  $('#limits').textContent = range
    ? `Lote fixo de 1000 números; até 3 pedidos por mês${left !== null ? ` (restam ${left})` : ''}.${data?.cnpjConfigurado ? '' : ' CNPJ da plataforma não configurado.'}`
    : `De 10 a 50 por pedido; até 50 por dia${left !== null ? ` (restam ${left} hoje)` : ''}.`;
  const blocked = !data?.podeSolicitar || !$('#consent').checked || busy || location.origin !== canonical || (range && !data?.cnpjConfigurado) || (left !== null && (range ? left < 1 : left < 10));
  $('#submit').disabled = blocked;
}
function renderProduction() {
  const p = data?.producao;
  $('#prd').hidden = !p;
  if (!p) return;
  const last = p.solicitacoes?.[0];
  if (result === 'prd-refused' && last && noBalance(last)) { $('#result').textContent = RESULTS['prd-no-balance'][0]; $('#result').className = 'bad'; }
  $('#prd-status').textContent = p.liberado ? `Liberado para o seu CRM. RCE neste mês: ${p.rceNoMes} de 3 · RET: ${p.retNoMes ?? 0} de 3.` : 'Seu cadastro não está liberado para pedidos de produção.';
  $('#prd-request').hidden = !p.liberado;
  $('#prd-history').replaceChildren(...(p.solicitacoes || []).map(s => {
    const li = document.createElement('li'), head = document.createElement('div'), state = document.createElement('span'), meta = document.createElement('span');
    const [label, tone] = PRD_STATES[s.estado] || [s.estado, 'idle'];
    head.className = 'head'; state.className = `state ${tone}`; state.textContent = label;
    meta.textContent = `${s.tipo} · ${s.quantidade} · ${when(s.criada_em)}${s.http ? ` · HTTP ${s.http}` : ''}`;
    head.append(meta, state); li.append(head);
    const lines = [s.recebidos ? `${s.recebidos} números: ${s.primeiro}${s.recebidos > 1 ? ` a ${s.ultimo}` : ''}` : '', s.mensagem || '', s.motivo || ''];
    for (const text of lines.filter(Boolean)) { const m = document.createElement('span'); m.className = 'msg'; m.textContent = text; li.append(m); }
    return li;
  }));
  updateProduction();
}
function updateProduction() {
  const t = $('#prd-type').value, rce = RANGE.includes(t), p = data?.producao;
  $('#prd-quantity').disabled = rce; if (rce) $('#prd-quantity').value = 1000; else if (Number($('#prd-quantity').value) > 50) $('#prd-quantity').value = 10;
  $('#prd-note').textContent = rce
    ? `Lote fixo de 1000 números no CNPJ da plataforma; até 3 pedidos por mês.${data?.cnpjConfigurado ? '' : ' CNPJ da plataforma não configurado.'}`
    : 'De 10 a 50. Em produção, só vem o saldo que a Vigilância Sanitária já aprovou para você; sem saldo, o SNCR recusa e nada é retirado.';
  $('#prd-consent-text').textContent = rce
    ? `Entendo que este pedido gera 1.000 números reais de ${t} no CNPJ da plataforma (${data?.cnpjPlataforma || 'não configurado'}), consome 1 dos 3 pedidos do mês e não pode ser desfeito.`
    : 'Entendo que, se a Visa já tiver aprovado saldo, este pedido retira números reais de produção, que não podem ser devolvidos.';
  const quantity = Number($('#prd-quantity').value);
  $('#prd-submit').disabled = !p?.liberado || !data?.podeSolicitar || !$('#prd-consent').checked || busy || location.origin !== canonical
    || (rce ? !data?.cnpjConfigurado || (t === 'RET' ? p.retNoMes : p.rceNoMes) >= 3 : !(Number.isInteger(quantity) && quantity >= 10 && quantity <= 50));
}
async function load() {
  try {
    const r = await fetch('/api/sncr/numeros', {credentials: 'same-origin', cache: 'no-store'});
    data = await r.json();
    if (!r.ok && !data?.entrou) throw Error();
    if (data.error && !RESULTS[result]) { $('#result').textContent = data.error; $('#result').className = 'bad'; }
  } catch { data = null; $('#professional').textContent = 'Não foi possível consultar seus números.'; }
  render();
}
$('#type').onchange = updateForm; $('#quantity').oninput = updateForm; $('#consent').onchange = updateForm;
$('#prd-type').onchange = () => { $('#prd-consent').checked = false; updateProduction(); }; $('#prd-quantity').oninput = updateProduction; $('#prd-consent').onchange = updateProduction;
$('#prd-request').onsubmit = async e => {
  e.preventDefault(); if ($('#prd-submit').disabled) return;
  busy = true; updateProduction(); $('#result').className = ''; $('#result').textContent = 'Preparando o pedido de produção…';
  try {
    const tipo = $('#prd-type').value, quantidade = RANGE.includes(tipo) ? 1000 : Number($('#prd-quantity').value);
    const r = await fetch('/api/sncr/login', {method: 'POST', credentials: 'same-origin', cache: 'no-store', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ambiente: 'prd', tipo, quantidade})});
    const body = await r.json();
    if (!r.ok) throw Error(body.error || 'Não foi possível preparar o pedido.');
    const destination = new URL(body.url);
    if (destination.origin !== gatewayPrd || destination.pathname !== '/api-sncr/api/v1/auth/login') throw Error('Destino de login inesperado.');
    $('#result').textContent = 'Abrindo o login gov.br de produção…';
    location.assign(destination.href);
  } catch (err) { busy = false; $('#result').textContent = err.message; $('#result').className = 'bad'; updateProduction(); }
};
$('#request').onsubmit = async e => {
  e.preventDefault(); if ($('#submit').disabled) return;
  busy = true; updateForm(); $('#result').className = ''; $('#result').textContent = 'Preparando o pedido…';
  try {
    const tipo = $('#type').value, quantidade = RANGE.includes(tipo) ? 1000 : Number($('#quantity').value);
    const r = await fetch('/api/sncr/login', {method: 'POST', credentials: 'same-origin', cache: 'no-store', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ambiente: 'hmg', tipo, quantidade})});
    const body = await r.json();
    if (!r.ok) throw Error(body.error || 'Não foi possível preparar o pedido.');
    const destination = new URL(body.url);
    if (destination.origin !== gateway || destination.pathname !== '/api-sncr/api/v1/auth/login') throw Error('Destino de login inesperado.');
    $('#result').textContent = 'Abrindo o login gov.br…';
    location.assign(destination.href);
  } catch (err) { busy = false; $('#result').textContent = err.message; $('#result').className = 'bad'; updateForm(); }
};
if (location.origin !== canonical) $('#professional').textContent = `Abra ${canonical}/numeros.html.`; else load();
