const $ = s => document.querySelector(s);
const local = document.documentElement.dataset.local === 'true';
if (local) $('.intro').textContent = 'Consulta no computador que emitiu a receita. O código abre a cópia assinada guardada no banco local; este endereço não é um portal público.';
// /r/<código curto da receita> (26 caracteres base32, do QR ou do endereço impresso).
const token = location.pathname.split('/').pop() || '';
const TITLES = {NRA: 'Notificação de Receita A', NRB: 'Notificação de Receita B', NRB2: 'Notificação de Receita B2', RCE: 'Receita de Controle Especial', RET: 'Receita Sujeita a Retenção'};
let blobUrl = '';
function status(text) { $('#status').textContent = text; }
if (!/^[A-Za-z2-7]{26}$/.test(token)) { status('Endereço de receita inválido. Confira o QR ou o endereço impresso.'); $('#form').hidden = true; }
$('#code').oninput = e => { e.target.value = e.target.value.replace(/\D/g, '').slice(0, 6); };
// The link sent to the patient (and the printed QR) carries the code in the fragment: open straight away,
// then take it off the address bar.
const fromLink = /^#\d{6}$/.test(location.hash) ? location.hash.slice(1) : '';
if (fromLink) history.replaceState(null, '', location.pathname);
async function verify(code) {
  if (!/^\d{6}$/.test(code)) return status('Digite os 6 dígitos do código.');
  const button = $('#form button'); button.disabled = true; status('Verificando…');
  try {
    const headers = {'Content-Type':'application/json'};
    if (local) {
      const session = await (await fetch('/api/local/session', {headers:{'X-OpenPEP-Request':'local'},cache:'no-store'})).json();
      headers['X-OpenPEP-Request']='local'; headers['X-OpenPEP-Local']=session.token;
    }
    const r = await fetch('/api/receita/acesso', {method: 'POST', headers, cache: 'no-store', credentials: 'same-origin', body: JSON.stringify({id: token, codigo: code})});
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw Error(data.error || 'Não foi possível verificar a receita.');
    const bytes = Uint8Array.from(atob(data.pdf), c => c.charCodeAt(0));
    if (blobUrl) URL.revokeObjectURL(blobUrl);
    blobUrl = URL.createObjectURL(new Blob([bytes], {type: 'application/pdf'}));
    $('#summary').textContent = `${TITLES[data.tipo] || data.tipo} assinada digitalmente.`;
    $('#numero').textContent = data.numero;
    $('#data').textContent = new Date(data.emitidaEm).toLocaleString('pt-BR', {dateStyle: 'short', timeStyle: 'short', timeZone: 'America/Sao_Paulo'});
    const p = data.prescritor || {};
    $('#prescritor').textContent = `${p.nome || ''} · ${p.conselho || 'CRM'} ${p.inscricao || ''}/${p.uf || ''}`;
    $('#view').href = blobUrl; $('#save').href = blobUrl; $('#save').download = `receita-${data.tipo}-${data.numero}.pdf`;
    $('#sncr').href = 'https://sncr.anvisa.gov.br/receita/consultar?numero=' + encodeURIComponent(data.numero);
    $('#found').hidden = false; $('#form').hidden = true; status(''); $('#view').focus();
  } catch (e) { status(e.message); }
  finally { button.disabled = false; $('#code').value = ''; }
}
$('#form').onsubmit = ev => { ev.preventDefault(); verify($('#code').value); };
if (fromLink && !$('#form').hidden) verify(fromLink);
addEventListener('pagehide', () => { if (blobUrl) URL.revokeObjectURL(blobUrl); });
import {rxFetch as fetch} from './local-client.js';
