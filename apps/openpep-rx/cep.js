// SPDX-License-Identifier: AGPL-3.0-or-later
export function bindCEP({input,button,fields,lookup,notify,onFill=()=>{},canApply=()=>true}){
  const keys=['logradouro','bairro','cidade','uf'];let version=0,last='',pending='';
  const digits=()=>input.value.replace(/\D/g,'').slice(0,8);
  function reset(){version++;last='';pending='';input.removeAttribute('aria-busy');button.disabled=input.disabled;notify({});}
  async function search(force=false){
    const cep=digits();input.value=cep.length>5?cep.slice(0,5)+'-'+cep.slice(5):cep;
    if(cep.length!==8){reset();if(force)notify({error:'Informe os oito dígitos do CEP.'});return;}
    if(input.disabled||!canApply()||pending===cep||(!force&&last===cep))return;
    const ticket=++version,before=Object.fromEntries(keys.map(k=>[k,fields[k].value]));pending=cep;
    input.setAttribute('aria-busy','true');button.disabled=true;notify({text:'Buscando endereço…'});
    try{
      const r=await lookup(cep);
      if(ticket!==version||digits()!==cep||!canApply()||input.disabled)return;
      if(!r.ok)throw Error(r.json?.error||'Não foi possível consultar. Tente novamente.');
      const a=r.json;
      if(typeof a?.cidade!=='string'||!a.cidade.trim()||!/^[A-Z]{2}$/.test(a.uf||'')||!fields.uf.querySelector(`option[value="${a.uf}"]`))throw Error('O serviço retornou um endereço incompleto. Tente novamente.');
      // Do not replace edits made while the request was in flight.
      if(keys.some(k=>fields[k].value!==before[k])){notify({text:'Endereço editado durante a busca. Use Buscar CEP para aplicar a consulta novamente.'});return;}
      for(const k of keys){fields[k].value=typeof a[k]==='string'?a[k]:'';fields[k].removeAttribute('aria-invalid');}
      last=cep;notify({ok:a.logradouro?`${a.cidade}/${a.uf} · endereço preenchido`:`${a.cidade}/${a.uf} · informe a rua e o número`});onFill();
      if(input.ownerDocument.activeElement===input||input.ownerDocument.activeElement===button)fields[a.logradouro?'numero':'logradouro'].focus();
    }catch(error){if(ticket===version&&digits()===cep&&canApply())notify({error:error.message||'Consulta indisponível. Tente novamente.'});}
    finally{if(ticket===version){pending='';input.removeAttribute('aria-busy');button.disabled=input.disabled;}}
  }
  input.addEventListener('input',()=>{if(digits()!==pending){version++;pending='';input.removeAttribute('aria-busy');button.disabled=input.disabled;}search();});
  input.addEventListener('change',()=>search());input.addEventListener('blur',()=>search());
  button.onclick=()=>search(true);
  return {reset,search};
}
