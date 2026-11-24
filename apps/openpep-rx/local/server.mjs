import {backupDatabase} from './backup.mjs';
import {createPublications} from './publications.mjs';
// SPDX-License-Identifier: AGPL-3.0-or-later
import {createServer} from 'node:http';
import {randomBytes, createHash, timingSafeEqual} from 'node:crypto';
import {readFile, access, mkdir} from 'node:fs/promises';
import {chmodSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {prepareSignature} from './prepare-pdf.mjs';
import {certificateName} from './appearance.mjs';
import {native} from './native.mjs';
import {LocalDatabase, dataDirectory, ownerOf} from './database.mjs';
import {createPrescriptions, profileInput, officeInput} from './prescriptions.mjs';
import {createLocalSNCR, sncrConfig} from './sncr.mjs';
import {lockRuntime} from './runtime-lock.mjs';
import {webBridge} from './web-bridge.mjs';
import {createCEPLookup} from '../api/cep.mjs';
import {createLotImporter} from './lots.mjs';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const equal = (a, b) => typeof a === 'string' && /^[a-f0-9]{64}$/.test(a) && a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const json = (res, status, data) => res.writeHead(status, {'Content-Type': 'application/json'}).end(JSON.stringify(data));
async function input(req, max) {
  const chunks = []; let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > max) throw Error('Arquivo ou pedido acima do limite.');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}
const types = {html: 'text/html; charset=utf-8', js: 'text/javascript', css: 'text/css', png: 'image/png', json: 'application/json', ttf: 'font/ttf', webp: 'image/webp', pdf: 'application/pdf', mjs: 'text/javascript', wasm: 'application/wasm', pfb: 'application/octet-stream', bcmap: 'application/octet-stream'};

