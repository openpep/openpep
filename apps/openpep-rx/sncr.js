const canonical = 'https://rx-hml.openpep.com.br';
const status = document.querySelector('#status');
const statusPrd = document.querySelector('#status-prd');
const start = document.querySelector('#start');
const startPrd = document.querySelector('#start-prd');
const probeButton = document.querySelector('#probe');
const probeResult = document.querySelector('#probe-result');
const gateways = {hmg: 'https://api-gateway.hmg.apps.anvisa.gov.br', prd: 'https://api-gateway.prd.apps.anvisa.gov.br'};
const results = {
  'idle': 'Pronto para conectar sua conta Gov.br. Escolha o ambiente abaixo.',
  'pending': 'Tentativa preparada. Conclua o login Gov.br ou inicie uma nova tentativa.',
  'exchanging': 'A troca foi iniciada, mas ainda não há resultado confirmado. Não reutilize o retorno. Atualize a página para conferir.',
  'token-received': 'Teste concluído: o SNCR entregou um token Bearer ao servidor, que o descartou. Nenhum número foi solicitado. Vínculo profissional e autorização de numeração ainda não foram testados.',
  'token-rejected': 'O SNCR recusou a troca. O identificador pode ter expirado ou já ter sido usado, ou a origem pode não ter sido aceita. Inicie um novo login; a chamada não será repetida.',
  'token-unavailable': 'A troca não foi confirmada. O identificador pode ter sido consumido; a chamada não será repetida. Inicie um novo login.',
  'token-invalid-response': 'A resposta não correspondeu ao formato esperado do token. O conteúdo foi descartado. Inicie um novo login.',
  'invalid-attempt': 'Não há uma tentativa válida neste navegador. Inicie novamente por esta página.',
  'expired': 'A tentativa expirou. Inicie novamente por esta página.',
  'provider-error': 'O serviço retornou um erro ou cancelamento. Nenhum token foi recuperado.',
  'missing-session': 'O retorno não trouxe um identificador de sessão válido. Nenhum token foi recuperado.',
  'return-unverified': 'O retorno não trouxe o state da tentativa. A troca foi bloqueada para não aceitar um retorno sem correlação. Precisamos confirmar esse comportamento no novo gateway.',
  'state-mismatch': 'O state recebido não corresponde à tentativa. O retorno foi recusado.',
  'already-used': 'Esta tentativa não está mais disponível para troca. Confira o resultado abaixo ou inicie um novo login.',
  'result-unavailable': 'Não foi possível confirmar o resultado. A troca pode ter ocorrido; não reutilize o identificador. Inicie um novo login.'
};
// Production login-only test: what the token exchange answered, in plain words.
function production(data){
  const parts=['Produção:'];
  if(data.status==='token-received') parts.push('o SNCR de produção entregou um token Bearer ao servidor da Vercel, que o descartou. Nenhum número foi solicitado.');
  else if(data.bloqueio) parts.push('o Cloudflare da Anvisa bloqueou a troca do token feita pelo servidor da Vercel.');
  else if(data.status==='token-rejected' && data.http>=500) parts.push(`o gateway de produção respondeu com erro do servidor (HTTP ${data.http}). Tente mais tarde.`);
  else if(data.status==='token-rejected') parts.push(`o SNCR de produção recusou a troca (HTTP ${data.http}). O identificador pode ter expirado ou a origem pode não ter sido aceita.`);
  else parts.push(results[data.status]||'resultado desconhecido.');
  if(data.campos?.length) parts.push(`Campos da resposta: ${data.campos.join(', ')}.`);
  return parts.join(' ');
}
function cell(hop){
  const td=document.createElement('td');
  if(!hop||hop.http===null){td.textContent='sem resposta';td.className='bad';return td;}
  let text=`HTTP ${hop.http}`;
  if(hop.bloqueio){text+=' · bloqueado pelo Cloudflare';td.className='bad';}
  else if(hop.destino){text+=` → ${hop.destino}`;td.className=hop.http>=300&&hop.http<400?'ok':'';}
  else if(hop.http>=500)td.className='bad';
  if(hop.mensagem)text+=` · “${hop.mensagem}”`;
  td.textContent=text;return td;
}
function renderProbe(data,label){
  const title=document.createElement('p');title.className='probe-title';title.textContent=label;
  const table=document.createElement('table');
  const head=table.createTHead().insertRow();
  for(const h of ['Gateway','Raiz da API (sem token)','Início do login com este domínio'])head.appendChild(Object.assign(document.createElement('th'),{textContent:h}));
  const body=table.createTBody();
  for(const [env,label] of [['hmg','Homologação'],['prd','Produção']]){const row=body.insertRow();row.appendChild(Object.assign(document.createElement('th'),{textContent:label}));row.appendChild(cell(data[env]?.raiz));row.appendChild(cell(data[env]?.login));}
  const note=document.createElement('p');
  note.textContent=`Sondado pela Vercel${data.regiao?` (região ${data.regiao})`:''} em ${new Date(data.em).toLocaleString('pt-BR')}.`;
  return [title,table,note];
}
// Node (serverless) and Edge leave the Vercel network differently; some upstream networks only accept Edge.
const probes=[['/api/sncr/sondar','Função Node (servidor)'],['/api/sncr/sondar-edge','Função Edge']];
const errors=new Set(['invalid-attempt','expired','provider-error','missing-session','return-unverified','state-mismatch','already-used','result-unavailable']);
const url = new URL(location.href), result=url.searchParams.get('result');
if (url.search) history.replaceState(null, '', '/sncr.html');
const canonicalPage=location.origin===canonical;
start.disabled=true;startPrd.disabled=true;probeButton.disabled=!canonicalPage;
if (!canonicalPage) status.textContent=`Para iniciar o teste, abra ${canonical}/sncr.html.`;
else {
  if(errors.has(result)) status.textContent=results[result];
  fetch('/api/sncr/status',{credentials:'same-origin',cache:'no-store'}).then(async response=>{
    if(!response.ok) throw Error();
    const data=await response.json();
    // Production results go to the production section, which is scrolled into view on return.
    if(data.ambiente==='prd'){
      statusPrd.textContent=data.status!=='pending'&&data.status!=='exchanging'?production(data):'Produção: '+(results[data.status]||'Resultado desconhecido. Inicie novamente.');
      statusPrd.dataset.result=data.status==='token-received'?'ok':(data.status==='pending'||data.status==='exchanging'?'':'bad');
      statusPrd.scrollIntoView({block:'center'});
      if(!errors.has(result)) status.textContent=results.idle;
    }
    else if(!errors.has(result)) status.textContent=results[data.status]||'Resultado desconhecido. Inicie novamente.';
    else if(result==='already-used' && data.status==='token-received') status.textContent=results['token-received'];
  }).catch(()=>{if(!errors.has(result))status.textContent='Não foi possível consultar o resultado. Você pode iniciar uma nova tentativa.';}).finally(()=>{start.disabled=false;startPrd.disabled=false;});
}
document.querySelector('#copy').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText(document.querySelector('#callback').value); status.textContent = 'URL de retorno copiada.'; }
  catch { document.querySelector('#callback').select(); status.textContent = 'Selecione e copie a URL de retorno acima.'; }
});
async function begin(ambiente, button) {
  start.disabled = true; startPrd.disabled = true;
  status.textContent = 'Preparando o redirecionamento…';
  try {
    const init = { method: 'POST', credentials: 'same-origin', cache: 'no-store' };
    Object.assign(init, { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ambiente }) });
    const response = await fetch('/api/sncr/login', init);
    if (!response.ok) throw new Error('start');
    const data = await response.json();
    const destination = new URL(data.url);
    if (destination.origin !== gateways[ambiente] || destination.pathname !== '/api-sncr/api/v1/auth/login') throw new Error('destination');
    location.assign(destination.href);
  } catch { status.textContent = 'Não foi possível iniciar o teste. Aguarde e tente novamente.'; start.disabled = false; startPrd.disabled = false; button.focus(); }
}
start.addEventListener('click', () => begin('hmg', start));
startPrd.addEventListener('click', () => begin('prd', startPrd));
probeButton.addEventListener('click', async () => {
  probeButton.disabled = true;
  probeResult.textContent = 'Sondando os gateways a partir da Vercel…';
  const parts = await Promise.all(probes.map(async ([path, label]) => {
    try {
      const response = await fetch(path, { credentials: 'same-origin', cache: 'no-store' });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(data.error || 'Sondagem indisponível.');
      return renderProbe(data, label);
    } catch (e) { return [Object.assign(document.createElement('p'), { textContent: `${label}: ${e.message || 'sondagem indisponível.'}` })]; }
  }));
  const hint = Object.assign(document.createElement('p'), { textContent: 'Um redirecionamento no início do login indica que o gateway aceitou este domínio.' });
  probeResult.replaceChildren(...parts.flat(), hint);
  probeButton.disabled = false;
});
