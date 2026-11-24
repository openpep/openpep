// SPDX-License-Identifier: AGPL-3.0-or-later
const $=id=>document.getElementById(id),params=new URL(location.href).searchParams;
const origin=params.get('origin'),challenge=params.get('challenge');let token;
$('web-origin').textContent=origin||'Endereço ausente';
try{
  const parsed=new URL(origin);
  if(parsed.protocol!=='https:'||parsed.origin!==origin||!/^[a-f0-9]{64}$/.test(challenge||''))throw Error('Endereço inválido.');
  const r=await fetch('/api/local/session',{headers:{'X-OpenPEP-Request':'local'},cache:'no-store'});if(!r.ok)throw Error((await r.json().catch(()=>({}))).error||'Reabra o auxiliar local.');token=(await r.json()).token;
  $('connect').disabled=false;$('status').textContent='Confira o endereço antes de conectar.';
}catch(error){$('status').textContent=error.message;}
$('connect').onclick=async()=>{
  $('connect').disabled=true;
  try{
    const r=await fetch('/api/local/pair',{method:'POST',headers:{'Content-Type':'application/json','X-OpenPEP-Request':'local','X-OpenPEP-Local':token},body:JSON.stringify({origin,challenge})});const data=await r.json();if(!r.ok)throw Error(data.error);
    $('code').textContent=data.code;$('fallback').hidden=false;$('status').textContent='Conexão autorizada. Volte ao OpenPEP-Rx web.';
    window.opener?.postMessage({type:'openpep-rx-paired',challenge,token:data.token},origin);
  }catch(error){$('connect').disabled=false;$('status').textContent=error.message;}
};