export function createLocalServer({signer = native, prepare = prepareSignature, now = Date.now, available, database, fetcher = fetch, webOrigins,lotOptions,publicationOptions} = {}) {
  const findCEP=createCEPLookup({fetcher,now});
  const token = randomBytes(32).toString('hex');
  // Single-use launch key shown only in the helper's terminal. Opening it sets the
  // session cookie; the session token is never handed to a client without it.
  let launch = randomBytes(32).toString('hex');
  const db = database || new LocalDatabase();
  const bridge=webBridge({origins:webOrigins,now});
  const publications=createPublications({db,fetcher,...publicationOptions});
  const prescriptions = createPrescriptions({db, signer, now,publications}), sncr = createLocalSNCR({db, fetcher, now});
  const lots=createLotImporter({db,...lotOptions});
  const cookie = (req, name) => { const found = (req.headers.cookie || '').split(';').map(x => x.trim()).filter(x => x.startsWith(name + '=')); return found.length === 1 ? found[0].slice(name.length + 1) : ''; };
  const authorized = req => bridge.authorized(req) || equal(req.headers['x-openpep-local'], token) || equal(cookie(req, 'openpep_rx_local'), token);
  let review = null, busy = false;
  const signedFile=id=>typeof id==='string'&&/^[a-f0-9-]{36}$/.test(id)?db.get('SELECT * FROM rx_signed_files WHERE id=?',id):null;
  const server = createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self' blob: data:; worker-src 'self'; connect-src 'self'; frame-src blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
    const host = `127.0.0.1:${server.address().port}`, origin = `http://${host}`;
    const url = new URL(req.url, origin);
    if (req.headers.host !== host) return json(res, 403, {error: 'Abra o endereço local exibido no terminal.'});
    const webOrigin=bridge.allows(req.headers.origin),paired=webOrigin&&bridge.authorized(req),requestOrigin=paired?req.headers.origin:origin;
    if(webOrigin&&url.pathname.startsWith('/api/')){
      res.setHeader('Access-Control-Allow-Origin',req.headers.origin);res.setHeader('Vary','Origin');
      res.setHeader('Access-Control-Expose-Headers','X-Document-Ticket, X-Document-SHA256, X-Document-ID, Content-Disposition');
      if(req.method==='OPTIONS'){
        res.setHeader('Access-Control-Allow-Methods','GET, POST');res.setHeader('Access-Control-Allow-Headers','Content-Type, X-OpenPEP-Request, X-OpenPEP-Local');res.setHeader('Access-Control-Allow-Private-Network','true');return res.writeHead(204).end();
      }
      if(url.pathname==='/api/local/pair/complete'&&req.method==='POST'&&req.headers['content-type']==='application/json'&&req.headers['x-openpep-request']==='local'){
        try{return json(res,200,bridge.complete(req.headers.origin,JSON.parse((await input(req,2048)).toString())));}catch(error){return json(res,403,{error:error.message});}
      }
    }
    if (url.pathname === '/sncr/retorno' && req.method === 'GET') {
      let result;
      try { result = await sncr.finish(url, cookie(req, 'openpep_rx_sncr'), origin); }
      catch { result = 'nao-concluido'; }
      res.setHeader('Set-Cookie', 'openpep_rx_sncr=; HttpOnly; SameSite=Lax; Path=/sncr/retorno; Max-Age=0');
      return res.writeHead(303, {Location:'/dados-locais.html?sncr=' + result}).end();
    }
    // OAuth redirects retain cross-site Fetch Metadata until the final document.
    // Permit only navigation to inert page shells; API, iframe and fetch requests
    // keep the same origin checks, including requests carrying our session cookie.
    const pageNavigation = ['GET','HEAD'].includes(req.method) && req.headers['sec-fetch-mode'] === 'navigate' && req.headers['sec-fetch-dest'] === 'document' &&
      ['/', '/index.html', '/receita.html', '/assinatura.html', '/dados-locais.html','/conectar.html'].includes(url.pathname);
    // Cookies are not port-scoped on 127.0.0.1, so a page on another local port is 'same-site': accept only same-origin or direct navigation.
    const fetchSite = req.headers['sec-fetch-site'];
    if (!pageNavigation && !paired && ((req.headers.origin && req.headers.origin !== origin) || (fetchSite && !['same-origin', 'none'].includes(fetchSite)))) return json(res, 403, {error: 'Pedido de outra origem recusado.'});
    if (!['GET', 'HEAD', 'POST'].includes(req.method)) return json(res, 405, {error: 'Método não permitido.'});
    if (url.pathname === '/abrir' && req.method === 'GET') {
      if (!launch || !equal(url.searchParams.get('chave'), launch)) return json(res, 403, {error: 'Endereço de abertura inválido ou já usado. Reinicie o auxiliar local e abra o novo endereço exibido no terminal.'});
      launch = null;
      res.setHeader('Set-Cookie', `openpep_rx_local=${token}; HttpOnly; SameSite=Strict; Path=/`);
      return res.writeHead(303, {Location: '/'}).end();
    }
    if (url.pathname.startsWith('/api/')) {
      if (url.pathname.startsWith('/api/receita/')) {
        if (!authorized(req) || (req.method === 'POST' && (req.headers.origin !== requestOrigin || req.headers['x-openpep-request'] !== 'local'))) return json(res, 403, {error:'Reabra o receituário local.'});
        const route = url.pathname.slice('/api/receita/'.length);
        try {
          if (req.method === 'GET') {
            if (route === 'compartilhar') return json(res,200,prescriptions.sharing(url.searchParams.get('id')));
            if (route === 'estado') return json(res, 200, prescriptions.state());
            if(route==='cep'){
              const cep=url.searchParams.get('cep');
              if([...url.searchParams.keys()].length!==1||!/^\d{8}$/.test(cep||''))return json(res,400,{error:'Informe um CEP com oito dígitos.'});
              try{const address=await findCEP(cep);return address?json(res,200,address):json(res,404,{error:'CEP não encontrado. Confira os oito dígitos ou preencha o endereço.'});}
              catch{return json(res,503,{error:'Não foi possível consultar o CEP agora. Tente novamente ou preencha o endereço.'});}
            }
            if (['previa','pdf','termo'].includes(route)) {
              const bytes = route === 'termo' ? await prescriptions.term(url.searchParams.get('id')) : prescriptions.pdf(url.searchParams.get('id'), route === 'pdf');
              return res.writeHead(200, {'Content-Type':'application/pdf', 'Content-Disposition':`${url.searchParams.get('inline') === '1' || route !== 'pdf' ? 'inline' : 'attachment'}; filename="openpep-rx.pdf"`}).end(bytes);
            }
          }
          if (req.method === 'POST') {
            if (busy) return json(res, 409, {error:'Aguarde a operação em andamento.'});
            if (req.headers['content-type'] !== 'application/json') return json(res, 415, {error:'Pedido inválido.'});
            busy = true;
            try {
              const body = JSON.parse((await input(req, 32000)).toString());
              if (route === 'acesso') return json(res, 200, prescriptions.access(body));
              if (route === 'contato') return json(res, 200, prescriptions.contact(body));
              if (route === 'rascunho') return json(res, 200, await prescriptions.draft(body, origin));
              if (route === 'revisar') return json(res, 200, await prescriptions.review(body.id, origin));
              if (route === 'emitir') return json(res, 200, await prescriptions.sign(body));
              if (route === 'publicar') return json(res,200,await prescriptions.publish(body));
              if (route === 'revogar-link') return json(res,200,await prescriptions.revoke(body));
              if (route === 'cancelar') return json(res, 200, prescriptions.cancel(body));
            } finally { busy = false; }
          }
          return json(res, 404, {error:'Operação indisponível.'});
        } catch (error) { return json(res, 422, {error: error.message || 'Não foi possível concluir a receita.'}); }
      }
      if (!url.pathname.startsWith('/api/local/')) return json(res, 404, {error: 'Este servidor disponibiliza somente assinatura local.'});
      if (req.headers['x-openpep-request'] !== 'local') return json(res, 403, {error: 'Pedido local inválido.'});
      if (url.pathname === '/api/local/session' && req.method === 'GET') {
        if (!paired && !equal(cookie(req, 'openpep_rx_local'), token)) return json(res, 403, {error: 'Abra neste navegador o endereço de abertura exibido no terminal do auxiliar local.'});
        let ready = available;
        if (ready === undefined) {
          ready = process.platform === 'darwin';
          try { await access(new URL('./bin/vidaas-signer', import.meta.url)); } catch { ready = false; }
        }
        return json(res, 200, {token:paired?req.headers['x-openpep-local']:token, ready, platform: process.platform});
      }
      if (url.pathname === '/api/local/settings' && req.method === 'GET' && authorized(req)) {
        const profile = db.profile();
        return json(res, 200, {profile, sncr:db.config(), portal:lots.portal, ...db.summary(profile ? ownerOf(profile) : '')});
      }
      if(req.method==='GET'&&authorized(req)){
        if(url.pathname==='/api/local/signed-files')return json(res,200,{documents:db.all('SELECT id,hash,created_at FROM rx_signed_files ORDER BY created_at DESC LIMIT 100').map(r=>({...r,publication:publications.info(r.id)}))});
        if(['/api/local/document-share','/api/local/signed-file'].includes(url.pathname)){
          const record=signedFile(url.searchParams.get('id'));
          if(!record)return json(res,404,{error:'PDF assinado não encontrado neste banco.'});
          if(url.pathname==='/api/local/signed-file')return res.writeHead(200,{'Content-Type':'application/pdf','Content-Disposition':'attachment; filename="openpep-rx-assinado.pdf"'}).end(Buffer.from(record.pdf));
          if(url.searchParams.get('hash')!==record.hash)return json(res,409,{error:'O documento mudou. Abra o compartilhamento novamente.'});
          return json(res,200,{...publications.info(record.id),printedQR:false});
        }
      }
      if (req.method !== 'POST' || req.headers.origin !== requestOrigin || (!paired && !equal(req.headers['x-openpep-local'], token))) {
        return json(res, 403, {error: 'Reabra o assinador local para continuar.'});
      }
      if (busy) return json(res, 409, {error: 'Aguarde a assinatura em andamento.'});
      try {
        if(['/api/local/sncr/destination','/api/local/sncr/inspect-lot','/api/local/sncr/import-lot'].includes(url.pathname)){
          if(req.headers['content-type']!=='application/json')return json(res,415,{error:'Pedido inválido.'});
          busy=true;
          try{
            const body=JSON.parse((await input(req,420000)).toString());
            if(url.pathname.endsWith('/destination'))return json(res,200,lots.target());
            if(url.pathname.endsWith('/inspect-lot'))return json(res,200,await lots.inspect(body.bundle));
            return json(res,200,await lots.import(body));
          }finally{busy=false;}
        }
        if(url.pathname==='/api/local/pair'){
          if(paired||req.headers['content-type']!=='application/json')return json(res,403,{error:'Autorize a conexão na página local.'});
          try{return json(res,200,bridge.pair(JSON.parse((await input(req,2048)).toString())));}catch(error){return json(res,422,{error:error.message});}
        }
        if (['/api/local/settings', '/api/local/sncr/request'].includes(url.pathname)) {
          if (req.headers['content-type'] !== 'application/json') return json(res, 415, {error:'Pedido inválido.'});
          busy = true;
          try {
            const body = JSON.parse((await input(req, 8192)).toString());
            if (url.pathname.endsWith('/settings')) {
              const profile = body.profile ? profileInput(body.profile) : null;
              const config = body.sncr ? sncrConfig(body.sncr) : null;
              const office = body.office ? officeInput(body.office) : null, effective = profile || db.profile();
              if (office && !effective) throw Error('Cadastre o emitente antes de salvar o consultório.');
              db.transaction(() => { if (profile) db.setSetting('profile', profile); if (config) db.setSetting('sncr', config); if (office) db.setSetting('office:' + ownerOf(effective), office); });
              return json(res, 200, {saved:true});
            }
            // A paired web origin requests numbers through the portal and imports the signed lot.
            if(paired)return json(res,403,{error:'Peça números pelo portal do provedor; o lote assinado é importado neste computador.'});
            const result = sncr.start(body, origin);
            res.setHeader('Set-Cookie', `openpep_rx_sncr=${result.state}; HttpOnly; SameSite=Lax; Path=/sncr/retorno; Max-Age=300`);
            return json(res, 200, {url:result.url});
          } finally { busy = false; }
        }
        if (url.pathname === '/api/local/certificates') {
          busy = true;
          try { return json(res, 200, {certificates: await signer('list')}); }
          finally { busy = false; }
        }
        if (url.pathname === '/api/local/prepare') {
          review = null;
          if (req.headers['content-type'] !== 'application/pdf') return json(res, 415, {error: 'Selecione um PDF.'});
          busy = true;
          try {
            const original = await input(req, 20 * 1024 * 1024), prepared = await prepare(original);
            const pdf = Buffer.from(prepared.pdf), hash = digest(pdf), ticket = randomBytes(32).toString('hex');
            review = {original, pdf, range: prepared.range, hash, ticket, expires: now() + 600_000};
            res.writeHead(200, {'Content-Type': 'application/pdf', 'X-Document-Ticket': ticket, 'X-Document-SHA256': hash});
            return res.end(pdf);
          } finally { busy = false; }
        }
        if (url.pathname === '/api/local/appearance') {
          if (req.headers['content-type'] !== 'application/json') return json(res,415,{error:'Pedido inválido.'});
          busy=true;
          try {
            const body=JSON.parse((await input(req,8192)).toString());
            if (!review || review.expires<=now() || body.ticket!==review.ticket || body.hash!==review.hash || !/^[a-f0-9]{64}$/.test(body.identity || '')) return json(res,409,{error:'Selecione e revise o PDF novamente.'});
            const certs=await signer('list'), cert=certs.find(c=>c.id===body.identity);
            if(!cert) throw Error('Certificado indisponível.');
            const appearance={page:body.page,x:body.x,y:body.y,width:body.width,height:body.height,name:certificateName(cert.name)};
            const prepared=await prepare(review.original,{appearance}),pdf=Buffer.from(prepared.pdf),hash=digest(pdf),ticket=randomBytes(32).toString('hex');
            review={original:review.original,pdf,range:prepared.range,hash,ticket,identity:body.identity,expires:now()+600_000};
            res.writeHead(200,{'Content-Type':'application/pdf','X-Document-Ticket':ticket,'X-Document-SHA256':hash});
            return res.end(pdf);
          } finally {busy=false;}
        }
        if(url.pathname==='/api/local/document-share'){
          if(req.headers['content-type']!=='application/json')return json(res,415,{error:'Pedido inválido.'});
          busy=true;
          try{
            const body=JSON.parse((await input(req,2048)).toString()),current=signedFile(body.id);
            if(!current||body.hash!==current.hash)return json(res,409,{error:'O documento mudou. Abra o compartilhamento novamente.'});
            return json(res,200,body.revoke===true?await publications.revoke(current.id,body.confirm):await publications.publish(current.id,Buffer.from(current.pdf),body.confirm));
          }finally{busy=false;}
        }
        if (url.pathname === '/api/local/sign') {
          if (req.headers['content-type'] !== 'application/json') return json(res, 415, {error: 'Pedido inválido.'});
          busy = true;
          try {
            const body = JSON.parse((await input(req, 8192)).toString());
            if (!review || review.expires <= now() || body.confirm !== true || body.ticket !== review.ticket ||
              body.hash !== review.hash || (review.identity && body.identity !== review.identity) || !/^[a-f0-9]{64}$/.test(body.identity || '')) {
              return json(res, 409, {error: 'Selecione e revise o PDF novamente antes de autorizar.'});
            }
            const document = review;
            review = null; // Consume BEFORE the native operation; never retry an uncertain signature.
            const result = await signer('sign', {pdf: document.pdf.toString('base64'), range: document.range, identity: body.identity});
            if (typeof result.pdf !== 'string' || result.pdf.length > 36 * 1024 * 1024 || !/^JVBERi0[A-Za-z0-9+/]*={0,2}$/.test(result.pdf)) throw Error('Resposta de assinatura inválida.');
            const signed = Buffer.from(result.pdf, 'base64'), [, start, end] = document.range;
            if (signed.length !== document.pdf.length || !signed.subarray(0, start).equals(document.pdf.subarray(0, start)) ||
                !signed.subarray(end).equals(document.pdf.subarray(end)) || digest(signed) === document.hash) throw Error('O documento retornado não corresponde à prévia.');
            const id=crypto.randomUUID();
            db.run('INSERT INTO rx_signed_files(id,pdf,hash,created_at) VALUES(?,?,?,?)',id,signed,digest(signed),now());
            res.setHeader('X-Document-ID',id);
            res.writeHead(200, {'Content-Type': 'application/pdf', 'Content-Disposition': 'attachment; filename="openpep-rx-assinado.pdf"'});
            return res.end(signed);
          } finally { busy = false; }
        }
        return json(res, 404, {error: 'Operação indisponível.'});
      } catch (error) {
        if (url.pathname==='/api/local/document-share'||url.pathname==='/api/local/settings'||url.pathname.startsWith('/api/local/sncr/')) return json(res, 422, {error:error.message || 'Confira os dados.'});
        return json(res, 422, {error: 'A operação não foi concluída. Confira o PDF e o VIDaaS Connect. Para tentar novamente, revise o arquivo outra vez.'});
      }
    }
    if (!['GET', 'HEAD'].includes(req.method)) return json(res, 405, {error: 'Método não permitido.'});
    const name = ['/', '/index.html'].includes(url.pathname) ? 'index.html' : /^\/r\/[a-z2-7]{26}$/i.test(url.pathname) ? 'verificar.html' : url.pathname.slice(1);
    if (!/^[\w/@.-]+\.(html|js|mjs|css|png|json|ttf|webp|pdf|pfb|bcmap|wasm)$/.test(name) || name.includes('..')) return res.writeHead(404).end();
    try {
      let bytes = await readFile(new URL('../.vercel/output/static/' + name, import.meta.url));
      if (['index.html','receita.html','verificar.html'].includes(name)) bytes = Buffer.from(bytes.toString().replace('<html lang="pt-BR"', '<html lang="pt-BR" data-local="true"'));
      res.writeHead(200, {'Content-Type': types[name.split('.').at(-1)]});
      res.end(req.method === 'HEAD' ? undefined : bytes);
    } catch { res.writeHead(404).end(); }
  });
  server.launchPath = '/abrir?chave=' + launch;
  server.on('close', () => { if (!database) db.close(); });
  return server;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT || 4197);
  const directory = dataDirectory();
  await mkdir(directory,{recursive:true,mode:0o700});
  // A pre-existing shared folder keeps its own mode on mkdir; restrict it explicitly.
  chmodSync(directory,0o700);
  const unlock = lockRuntime(directory);
  try { await backupDatabase(directory); } catch(error) { unlock(); throw error; }
  const database = new LocalDatabase(directory); database.recoverInterrupted();
  process.on('exit', unlock);
  for (const signal of ['SIGINT','SIGTERM']) process.on(signal, () => {database.close(); unlock(); process.exit(0);});
  if (process.env.OPENPEP_RX_SNCR_ENV || process.env.OPENPEP_RX_SNCR_ENABLED) database.setSetting('sncr', sncrConfig({environment:process.env.OPENPEP_RX_SNCR_ENV || 'prd', enabled:process.env.OPENPEP_RX_SNCR_ENABLED === 'true', confirmProduction:true, cnpj:process.env.SNCR_PLATFORM_CNPJ || ''}));
  const server = createLocalServer({database});
  server.listen(port, '127.0.0.1', () => {
    const address = `http://127.0.0.1:${server.address().port}`;
    console.log(`OpenPEP-Rx · ${address}/`);
    console.log(`Abra uma vez, no navegador que vai usar: ${address}${server.launchPath}`);
    if (!process.env.OPENPEP_RX_WEB_ORIGINS) console.log('Ambiente web: nenhum autorizado. Para conectar um site, defina OPENPEP_RX_WEB_ORIGINS no arquivo .env (por exemplo, https://rx.openpep.com.br) e reinicie.');
  });
}
