import {normalizeContact} from './contato.js';
import {bindCEP} from './cep.js';
import {createDocumentShare} from './compartilhar-documento.js';
import {phoneField} from '/telefone.js';
import {rxFetch as fetch} from './local-client.js';
import {medicationSearch, regimens, DAYS, loadCatalog, posologyFor} from '/medicamentos.js';

const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
const LOCAL = document.documentElement.dataset.local === 'true';
let localToken, localReady = false, localReviewReady = false, localPDFURL;
const canonical = 'https://rx-hml.openpep.com.br';
// Retinoides (NRR) e talidomida (NRT) têm modelos com campos próprios e entram depois.
const TYPES = [['NRA', 'Notificação A'], ['NRB', 'Notificação B'], ['NRB2', 'Notificação B2'], ['RCE', 'Controle especial'], ['RET', 'Retenção'], ['NRR', 'Retinoides'], ['NRT', 'Talidomida']];
const TITLES = {NRA: 'Notificação de Receita A', NRB: 'Notificação de Receita B', NRB2: 'Notificação de Receita B2', RCE: 'Receita de Controle Especial', RET: 'Receita Sujeita a Retenção', NRR: 'Notificação de Receita Especial (retinoides)', NRT: 'Notificação de Receita de Talidomida'};
const UFS = 'AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO'.split(' ');
const STATES = {revisao:['Em revisão','idle'], assinando:['Assinando','warn'], assinada:['Assinada','ok'],rascunho: ['Rascunho', 'idle'], emitindo: ['Em emissão', 'warn'], pendente: ['Assinatura pendente', 'warn'], emitida: ['Emitida', 'ok'], cancelada: ['Cancelada', 'bad']};
let data = null, current = crypto.randomUUID(), reviewed = null, issued = false, busy = false, lastIssued = null;
// The emitter's saved address (from the last prescription) shows as a summary until "Alterar".
let savedEmitter = null, editingEmitter = true, emitterInitialized = false;

