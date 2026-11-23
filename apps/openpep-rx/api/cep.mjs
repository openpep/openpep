// SPDX-License-Identifier: AGPL-3.0-or-later
const UFS=new Set('AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO'.split(' '));
const clean=(value,max)=>typeof value==='string'?value.normalize('NFC').trim().replace(/\s+/g,' ').slice(0,max):'';
export async function lookupCEP(cep,fetcher=fetch){
  if(typeof cep!=='string'||!/^\d{8}$/.test(cep))throw Error('Informe um CEP com oito dígitos.');
  let notFound=false;
  const providers=[['https://viacep.com.br/ws/'+cep+'/json/',v=>({logradouro:v.logradouro,bairro:v.bairro,cidade:v.localidade,uf:v.uf})],['https://brasilapi.com.br/api/cep/v1/'+cep,v=>({logradouro:v.street,bairro:v.neighborhood,cidade:v.city,uf:v.state})]];
  for(const [url,map]of providers){
    try{
      const response=await fetcher(url,{headers:{Accept:'application/json'},redirect:'error',signal:AbortSignal.timeout(4000)});
      if(response.status===404){notFound=true;continue;}
      if(!response.ok)throw Error('provider');
      const value=await response.json();
      if(value?.erro===true||value?.erro==='true'){notFound=true;continue;}
      if(!value||typeof value!=='object'||typeof value.cep!=='string'||value.cep.replace(/\D/g,'')!==cep)throw Error('provider');
      const a=map(value),address={cep:cep.slice(0,5)+'-'+cep.slice(5),logradouro:clean(a.logradouro,100),bairro:clean(a.bairro,60),cidade:clean(a.cidade,80),uf:clean(a.uf,2).toUpperCase()};
      if(!address.cidade||!UFS.has(address.uf))throw Error('provider');
      return address; // City-wide CEPs legitimately have no street or district.
    }catch{ /* Try the independent provider, including malformed JSON or partial responses. */ }
  }
  if(notFound)return null;
  throw Error('Não foi possível consultar o CEP agora. Tente novamente ou preencha o endereço.');
}
export function createCEPLookup({fetcher=fetch,now=Date.now}={}){
  const cache=new Map(),pending=new Map();
  return async cep=>{
    if(!/^\d{8}$/.test(cep||''))throw Error('Informe um CEP com oito dígitos.');
    const saved=cache.get(cep);if(saved&&saved.expires>now())return {...saved.address};
    if(pending.has(cep)){const address=await pending.get(cep);return address?{...address}:null;}
    const task=lookupCEP(cep,fetcher);pending.set(cep,task);
    try{const address=await task;if(address){cache.delete(cep);if(cache.size>=256)cache.delete(cache.keys().next().value);cache.set(cep,{address,expires:now()+86400000});}return address?{...address}:null;}
    finally{pending.delete(cep);}
  };
}
