// Receitas em homologação (docs/SNCR-NUMEROS-FLUXO.md, seção 5): rascunho, prévia, emissão com número do registro,
// motor de demonstração com assinador injetado. A distribuição pública não hospeda emissão clínica.
import {randomBytes, randomInt, createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {makeStore} from './store.mjs';
import {hash} from './http-utils.mjs';
import {sha256} from './store.mjs';
import {makeLedger, LedgerError} from './ledger.mjs';
import {databaseClient} from './db.mjs';
import {verifiedCertificate, reportShape, SESSION_SIGNATURES} from './entry-proof.mjs';
import {prescriptionContent, prescriptionPDF, PRESCRIPTION_TYPES, fromShortId, shortId, PrescriptionTooLong} from './receita-doc.mjs';
import {termoPDF, TERM_TYPES} from './termo-doc.mjs';
import {ORIGIN, HOST} from './origin.mjs';

const COOKIE = '__Host-crx-entry';
export const RECEITA_ROUTES = {posts: ['rascunho', 'emitir', 'cancelar', 'codigo', 'acesso'], gets: ['estado', 'previa', 'pdf', 'cep', 'termo']};
// Access to an issued prescription by its QR and the patient's code: the only route without the entry session.
const PUBLIC = new Set(['acesso']);
export const ACCESS_ATTEMPTS = 5; // per prescription, per 15 minutes (store.allow window)
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const MAX_BODY = 8192;

function respond(res, code, data) { res.statusCode = code; res.setHeader('Content-Type', 'application/json; charset=utf-8'); res.end(JSON.stringify(data)); }
function pdfResponse(res, bytes, filename, inline) {
  res.statusCode = 200; res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `${inline ? 'inline' : 'attachment'}; filename="${filename}"`); res.end(bytes);
}
function entryCookie(req) {
  const all = (req.headers.cookie || '').split(';').map(s => s.trim()).filter(s => s.startsWith(COOKIE + '='));
  const id = all.length === 1 ? all[0].slice(COOKIE.length + 1) : '';
  return /^[a-f0-9]{64}$/.test(id) ? id : null;
}
async function input(req) {
  let data = req.body;
  if (data === undefined) {
    const chunks = []; let n = 0;
    for await (const c of req) { n += c.length; if (n > MAX_BODY) throw Error('body'); chunks.push(Buffer.from(c)); }
    data = Buffer.concat(chunks).toString();
  }
  if (typeof data !== 'string') data = JSON.stringify(data);
  if (Buffer.byteLength(data) > MAX_BODY) throw Error('body');
  return JSON.parse(data);
}
// Mensagens do registro (P0001) vão à tela; o resto sai genérico.
// Six-digit patient code; only sha256("<prescription id>:<code>") is stored.
const newCode = () => String(randomInt(0, 1000000)).padStart(6, '0');
// Link sent to the patient (WhatsApp) and encoded in the access QR: the code rides in the fragment, never sent to the server.
export const accessLink = (id, code) => `${ORIGIN}/r/${shortId(id)}#${code}`;
export const accessHash = (id, code) => createHash('sha256').update(`${id}:${code}`).digest('hex');
import {lookupCEP} from './cep.mjs';
export {lookupCEP} from './cep.mjs';
const ledgerMessage = e => e instanceof LedgerError && e.message !== 'registro indisponível' ? e.message[0].toUpperCase() + e.message.slice(1) + '.' : null;

