import {normalizeContact} from './contato.js';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Only explicit per-document confirmation sends bytes to the configured portal.
export function publicDocumentURL(value) {
  if(!value)return '';
  const u=new URL(value);
  if(u.protocol!=='https:'||u.username||u.password||u.port||u.hostname==='localhost'||u.hostname.endsWith('.localhost')||!u.hostname.includes('.')||/^\d+(?:\.\d+){3}$/.test(u.hostname)||u.hostname.includes(':')||!/^\/r\/[A-Z2-7]{26}$/i.test(u.pathname)||!/^#[A-F0-9]{32}$/i.test(u.hash)||u.search)throw Error('Link público do documento inválido.');
  return u.href;
}
export function messageLinks({phone='',email='',practice=false,url=''}={}) {
  const {phone:full,email:address}=normalizeContact({phone,email});
  const title=practice?'Prévia de teste — OpenPEP-Rx':'Documento assinado — OpenPEP-Rx';
  let text=practice?'Olá. Este é um documento de teste do OpenPEP-Rx, sem validade para uso como receita.':'Olá. Encaminho seu documento assinado. Guarde o arquivo PDF original para conferir a assinatura digital.';
  if(url)text+='\n\nAbra seu documento: '+publicDocumentURL(url);
  return {title,text,whatsapp:`https://wa.me/${full||''}?text=${encodeURIComponent(text)}`,email:`mailto:${encodeURIComponent(address)}?subject=${encodeURIComponent(title)}&body=${encodeURIComponent(text)}`};
}
export function signedFile(bytes,practice=false) {
  const data=new Uint8Array(bytes);
  if(new TextDecoder().decode(data.subarray(0,5))!=='%PDF-')throw Error('O arquivo recebido não é um PDF.');
  return new File([data],practice?'openpep-rx-ensaio.pdf':'openpep-rx-assinado.pdf',{type:'application/pdf'});
}
export function createDocumentShare() {
  const dialog=document.createElement('dialog');dialog.className='document-share';dialog.setAttribute('aria-labelledby','document-share-title');
  dialog.innerHTML=`<header><h2 id="document-share-title">Enviar documento</h2><button type="button" data-close aria-label="Fechar compartilhamento">×</button></header>
<p data-file></p><p data-patient hidden></p><p data-status role="status">Preparando o PDF…</p>
<section class="document-share-portal" data-portal hidden><h3>Link com código de acesso</h3><p data-publication></p><p class="hint" data-qr></p>
<div data-publish-controls><label class="document-share-consent"><input type="checkbox" data-consent><span>Autorizo enviar este PDF assinado para <strong data-origin></strong>. Quem tiver o link completo poderá abrir o documento.</span></label><button type="button" data-publish disabled>Publicar este PDF</button></div>
<div data-link-controls hidden><a data-link target="_blank" rel="noopener noreferrer">Abrir documento no portal</a><div class="document-share-actions"><button type="button" data-copy>Copiar link</button><button type="button" data-revoke>Desativar link…</button></div><div data-revoke-confirm hidden><p>O link deixará de abrir o documento. Cópias já recebidas não serão apagadas.</p><button type="button" data-revoke-yes>Confirmar desativação</button><button type="button" data-revoke-no>Manter link</button></div></div></section>
<details data-messages><summary>Enviar por WhatsApp ou e-mail</summary><p class="hint" data-message-note></p>
<label>Celular com DDD<input data-phone type="tel" autocomplete="off" placeholder="DDD e número"></label>
<label>E-mail<input data-email type="email" autocomplete="off" placeholder="paciente@exemplo.com"></label>
<button type="button" data-save-contact hidden>Salvar contato desta receita</button><p class="hint" data-contact-note hidden>Contato salvo apenas neste computador, vinculado a esta receita.</p>
<div class="document-share-actions"><a data-whatsapp target="_blank" rel="noopener noreferrer" href="https://wa.me/">Abrir WhatsApp</a><a data-email-link href="mailto:">Abrir e-mail</a></div></details>
<button type="button" data-share class="primary" disabled>Compartilhar arquivo PDF…</button><p class="hint" data-native-note></p>
<div class="document-share-actions"><a data-download hidden>Salvar PDF</a><button type="button" data-close>Fechar</button></div>`;
  document.body.append(dialog);const el=s=>dialog.querySelector(s);let file=null,blobURL=null,practice=false,generation=0,working=false,canShare=false,publication=null,options=null;
  const status=text=>el('[data-status]').textContent=text;
  function reset(){generation++;file=null;publication=null;options=null;if(blobURL)URL.revokeObjectURL(blobURL);blobURL=null;el('[data-share]').disabled=true;el('[data-download]').hidden=true;el('[data-portal]').hidden=true;el('[data-consent]').checked=false;el('[data-revoke-confirm]').hidden=true;el('[data-patient]').hidden=true;el('[data-save-contact]').hidden=el('[data-contact-note]').hidden=true;}
  function links(){const values=messageLinks({phone:el('[data-phone]').value,email:el('[data-email]').value,practice,url:publication?.url||''});el('[data-whatsapp]').href=values.whatsapp;el('[data-email-link]').href=values.email;return values;}
  function refresh(){
    const live=publication?.status==='publicado'&&Boolean(publication.url);
    el('[data-portal]').hidden=!publication?.configured;
    el('[data-origin]').textContent=publication?.origin ? new URL(publication.origin).host : '';
    el('[data-save-contact]').hidden=el('[data-contact-note]').hidden=!options?.saveContact;
    el('[data-save-contact]').disabled=working||!file;
    el('[data-publish-controls]').hidden=live||publication?.status==='revogado';
    el('[data-link-controls]').hidden=!live;
    el('[data-consent]').disabled=working;
    el('[data-publish]').disabled=working||!file||!el('[data-consent]').checked;
    el('[data-share]').disabled=working||!canShare;
    for(const b of dialog.querySelectorAll('[data-copy],[data-revoke],[data-revoke-yes],[data-close]'))b.disabled=working;
    el('[data-publication]').textContent=live?'PDF publicado. O código já está incluído no link e no QR; não é preciso digitar.':publication?.status==='revogado'?'Link desativado. O PDF continua salvo neste computador.':publication?.error||'Publique uma cópia do PDF para enviar o link ao paciente.';
    el('[data-qr]').textContent=publication?.status==='revogado'?'O link e o QR de acesso ao portal foram desativados.':publication?.printedQR?'O QR impresso aponta para este documento.': 'O PDF já assinado será preservado. Esta publicação não modifica nem acrescenta o QR impresso.';
    if(live)el('[data-link]').href=publicDocumentURL(publication.url);
    el('[data-message-note]').textContent=live?'A mensagem incluirá o link. Confira o destinatário e confirme o envio no aplicativo.':publication?.status==='revogado'?'O link foi removido da mensagem. Para enviar o documento, compartilhe ou anexe o PDF original.':'Estes atalhos não anexam o PDF. Publique o documento para incluir um link ou anexe o arquivo antes de enviar.';
    try{links();}catch(error){status(error.message);}
  }
  for(const control of dialog.querySelectorAll('[data-close]'))control.onclick=()=>{if(!working)dialog.close();};
  dialog.addEventListener('cancel',e=>{if(working)e.preventDefault();});dialog.addEventListener('close',reset);
  el('[data-phone]').oninput=el('[data-email]').oninput=()=>{try{links();status('Confira o destinatário no aplicativo escolhido.');}catch(error){status(error.message);}};
  el('[data-save-contact]').onclick=async()=>{
    if(working||!file||!options?.saveContact)return;
    try{const contact=normalizeContact({phone:el('[data-phone]').value,email:el('[data-email]').value});working=true;refresh();await options.saveContact(contact);status('Contato desta receita salvo localmente.');}
    catch(error){status(error.message);}finally{working=false;refresh();}
  };
  el('[data-consent]').onchange=refresh;
  for(const selector of ['[data-whatsapp]','[data-email-link]'])el(selector).onclick=e=>{try{if(!file||working)throw Error('Aguarde o documento ficar pronto.');links();status(publication?.url?'Mensagem aberta com o link. Confirme o destinatário e o envio no aplicativo.':'Mensagem aberta. Anexe o PDF antes de enviar.');}catch(error){e.preventDefault();status(error.message);}};
  el('[data-publish]').onclick=async()=>{
    if(working||!file||!el('[data-consent]').checked||!options?.publish)return;
    working=true;refresh();status('Enviando este PDF assinado ao portal…');
    try{publication={...publication,...await options.publish()};el('[data-consent]').checked=false;el('[data-messages]').open=publication.status==='publicado';status(publication.status==='publicado'?'Link pronto. Escolha WhatsApp ou e-mail.':publication.error||'A publicação não foi confirmada. Tente novamente.');}
    catch(error){status(error.message);}finally{working=false;refresh();}
  };
  el('[data-copy]').onclick=async()=>{try{await navigator.clipboard.writeText(publicDocumentURL(publication.url));status('Link copiado. Envie apenas ao destinatário desejado.');}catch{status('Não foi possível copiar. Abra o documento no portal e copie o endereço.');}};
  el('[data-revoke]').onclick=()=>{el('[data-revoke-confirm]').hidden=false;};el('[data-revoke-no]').onclick=()=>{el('[data-revoke-confirm]').hidden=true;};
  el('[data-revoke-yes]').onclick=async()=>{if(working||!options?.revoke)return;working=true;refresh();try{publication={...publication,...await options.revoke()};el('[data-revoke-confirm]').hidden=true;status('Link desativado.');}catch(error){status(error.message);}finally{working=false;refresh();}};
  el('[data-share]').onclick=async()=>{
    if(!file||working)return;working=true;refresh();
    try{await navigator.share({files:[file],title:practice?'Prévia de teste — OpenPEP-Rx':'Documento assinado — OpenPEP-Rx'});status('Documento entregue ao aplicativo escolhido. Confira nele a conclusão do envio.');}
    catch(error){status(error.name==='AbortError'?'Compartilhamento cancelado. O PDF continua disponível aqui.':'Não foi possível compartilhar pelo sistema. Use o link ou salve o PDF para anexá-lo.');}
    finally{working=false;refresh();}
  };
  return {async open({load,phone='',email='',practice:isPractice=false,label='PDF assinado',...callbacks}={}){
    if(working)return;reset();const current=generation;options=callbacks;practice=isPractice;el('[data-file]').textContent=label;el('[data-phone]').value=phone;el('[data-email]').value=email;el('[data-messages]').open=false;status('Preparando o PDF…');dialog.showModal();
    try{
      const bytes=await load();if(current!==generation)return;
      file=signedFile(bytes,practice);blobURL=URL.createObjectURL(file);el('[data-download]').href=blobURL;el('[data-download]').download=file.name;el('[data-download]').hidden=false;
      canShare=false;try{canShare=Boolean(navigator.share&&navigator.canShare?.({files:[file]}));}catch{}
      el('[data-native-note]').textContent=canShare?'Escolha um aplicativo na janela do sistema. O arquivo será compartilhado sem download prévio.':'Este navegador não permite compartilhar arquivos diretamente. Envie o link do portal ou salve o PDF para anexá-lo.';
      status(practice?'Ensaio assinado. Não é uma receita emitida.':'PDF assinado pronto para compartilhar.');
      refresh();
      if(callbacks.info){const info=await callbacks.info();if(current!==generation)return;publication=info;if(info.contact){el('[data-phone]').value=info.contact.phone||'';el('[data-email]').value=info.contact.email||'';}el('[data-patient]').textContent=info.patient?'Paciente: '+info.patient:'';el('[data-patient]').hidden=!info.patient;refresh();el('[data-messages]').open=Boolean(info.contact?.phone||info.contact?.email)||publication.status==='publicado';}
    }catch(error){if(current===generation)status(error.message||'Não foi possível preparar o documento.');}
  }};
}