for (const select of $$('select.uf')) { select.append(new Option('UF', '')); for (const uf of UFS) select.append(new Option(uf, uf)); }
// The patient's phone only feeds the WhatsApp link: never sent to the server. The office phone is printed.
$('#patient-email-row').hidden=!LOCAL;
const patientPhone = phoneField($('#patient-phone'), {mobile: true}), emitterPhone = phoneField($('#emitter-phone'));
const tipo = () => $('#tipo').value;
const loaded = () => delete document.documentElement.dataset.transition;
const when = iso => iso ? new Date(iso).toLocaleString('pt-BR', {day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit'}) : '';
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
function result(text, tone = '') { $('#result').textContent = text; $('#result').className = tone; }
async function call(path, body) {
  const r = await fetch(path, {method: body ? 'POST' : 'GET', credentials: 'same-origin', cache: 'no-store', headers: {...(LOCAL ? {'X-OpenPEP-Request':'local', 'X-OpenPEP-Local':localToken || ''} : {}), ...(body ? {'Content-Type':'application/json'} : {})}, body: body ? JSON.stringify(body) : undefined});
  let json = {}; try { json = await r.json(); } catch {}
  return {ok: r.ok, status: r.status, json};
}

// CPF: mask while typing digits, check digits when complete. Letters mean a passport, kept as typed (uppercase).
const cpfDigits = v => /^[\d.\-\s]*$/.test(v) ? v.replace(/\D/g, '') : null;
function validCPF(d) {
  if (!/^\d{11}$/.test(d) || /^(\d)\1{10}$/.test(d)) return false;
  for (const len of [9, 10]) { let sum = 0; for (let i = 0; i < len; i++) sum += Number(d[i]) * (len + 1 - i); if ((sum * 10) % 11 % 10 !== Number(d[len])) return false; }
  return true;
}
const maskCPF = d => d.replace(/^(\d{3})(\d)/, '$1.$2').replace(/^(\d{3})\.(\d{3})(\d)/, '$1.$2.$3').replace(/\.(\d{3})(\d{1,2})$/, '.$1-$2');
function documentState(value) {
  const d = cpfDigits(value);
  if (!value.trim()) return {};
  if (d !== null) return d.length < 11 ? {} : validCPF(d) ? {ok: 'CPF válido'} : {error: 'CPF inválido: confira os dígitos.'};
  return /^[A-Z0-9]{5,20}$/.test(value) ? {ok: 'Passaporte'} : {error: 'Passaporte: use de 5 a 20 letras e números.'};
}
function hint(id, {ok, error, text} = {}) { const el = $(id); el.textContent = error || ok || text || ''; el.className = `hint${error ? ' bad' : ok ? ' ok' : ''}`; }
$('#patient-document').addEventListener('input', e => {
  const el = e.target, d = cpfDigits(el.value);
  el.value = d !== null ? maskCPF(d.slice(0, 11)) : el.value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 20);
  const state = documentState(el.value); hint('#patient-document-hint', state);
  if (!state.error) el.removeAttribute('aria-invalid');
});

// Address from the CEP (server-side ViaCEP/BrasilAPI). The CEP fills street, district, city and UF; the number is typed.
function address(prefix) {
  const v = k => $(`#${prefix}-${k}`).value.trim().replace(/\s+/g, ' '), cep = v('cep').replace(/\D/g, '');
  const street = [v('logradouro'), v('numero'), v('complemento')].filter(Boolean).join(', ');
  return [street, v('bairro'), cep.length === 8 ? `CEP ${cep.slice(0, 5)}-${cep.slice(5)}` : ''].filter(Boolean).join(' - ');
}
function wireCEP(prefix){
  return bindCEP({input:$(`#${prefix}-cep`),button:$(`#${prefix}-cep-search`),fields:Object.fromEntries(['logradouro','bairro','cidade','uf','numero'].map(k=>[k,$(`#${prefix}-${k}`)])),
    lookup:cep=>call('/api/receita/cep?cep='+cep),notify:value=>hint(`#${prefix}-cep-hint`,value),onFill:invalidateReview,canApply:()=>!busy&&!issued&&(prefix==='patient'||editingEmitter)});
}
const patientCEP=wireCEP('patient'),emitterCEP=wireCEP('emitter');

function showEmitter() {
  $('#emitter-summary').hidden = editingEmitter; $('#emitter-fields').hidden = !editingEmitter;
  const p = data?.prescritor;
  $('#emitter-name').hidden = LOCAL && !editingEmitter;
  $('#emitter-summary-identity').textContent = p && data.configured !== false ? `${p.nome} · CRM ${p.crm}/${p.uf}` : '';
  $('#emitter-summary-text').textContent = savedEmitter ? `${savedEmitter.endereco}, ${savedEmitter.cidade} / ${savedEmitter.uf}${savedEmitter.telefone ? ` · Tel. ${savedEmitter.telefone}` : ''}` : 'Endereço do consultório não cadastrado.';
  $('#emitter-edit').textContent = savedEmitter ? 'Editar cadastro' : 'Completar cadastro';
  $('#emitter-cancel').hidden = !data?.configured;
}
function fillEmitter() {
  emitterCEP.reset();
  const p = data?.configured ? data.prescritor : {};
  for (const [key,id] of Object.entries({nome:'name',cpf:'cpf',crm:'crm',uf:'uf'})) $(`#emitter-profile-${id}`).value = p[key] || '';
  const legacy = Boolean(savedEmitter?.endereco && !savedEmitter.parts);
  $('#emitter-full-address-row').hidden = !legacy; $('#emitter-address-parts').hidden = legacy;
  $('#emitter-full-address').value = savedEmitter?.endereco || '';
  for (const key of ['cep','logradouro','numero','complemento','bairro']) $(`#emitter-${key}`).value = savedEmitter?.parts?.[key] || '';
  for (const key of ['cidade','uf']) $(`#emitter-${key}`).value = savedEmitter?.[key] || '';
  emitterPhone.set(savedEmitter?.telefone || '');
  hint('#emitter-cep-hint');
}
$('#emitter-edit').onclick = () => {
  if (LOCAL) fillEmitter();
  editingEmitter = true; showEmitter(); invalidateReview();
  if (LOCAL) { $('#emitter-profile-name').focus(); return; }
  const cep = /CEP (\d{5}-\d{3})/.exec(savedEmitter?.endereco || '')?.[1];
  if (cep) { $('#emitter-cep').value = cep; $('#emitter-cep').dispatchEvent(new Event('input')); }
  if (savedEmitter?.telefone) emitterPhone.set(savedEmitter.telefone);
  $('#emitter-cep').focus();
};
function emitterProblem() {
  const checks = [
    ['#emitter-profile-name', v => /^[A-Za-zÀ-ÿ .'-]{3,120}$/.test(v), 'Informe o nome completo do emitente.'],
    ['#emitter-profile-cpf', v => validCPF(v.replace(/\D/g,'')), 'Confira o CPF do emitente.'],
    ['#emitter-profile-crm', v => /^\d{1,10}$/.test(v), 'Informe o CRM do emitente.'],
    ['#emitter-profile-uf', v => UFS.includes(v), 'Selecione a UF do CRM.'],
    ...($('#emitter-full-address-row').hidden ? [
      ['#emitter-logradouro', v => v.length >= 2, 'Informe o endereço do consultório.'],
      ['#emitter-numero', v => v.length > 0, 'Informe o número do consultório (ou s/n).'],
      ['#emitter-cep', v => !v || /^\d{8}$/.test(v.replace(/\D/g,'')), 'Confira o CEP do consultório.'],
    ] : [['#emitter-full-address', v => v.length >= 3, 'Informe o endereço do consultório.']]),
    ['#emitter-cidade', v => v.length >= 2, 'Informe a cidade do consultório.'],
    ['#emitter-uf', v => UFS.includes(v), 'Selecione a UF do consultório.'],
    ['#emitter-phone', () => emitterPhone.empty() || emitterPhone.valid(), 'Confira o telefone do consultório.'],
  ];
  const bad = checks.find(([id,valid]) => !valid($(id).value.trim()));
  return bad ? {el:$(bad[0]),message:bad[2]} : null;
}
async function saveEmitter() {
  const bad = emitterProblem();
  if (bad) { bad.el.setAttribute('aria-invalid','true'); bad.el.focus(); throw Error(bad.message); }
  const profile = Object.fromEntries(Object.entries({nome:'name',cpf:'cpf',crm:'crm',uf:'uf'}).map(([k,id]) => [k,$(`#emitter-profile-${id}`).value.trim()]));
  const office = {endereco: $('#emitter-full-address-row').hidden ? address('emitter') : $('#emitter-full-address').value,
    cidade:$('#emitter-cidade').value,uf:$('#emitter-uf').value,telefone:emitterPhone.empty() ? '' : emitterPhone.printed(),
    ...($('#emitter-full-address-row').hidden ? {parts:Object.fromEntries(['cep','logradouro','numero','complemento','bairro'].map(k=>[k,$(`#emitter-${k}`).value]))} : {})};
  const r = await call('/api/local/settings',{profile,office});
  if (!r.ok) throw Error(r.json.error || 'Não foi possível salvar o emitente.');
  const state = await call('/api/receita/estado');
  if (!state.ok) throw Error('Emitente salvo. Reabra a página para carregar o cadastro.');
  const previous = data?.prescritor;
  data = state.json; savedEmitter = data.emitente; editingEmitter = false; emitterInitialized = true;
  if (previous && ['cpf','crm','uf'].some(k=>previous[k] !== data.prescritor[k])) current = crypto.randomUUID();
  invalidateReview(); render(); $('#emitter-status').textContent = 'Emitente salvo neste computador.';
}
$('#emitter-profile-cpf').addEventListener('input', e=>{e.target.value = maskCPF(e.target.value.replace(/\D/g,'').slice(0,11));});
$('#emitter-save').onclick = async () => {
  if (busy || issued) return;
  const bad = emitterProblem(); if (bad) {bad.el.focus(); $('#emitter-status').textContent=bad.message; return;}
  busy = true; lockForm(true);
  try { await saveEmitter(); } catch (error) { $('#emitter-status').textContent = error.message; }
  finally { busy=false; lockForm(issued); }
};
$('#emitter-cancel').onclick = () => {fillEmitter(); editingEmitter=false; showEmitter(); $('#emitter-status').textContent='';};

// Medication: search by name or brand; the pick fills the presentation and moves to the notification type of its list.
const setField = (name, value) => { const el = $(`#form [name="medicamento.${name}"]`); el.value = value; el.removeAttribute('aria-invalid'); };
let picked = null;
function chip(label, onClick, pressed = false) {
  const b = document.createElement('button'); b.type = 'button'; b.className = 'chip'; b.textContent = label; b.setAttribute('aria-pressed', String(pressed)); b.onclick = onClick; return b;
}
let catalogData = {list: [], posologies: []}, showAllPresentations = false;
loadCatalog().then(c => { catalogData = c; });
const MED_EXTRAS = ['#med-presentations', '#med-regimens', '#med-regimens-note', '#med-calc', '#med-notes'];
function usePresentation(p) {
  picked.presentation = p;
  // Injectables come in hospital boxes (50 ampoules): their quantity is left for the physician, except GLP-1 pens.
  setField('concentracao', p.concentracao); setField('forma', p.forma); setField('unidade', p.unidade);
  setField('quantidade', /injet/i.test(p.forma) && !p.dispositivo ? '' : String(p.quantidade));
  renderPresentation(p);
  explain();
  invalidateReview();
}
// Chips, bula regimens, calculator and instructions of the picked presentation (also when an item is reopened).
function renderPresentation(p) {
  const s = picked.substance;
  // Presentation chips: dose and device for pens and syringes; the pack size only when it is what tells two apart.
  const brands = new Set(s.apresentacoes.map(x => x.marcas?.[0]).filter(Boolean));
  const label = x => [x.dose && x.dispositivo ? `${x.dose} · ${x.dispositivo.replace(/\s*\(.*\)$/, '')}` : `${x.concentracao} · ${x.forma}`,
    s.apresentacoes.some(y => y !== x && y.concentracao === x.concentracao && y.forma === x.forma && y.dose === x.dose && y.dispositivo === x.dispositivo) ? `${x.quantidade} ${x.unidade}` : '',
    brands.size > 1 ? x.marcas?.[0] : ''].filter(Boolean).join(' · ');
  // GLP-1 read best by device, pack and dose; the rest by sales. Presentations without sales in the period (recent
  // launches, other pack sizes) wait behind "mais".
  const doseOf = x => Number(String(x.dose || x.concentracao).replace(/[^\d,]/g, '').replace(',', '.')) || 0;
  const ordered = s.classe === 'glp1' ? [...s.apresentacoes].sort((a, b) => (a.dispositivo || '').localeCompare(b.dispositivo || '') || a.quantidade - b.quantidade || doseOf(a) - doseOf(b)) : s.apresentacoes;
  const shown = showAllPresentations ? ordered : ordered.filter(x => x.vendas > 0 || x === p), hidden = ordered.length - shown.length;
  $('#med-presentations').replaceChildren(...shown.map(x => chip(label(x), () => usePresentation(x), x === p)),
    ...(hidden ? [chip(`mais ${hidden} sem venda no período`, () => { showAllPresentations = true; renderPresentation(p); })] : []));
  $('#med-presentations').hidden = s.apresentacoes.length < 2;
  // RET and the RCE catalog: the bula's regimens, instructions and pediatric calculator (curated files). Otherwise
  // timing chips by class; none for C1 substances without a curated regimen.
  const bula = s.classe ? posologyFor(catalogData.posologies, s, p) : null;
  const plans = bula ? bula.regimes.map(r => ({label: r.rotulo, text: r.texto, quantity: r.quantidade, days: r.dias, tempo: r.tempo})) : p.tipo === 'RET' ? [] : regimens(s, p, {generic: !s.classe});
  $('#med-regimens').replaceChildren(...plans.map(r => chip(r.label, () => useRegimen(r))));
  $('#med-regimens').hidden = !plans.length; $('#med-regimens-note').hidden = true;
  calculator(bula?.pediatrico, p);
  $('#med-notes-list').replaceChildren(...(bula?.orientacoes || []).map(text => {
    const li = document.createElement('li'), span = document.createElement('span');
    span.textContent = text; li.append(span, chip('Incluir', () => appendNote(text)));
    return li;
  }));
  $('#med-notes').hidden = !bula?.orientacoes?.length;
}
// Where the picked presentation goes, from its catalog: the notification of its list, the RCE (adendo exemptions),
// or the RET (antimicrobials and GLP-1). The type switches when there are numbers; otherwise the note says which to ask.
function explain() {
  const {substance: s, presentation: p} = picked, needed = p.tipo, stock = data?.estoque[needed] || 0;
  // RCE: valid 30 days (Portaria 344/1998, art. 52).
  const why = p.tipo === 'RCE' ? (s.classe && /^C\d/.test(s.classe) ? `Lista ${s.classe}: ${TITLES.RCE}, válida por 30 dias` : `${s.nome} ${p.concentracao} vai em ${TITLES.RCE}, válida por 30 dias`)
    : needed === 'RET' ? `${s.classe === 'glp1' ? 'Agonista de GLP-1' : 'Antimicrobiano'}: ${TITLES.RET}, válida por ${s.classe === 'glp1' ? 90 : 10} dias${s.fora_da_lista ? ' (fora da lista da IN 360/2025; retenção por decisão clínica)' : ''}`
    : needed === 'NRR' ? `Lista C2: ${TITLES.NRR}, válida por 30 dias; acompanha o Termo de Consentimento Pós-Informação, gerado já preenchido com a prévia, para você e o paciente assinarem`
    : needed === 'NRT' ? `Lista C3: ${TITLES.NRT}, válida por 20 dias e só na UF de emissão; acompanha o Termo de Responsabilidade/Esclarecimento (3 vias, gerado já preenchido com a prévia) e é dispensada em unidade credenciada do SUS`
    : `Lista ${s.lista || s.classe}: ${TITLES[needed]}`;
  // Cannabis products: the THC content decides the prescription (RCE up to 0,2%; Notificação A above).
  const cannabis = s.keys.some(k => k === 'cannabis' || k === 'canabidiol') ? ' Produtos de Cannabis: THC até 0,2% vão em RCE; acima de 0,2%, em Notificação de Receita A.' : '';
  if (needed === tipo()) return medInfo(`${why}.${cannabis}`);
  // Other medications already on this prescription: its type stays; this one goes on another prescription.
  if (meds.length > 1) return medInfo(`${why}. Esta receita é ${TITLES[tipo()]}: emita este medicamento em outra receita.`, 'bad');
  if (LOCAL || stock > 0) { $('#tipo').value = needed; $('#tipo').removeAttribute('aria-invalid'); showRetention(); renderStack(); return medInfo(`${why}. Tipo sugerido pela apresentação.${cannabis}`); }
  medInfo(`${why}, e você não tem números ${needed}. Solicite em Meus números.${cannabis}`, 'bad');
}
function useRegimen(r) {
  const area = $('#form [name="medicamento.posologia"]');
  area.value = r.text; area.removeAttribute('aria-invalid');
  if (r.quantity) setField('quantidade', String(r.quantity));
  if (r.tempo && tipo() === 'NRT') setField('tempo', r.tempo);
  $('#med-regimens-note').hidden = false;
  $('#med-regimens-note').textContent = r.quantity ? `Quantidade para ${r.days || DAYS} dias. Ajuste se precisar.` : 'Complete o número de gotas.';
  for (const b of $$('#med-regimens .chip')) b.setAttribute('aria-pressed', String(b.textContent === r.label));
  const gap = r.text.indexOf('__');
  area.focus(); if (gap >= 0) area.setSelectionRange(gap, gap + 2);
  invalidateReview();
}
// A bula instruction appended to the posology, within the field's 600 characters.
// On the NRT it goes to the model's "Outras orientações" (300 characters).
function appendNote(text) {
  const nrt = tipo() === 'NRT', area = $(`#form [name="medicamento.${nrt ? 'orientacoes' : 'posologia'}"]`), limit = nrt ? 300 : 600;
  const next = [area.value.trim(), text].filter(Boolean).join(' ');
  if (area.value.includes(text)) return;
  if (next.length > limit) return result(`${nrt ? 'Outras orientações' : 'A posologia'} passaria de ${limit} caracteres; resuma antes de incluir esta orientação.`, 'bad');
  area.value = next; area.removeAttribute('aria-invalid'); invalidateReview();
}
// Pediatric suspension by weight (bula data): dose per take = min(mg/kg/day x weight, maximum per day) / doses per day;
// the volume goes into the regimen text and the bottles cover the whole course.
const decimal = n => n.toLocaleString('pt-BR', {maximumFractionDigits: 1});
let dosing = null;
function calculator(c, p) {
  $('#med-calc').hidden = !c; $('#med-weight').value = ''; $('#med-calc-out').textContent = ''; $('#med-calc-use').disabled = true; dosing = null;
  $('#med-calc-dose-label').hidden = !c?.mgPorUnidade;
  if (!c) return;
  if (c.mgPorUnidade) return capsules(c);
  $('#med-weight').oninput = () => {
    const kg = Number($('#med-weight').value);
    if (!(kg >= 1 && kg <= 150)) { dosing = null; $('#med-calc-use').disabled = true; $('#med-calc-out').textContent = ''; return; }
    // Some bulas give no daily maximum (phenobarbital drops): then only mg/kg/day applies.
    const cap = c.maxMgDia ?? Infinity, mgDay = Math.min(c.mgKgDia * kg, cap), mg = Math.round(mgDay / c.dosesDia), ml = Math.round(mg / c.mgPorMl * 10) / 10;
    const bottle = Number((/(\d+(?:,\d+)?)\s*mL/.exec(p.unidade)?.[1] || '').replace(',', '.'));
    const bottles = bottle ? Math.ceil(ml * c.dosesDia * c.dias / bottle) : null;
    dosing = {text: c.texto.replace('__ mL', `${decimal(ml)} mL (${mg} mg${c.componente ? ` de ${c.componente}` : ''})`).replace('__', decimal(ml)), bottles};
    $('#med-calc-out').textContent = `${c.mgKgDia} mg/kg/dia${mgDay < c.mgKgDia * kg ? ` (limitado a ${cap} mg/dia)` : ''} em ${c.dosesDia} tomada${c.dosesDia > 1 ? 's' : ''}: ${decimal(ml)} mL (${mg} mg) por tomada, ${c.dias} dias${bottles ? `, ${bottles} ${bottles === 1 ? 'frasco' : 'frascos'}` : ''}.`;
    $('#med-calc-use').disabled = false;
  };
  $('#med-calc-use').onclick = () => { if (dosing) { useRegimen({label: '', text: dosing.text, quantity: dosing.bottles, days: c.dias}); } };
}
// Capsules by weight (isotretinoin): mg/kg/day from the bula range, rounded to whole capsules; the course length follows
// the cumulative target dose (120 to 150 mg/kg).
function capsules(c) {
  const unit = c.mgPorUnidade, steps = [...new Set([c.mgKgDia, (c.mgKgDia + c.mgKgDiaMax) / 2, c.mgKgDiaMax])];
  $('#med-calc-dose').replaceChildren(...steps.map(v => new Option(`${decimal(v)} mg/kg/dia`, String(v))));
  const update = () => {
    const kg = Number($('#med-weight').value), perKg = Number($('#med-calc-dose').value);
    if (!(kg >= 20 && kg <= 200)) { dosing = null; $('#med-calc-use').disabled = true; $('#med-calc-out').textContent = ''; return; }
    const units = Math.max(1, Math.round(perKg * kg / unit)), daily = units * unit, real = daily / kg;
    const [low, high] = (c.doseAcumuladaMgKg || []).map(total => Math.round(total * kg / daily));
    dosing = {text: c.texto.replace('__', `${units} ${units === 1 ? 'cápsula' : 'cápsulas'} (${daily} mg)`), bottles: units * c.dias};
    $('#med-calc-out').textContent = `${decimal(kg)} kg × ${decimal(perKg)} mg/kg = ${decimal(perKg * kg)} mg/dia → ${units} de ${unit} mg (${daily} mg/dia, ${decimal(real)} mg/kg).`
      + (low ? ` Dose acumulada de ${c.doseAcumuladaMgKg[0]} a ${c.doseAcumuladaMgKg[1]} mg/kg: ${low} a ${high} dias nesta dose.` : '');
    $('#med-calc-use').disabled = false;
  };
  $('#med-weight').oninput = update; $('#med-calc-dose').onchange = update;
  $('#med-calc-use').onclick = () => { if (dosing) useRegimen({label: '', text: dosing.text, quantity: dosing.bottles, days: c.dias}); };
}
// Birth date and sex: RET (age, RDC 471/2021), NRR and NRT (their models). NRT also has the CID, the patient's phone,
// the guardian, the physician's specialty and registry, and the treatment time.
const withBirth = () => ['RET', 'NRR', 'NRT'].includes(tipo());
function showRetention() {
  const nrt = tipo() === 'NRT';
  const required = withBirth();
  $('#patient-birth').required = $('#patient-sex').required = required;
  $('#patient-birth-requirement').textContent = required ? 'obrigatória neste modelo' : 'opcional neste modelo';
  $('#patient-sex-requirement').textContent = required ? 'obrigatório neste modelo' : 'opcional neste modelo';
  for (const id of ['#patient-nrt', '#patient-guardian', '#emitter-nrt', '#med-nrt']) $(id).hidden = !nrt;
  if (nrt && savedEmitter) for (const [k, id] of [['especialidade', '#emitter-specialty'], ['cadastro', '#emitter-registry']]) if (!$(id).value && savedEmitter[k]) $(id).value = savedEmitter[k];
}
$('#patient-birth').addEventListener('input', () => {
  const v = $('#patient-birth').value, [y, m, d] = v.split('-').map(Number), now = new Date();
  if (!y) return hint('#patient-age');
  let months = (now.getFullYear() - y) * 12 + (now.getMonth() + 1 - m) - (now.getDate() < d ? 1 : 0);
  hint('#patient-age', months < 0 || y < now.getFullYear() - 130 ? {error: 'Confira a data.'} : {ok: months >= 24 ? `${Math.floor(months / 12)} anos` : `${months} ${months === 1 ? 'mês' : 'meses'}`});
});
function medInfo(text, tone = '') { $('#med-info').hidden = !text; $('#med-info').textContent = text; $('#med-info').className = `med-info ${tone}`; }
const medication = medicationSearch({input: $('#med-name'), list: $('#med-list'), tipo,
  recent: () => (data?.receitas || []).map(r => r.medicamento),
  onPick({substance, presentation}) {
    picked = {substance}; showAllPresentations = false;
    $('#med-name').value = substance.nome; $('#med-name').removeAttribute('aria-invalid');
    usePresentation(presentation);
    $('#form [name="medicamento.posologia"]').focus();
  }});
// Typing a different name drops the link to the catalog entry (free text is allowed).
$('#med-name').addEventListener('input', () => {
  if (picked && $('#med-name').value !== picked.substance.nome) { picked = null; medInfo(''); for (const id of MED_EXTRAS) $(id).hidden = true; }
});

// Several medications (RCE and RET, up to 3): one editor for the item being written; the others collapse into cards,
// in their order, and reopen with a click (accordion). meds[i] = {fields, picked}; the active one lives in the editor.
const MAX_MEDS = 3, MED_FIELDS = ['nome', 'concentracao', 'forma', 'quantidade', 'unidade', 'posologia'];
let meds = [null], active = 0;
const multi = () => tipo() === 'RCE' || tipo() === 'RET';
const editorFields = () => Object.fromEntries(MED_FIELDS.map(k => [k, $(`[name="medicamento.${k}"]`).value]));
const filled = f => MED_FIELDS.some(k => String(f?.[k] ?? '').trim());
const toItem = f => ({nome: f.nome, concentracao: f.concentracao, forma: f.forma, quantidade: Number(f.quantidade), unidade: f.unidade, posologia: f.posologia,
  ...(tipo() === 'NRT' ? {tempo: $('[name="medicamento.tempo"]').value, orientacoes: $('[name="medicamento.orientacoes"]').value} : {})});
const motion = !matchMedia('(prefers-reduced-motion: reduce)').matches;
const reveal = (el, from) => { if (motion && el?.animate) el.animate([{opacity: 0, transform: `translateY(${from}px)`}, {opacity: 1, transform: 'none'}], {duration: 220, easing: 'ease-out'}); };
function saveActive() { meds[active] = {fields: editorFields(), picked: picked ? {...picked} : null}; }
function loadEditor(item) {
  picked = item?.picked ? {...item.picked} : null; showAllPresentations = false;
  for (const k of MED_FIELDS) { const el = $(`[name="medicamento.${k}"]`); el.value = item?.fields?.[k] ?? ''; el.removeAttribute('aria-invalid'); }
  for (const id of MED_EXTRAS) $(id).hidden = true; medInfo('');
  if (picked?.presentation) { renderPresentation(picked.presentation); explain(); }
}
function medCard(m, i) {
  const f = m?.fields || {}, box = document.createElement('div'), open = document.createElement('button'), remove = document.createElement('button');
  const title = document.createElement('strong'), meta = document.createElement('span'), dose = document.createElement('small');
  box.className = 'med-card'; open.type = 'button'; open.className = 'med-card-open'; open.setAttribute('aria-label', `Editar o medicamento ${i + 1}`);
  title.textContent = `${i + 1}. ${f.nome || 'Medicamento sem nome'}`;
  meta.textContent = [f.concentracao, f.forma, f.quantidade && `${f.quantidade} ${f.unidade}`].filter(Boolean).join(' · ');
  dose.textContent = f.posologia || '';
  open.append(title, meta, dose); open.onclick = () => openItem(i);
  remove.type = 'button'; remove.className = 'link'; remove.textContent = 'Remover'; remove.onclick = () => removeItem(i);
  box.append(open, remove);
  return box;
}
function renderStack() {
  const several = meds.length > 1;
  $('#med-stack').replaceChildren(...meds.map((m, i) => i === active ? $('#med-editor') : medCard(m, i)));
  $('#med-stack').classList.toggle('several', several);
  $('#med-editor-title').hidden = !several; $('#med-editor-label').textContent = `Medicamento ${active + 1}`;
  $('#med-legend').textContent = several ? `Medicamentos · ${meds.length} de até ${MAX_MEDS}` : 'Medicamento';
  $('#med-add-row').hidden = !multi() && !several;
  $('#med-add').disabled = busy || issued || meds.length >= MAX_MEDS || !multi();
  $('#med-add-note').textContent = !multi() ? 'A notificação de receita tem um medicamento só.' : meds.length >= MAX_MEDS ? `Limite de ${MAX_MEDS} medicamentos por receita.` : `Até ${MAX_MEDS} por receita.`;
}
function openItem(i) {
  if (i === active || busy || issued) return;
  saveActive(); active = i; loadEditor(meds[i]); renderStack(); reveal($('#med-editor'), 4); $('#med-name').focus();
}
function removeItem(i) {
  if (busy || issued) return;
  if (i === active) { meds.splice(i, 1); active = Math.max(0, i - 1); loadEditor(meds[active]); }
  else { saveActive(); meds.splice(i, 1); if (i < active) active--; }
  if (!meds.length) { meds = [null]; active = 0; loadEditor(null); }
  renderStack(); invalidateReview();
}
// "Adicionar outro medicamento": the item being written must be complete; it collapses and a blank editor opens below.
$('#med-add').onclick = () => {
  const bad = medicationProblem(active);
  if (bad) { bad.el.setAttribute('aria-invalid', 'true'); bad.el.focus(); return result(bad.message, 'bad'); }
  result(''); saveActive(); const previous = active;
  meds.push(null); active = meds.length - 1; loadEditor(null); renderStack();
  reveal($('#med-stack').children[previous], -6); reveal($('#med-editor'), 8);
  $('#med-name').focus(); invalidateReview();
};
$('#med-editor-remove').onclick = () => removeItem(active);
// The first problem of one medication (the active one is read from the editor): missing fields or the wrong type.
function medicationProblem(i) {
  const f = i === active ? editorFields() : meds[i]?.fields || {}, pk = i === active ? picked : meds[i]?.picked;
  const prefix = meds.length > 1 ? `Medicamento ${i + 1}: ` : '', same = (a, b) => String(a).trim().toLowerCase() === String(b).trim().toLowerCase();
  const sub = pk?.substance || medication.find(f.nome);
  const pres = sub?.apresentacoes.find(p => same(p.concentracao, f.concentracao) && same(p.forma, f.forma));
  const types = new Set(sub?.apresentacoes.map(p => p.tipo)), needed = pres?.tipo || (types.size === 1 && !types.has(tipo()) ? [...types][0] : null);
  const at = k => { if (i !== active) openItem(i); return $(`[name="medicamento.${k}"]`); };
  if (needed && needed !== tipo()) return {el: i === active ? $('#tipo') : (openItem(i), $('#tipo')), message: `${prefix}${sub.nome}${pres ? ` ${pres.concentracao}` : ''} vai em ${TITLES[needed]}.${meds.length > 1 ? ' Emita em outra receita.' : data?.estoque[needed] > 0 ? '' : ` Solicite números ${needed} em Meus números.`}`};
  const missing = MED_FIELDS.find(k => !String(f[k] ?? '').trim());
  if (missing) return {el: at(missing), message: `${prefix}Preencha os dados do medicamento.`};
  return null;
}

const patientContact = () => normalizeContact({phone:patientPhone.empty()?'':patientPhone.digits(), email:$('#patient-email').value});
function formData() {
  const v = name => $(`#form [name="${name}"]`).value;
  const nrt = tipo() === 'NRT', saved = savedEmitter ? {endereco: savedEmitter.endereco, cidade: savedEmitter.cidade, uf: savedEmitter.uf, telefone: savedEmitter.telefone} : null;
  const emitente = {...(!editingEmitter && saved ? saved
    : {endereco: LOCAL && !$('#emitter-full-address-row').hidden ? $('#emitter-full-address').value : address('emitter'), cidade: v('emitente.cidade'), uf: v('emitente.uf'), telefone: emitterPhone.empty() ? '' : emitterPhone.printed()}),
    ...(nrt ? {especialidade: v('emitente.especialidade'), cadastro: v('emitente.cadastro')} : {})};
  return {id: current, tipo: tipo(), emitente, ...(LOCAL ? {practice:$('#local-practice').checked,publish:$('#local-publish').checked,contact:patientContact()} : {}),
    paciente: {nome: v('paciente.nome'), documento: v('paciente.documento'), endereco: address('patient'), cidade: v('paciente.cidade'), uf: v('paciente.uf'),
      ...(withBirth() ? {sexo: v('paciente.sexo'), nascimento: v('paciente.nascimento')} : {}),
      ...(nrt ? {cid: v('paciente.cid'), telefone: v('paciente.telefone')} : {})},
    ...(nrt && v('responsavel.nome').trim() ? {responsavel: {nome: v('responsavel.nome'), documento: v('responsavel.documento'), endereco: v('responsavel.endereco'), telefone: v('responsavel.telefone')}} : {}),
    ...medicationsBody()};
}
// RCE and RET send the list (a blank editor after complete items is left out); notifications send the one medication.
function medicationsBody() {
  saveActive();
  const list = meds.filter((m, i) => filled(m?.fields) || (meds.length === 1 && i === 0)).map(m => toItem(m?.fields || editorFields()));
  return multi() ? {medicamentos: list} : {medicamento: list[0] || toItem(editorFields())};
}
// First problem in the form, in reading order: the field is marked and focused; the server repeats every check.
function problem() {
  const blank = sel => !$(sel).value.trim(), doc = documentState($('#patient-document').value);
  saveActive();
  // Each medication in order (a catalog substance must go on the prescription type of its list); a blank editor after
  // complete items is ignored. Notifications take one medication.
  const toCheck = meds.map((m, i) => i).filter(i => meds.length === 1 || filled(meds[i]?.fields));
  const medicationIssue = () => {
    if (!multi() && toCheck.length > 1) return {el: $('#tipo'), message: 'A notificação de receita tem um medicamento só: remova os demais ou escolha RCE ou RET.'};
    for (const i of toCheck) { const issue = medicationProblem(i); if (issue) return issue; } // stops at the first (it may reopen that item)
    return null;
  };
  let medIssue;
  const checks = [
    [() => !tipo(), '#tipo', 'Escolha o tipo de receita.'],
    [() => $('#patient-name').value.trim().length < 3, '#patient-name', 'Informe o nome do paciente.'],
    [() => withBirth() && !$('#patient-birth').value, '#patient-birth', `Informe a data de nascimento do paciente (exigida na ${TITLES[tipo()]}).`],
    [() => withBirth() && !$('#patient-sex').value, '#patient-sex', `Informe o sexo do paciente (exigido na ${TITLES[tipo()]}).`],
    [() => tipo() === 'NRT' && !/^[A-Z][0-9]{2}(\.?[0-9A-Z]{1,2})?$/.test($('#patient-cid').value.trim().toUpperCase()), '#patient-cid', 'Informe o CID do paciente (ex.: A30.5).'],
    [() => !doc.ok, '#patient-document', doc.error || 'Informe o CPF ou, se estrangeiro, o passaporte do paciente.'],
    [() => !patientPhone.empty() && !patientPhone.valid(), '#patient-phone', 'Confira o celular do paciente (com DDD).'],
    [() => LOCAL && !$('#patient-email').checkValidity(), '#patient-email', 'Confira o e-mail do paciente.'],
    [() => blank('#patient-logradouro'), '#patient-logradouro', 'Informe o endereço do paciente (o CEP preenche).'],
    [() => blank('#patient-numero'), '#patient-numero', 'Informe o número do endereço do paciente (ou s/n).'],
    [() => blank('#patient-cidade'), '#patient-cidade', 'Informe a cidade do paciente.'],
    [() => blank('#patient-uf'), '#patient-uf', 'Selecione a UF do paciente.'],
    [() => (medIssue = medicationIssue()), null, null],
    [() => tipo() === 'NRT' && $('#emitter-specialty').value.trim().length < 3, '#emitter-specialty', 'Informe a sua especialidade (exigida na notificação de talidomida).'],
    [() => tipo() === 'NRT' && !$('#emitter-registry').value.trim(), '#emitter-registry', 'Informe o Nº do seu cadastro de prescritor de talidomida.'],
    [() => tipo() === 'NRT' && $('[name="medicamento.tempo"]').value.trim().length < 2, '[name="medicamento.tempo"]', 'Informe o tempo de tratamento.'],
    ...(!LOCAL && (editingEmitter || !savedEmitter) ? [
      [() => blank('#emitter-logradouro'), '#emitter-logradouro', 'Informe o endereço do consultório (o CEP preenche).'],
      [() => blank('#emitter-numero'), '#emitter-numero', 'Informe o número do endereço do consultório (ou s/n).'],
      [() => blank('#emitter-cidade'), '#emitter-cidade', 'Informe a cidade do consultório.'],
      [() => blank('#emitter-uf'), '#emitter-uf', 'Selecione a UF do consultório.'],
      [() => !emitterPhone.empty() && !emitterPhone.valid(), '#emitter-phone', 'Confira o telefone do consultório.']] : []),
  ];
  const found = checks.find(([bad]) => bad());
  return found && (found[1] ? {el: $(found[1]), message: found[2]} : medIssue);
}
$('#form').addEventListener('input', e => {
  e.target.removeAttribute?.('aria-invalid'); if (e.target.name === 'tipo') { $('#tipo').removeAttribute('aria-invalid'); showRetention(); renderStack(); }
  if (['patient-phone','patient-email'].includes(e.target.id)) updateSend(); else invalidateReview();
});
// Choosing another country for the patient's phone changes the WhatsApp link too.
$('#patient-phone').addEventListener('countrychange', updateSend);
function lockForm(locked) {
  for (const el of $$('#form input:not(#patient-phone):not(#patient-email), #form select, #form textarea, #form .chip, #form .med-card button, #med-editor-remove, #patient-cep-search, #emitter-cep-search, #review, #emitter-edit, #emitter-save, #emitter-cancel')) el.disabled = locked || busy;
  emitterPhone.disable(locked || busy);
  $('#med-add').disabled = locked || busy || meds.length >= MAX_MEDS || !multi();
}

// wa.me opens the installed WhatsApp app or WhatsApp Web.
function whatsappUrl(phone, {paciente, tipo, numero, link}) {
  const p = data.prescritor, first = String(paciente || '').split(' ')[0];
  const text = `Olá${first ? `, ${first}` : ''}. Sua receita (${TITLES[tipo] || tipo} nº ${numero}) foi emitida por ${p.nome}, CRM ${p.crm}/${p.uf}.\n\nAbra a receita assinada: ${link}\n\nNa farmácia, apresente este link ou o PDF.`;
  return `https://wa.me/${phone}?text=${encodeURIComponent(text)}`;
}
const documentShare = createDocumentShare();
async function shareLocalDocument(record) {
  if (!record?.id) return;
  const action=async(route,body)=>{const r=await call(route,body);if(!r.ok)throw Error(r.json.error||'Não foi possível acessar a publicação.');return r.json;};
  await documentShare.open({info:()=>action('/api/receita/compartilhar?id='+record.id),publish:()=>action('/api/receita/publicar',{id:record.id,confirm:true}),revoke:()=>action('/api/receita/revogar-link',{id:record.id,confirm:true}),saveContact:contact=>action('/api/receita/contato',{id:record.id,contact}),practice:record.practice, label:record.practice?'Ensaio assinado · prévia':'Receita assinada',
    load:async()=>{const response=await fetch(`/api/receita/pdf?id=${record.id}`,{cache:'no-store',headers:{'X-OpenPEP-Request':'local','X-OpenPEP-Local':localToken||''}});if(!response.ok)throw Error('Não foi possível abrir o PDF assinado.');return response.arrayBuffer();}});
}
const patientWhatsApp = () => !patientPhone.empty() && patientPhone.valid() ? patientPhone.digits() : null;
function updateSend() {
  $('#local-share').hidden = $('#preview-share').hidden = !LOCAL || !lastIssued;
  const phone = patientWhatsApp(), url = !LOCAL && lastIssued && phone ? whatsappUrl(phone, lastIssued) : null;
  $('#whatsapp').hidden = !url; $('#whatsapp-note').hidden = !lastIssued || Boolean(url);
  $('#preview-whatsapp').hidden = !url; $('#preview-phone').hidden = LOCAL || Boolean(url);
  if (LOCAL) $('#whatsapp-note').hidden = true;
  if (url) { $('#whatsapp').href = url; $('#preview-whatsapp').href = url; }
}

// Preview dialog: opens on "Revisar e emitir" with the PDF, signs from there and shows the signed result.
// NRR and NRT go with a form signed by the physician and the patient, filled in from the prescription (Portaria
// 344/1998, Anexos XV-XVI; RDC 11/2011, Anexos V-A/V-B, art. 20). Opens as a PDF to print.
const TERMS = {NRR: ['Termo de Consentimento Pós-Informação', '1ª paciente, 2ª médico, 3ª farmácia'], NRT: ['Termo de Responsabilidade/Esclarecimento', '1ª prontuário, 2ª unidade pública dispensadora, 3ª paciente']};
const termUrl = id => `/api/receita/termo?id=${id}&inline=1`;
function showTerm(id, t) {
  const term = TERMS[t];
  for (const el of ['#preview-term-note', '#preview-term-done', '#term']) $(el).hidden = !term;
  if (!term) return;
  $('#preview-term').textContent = term[0]; $('#preview-term-vias').textContent = term[1];
  for (const el of ['#preview-term', '#preview-term-done', '#term']) $(el).href = termUrl(id);
}
const dialog = $('#preview');
function preview(state, {title, sub, src, wait} = {}) {
  dialog.dataset.state = state; $('#preview-error').textContent = '';
  if (title) $('#preview-title').textContent = title;
  if (sub !== undefined) $('#preview-sub').textContent = sub;
  if (wait) $('#preview-wait-text').textContent = wait;
  if (src) { $('#preview-wait').hidden = false; $('#preview-frame').src = `${src}#view=FitH&toolbar=0&navpanes=0`; $('#preview-open').href = src; }
  if (!dialog.open) dialog.showModal();
}
$('#preview-frame').addEventListener('load', () => { if ($('#preview-frame').getAttribute('src')) $('#preview-wait').hidden = true; });
function closePreview() { if (dialog.dataset.state !== 'signing') dialog.close(); }
dialog.addEventListener('cancel', e => { if (dialog.dataset.state === 'signing') e.preventDefault(); });
dialog.addEventListener('close', () => { $('#preview-frame').removeAttribute('src'); if (issued) $('#done').scrollIntoView({block: 'nearest'}); });
$('#preview-close').onclick = closePreview; $('#preview-edit').onclick = closePreview;
$('#preview-phone').onclick = () => { dialog.close(); $('#patient-phone').focus(); };
$('#preview-new').onclick = () => { dialog.close(); newPrescription(); };

function render() {
  const p = data.prescritor;
  $('#panel').hidden = false;
  $('#who').textContent = LOCAL && !data.configured ? 'Configure o emitente' : `${p.nome} · CRM ${p.crm}/${p.uf}`;
  $('#professional').hidden = true;
  $('#emitter-name').textContent = LOCAL ? 'Cadastre seus dados e o consultório aqui. Eles serão usados nas próximas receitas.' : `${p.nome} · CRM ${p.crm}/${p.uf} (da sua conta)`;
  // 12-hour sessions cross midnight: the date shows when the end is not today.
  const end = new Date(data.expiraEm), today = end.toDateString() === new Date().toDateString();
  const until = end.toLocaleString('pt-BR', today ? {hour: '2-digit', minute: '2-digit'} : {day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit'});
  $('#session-bar').hidden = false; $('#renew').hidden = data.podeAssinar;
  $('#session').className = data.podeAssinar ? 'session' : 'session warn';
  $('#session').textContent = data.podeAssinar
    ? `Certificado autorizado até ${until} · ${plural(data.assinaturasRestantes, 'assinatura disponível', 'assinaturas disponíveis')}.`
    : 'A autorização do certificado acabou. Entre de novo para assinar; o rascunho e o histórico continuam aqui.';
  if (LOCAL) { $('#renew').hidden = true; $('#session').textContent = data.configured ? `VIDaaS local · uma confirmação por documento · SNCR ${data.environment === 'prd' ? 'produção' : 'homologação'}` : 'Cadastre seus dados na seção Emitente para revisar e assinar.'; }
  renderTypes(); showRetention(); renderStack();
  if (LOCAL && !emitterInitialized) { savedEmitter=data.emitente; editingEmitter=!data.configured; emitterInitialized=true; fillEmitter(); }
  else if (!LOCAL && data.emitente && !savedEmitter) { savedEmitter = data.emitente; editingEmitter = false; }
  showEmitter();
  const rows = (data.receitas || []).map(r => {
    const tr = document.createElement('tr'), [label, tone] = STATES[r.estado] || [r.estado, 'idle'];
    const cells = [when(r.emitidaEm || r.criadaEm), r.tipo, r.numero || '—', r.paciente || '', r.medicamento || ''];
    for (const [i, text] of cells.entries()) { const td = document.createElement('td'); td.textContent = text; if (i > 2) td.className = 'wrap'; tr.append(td); }
    const state = document.createElement('td'); state.className = `state ${tone}`; state.textContent = r.practice ? `Ensaio · ${label}` : label; tr.append(state);
    const actions = document.createElement('td');
    if (['emitida','assinada'].includes(r.estado)) {
      const a = document.createElement('a'); a.href = `/api/receita/pdf?id=${r.id}`; a.textContent = 'Baixar'; actions.append(a);
      const send = document.createElement('button'); send.type = 'button'; send.className = 'small secondary'; send.textContent = 'WhatsApp'; send.disabled = busy;
      send.onclick = () => sendWhatsApp(r); if (!LOCAL) actions.append(send);
      else {const share=document.createElement('button');share.type='button';share.className='small secondary';share.textContent='Enviar documento';share.onclick=()=>shareLocalDocument(r);actions.append(share);}
    }
    if (TERMS[r.tipo] && ['rascunho','revisao','pendente','emitida','assinada'].includes(r.estado)) {
      const a = document.createElement('a'); a.href = termUrl(r.id); a.target = '_blank'; a.rel = 'noopener noreferrer'; a.textContent = 'Termo'; a.title = TERMS[r.tipo][0]; actions.append(a);
    }
    if (r.estado === 'pendente' || (LOCAL && ['rascunho','revisao'].includes(r.estado))) {
      const a = document.createElement('a'); a.href = `/api/receita/previa?id=${r.id}`; a.target = '_blank'; a.rel = 'noopener noreferrer'; a.textContent = 'Prévia'; actions.append(a);
      const retry = document.createElement('button'); retry.type = 'button'; retry.className = 'small'; retry.textContent = LOCAL ? 'Revisar e assinar' : 'Tentar assinar'; retry.disabled = !data.podeAssinar || busy;
      retry.onclick = () => LOCAL ? reopenLocal(r.id) : emit(r.id, r.hash, r.tipo); actions.append(retry);
    }
    if (['rascunho','revisao','pendente'].includes(r.estado)) {
      const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'small secondary'; cancel.textContent = 'Cancelar'; cancel.disabled = busy;
      cancel.onclick = () => cancelPrescription(r); actions.append(cancel);
    }
    tr.append(actions); return tr;
  });
  $('#history').replaceChildren(...rows); $('#history-empty').hidden = rows.length > 0;
  lockForm(issued);
}
// The medication chooses the model; a compact select keeps manual entry available.
function renderTypes() {
  const chosen = tipo(), firstWithStock = TYPES.find(([t]) => data.estoque[t] > 0)?.[0];
  const selected = LOCAL ? chosen : chosen && data.estoque[chosen] > 0 ? chosen : firstWithStock;
  const placeholder = new Option('Identificado ao escolher o medicamento', '');
  $('#tipo').replaceChildren(placeholder, ...TYPES.map(([t]) => {
    const option = new Option(TITLES[t], t);
    option.disabled = !LOCAL && !(data.estoque[t] > 0);
    return option;
  }));
  $('#tipo').value = selected || '';
}
async function load() {
  try {
    const r = await call('/api/receita/estado');
    // No session: the entry page finishes the login and brings the user back here. A 403 stays here with its reason
    // (the entry page would send a confirmed session straight back, looping).
    if (r.status === 401) return location.replace('/entrada.html');
    if (r.status === 403) { loaded(); $('#professional').textContent = r.json.error || 'Sua sessão não permite emitir receitas.'; $('#blocked').hidden = false; $('#panel').hidden = true; return; }
    if (!r.ok) throw Error(r.json.error);
    data = r.json; if(LOCAL){$('#local-publication-option').hidden=!data.publication?.configured;$('#local-publish').disabled=!data.publication?.configured;if(!data.publication?.configured)$('#local-publish').checked=false;} render();
  } catch (e) { const text = e.message || 'Não foi possível carregar as receitas. Tente de novo.'; if (data) result(text, 'bad'); else $('#professional').textContent = text; }
  loaded();
}
function invalidateReview() { if (reviewed && !issued) reviewed = null; }

// "Revisar e emitir": check, save the draft and open the preview at once.
$('#form').onsubmit = async ev => {
  ev.preventDefault(); if (busy || issued) return;
  if (LOCAL && (editingEmitter || !savedEmitter)) {
    if (!editingEmitter) {fillEmitter(); editingEmitter=true; showEmitter();}
    const issue=emitterProblem();
    if(issue){issue.el.setAttribute('aria-invalid','true'); issue.el.focus(); return result(issue.message,'bad');}
    busy=true; lockForm(true);
    try {await saveEmitter();} catch(error){result(error.message,'bad'); return;} finally{busy=false; lockForm(false);}
  }
  const bad = problem();
  if (bad) { bad.el.setAttribute('aria-invalid', 'true'); bad.el.focus(); bad.el.scrollIntoView?.({block: 'center', behavior: 'smooth'}); return result(bad.message, 'bad'); }
  busy = true; lockForm(true); result('');
  const t = tipo(), left = data.estoque[t] || 0;
  $('#preview-frame').removeAttribute('src'); $('#preview-wait').hidden = false;
  preview('loading', {title: 'Prévia da receita', sub: `${TITLES[t]} · sem número e sem assinatura`, wait: 'Gerando a prévia…'});
  try {
    const r = await call('/api/receita/rascunho', formData());
    if (!r.ok) throw Error(r.json.error || 'Não foi possível salvar o rascunho.');
    reviewed = {id: r.json.id, hash: r.json.hash, tipo: t, ...(LOCAL ? r.json : {})};
    showTerm(reviewed.id, t);
    $('#preview-note').textContent = data.podeAssinar
      ? `Ao assinar, um número ${t} do seu estoque é reservado (${left === 1 ? 'resta 1' : `restam ${left}`}) e a receita é assinada com seu certificado.`
      : 'A autorização do certificado acabou: entre de novo para assinar. O rascunho fica salvo.';
    $('#emit').disabled = !data.podeAssinar;
    if (LOCAL) await localReview(reviewed);
    else { preview('review', {src: `/api/receita/previa?id=${reviewed.id}`}); $('#emit').focus(); }
  } catch (e) { dialog.close(); result(e.message, 'bad'); }
  finally { busy = false; lockForm(issued); }
};
async function emit(id, hash, t, fromDialog = false) {
  if (busy) return;
  if (LOCAL && (!localReviewReady || !reviewed?.signable || !$('#local-confirm').checked || !$('#local-identity').value || (reviewed.publicationRequested&&!$('#local-publish-confirm').checked))) return;
  if (LOCAL) localReviewReady = false;
  busy = true; lockForm(true);
  const waiting = LOCAL ? 'Autorize no VIDaaS Connect a assinatura do PDF revisado. Não repita o pedido.' : `Reservando o número ${t} e assinando com seu certificado… pode levar até um minuto.`;
  if (fromDialog) { preview('signing'); $('#preview-signing-text').textContent = waiting; } else result(waiting);
  try {
    const r = await call('/api/receita/emitir', {id, hash, confirm: true, ...(LOCAL ? {...(id===current?{contact:patientContact()}:{}),publish:$('#local-publish-confirm').checked,ticket:reviewed.ticket, identity:$('#local-identity').value} : {})});
    if (!r.ok) throw Error(r.json.error || 'Não foi possível emitir a receita.');
    if (LOCAL) {
      issued = id === current; reviewed = null; lastIssued = {id,tipo:t,practice:r.json.practice};
      $('#download').href = `/api/receita/pdf?id=${id}`; $('#preview-download').href = `/api/receita/pdf?id=${id}`;
      $('#done').hidden = false; $('#code-box').hidden = $('#preview-code-box').hidden = true;
      $('#preview-ok').textContent = r.json.practice ? 'Ensaio assinado. A prévia não é uma receita emitida.' : 'Receita assinada e salva no banco local.';
      if(r.json.publication?.status==='publicado')$('#preview-ok').textContent+=' Link do portal pronto para enviar.';
      else if(r.json.publication?.error)$('#preview-ok').textContent+=' '+r.json.publication.error;
      preview('done', {title:'Documento assinado', sub:r.json.numero ? `${TITLES[t]} · ${r.json.numero}` : 'Ensaio sem numeração oficial'});
      await showLocalPDF(`/api/receita/pdf?id=${id}&inline=1`); showTerm(id,t); updateSend(); result('PDF assinado e salvo localmente.', 'good');
      return;
    }
    // The emitter just used becomes the saved one: the next prescription shows it as a summary.
    if (id === current) { issued = true; savedEmitter = formData().emitente; editingEmitter = false; }
    const patient = id === current ? $('#patient-name').value : (data.receitas || []).find(x => x.id === id)?.paciente;
    lastIssued = {paciente: patient, tipo: t, numero: r.json.numero, link: r.json.link};
    $('#download').href = `/api/receita/pdf?id=${id}`; $('#preview-download').href = `/api/receita/pdf?id=${id}`;
    showTerm(id, t);
    $('#done').hidden = false; $('#code-box').hidden = !r.json.codigo; $('#patient-code').textContent = r.json.codigo || '';
    $('#preview-code-box').hidden = !r.json.codigo; $('#preview-code').textContent = r.json.codigo || '';
    $('#preview-ok').textContent = `${TITLES[t]} nº ${r.json.numero} assinada e registrada.`;
    result(`Receita emitida com o número ${r.json.numero}.`, 'good');
    updateSend();
    if (fromDialog) preview('done', {title: 'Receita emitida', sub: `${TITLES[t]} nº ${r.json.numero}`, src: `/api/receita/pdf?id=${id}&inline=1`});
  } catch (e) {
    if (fromDialog) { preview('review'); $('#emit').disabled = true; $('#preview-error').textContent = e.message; } else result(e.message, 'bad');
  } finally { busy = false; await load(); }
}
$('#local-share').onclick = $('#preview-share').onclick = () => shareLocalDocument(lastIssued);
$('#emit').onclick = () => reviewed && (!LOCAL || ($('#local-confirm').checked && $('#local-identity').value)) && emit(reviewed.id, reviewed.hash, reviewed.tipo, true);
// WhatsApp for an issued prescription from the history: the link carries its printed code (older ones get one now).
function promptedPhone(name) {
  const d = String(prompt(`Celular (WhatsApp) de ${name || 'paciente'}, com DDD:`) || '').replace(/\D/g, '');
  const full = d.length === 10 || d.length === 11 ? '55' + d : d;
  return full.length >= 12 && full.length <= 15 ? full : null;
}
async function sendWhatsApp(r) {
  const phone = patientWhatsApp() || promptedPhone(r.paciente);
  if (!phone) return result('Informe um celular com DDD para enviar por WhatsApp.', 'bad');
  const tab = window.open('', '_blank');
  try {
    let link = r.link;
    if (!link) { const c = await call('/api/receita/codigo', {id: r.id}); if (!c.ok) throw Error(c.json.error || 'Não foi possível preparar o link.'); link = c.json.link; }
    const url = whatsappUrl(phone, {...r, link});
    if (tab) { tab.opener = null; tab.location = url; } else location.assign(url);
  } catch (e) { tab?.close(); result(e.message, 'bad'); }
}
async function cancelPrescription(r) {
  const motivo = prompt(`Motivo do cancelamento${r.numero ? ` (o número ${r.numero} será inutilizado)` : ''}:`);
  if (motivo === null) return;
  busy = true; result('Cancelando…');
  try {
    const c = await call('/api/receita/cancelar', {id: r.id, motivo});
    if (!c.ok) throw Error(c.json.error || 'Não foi possível cancelar.');
    result('Receita cancelada.', 'good');
  } catch (e) { result(e.message, 'bad'); }
  finally { busy = false; await load(); }
}
// New prescription: clears patient and medication; keeps the type and the emitter.
function newPrescription() {
  patientCEP.reset();
  lastIssued = null; patientPhone.clear(); updateSend();
  current = crypto.randomUUID(); reviewed = null; issued = false;
  if (LOCAL) {$('#tipo').value = '';$('#local-publish').checked=false;}
  for (const el of $$('#form [name^="paciente."], #form [name^="medicamento."], #form [name^="responsavel."], #form [id^="patient-"]:is(input, select)')) { if (el.id !== 'patient-phone') el.value = ''; el.removeAttribute('aria-invalid'); }
  $('#patient-guardian').open = false;
  hint('#patient-document-hint'); hint('#patient-cep-hint');
  meds = [null]; active = 0; loadEditor(null); renderStack(); hint('#patient-age');
  showRetention();
  $('#done').hidden = true; $('#code-box').hidden = true; result('');
  lockForm(false); $('#patient-name').focus();
}
$('#new').onclick = newPrescription;
async function entry(route, body) {
  const r = await fetch('/api/entrada/' + route, {method: 'POST', credentials: 'same-origin', cache: 'no-store', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)});
  const json = await r.json().catch(() => ({}));
  if (!r.ok) throw Error(json.error || 'Não foi possível concluir a etapa.');
  return json;
}
$('#logout').onclick = async () => { try { await entry('logout', {}); } finally { location.replace('/entrada.html'); } };
// One click: close this session and start a new SSO login; the entry page continues to VIDaaS and returns here.
$('#renew').onclick = async () => {
  $('#renew').disabled = true; result('Abrindo o login institucional…');
  try { await entry('logout', {}); location.assign((await entry('sso', {confirm: true})).url); }
  catch (e) { result(e.message, 'bad'); $('#renew').disabled = false; }
};
if (LOCAL) await startLocal(); else if (location.origin !== canonical) { loaded(); $('#professional').textContent = `Abra ${canonical}/receita.html.`; } else load();

async function showLocalPDF(url) {
  $('#preview-frame').hidden = true; $('#preview-frame').removeAttribute('src');
  $('#preview-pages').hidden = false; $('#preview-pages').replaceChildren(); $('#preview-wait').hidden = false;
  const response = await fetch(url, {cache:'no-store', credentials:'same-origin'});
  if (!response.ok) throw Error('Não foi possível carregar a prévia.');
  const bytes = await response.arrayBuffer();
  if (reviewed && url.includes('/previa')) {
    const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), b => b.toString(16).padStart(2,'0')).join('');
    if (hash !== reviewed.hash) throw Error('O PDF mudou. Faça uma nova revisão.');
  }
  const {renderPDF} = await import('/pdf-preview.js'); await renderPDF(bytes, $('#preview-pages'));
  if (localPDFURL) URL.revokeObjectURL(localPDFURL);
  localPDFURL = URL.createObjectURL(new Blob([bytes],{type:'application/pdf'}));
  $('#preview-open').href = localPDFURL; $('#preview-wait').hidden = true;
}
function localCanSign() {
  const missingStock = reviewed && !reviewed.practice && !reviewed.signable;
  const environment = (reviewed?.environment || data?.environment) === 'prd' ? 'produção' : 'homologação';
  const reason = missingStock ? `Sem número ${reviewed.tipo} disponível em ${environment} para esta receita. Importe um lote desse tipo e ambiente e revise novamente.`
    : !localReady ? 'O auxiliar de assinatura VIDaaS não está disponível. Confira a instalação local.'
    : !reviewed || !localReviewReady ? 'A prévia precisa estar pronta e revisada antes de assinar.'
    : !$('#local-identity').value ? 'Consulte o VIDaaS e selecione o titular do certificado.'
    : reviewed?.publicationRequested&&!$('#local-publish-confirm').checked ? 'Confirme o envio deste PDF ao portal ou volte para editar e desmarque o link.'
    : !$('#local-confirm').checked ? 'Confirme a revisão do PDF e a correspondência do certificado com o emitente.' : '';
  $('#emit').disabled = Boolean(reason);
  $('#emit').title = reason || 'Assinar o PDF revisado com o certificado selecionado';
  $('#local-sign-status').hidden = Boolean(missingStock);
  $('#local-sign-status').textContent = reason || (reviewed?.practice ? 'Pronto para assinar o ensaio. O PDF continuará identificado como prévia.' : 'Pronto para assinar com o certificado selecionado.');
  $('#local-stock-help').hidden = !missingStock;
  $('#local-stock-reason').textContent = missingStock ? reason : '';
  $('#local-practice-start').hidden = reviewed?.id !== current;
}
async function localReview(record) {
  localReviewReady = false; reviewed = record; $('#local-confirm').checked = false; $('#local-publish-confirm').checked=false; $('#local-publication-confirm').hidden=!record.publicationRequested; $('#local-publication-origin').textContent=record.publicationOrigin||''; $('#emit').disabled = true; $('#local-stock-help').hidden = true;
  preview('loading', {title:'Revisar receita', sub:record.numero ? `${TITLES[record.tipo]} · ${record.numero}` : TITLES[record.tipo], wait:'Preparando todas as páginas…'});
  await showLocalPDF(`/api/receita/previa?id=${record.id}`);
  localReviewReady = true;
  $('#preview-note').textContent = record.practice ? 'Ensaio: este PDF fica identificado como prévia e não consome números.' : record.signable ? 'O número já está reservado para esta receita. A assinatura usará exatamente o PDF exibido.' : 'O certificado pode ser consultado, mas a emissão aguarda a numeração SNCR indicada acima.';
  preview('review'); localCanSign(); showTerm(record.id,record.tipo);
}
async function reopenLocal(id) {
  if (busy) return;
  busy = true; $('#local-stock-retry').disabled = true; $('#local-stock-retry').setAttribute('aria-busy','true');
  try { const r = await call('/api/receita/revisar',{id}); if (!r.ok) throw Error(r.json.error); await localReview(r.json); }
  catch(error) { if(dialog.open) $('#preview-error').textContent=error.message; else result(error.message,'bad'); }
  finally { busy = false; $('#local-stock-retry').disabled=false; $('#local-stock-retry').removeAttribute('aria-busy'); }
}
async function startLocal() {
  $$('[data-local-only]').forEach(el => el.hidden=false); $('#logout').hidden = true;
  $('#numbers-link').href='/dados-locais.html#transferencia'; $('#review').textContent='Revisar e assinar'; $('#emit').textContent='Assinar com VIDaaS local';
  $('#local-stock-retry').onclick=()=>reviewed && reopenLocal(reviewed.id);
  $('#local-practice-start').onclick=()=>{
    if(busy || !reviewed || reviewed.id!==current || reviewed.signable) return;
    $('#local-practice').checked=true; $('.practice-options').open=true; invalidateReview(); closePreview();
    result('Modo de ensaio selecionado. Clique em Revisar e assinar para gerar uma prévia sem numeração oficial.');
    $('#review').focus();
  };
  $('#local-confirm').onchange=$('#local-publish-confirm').onchange=localCanSign; $('#local-identity').onchange=()=>{ $('#local-confirm').checked=false; localCanSign(); };
  $('#local-certificates').onclick=async()=>{
    $('#local-certificates').disabled=true; $('#local-certificates').setAttribute('aria-busy','true'); $('#local-confirm').checked=false; localCanSign(); $('#local-cert-status').textContent='Consultando VIDaaS Connect…';
    try { const r=await call('/api/local/certificates',{}); if(!r.ok)throw Error(r.json.error); $('#local-identity').replaceChildren(new Option('Selecione o titular',''),...r.json.certificates.map(c=>new Option(c.name,c.id))); $('#local-cert-status').textContent=r.json.certificates.length?'Confira o titular e o emitente antes de autorizar.':'Abra e autentique o VIDaaS Connect.'; }
    catch(error){ $('#local-cert-status').textContent=error.message; }
    finally { $('#local-certificates').disabled=false; $('#local-certificates').removeAttribute('aria-busy'); localCanSign(); }
  };
  try {
    const response=await fetch('/api/local/session',{headers:{'X-OpenPEP-Request':'local'},cache:'no-store'});
    const session=await response.json(); localToken=session.token; localReady=session.ready;
    if(!localReady) $('#local-cert-status').textContent='Prepare o auxiliar VIDaaS local com npm run build:signer.';
    await load();
    if (location.hash === '#historico') { $('#historico').scrollIntoView(); $('#historico').focus({preventScroll:true}); }
  } catch (error) { loaded(); $('#professional').textContent=error.message||'Inicie o serviço local do OpenPEP-Rx para continuar.'; }
}
