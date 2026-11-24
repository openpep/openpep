// SPDX-License-Identifier: AGPL-3.0-or-later
import {rxFetch as fetch, HOSTED} from './local-client.js';
const $=id=>document.getElementById(id);
let token,lot;
const status=text=>{$('status').textContent=text;};
const formData=form=>Object.fromEntries(new FormData(form));
async function api(path,body){const r=await fetch('/api/local/'+path,{method:body?'POST':'GET',cache:'no-store',headers:{'X-OpenPEP-Request':'local','X-OpenPEP-Local':token||'',...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined});const data=await r.json();if(!r.ok)throw Error(data.error||'Não foi possível concluir.');return data;}
async function relay(path,body){const r=await fetch('/api/relay/'+path,{method:body?'POST':'GET',cache:'no-store',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined});const data=await r.json();if(!r.ok)throw Error(data.error||'Não foi possível consultar o ambiente web.');return data;}
$('profile-form').elements.uf.add(new Option('Selecione',''));
for(const uf of 'AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SE SP TO'.split(' '))$('profile-form').elements.uf.add(new Option(uf,uf));
const labels={recebido:'Recebido',aguardando:'Aguardando login',enviando:'Enviando',incerto:'Resultado incerto',recusado:'Recusado','nao-enviado':'Não enviado',quarentena:'A conferir',concluido:'Concluído',autenticando:'Em processamento'};
function rows(target,data){$(target).replaceChildren(...data.map(values=>{const tr=document.createElement('tr');for(const value of values){const td=document.createElement('td');td.textContent=value??'—';tr.append(td);}return tr;}));}
async function load(){
  const data=await api('settings');
  for(const [key,value]of Object.entries(data.profile||{}))if($('profile-form').elements[key])$('profile-form').elements[key].value=value;
  for(const [key,value]of Object.entries(data.sncr)){const el=$('sncr-form').elements[key];if(el)el.type==='checkbox'?el.checked=value:el.value=value;}
  $('database-path').textContent=data.path;
  $('destination-download').disabled=!data.profile;$('portal-link').href=data.portal;
  $('stock').replaceChildren(...data.numbers.map(r=>{const span=document.createElement('span');span.className='stock-chip';span.textContent=`${r.environment==='prd'?'Produção':'Homologação'} · ${r.type} · ${r.count} ${r.status}`;return span;}));
  rows('requests',data.requests.map(r=>[new Date(r.created_at).toLocaleString('pt-BR'),r.environment==='prd'?'Produção':'Homologação',r.type,r.quantity,labels[r.status]||r.status,r.message||'—']));
  rows('numbers',data.allocated.map(r=>[r.environment,r.number,r.type,r.status,r.document_id]));$('request').disabled=!data.profile||(!HOSTED&&!data.sncr.enabled);
}
function downloadJSON(value,name){const url=URL.createObjectURL(new Blob([JSON.stringify(value,null,2)],{type:'application/json'})),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
$('destination-download').onclick=async()=>{try{downloadJSON(await api('sncr/destination',{}),'openpep-rx-estoque.json');$('lot-status').textContent='Identificação baixada. Selecione esse arquivo no portal para solicitar números para este banco.';}catch(error){$('lot-status').textContent=error.message;}};
async function review(bundle){
  lot=null;$('lot-review').hidden=true;$('lot-confirm').checked=false;$('lot-production').checked=false;
  const summary=await api('sncr/inspect-lot',{bundle});lot=bundle;
    $('lot-summary').textContent=`${summary.quantity} números ${summary.type} · ${summary.environment==='prd'?'PRODUÇÃO':'HOMOLOGAÇÃO'} · CRM ${summary.crm}/${summary.uf} · Portal ${summary.issuer}`;
    $('lot-production-label').hidden=summary.environment!=='prd';$('lot-review').hidden=false;$('lot-status').textContent='Assinatura do lote e estoque de destino conferidos. Revise os dados e confirme a importação.';
}
$('lot-file').onchange=async e=>{
  try{const file=e.target.files[0];if(!file)return;if(file.size>400000)throw Error('Arquivo de lote acima do limite.');await review(JSON.parse(await file.text()));}
  catch(error){lot=null;$('lot-review').hidden=true;$('lot-status').textContent=error.message;}finally{e.target.value='';}
};
$('lot-import').onclick=async()=>{
  $('lot-import').disabled=true;
  try{if(!lot)throw Error('Selecione o lote do portal.');const result=await api('sncr/import-lot',{bundle:lot,confirm:$('lot-confirm').checked,confirmProduction:$('lot-production').checked});await load();$('lot-status').textContent=result.alreadyImported?'Este lote já estava importado. Nenhum número foi duplicado ou recolocado no estoque.':`${result.quantity} números importados em ${result.environment==='prd'?'produção':'homologação'}. O estoque está pronto para a revisão das receitas.`;lot=null;$('lot-review').hidden=true;}catch(error){$('lot-status').textContent=error.message;}finally{$('lot-import').disabled=false;}
};
// The web environment hands over only the lot signed by the portal; the local helper verifies it before import.
async function fetchLot(id){
  await review(await relay('portal/download',{id}));
  $('transferencia').scrollIntoView();status('Lote assinado recebido do portal. Confira os dados e confirme a importação.');
}
async function loadRelay(){
  if(!HOSTED)return;
  $('web-history').hidden=false;
  const data=await relay('portal/history');
  $('web-requests').replaceChildren(...data.requests.map(r=>{
    const row=document.createElement('p'),text=document.createElement('span'),button=document.createElement('button');
    text.textContent=`${new Date(r.createdAt).toLocaleString('pt-BR')} · ${r.environment==='prd'?'Produção':'Homologação'} · ${r.type} · ${r.count||r.quantity} · ${labels[r.status]||r.status} ${r.message||''} `;
    button.type='button';button.textContent='Trazer lote para este computador';button.disabled=!(r.status==='concluido'&&r.count);
    button.onclick=async()=>{button.disabled=true;try{await fetchLot(r.id);}catch(error){status(error.message);}finally{button.disabled=false;}};
    row.append(text,button);return row;
  }));
}
$('profile-form').onsubmit=async e=>{e.preventDefault();try{await api('settings',{profile:formData(e.target)});status('Emitente salvo localmente.');await load();}catch(error){status(error.message);}};
$('sncr-form').onsubmit=async e=>{e.preventDefault();const data=formData(e.target);data.enabled=e.target.elements.enabled.checked;data.confirmProduction=e.target.elements.confirmProduction.checked;try{await api('settings',{sncr:data});status('Configuração SNCR salva. Nenhum pedido foi enviado.');await load();}catch(error){status(error.message);}};
$('request-form').elements.tipo.onchange=()=>{const range=['RCE','RET'].includes($('request-form').elements.tipo.value),q=$('request-form').elements.quantidade;q.min=range?'1000':'10';q.max=range?'1000':'50';q.value=range?'1000':'10';q.readOnly=range;};
$('request-form').onsubmit=async e=>{
  e.preventDefault();$('request').disabled=true;
  try{
    const body=formData(e.target);body.quantidade=Number(body.quantidade);body.confirm=e.target.elements.confirm.checked;body.confirmProduction=e.target.elements.confirmProduction.checked;
    if(!HOSTED){location.assign((await api('sncr/request',body)).url);return;}
    const meta=await relay('meta');if(!meta.enabled||!meta.exportReady)throw Error('O portal do provedor ainda não está configurado para emitir lotes assinados.');
    const target=await api('sncr/destination',{}),sncr=$('sncr-form').elements,range=['RCE','RET'].includes(body.tipo);
    const receipt=Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
    const result=await relay('portal/start',{id:crypto.randomUUID(),receipt,destination:target,environment:sncr.environment.value,back:'local',confirm:body.confirm,confirmProduction:body.confirmProduction,
      request:{tipo:body.tipo,quantidade:body.quantidade,conselho:'CRM',documento:target.crm,uf:target.uf,...(range?{cnpj:sncr.cnpj.value.replace(/\D/g,'')}:{})}});
    if(result.url)location.assign(result.url);else{await loadRelay();status('Pedido já registrado. Confira o histórico web antes de continuar.');}
  }catch(error){status(error.message);$('request').disabled=false;await loadRelay().catch(()=>{});}
};
try{
  token=(await api('session')).token;await load();
  const params=new URL(location.href).searchParams,result=params.get('sncr'),remote=params.get('relay');
  if(HOSTED){$('web-note').hidden=false;await loadRelay();}
  if(HOSTED&&remote){history.replaceState(null,'','/dados-locais.html');await fetchLot(remote);}
  else{status(result?(result==='nao-enviado'?'A autenticação não foi concluída. Nenhum pedido de números foi enviado. Confira o motivo no registro abaixo.':result==='recebido'?'Numeração recebida e gravada no banco local.':'Retorno do SNCR registrado. Confira o resultado abaixo antes de tentar novamente.'):'Dados armazenados neste computador.');if(result)history.replaceState(null,'','/dados-locais.html');}
}catch(error){status(error.message);}
