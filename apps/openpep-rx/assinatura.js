import {createDocumentShare} from './compartilhar-documento.js';
// SPDX-License-Identifier: AGPL-3.0-or-later
import {renderPDF} from './pdf-preview.js';
import {rxFetch as fetch} from './local-client.js';
const documentShare=createDocumentShare();
let signedBytes=null,signedID=null;
const $ = id => document.getElementById(id);
let token, review, previewURL, signedURL, busy = false, markedIdentity = null, withoutMark = false, placement = null, marker = null;
const status = text => { $('status').textContent = text; };
const refresh = () => {
  const ready=!busy && Boolean(review) && Boolean($('identity').value);
  $('position').disabled=$('without-mark').disabled=!ready;
  $('sign').disabled=!ready || Boolean(placement) || !(markedIdentity === $('identity').value || withoutMark) || !$('confirm').checked;
  $('confirm').disabled=!ready || Boolean(placement) || !(markedIdentity === $('identity').value || withoutMark);
};
function closePlacement() {marker?.remove();marker=null;placement=null;$('placement').hidden=true;refresh();}
function resetReview() {
  closePlacement(); markedIdentity=null; withoutMark=false;
  review = null; signedBytes=null;signedID=null; $('share-document').hidden=true; $('confirm').checked = false; $('confirm').disabled = true;
  for (const url of [previewURL, signedURL]) if (url) URL.revokeObjectURL(url);
  previewURL = signedURL = null;
  $('preview').replaceChildren(); $('preview').hidden = true;
  $('open-preview').hidden = $('download').hidden = true;
  $('empty').hidden = false; $('hash').textContent = ''; refresh();
}

