// SPDX-License-Identifier: AGPL-3.0-or-later
export const HOSTED=document.documentElement.dataset.web==='true';
const key='openpep-rx-local-session';
let credential=null,connecting,localOrigin='http://127.0.0.1:4197';
if(HOSTED)try{const saved=JSON.parse(sessionStorage.getItem(key)||'null');if(saved&&/^http:\/\/127\.0\.0\.1:\d{1,5}$/.test(saved.origin)&&/^[a-f0-9]{64}$/.test(saved.token)){credential=saved.token;localOrigin=saved.origin;}}catch{}
export async function connectComputer(){
  if(!HOSTED||credential)return credential;
  if(connecting)return connecting;
  connecting=new Promise((resolve,reject)=>{
    const challenge=Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
    const dialog=document.createElement('dialog');dialog.className='rx-connection';
    const title=document.createElement('h2');title.textContent='Conecte seu computador';
    const text=document.createElement('p');text.textContent='Abra o auxiliar local do OpenPEP-Rx e autorize este ambiente web. Suas receitas, PDFs e certificados serão acessados somente no seu computador.';
    const open=document.createElement('button');open.type='button';open.textContent='Abrir auxiliar local';
    const details=document.createElement('details'),summary=document.createElement('summary'),portLabel=document.createElement('label'),port=document.createElement('input');
    summary.textContent='Opções de conexão';portLabel.textContent='Porta do auxiliar local';port.type='number';port.min='1024';port.max='65535';port.value=new URL(localOrigin).port;portLabel.append(port);details.append(summary,portLabel);
    const label=document.createElement('label');label.textContent='Código do auxiliar (se solicitado)';
    const code=document.createElement('input');code.inputMode='numeric';code.maxLength=6;code.autocomplete='off';label.append(code);
    const complete=document.createElement('button');complete.type='button';complete.textContent='Conectar com código';
    const message=document.createElement('p');message.role='status';message.textContent='Mantenha o auxiliar local em execução. Se o navegador pedir acesso à rede local, permita para conectar este computador.';
    const cancel=document.createElement('button');cancel.type='button';cancel.textContent='Agora não';
    dialog.append(title,text,details,open,label,complete,message,cancel);document.body.append(dialog);dialog.showModal();
    let popup;
    const finish=token=>{if(!/^[a-f0-9]{64}$/.test(token||''))return;credential=token;sessionStorage.setItem(key,JSON.stringify({origin:localOrigin,token}));window.removeEventListener('message',receive);dialog.close();dialog.remove();resolve(token);};
    const receive=e=>{if(e.origin===localOrigin&&e.source===popup&&e.data?.type==='openpep-rx-paired'&&e.data.challenge===challenge)finish(e.data.token);};
    window.addEventListener('message',receive);
    open.onclick=()=>{const n=Number(port.value);if(!Number.isInteger(n)||n<1024||n>65535){message.textContent='Informe a porta exibida pelo auxiliar, entre 1024 e 65535.';return;}localOrigin='http://127.0.0.1:'+n;popup=window.open(localOrigin+'/conectar.html?origin='+encodeURIComponent(location.origin)+'&challenge='+challenge,'openpep-rx-connection');port.disabled=true;};
    complete.onclick=async()=>{
      complete.disabled=true;
      try{const r=await globalThis.fetch(localOrigin+'/api/local/pair/complete',{method:'POST',credentials:'omit',targetAddressSpace:'loopback',signal:AbortSignal.timeout(30000),headers:{'Content-Type':'application/json','X-OpenPEP-Request':'local'},body:JSON.stringify({challenge,code:code.value.trim()})});const data=await r.json();if(!r.ok)throw Error(data.error);finish(data.token);}
      catch(error){message.textContent=error.message||'Não foi possível conectar ao auxiliar.';}finally{complete.disabled=false;}
    };
    const dismiss=()=>{window.removeEventListener('message',receive);dialog.close();dialog.remove();reject(Error('Conecte o auxiliar local para continuar.'));};
    cancel.onclick=dismiss;dialog.addEventListener('cancel',e=>{e.preventDefault();dismiss();});
  }).finally(()=>{connecting=null;});
  return connecting;
}
export async function rxFetch(input,options={}){
  const url=new URL(input,location.href);
  if(!HOSTED||url.origin!==location.origin||!/^\/api\/(local|receita)\//.test(url.pathname))return globalThis.fetch(input,options);
  const token=await connectComputer(),headers=new Headers(options.headers);headers.set('X-OpenPEP-Request','local');headers.set('X-OpenPEP-Local',token);
  let response;
  // Bound read-only connection checks; signing may wait for the user in VIDaaS.
  const signal=options.signal||((options.method||'GET').toUpperCase()==='GET'?AbortSignal.timeout(30000):undefined);
  try{response=await globalThis.fetch(localOrigin+url.pathname+url.search,{...options,signal,headers,credentials:'omit',mode:'cors',cache:'no-store',targetAddressSpace:'loopback'});}
  catch{throw Error('Não foi possível acessar o auxiliar. Mantenha-o aberto e permita a conexão à rede local no navegador.');}
  if(response.status===403){credential=null;sessionStorage.removeItem(key);}
  return response;
}
if(HOSTED)document.addEventListener('click',async e=>{
  const link=e.target.closest('a[href]');if(!link)return;const url=new URL(link.href);
  if(url.origin!==location.origin||!/^\/api\/receita\/(pdf|previa|termo)$/.test(url.pathname))return;
  e.preventDefault();
  try{const r=await rxFetch(url.href);if(!r.ok)throw Error('Documento indisponível.');const blob=URL.createObjectURL(await r.blob()),a=document.createElement('a');a.href=blob;a.download=url.pathname.endsWith('termo')?'openpep-rx-termo.pdf':'openpep-rx.pdf';a.click();setTimeout(()=>URL.revokeObjectURL(blob),60000);}
  catch(error){const message=document.querySelector('[role=status]');if(message)message.textContent=error.message;}
});
if(HOSTED){const button=document.createElement('button');button.className='rx-disconnect';button.type='button';button.textContent='Trocar conexão local';button.onclick=()=>{sessionStorage.removeItem(key);location.reload();};document.querySelector('header')?.append(button);}