// Inter (OFL) in Latin subsets, packaged next to the function by build.mjs.
const FONT_FILES = {regular: 'inter-400-latin.ttf', medium: 'inter-500-latin.ttf', semibold: 'inter-600-latin.ttf', bold: 'inter-700-latin.ttf'};
let fontCache;
export const loadFonts = async (dir = new URL('./', import.meta.url)) => fontCache ??= Object.fromEntries(await Promise.all(Object.entries(FONT_FILES).map(async ([k, f]) => [k, await readFile(new URL(f, dir))])));
export function createReceitaHandler({store = makeStore(process.env, fetch, {namespace: 'crx:entry:v1', ttl: 1800}), limits = makeStore(process.env, fetch, {namespace: 'crx:acesso:v1', ttl: 900}),
  services, ledger, code = newCode, cep: findCEP = lookupCEP,
  now = Date.now, random = () => randomBytes(32).toString('hex'), fonts = loadFonts,
  // Only explicitly injected synthetic verifiers may opt into demonstration alerts.
  homologation = false, log = event => console.warn(JSON.stringify(event))} = {}) {
  let registry = ledger;
  const getLedger = () => registry ??= makeLedger((text, params) => databaseClient().query(text, params));
  return async (req, res) => {
    for (const [k, v] of Object.entries({'Cache-Control': 'no-store, max-age=0', 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff', 'X-Robots-Tag': 'noindex, nofollow'})) res.setHeader(k, v);
    if (req.headers.host !== new URL(ORIGIN).host) return respond(res, 403, {error: `Use o endereço ${HOST}.`});
    const url = new URL(req.url, ORIGIN), route = url.pathname.split('/').pop(), {posts, gets} = RECEITA_ROUTES;
    if (![...posts, ...gets].includes(route)) return respond(res, 404, {error: 'Rota indisponível.'});
    if (req.method !== (posts.includes(route) ? 'POST' : 'GET')) return respond(res, 405, {error: 'Método não permitido.'});
    if (posts.includes(route) && req.headers.origin !== ORIGIN) return respond(res, 403, {error: 'Origem não autorizada.'});
    if (req.url.length > 1024) return respond(res, 400, {error: 'Requisição inválida.'});
    const keys = [...url.searchParams.keys()], queryId = url.searchParams.get('id');
    // previa: ?id; pdf and termo: ?id and optionally inline=1 (shown in the page instead of downloaded); cep: ?cep=8 digits.
    const allowed = {previa: ['id'], pdf: ['id', 'inline'], termo: ['id', 'inline'], cep: ['cep']}[route] || [];
    const queryOk = keys.every(k => allowed.includes(k) && url.searchParams.getAll(k).length === 1)
      && (route === 'cep' ? /^\d{8}$/.test(url.searchParams.get('cep') || '') : !allowed.length || UUID.test(queryId || ''))
      && (!url.searchParams.has('inline') || url.searchParams.get('inline') === '1');
    if (!queryOk) return respond(res, 400, {error: 'Parâmetros não permitidos.'});

    if (PUBLIC.has(route)) {
      // Same answer for unknown prescription and wrong code; attempts are limited per prescription and overall.
      const denied = 'Receita não encontrada ou código incorreto.';
      let body; try { body = await input(req); } catch { return respond(res, 400, {error: denied}); }
      // The id comes as printed on the PDF (26-character base32) or as the UUID.
      const rid = fromShortId(body?.id) || (typeof body?.id === 'string' && UUID.test(body.id.toLowerCase()) ? body.id.toLowerCase() : null);
      if (!rid || !/^\d{6}$/.test(body?.codigo || '')) return respond(res, 400, {error: denied});
      try {
        if (!await limits.allow('all', 300) || !await limits.allow(`r:${rid}`, ACCESS_ATTEMPTS)) return respond(res, 429, {error: 'Muitas tentativas. Aguarde 15 minutos.'});
        const r = await getLedger().byAccess(rid, accessHash(rid, body.codigo));
        if (!r) return respond(res, 404, {error: denied});
        return respond(res, 200, {tipo: r.tipo, numero: r.numero, emitidaEm: r.emitidaEm, pdfSha256: r.pdfSha256, prescritor: r.prescritor, pdf: r.pdf.toString('base64')});
      } catch { return respond(res, 503, {error: 'O serviço não respondeu. Tente novamente.'}); }
    }

    const id = entryCookie(req);
    let row;
    try { row = id ? await store.get(id) : null; } catch { return respond(res, 503, {error: 'A sessão não respondeu. Tente novamente.'}); }
    if (!row || !(row.expiresAt > now()) || row.mode !== 'institutional') return respond(res, 401, {error: 'Entre no OpenPEP para emitir receitas.'});
    // Receitas exigem a identidade conferida pelo certificado (CPF do certificado = CPF da conta).
    if (!row.certificate || !row.identity?.cpf || !row.identity.crm) return respond(res, 403, {error: 'Confirme a entrada com o certificado antes de emitir receitas.'});
    const i = row.identity, prescritor = {nome: i.fullName || i.name, crm: i.crm, uf: i.uf};
    // The NRT model prints the physician's CPF: only the PDF gets it, never the page's JSON.
    const signer = {...prescritor, cpf: i.cpf};
    const used = row.signaturesUsed ?? 1, remaining = Math.max(0, SESSION_SIGNATURES - used);
    async function swap(next) { const changed = {...next, revision: row.revision + 1}; const ok = await store.swap(id, row.revision, changed); if (ok) row = changed; return ok; }

    let prescritorId;
    try { prescritorId = await getLedger().ensurePrescriber({contaHash: await sha256(i.issuer + '|' + i.subject), cpf: i.cpf, nome: prescritor.nome, uf: i.uf, inscricao: i.crm}); }
    catch (e) { return respond(res, e instanceof LedgerError && ledgerMessage(e) ? 409 : 503, {error: ledgerMessage(e) || 'O registro de receitas não respondeu. Tente novamente.'}); }
    const l = getLedger();

    try {
      if (route === 'estado') {
        const [stock, history] = await Promise.all([l.stock(prescritorId), l.prescriptions(prescritorId)]);
        const disponiveis = Object.fromEntries(PRESCRIPTION_TYPES.map(t => [t, stock.find(s => s.tipo === t)?.disponiveis ?? 0]));
        return respond(res, 200, {prescritor, expiraEm: row.expiresAt, assinaturasRestantes: remaining,
          podeAssinar: row.status === 'active' && remaining > 0 && Boolean(row.kmsToken), sessao: row.status,
          estoque: disponiveis, receitas: history.lista.map(r => r.codigo ? {...r, link: accessLink(r.id, r.codigo)} : r), emitente: history.emitente});
      }
      if (route === 'rascunho') {
        let body; try { body = await input(req); } catch { return respond(res, 400, {error: 'Dados inválidos.'}); }
        if (!UUID.test(body?.id || '')) return respond(res, 400, {error: 'Identificador de receita inválido.'});
        const checked = prescriptionContent(body, now());
        if (checked.error) return respond(res, 400, {error: checked.error});
        // The draft must print: with 2 or 3 medications, long posologies may not fit the prescription block.
        try { await prescriptionPDF({id: body.id, tipo: checked.tipo, numero: null, conteudo: checked.conteudo, prescritor: signer, emitidaEm: now(), fonts: await fonts(), previa: true}); }
        catch (e) { if (e instanceof PrescriptionTooLong) return respond(res, 400, {error: checked.tipo === 'NRT' ? 'A posologia ou as outras orientações não cabem na notificação. Resuma o texto.' : `A posologia do medicamento ${e.item + 1} não cabe na receita. Resuma as posologias ou emita em receitas separadas.`}); throw e; }
        await l.saveDraft(body.id, prescritorId, checked.tipo, checked.conteudo, checked.sha256);
        return respond(res, 200, {id: body.id, estado: 'rascunho', hash: checked.sha256});
      }
      if (route === 'previa') {
        const r = await l.prescription(queryId, prescritorId);
        if (!r) return respond(res, 404, {error: 'Receita não encontrada.'});
        if (!['rascunho', 'pendente'].includes(r.estado)) return respond(res, 409, {error: 'A prévia só existe antes da emissão.'});
        const bytes = await prescriptionPDF({id: r.id, tipo: r.tipo, numero: r.estado === 'pendente' ? r.numero : null, conteudo: r.conteudo, prescritor: signer, emitidaEm: now(), fonts: await fonts(), previa: true});
        return pdfResponse(res, bytes, `previa-${r.tipo}.pdf`, true);
      }
      if (route === 'pdf') {
        const r = await l.prescription(queryId, prescritorId), bytes = r?.estado === 'emitida' ? await l.signedPdf(queryId, prescritorId) : null;
        if (!bytes) return respond(res, 404, {error: 'Receita assinada indisponível.'});
        return pdfResponse(res, bytes, `receita-${r.tipo}-${r.numero}.pdf`, url.searchParams.get('inline') === '1');
      }
      if (route === 'termo') {
        // NRR and NRT go with a consent form signed by the physician and the patient (data/termos.json), filled in
        // from the prescription; the physician's CPF is not on it. Before issue it carries no number.
        const r = await l.prescription(queryId, prescritorId);
        if (!r || !TERM_TYPES.includes(r.tipo) || !['rascunho', 'pendente', 'emitida'].includes(r.estado)) return respond(res, 404, {error: 'Termo indisponível para esta receita.'});
        const bytes = await termoPDF({tipo: r.tipo, numero: r.estado === 'rascunho' ? null : r.numero, conteudo: r.conteudo, prescritor, emitidaEm: r.emitidaEm ? Date.parse(r.emitidaEm) : now(), fonts: await fonts()});
        return pdfResponse(res, bytes, `termo-${r.tipo}${r.estado === 'rascunho' ? '' : `-${r.numero}`}.pdf`, url.searchParams.get('inline') === '1');
      }
      if (route === 'cep') {
        if (!await limits.allow(`cep:${prescritorId}`, 120)) return respond(res, 429, {error: 'Muitas consultas de CEP. Aguarde alguns minutos.'});
        let address;
        try { address = await findCEP(url.searchParams.get('cep')); } catch { return respond(res, 503, {error: 'A consulta de CEP não respondeu. Preencha o endereço.'}); }
        return address ? respond(res, 200, address) : respond(res, 404, {error: 'CEP não encontrado. Confira ou preencha o endereço.'});
      }
      if (route === 'codigo') {
        // The patient code of an issued prescription: the one printed on its PDF (never replaced, or the printed QR
        // would stop working); prescriptions issued before the code was printed get one now.
        let body; try { body = await input(req); } catch { return respond(res, 400, {error: 'Dados inválidos.'}); }
        if (!UUID.test(body?.id || '')) return respond(res, 400, {error: 'Receita inválida.'});
        const c = code();
        const codigo = await l.accessCode(body.id, prescritorId, c, accessHash(body.id, c));
        return respond(res, 200, {id: body.id, codigo, link: accessLink(body.id, codigo)});
      }
      if (route === 'cancelar') {
        let body; try { body = await input(req); } catch { return respond(res, 400, {error: 'Dados inválidos.'}); }
        const motivo = typeof body?.motivo === 'string' ? body.motivo.normalize('NFC').trim().replace(/\s+/g, ' ') : '';
        if (!UUID.test(body?.id || '') || motivo.length < 3 || motivo.length > 200) return respond(res, 400, {error: 'Informe o motivo do cancelamento (3 a 200 caracteres).'});
        return respond(res, 200, {id: body.id, estado: await l.cancelPrescription(body.id, prescritorId, motivo)});
      }
    } catch (e) { return respond(res, ledgerMessage(e) ? 409 : 503, {error: ledgerMessage(e) || 'O registro de receitas não respondeu. Tente novamente.'}); }

    // The public runtime only injects synthetic services in its explicit demonstration.
    if (!services) return respond(res, 503, {error: 'Use o assinador VIDaaS local para assinar um PDF revisado.'});
    // route === 'emitir'
    let body; try { body = await input(req); } catch { return respond(res, 400, {error: 'Dados inválidos.'}); }
    if (body?.confirm !== true || !UUID.test(body.id || '') || !/^[a-f0-9]{64}$/.test(body.hash || '')) return respond(res, 400, {error: 'Revise a prévia e confirme a emissão.'});
    if (row.status !== 'active' || !row.kmsToken) return respond(res, 409, {error: 'A sessão de assinatura não está disponível. Encerre a sessão e entre de novo.'});
    if (remaining < 1) return respond(res, 409, {error: 'As assinaturas desta autorização VIDaaS acabaram. Encerre a sessão e entre de novo.'});
    let r;
    try { r = await l.prescription(body.id, prescritorId); } catch { return respond(res, 503, {error: 'O registro de receitas não respondeu. Tente novamente.'}); }
    if (!r) return respond(res, 404, {error: 'Receita não encontrada. Revise a prévia de novo.'});
    if (r.conteudoSha256 !== body.hash) return respond(res, 409, {error: 'A receita mudou depois da prévia. Revise de novo.'});
    // Trava a sessão de assinatura (a mesma usada pelos PDFs de teste da entrada).
    if (!await swap({...row, status: 'signing', operationStartedAt: now()})) return respond(res, 409, {error: 'Outra assinatura está em andamento.'});
    let step = 'reserve', numero, released = false, report;
    try {
      numero = await l.startIssue(body.id, prescritorId, body.hash);
      step = 'pdf';
      // The patient code is printed under the access QR, so it exists before the PDF and is stored with it.
      const codigo = code();
      const pdf = await prescriptionPDF({id: r.id, tipo: r.tipo, numero, conteudo: r.conteudo, prescritor: signer, emitidaEm: now(), fonts: await fonts(), codigo});
      // A partir daqui o PDF com o número sai do servidor: o número não volta mais ao estoque.
      step = 'release'; await l.release(body.id, r.tipo); released = true;
      step = 'sign'; const token = await services.jwt(), signed = await services.sign(token, row.kmsToken, pdf);
      const nonce = Number.parseInt(random().slice(0, 7), 16);
      step = 'verify'; report = await services.verify(token, signed, nonce);
      step = 'check'; const cert = verifiedCertificate(report, i.cpf, nonce, now(), {homologation});
      if (cert.serial !== row.certificate.serial || cert.providerHash !== row.certificate.providerHash) throw Error('certificate-mismatch');
      step = 'record'; await l.finishIssueWithAccess(body.id, prescritorId, signed, hash(signed), cert.serial, codigo, accessHash(body.id, codigo));
      await swap({...row, status: 'active', signaturesUsed: used + 1});
      return respond(res, 200, {id: body.id, estado: 'emitida', numero, codigo, link: accessLink(body.id, codigo), assinaturasRestantes: remaining - 1});
    } catch (e) {
      try { log({event: 'prescription_issue_failed', step, released, error: /^[a-z-]{1,40}$/.test(e?.message) ? e.message : e instanceof LedgerError ? 'ledger' : 'other', status: Number.isInteger(e?.status) ? e.status : 0, ...(e?.check ? {check: e.check} : {}), ...(report ? {report: reportShape(report, now())} : {})}); } catch {}
      let estado = null;
      if (step !== 'reserve') { try { estado = await l.failIssue(body.id, prescritorId); } catch {} }
      if (!released) {
        // Nada saiu do servidor: a sessão continua e o número (se reservado) voltou ao estoque.
        await swap({...row, status: 'active'});
        return respond(res, ledgerMessage(e) ? 409 : 502, {error: ledgerMessage(e) || 'Não foi possível gerar a receita. Nenhum número foi gasto.', estado: estado || 'rascunho'});
      }
      // A operação de assinatura foi iniciada: como nas demais assinaturas, a sessão é encerrada e nada é repetido sozinho.
      const message = 'A assinatura da receita não foi confirmada. A receita ficou pendente com o mesmo número; entre de novo para tentar assinar ou cancelá-la.';
      const closed = {...row, status: 'uncertain', message}; delete closed.kmsToken; await swap(closed);
      return respond(res, 502, {error: message, estado: estado || 'pendente', numero});
    }
  };
}
export default createReceitaHandler();
