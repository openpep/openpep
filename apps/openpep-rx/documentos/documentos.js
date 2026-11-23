const $=id=>document.getElementById(id),id=/^\/r\/([A-Z2-7]{26})$/i.exec(location.pathname)?.[1]?.toUpperCase(),token=location.hash.slice(1);
// The permanent link secret is sent only in POST bodies. A separate, expiring PDF URL is created on demand for ITI.
if(id&&/^[A-F0-9]{32}$/.test(token)){
  $('status').textContent='Abrindo seu documento…';
  try{
    const response=await fetch('/api/documents/'+id+'/access',{method:'POST',cache:'no-store',headers:{'Content-Type':'application/json'},body:JSON.stringify({token})});
    if(!response.ok)throw Error((await response.json()).error);
    const bytes=await response.arrayBuffer(),hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
    if(hash!==response.headers.get('X-Document-SHA256'))throw Error('Não foi possível conferir o arquivo recebido.');
    const url=URL.createObjectURL(new Blob([bytes],{type:'application/pdf'}));$('pdf').hidden=false;$('download').href=$('open').href=url;$('actions').hidden=false;$('status').textContent='Documento disponível. Você pode abrir ou salvar o PDF original.';
    try{const {renderPDF}=await import('./pdf-preview.js');await renderPDF(bytes,$('pdf'));}catch{$('pdf').hidden=true;$('status').textContent='O PDF original está disponível para abrir ou salvar. Este navegador não conseguiu mostrar a prévia.';}
  }catch(error){$('status').textContent=error.message||'Não foi possível abrir. Confira o link completo com o emitente.';}
}else if(id)$('status').textContent='O link está incompleto. Use o endereço completo recebido ou leia novamente o QR.';

let validationLink='',validationExpiry=0,preparing=false;
async function prepareValidation(){
  if(preparing)return;preparing=true;$('iti-ready').hidden=true;$('iti-renew').hidden=true;$('iti-status').textContent='Preparando o link do PDF…';
  try{
    const response=await fetch('/api/documents/'+id+'/validation',{method:'POST',cache:'no-store',headers:{'Content-Type':'application/json'},body:JSON.stringify({token})});
    const result=await response.json();if(!response.ok)throw Error(result.error);
    const link=new URL(result.url);
    if(link.origin!==location.origin||!/^\/api\/validation\/[a-f0-9]{64}\.pdf$/.test(link.pathname)||link.search||link.hash||!Number.isFinite(result.expiresAt)||result.expiresAt<=Date.now())throw Error('Não foi possível preparar o link.');
    validationLink=link.href;validationExpiry=result.expiresAt;$('iti-url').value=validationLink;$('iti-ready').hidden=false;
    $('iti-status').textContent='Link pronto. Use o botão abaixo e siga os passos no ITI.';
  }catch(error){validationLink='';$('iti-status').textContent=error.message||'Não foi possível preparar. Tente novamente ou use Salvar PDF.';}
  finally{preparing=false;$('iti-renew').hidden=false;}
}
$('check-signature').onclick=()=>{const expanded=$('iti-panel').hidden;$('iti-panel').hidden=!expanded;$('check-signature').setAttribute('aria-expanded',String(expanded));if(expanded&&(!validationLink||Date.now()>=validationExpiry))prepareValidation();};
$('iti-renew').onclick=prepareValidation;
function copyValidation(event){
  if(!validationLink||Date.now()>=validationExpiry){event?.preventDefault();$('iti-status').textContent='O link expirou. Clique em Gerar novo link.';return;}
  try{navigator.clipboard.writeText(validationLink).then(()=>{$('iti-status').textContent='Link copiado. No ITI: Colar URL → colar → Enviar → aceitar os termos → Validar.';},manualCopy);}catch{manualCopy();}
}
function manualCopy(){$('iti-status').textContent='O navegador não permitiu copiar. Selecione o link abaixo e copie com Ctrl+C ou ⌘C; depois cole em Colar URL no ITI.';$('iti-url').focus();$('iti-url').select();}
$('iti-open').onclick=copyValidation;$('iti-copy').onclick=copyValidation;
$('iti-url').onclick=()=>$('iti-url').select();
