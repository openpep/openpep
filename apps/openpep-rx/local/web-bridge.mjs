// SPDX-License-Identifier: AGPL-3.0-or-later
import {randomBytes, randomInt, timingSafeEqual} from 'node:crypto';
const equal=(a,b)=>typeof a==='string'&&typeof b==='string'&&a.length===b.length&&timingSafeEqual(Buffer.from(a),Buffer.from(b));
export function webBridge({origins=process.env.OPENPEP_RX_WEB_ORIGINS||'',now=Date.now}={}) {
  const allowed=new Set(String(origins).split(',').map(s=>s.trim()).filter(Boolean).map(value=>{
    const u=new URL(value);if(u.protocol!=='https:'||u.origin!==value)throw Error('OPENPEP_RX_WEB_ORIGINS exige origens HTTPS completas, separadas por vírgula.');return u.origin;
  }));
  const sessions=new Map(),pending=new Map();
  function prune(){for(const [key,row]of sessions)if(row.expires<=now())sessions.delete(key);for(const [key,row]of pending)if(row.expires<=now())pending.delete(key);}
  return {
    allows:origin=>allowed.has(origin),
    authorized(req){prune();const row=sessions.get(req.headers['x-openpep-local']);return Boolean(row&&row.origin===req.headers.origin);},
    pair({origin,challenge}){
      prune();if(!allowed.has(origin)||!/^[a-f0-9]{64}$/.test(challenge||''))throw Error('Ambiente web não autorizado neste computador.');
      if(pending.size>=10)throw Error('Feche as conexões pendentes e tente novamente em cinco minutos.');
      const token=randomBytes(32).toString('hex'),code=String(randomInt(100000,1000000));
      sessions.set(token,{origin,expires:now()+12*3600_000});pending.set(challenge,{origin,token,code,tries:0,expires:now()+300_000});
      return {token,code};
    },
    complete(origin,{challenge,code}){
      prune();const row=pending.get(challenge);
      if(!row||row.origin!==origin)throw Error('Conexão expirada. Abra novamente o auxiliar.');
      row.tries++;if(row.tries>5){pending.delete(challenge);sessions.delete(row.token);throw Error('Abra novamente o auxiliar para conectar.');}
      if(!equal(row.code,code))throw Error('Confira o código exibido no auxiliar local.');
      pending.delete(challenge);return {token:row.token};
    },
  };
}