async function api(route, body, contentType = 'application/json') {
  const response = await fetch('/api/local/' + route, {method: body === undefined ? 'GET' : 'POST', cache: 'no-store',
    headers: {'X-OpenPEP-Request': 'local', ...(token ? {'X-OpenPEP-Local': token} : {}), ...(body !== undefined ? {'Content-Type': contentType} : {})},
    body: body === undefined ? undefined : contentType === 'application/json' ? JSON.stringify(body) : body});
  if (!response.ok) throw Error((await response.json().catch(() => ({}))).error || 'O serviço local não respondeu.');
  return response;
}
function lock(value) {
  busy = value;
  for (const id of ['file', 'certificates', 'identity','apply-position','cancel-position','stamp-page','stamp-size']) $(id).disabled = value;
  $('confirm').disabled = value || !review;
  refresh();
}
async function displayPrepared(response) {
  const bytes=await response.arrayBuffer(), hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
  if(hash!==response.headers.get('X-Document-SHA256')) throw Error('A prévia não corresponde ao documento preparado.');
  $('preview').replaceChildren(); await renderPDF(bytes,$('preview'));
  review={ticket:response.headers.get('X-Document-Ticket'),hash};
  if(previewURL) URL.revokeObjectURL(previewURL);
  previewURL=URL.createObjectURL(new Blob([bytes],{type:'application/pdf'}));
  $('preview').hidden=false;$('empty').hidden=true;$('open-preview').href=previewURL;$('open-preview').hidden=false;
  $('hash').textContent='SHA-256 da prévia: '+hash;
}
async function useFile(file) {
  if (busy) return;
  resetReview(); if (!file) return;
  $('file-name').textContent = file.name;
  if (!/\.pdf$/i.test(file.name)) return status('Escolha um arquivo PDF.');
  if (file.size > 20 * 1024 * 1024) return status('Selecione um PDF de até 20 MB.');
  lock(true); status('Preparando o PDF neste computador…');
  let rendering = false;
  try {
    const response = await api('prepare', file, 'application/pdf');
    rendering = true;
    await displayPrepared(response);
    rendering = false;
    status('Confira o documento, selecione seu certificado e posicione a assinatura.');
  } catch (error) { resetReview(); status(rendering ? 'Não foi possível mostrar todas as páginas. Selecione outro PDF, com até 50 páginas, para revisar antes de assinar.' : error.message); }
  finally { lock(false); }
};
$('file').onchange = () => useFile($('file').files[0]);
for (const event of ['dragenter','dragover']) $('dropzone').addEventListener(event, e => {e.preventDefault(); if(!busy)$('dropzone').classList.add('dragging');});
$('dropzone').addEventListener('dragleave', () => $('dropzone').classList.remove('dragging'));
$('dropzone').addEventListener('drop', e => {e.preventDefault(); $('dropzone').classList.remove('dragging'); if(busy)return; const files=e.dataTransfer.files; if(files.length!==1)return status('Arraste um PDF por vez.'); useFile(files[0]);});
$('dropzone').addEventListener('keydown', e=>{if(e.target===$('dropzone')&&['Enter',' '].includes(e.key)){e.preventDefault();$('file').click();}});
window.addEventListener('dragover', e=>e.preventDefault()); window.addEventListener('drop', e=>e.preventDefault());
$('certificates').onclick = async () => {
  lock(true); status('Consultando o VIDaaS Connect…');
  $('identity').replaceChildren(new Option('Selecione o titular', ''));
  try {
    const {certificates} = await (await api('certificates', {})).json();
    for (const cert of certificates) $('identity').add(new Option(cert.name, cert.id));
    status(certificates.length ? 'Selecione o titular e confira o documento.' : 'Nenhum certificado VIDaaS disponível. Abra e autentique o VIDaaS Connect.');
  } catch (error) { status(error.message); }
  finally { lock(false); }
};
$('identity').onchange = () => { closePlacement(); withoutMark=false; $('confirm').checked = false; refresh(); };
$('confirm').onchange = refresh;
function positionMarker() {
  const surface=marker.parentElement, box=surface.getBoundingClientRect();
  marker.style.left=placement.x*100+'%';marker.style.top=placement.y*100+'%';
  marker.style.width=placement.width*100+'%';marker.style.height=placement.height*100+'%';
  marker.style.fontSize=Math.max(7,box.width*placement.width/22)+'px';
}
function attachMarker() {
  marker?.remove();
  const figure=$('preview').querySelector(`[data-page="${$('stamp-page').value}"]`), width=Number(figure.dataset.width),height=Number(figure.dataset.height);
  const size=Math.min(Number($('stamp-size').value),width*.85,height*220/72*.85);
  placement={page:Number(figure.dataset.page),x:.06,y:.06,width:size/width,height:size*72/220/height};
  marker=document.createElement('div');marker.className='signature-marker';marker.tabIndex=0;marker.role='button';marker.setAttribute('aria-label','Posição da assinatura. Arraste ou use as setas para mover.');
  const logo=document.createElement('img');logo.src='openpep-mark.png';logo.alt='';
  const text=document.createElement('span'),label=document.createElement('span'),name=document.createElement('strong'),brand=document.createElement('small');
  label.textContent='Assinado digitalmente por';name.textContent=$('identity').selectedOptions[0].textContent.replace(/:\s*\d{11,14}\s*$/,'');brand.textContent='VIDaaS · OpenPEP-Rx';text.append(label,name,brand);marker.append(logo,text);
  const surface=figure.querySelector('.pdf-surface');surface.append(marker);positionMarker();
  const move=(x,y)=>{placement.x=Math.max(0,Math.min(1-placement.width,x));placement.y=Math.max(0,Math.min(1-placement.height,y));positionMarker();};
  let drag;
  marker.onpointerdown=e=>{if(busy)return;e.preventDefault();marker.focus();const b=surface.getBoundingClientRect();drag={x:e.clientX,y:e.clientY,px:placement.x,py:placement.y,b};marker.setPointerCapture(e.pointerId);};
  marker.onpointermove=e=>{if(drag&&!busy)move(drag.px+(e.clientX-drag.x)/drag.b.width,drag.py+(e.clientY-drag.y)/drag.b.height);};
  marker.onpointerup=marker.onpointercancel=()=>{drag=null;};
  marker.onkeydown=e=>{if(busy)return;const n=e.shiftKey?10:1,b=surface.getBoundingClientRect(),delta={ArrowLeft:[-n/b.width,0],ArrowRight:[n/b.width,0],ArrowUp:[0,-n/b.height],ArrowDown:[0,n/b.height]}[e.key];if(delta){e.preventDefault();move(placement.x+delta[0],placement.y+delta[1]);}};
  figure.scrollIntoView({block:'center',behavior:'smooth'});marker.focus();
}
$('position').onclick=()=>{
  if(busy||!review||!$('identity').value)return;
  $('confirm').checked=false;withoutMark=false;
  $('stamp-page').replaceChildren(...[...$('preview').querySelectorAll('figure')].map(f=>new Option('Página '+f.dataset.page,f.dataset.page)));
  $('placement').hidden=false;attachMarker();refresh();status('Posicione a caixa e clique em Aplicar posição. Depois confira a prévia final.');
};
$('stamp-page').onchange=$('stamp-size').onchange=attachMarker;
$('cancel-position').onclick=closePlacement;
$('without-mark').onclick=()=>{
  if(markedIdentity){status('Para remover uma marca já aplicada, selecione novamente o PDF original.');return;}
  closePlacement();withoutMark=true;$('confirm').checked=false;refresh();status('Assinatura sem marca visual. Revise o PDF e confirme para continuar.');
};
$('apply-position').onclick=async()=>{
  if(busy||!review||!placement)return;
  const request={...review,...placement,identity:$('identity').value};lock(true);status('Aplicando a assinatura à prévia…');
  try {
    const response=await api('appearance',request);closePlacement();await displayPrepared(response);
    markedIdentity=request.identity;withoutMark=false;$('confirm').checked=false;
    status('Marca aplicada. Confira a posição no PDF final e autorize a assinatura.');
  }catch(error){resetReview();status(error.message);}
  finally{lock(false);}
};
async function shareSignedFile(id,load){
  const bytes=await load(),hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
  await documentShare.open({load:async()=>bytes,label:'PDF assinado',info:async()=>(await api('document-share?id='+id+'&hash='+hash)).json(),publish:async()=>(await api('document-share',{id,hash,confirm:true})).json(),revoke:async()=>(await api('document-share',{id,hash,confirm:true,revoke:true})).json()});
}
$('share-document').onclick=()=>signedBytes&&shareSignedFile(signedID,async()=>signedBytes).catch(e=>status(e.message));
async function history(){
  const {documents}=await (await api('signed-files')).json();$('signed-history').hidden=!documents.length;$('signed-list').replaceChildren();
  for(const record of documents){const row=document.createElement('li'),label=document.createElement('span'),button=document.createElement('button');label.textContent='PDF assinado em '+new Date(record.created_at).toLocaleString('pt-BR');button.type='button';button.textContent='Enviar documento';button.onclick=()=>shareSignedFile(record.id,async()=>(await api('signed-file?id='+record.id)).arrayBuffer()).catch(e=>status(e.message));row.append(label,button);$('signed-list').append(row);}
}
$('sign').onclick = async () => {
  if (busy || !review || !$('confirm').checked || !$('identity').value) return;
  const request = {...review, identity: $('identity').value, confirm: true};
  review = null; lock(true); status('Autorize a assinatura no VIDaaS Connect. Aguarde a conclusão sem repetir o pedido.');
  try {
    const response = await api('sign', request);
    signedBytes=await response.arrayBuffer();signedID=response.headers.get('X-Document-ID');
    signedURL = URL.createObjectURL(new Blob([signedBytes],{type:'application/pdf'}));
    $('share-document').hidden=false;
    $('download').href = signedURL; $('download').hidden = false;
    status('PDF assinado e salvo no banco local. Integridade e certificado signatário conferidos localmente. Envie o documento ou salve o arquivo.');
    await history().catch(()=>{});
  } catch (error) { status(error.message); }
  finally { $('confirm').checked = false; $('file').value = ''; lock(false); }
};
try {
  const session = await (await api('session')).json(); token = session.token;
  await history().catch(()=>{});
  $('workspace').hidden = !session.ready; $('setup').hidden = session.ready;
  status(session.ready ? 'Serviço local pronto. Escolha um PDF para começar.' : 'Prepare o auxiliar local para assinar com VIDaaS.');
} catch {
  $('setup').hidden = false;
  status('O assinador precisa ser iniciado neste computador.');
}
