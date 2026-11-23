// SPDX-License-Identifier: AGPL-3.0-or-later
const $=id=>document.getElementById(id),form=$('request-form'),fields=form.elements;
let target=null,ready=false,pending=null;
const pendingKey='openpep-rx-sncr-pending';
const message=(text,error=false)=>{$('status').textContent=text;$('status').classList.toggle('error',error);};
const envName=env=>env==='prd'?'Produção':'Homologação';
async function api(path,body){const r=await fetch('/api/relay/'+path,{method:body?'POST':'GET',cache:'no-store',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined});const data=await r.json();if(!r.ok){const error=Error(data.error||'Não foi possível consultar o portal.');error.status=r.status;throw error;}return data;}
function download(data,name){const url=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'})),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
function showTarget(value){
  if(value?.format!=='openpep-rx.estoque'||value.version!==1||!/^[a-f0-9]{64}$/.test(value.stock||'')||!/^\d{1,10}$/.test(value.crm||'')||!['AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO'].includes(value.uf))throw Error('Selecione a identificação de estoque exportada pelo aplicativo local.');
  target=value;$('destination-summary').hidden=false;$('destination-summary').textContent=`CRM ${value.crm}/${value.uf} · Estoque ${value.stock.slice(0,12)}`;$('request-fields').disabled=!ready;
}
function updateFields(){const range=['RCE','RET'].includes(fields.tipo.value),prd=fields.environment.value==='prd';fields.quantidade.min=range?'1000':'10';fields.quantidade.max=range?'1000':'50';fields.quantidade.readOnly=range;fields.quantidade.value=range?'1000':'10';$('cnpj-label').hidden=!range;fields.cnpj.required=range;$('production-label').hidden=!prd;fields.confirmProduction.required=prd;fields.confirmProduction.checked=false;$('limit-note').textContent=range?'RCE e RET: 1.000 números por lote, até três pedidos por tipo/mês. Informe o CNPJ do provedor deste portal.':'Notificações: de 10 a 50 por pedido, até 50 por tipo/dia. É necessário ter numeração atribuída pela Vigilância Sanitária.';}
fields.tipo.onchange=updateFields;fields.environment.onchange=updateFields;
$('destination-file').onchange=async e=>{try{const file=e.target.files[0];if(!file)return;if(file.size>4096)throw Error('Arquivo de identificação acima do limite.');showTarget(JSON.parse(await file.text()));message('Estoque identificado. Confira o ambiente e a quantidade.');}catch(error){target=null;$('request-fields').disabled=true;message(error.message,true);}finally{e.target.value='';}};
async function history(){
  const data=await api('portal/history');
  if(pending&&data.requests.some(r=>r.clientId===pending.id&&r.status==='concluido')){pending=null;sessionStorage.removeItem(pendingKey);}
  $('history').replaceChildren(...data.requests.map(r=>{
    const row=document.createElement('article');row.className='request-row';const info=document.createElement('div'),title=document.createElement('h3'),details=document.createElement('p'),status=document.createElement('p');
    title.textContent=`${r.type} · ${envName(r.environment)} · ${r.count||r.quantity} números`;
    details.textContent=`${new Date(r.createdAt).toLocaleString('pt-BR')} · CRM ${r.destination.crm}/${r.destination.uf} · Estoque ${r.destination.stock.slice(0,12)}`;
    status.textContent=r.message||({aguardando:'Aguardando login no Gov.br. O pedido expira após cinco minutos.',autenticando:'Processamento iniciado. Não repita a solicitação.',concluido:'Confira o resultado.'}[r.status]||r.status);info.append(title,details,status);row.append(info);
    if(r.count&&r.status==='concluido'){const button=document.createElement('button');button.type='button';button.textContent='Baixar lote';button.onclick=async()=>{button.disabled=true;try{download(await api('portal/download',{id:r.id}),`openpep-rx-lote-${r.id}.json`);message('Lote baixado. Importe o arquivo no banco local indicado. Baixar novamente não solicita novos números.');}catch(error){message(error.message,true);}finally{button.disabled=false;}};row.append(button);}return row;
  }));
  if(!data.requests.length)$('history').textContent='Nenhum pedido registrado nesta conta.';
  return data.requests;
}
$('refresh').onclick=async()=>{try{await history();message('Histórico atualizado.');}catch(error){message(error.message,true);}};
form.onsubmit=async e=>{e.preventDefault();$('request-button').disabled=true;try{
  if(!target||!ready)throw Error('Identifique o estoque de destino.');
  if(pending){const rows=await history();if(pending&&rows.some(r=>r.clientId===pending.id))throw Error('Há um pedido iniciado nesta aba. Confira o histórico; um login não concluído expira após cinco minutos.');}
  const receipt=Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
  const candidate={destination:target,environment:fields.environment.value,request:{tipo:fields.tipo.value,quantidade:Number(fields.quantidade.value),conselho:'CRM',documento:target.crm,uf:target.uf,...(['RCE','RET'].includes(fields.tipo.value)?{cnpj:fields.cnpj.value.replace(/\D/g,'')}:{})},confirm:fields.confirm.checked,confirmProduction:fields.confirmProduction.checked};
  if(pending&&JSON.stringify(candidate)!==JSON.stringify(Object.fromEntries(Object.entries(pending).filter(([key])=>!['id','receipt'].includes(key)))))throw Error('Confira o pedido anterior antes de alterar seus dados. Tente recuperar usando o mesmo estoque, ambiente, tipo e quantidade.');
  pending=pending||{id:crypto.randomUUID(),receipt,...candidate};
  sessionStorage.setItem(pendingKey,JSON.stringify(pending));
  const result=await api('portal/start',pending);if(result.url){location.assign(result.url);return;}await history();message('Pedido já registrado. Confira o histórico.');
}catch(error){if(error.status>=400&&error.status<500&&pending){try{const rows=await history();if(pending&&!rows.some(r=>r.clientId===pending.id)){pending=null;sessionStorage.removeItem(pendingKey);}}catch{}}message(error.message,true);}finally{$('request-button').disabled=false;}};
try{
  const meta=await api('meta');ready=meta.enabled&&meta.exportReady;
  try{pending=JSON.parse(sessionStorage.getItem(pendingKey)||'null');if(pending?.destination){showTarget(pending.destination);fields.environment.value=pending.environment;fields.tipo.value=pending.request.tipo;}}catch{pending=null;sessionStorage.removeItem(pendingKey);}
  updateFields();if(pending){fields.quantidade.value=pending.request.quantidade;fields.cnpj.value=pending.request.cnpj||'';}await history();
  message(!meta.enabled?'Abra o portal no domínio configurado: '+meta.canonical:!meta.exportReady?'O provedor precisa configurar a assinatura dos lotes antes de receber pedidos.':new URL(location.href).searchParams.has('relay')?'Retorno do Gov.br registrado. Confira o resultado no histórico.':'Comece selecionando a identificação do estoque local.');
  if(new URL(location.href).searchParams.has('relay'))window.history.replaceState(null,'','/portal-sncr.html');
}catch(error){message(error.message,true);}
