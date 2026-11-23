// SPDX-FileCopyrightText: 2026 Carlos Pedrotti
// SPDX-License-Identifier: Apache-2.0
// Medication search for the prescription form, over two catalogs built by scripts/medicamentos/:
// - /medicamentos.json: Portaria 344 lists A1-A3, B1 and B2 (notifications NRA, NRB, NRB2); presentations marked
//   receita "RCE" (adendo exemptions such as tramadol up to 100 mg) go on the Receita de Controle Especial;
// - /medicamentos-retencao.json: antimicrobials and GLP-1 agonists (Receita Sujeita a Retenção, RET), with the
//   posologies and instructions from their bulas in /posologias-retencao.json;
// - /medicamentos-rce.json: lists C1 and C5 and the adendo exemptions of lists A and B (Receita de Controle Especial),
//   with their bula posologies in /posologias-rce.json;
// - /medicamentos-especiais.json: systemic retinoids (C2, NRR) and thalidomide (C3, NRT), with /posologias-especiais.json.
// Every presentation carries the prescription type it goes on. Picking one fills concentration, form, unit and
// quantity; free text stays allowed.
const norm = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
const words = s => norm(s).split(/[^a-z0-9]+/).filter(Boolean);
// Search keys: the words of the printed name, of the base substance and of the brands.
export const indexed = s => ({...s, keys: [...new Set([...words(s.nome), ...(s.busca || []).flatMap(words)])]});
const capital = s => s.replace(/(^|\s)\p{L}/gu, c => c.toUpperCase());
export const USES = {oftalmico: 'uso oftálmico', otologico: 'uso otológico', topico: 'uso tópico', vaginal: 'uso vaginal'};
// Merges the catalogs; `tipo` moves to each presentation, `rotulo` is the list shown in the search. The notification
// catalog's presentations marked RCE are left to the RCE catalog when it loaded, so each shows once.
export function merge(nr, ret, rce, special) {
  const notifications = (nr?.substancias || []).map(s => ({...s, rotulo: s.lista, apresentacoes: s.apresentacoes
    .filter(p => !(rce && p.receita === 'RCE')).map(p => ({...p, tipo: p.receita === 'RCE' ? 'RCE' : s.tipo}))}));
  return [
    ...notifications.filter(s => s.apresentacoes.length).map(indexed),
    ...(ret?.substancias || []).map(s => indexed({...s, rotulo: s.classe === 'glp1' ? 'GLP-1' : 'ATB', apresentacoes: s.apresentacoes.map(p => ({...p, tipo: 'RET'}))})),
    ...(rce?.substancias || []).map(s => indexed({...s, rotulo: /^C\d/.test(s.classe) ? s.classe : 'RCE', apresentacoes: s.apresentacoes.map(p => ({...p, tipo: 'RCE'}))})),
    ...(special?.substancias || []).map(s => indexed({...s, rotulo: s.classe, apresentacoes: s.apresentacoes.map(p => ({...p, tipo: s.tipo}))})),
  ];
}
// Bula posology of a retention presentation: same key, concentration and form; GLP-1 also by dose, and the tirzepatide
// vial by its device (its entry is marked "frasco-ampola").
export function posologyFor(posologies, s, p) {
  const item = posologies.find(i => i.chave === s.chave);
  if (!item) return null;
  const same = item.apresentacoes.filter(x => x.concentracao === p.concentracao && x.forma === p.forma && (item.classe !== 'glp1' || x.dose === p.dose));
  const vial = /frasco-ampola/.test(p.dispositivo || '');
  const match = same.find(x => /frasco-ampola/.test(x.marca || '') === vial) || same[0];
  if (!match) return null;
  // The bula rows have no route: a regimen that names another route than the presentation's (IM kit vs IV vial) is dropped.
  const ROUTES = {intramuscular: /intramuscular/i, intravenosa: /intravenos/i};
  const regimes = match.regimes.filter(r => !p.via || !Object.entries(ROUTES).some(([via, re]) => via !== p.via && re.test(r.texto)));
  return {regimes, fontes: match.fontes || [], pediatrico: match.pediatrico, orientacoes: [...item.orientacoes, ...match.orientacoes]};
}
// Every typed word must start one of the substance's words (name, base substance or brand).
const matches = (s, q) => q.every(w => s.keys.some(k => k.startsWith(w)));

// Regimen chips: dose timing by class, quantity for DAYS days. The physician picks one; nothing is filled unasked.
export const DAYS = 30;
const MORNING = ['metilfenidato', 'lisdexanfetamina', 'anfetamina', 'dexanfetamina', 'sibutramina', 'anfepramona', 'femproporex', 'mazindol', 'modafinila', 'modafinil', 'armodafinila'];
const BEDTIME = ['zolpidem', 'zopiclona', 'eszopiclona', 'flunitrazepam', 'nitrazepam', 'triazolam', 'estazolam', 'flurazepam', 'midazolam'];
const OPIOID = ['morfina', 'oxicodona', 'metadona', 'tramadol', 'codeina', 'tapentadol', 'hidromorfona', 'buprenorfina', 'fentanila', 'fentanil', 'petidina', 'nalbufina'];
function kind(sub) { const k = sub.keys; return MORNING.some(n => k.includes(n)) ? 'morning' : BEDTIME.some(n => k.includes(n)) ? 'bedtime' : OPIOID.some(n => k.includes(n)) ? 'opioid' : 'default'; }
// generic: false leaves out the plain schedule for substances without a known timing class (the C1 list: antidepressants,
// antipsychotics, anticonvulsants have their own schedules; they get curated regimens or free text).
export function regimens(sub, pres, {generic = true} = {}) {
  const f = norm(pres.forma);
  if (!generic && kind(sub) === 'default') return [];
  if (/comprimido|capsula|dragea/.test(f)) {
    const unit = f.includes('capsula') ? 'cápsula' : 'comprimido', via = f.includes('sublingual') ? 'por via sublingual' : 'por via oral';
    const halves = unit === 'comprimido' && !/liberacao|revestido|orodispersivel/.test(f);
    // [dose, times a day, when, chip label]
    const plans = {
      morning: [[1, 1, 'pela manhã', '1 pela manhã'], [1, 2, 'pela manhã e 1 ao meio-dia', '1 manhã + 1 meio-dia'], [0.5, 1, 'pela manhã', '½ pela manhã']],
      bedtime: [[1, 1, 'ao deitar', '1 ao deitar'], [0.5, 1, 'ao deitar', '½ ao deitar']],
      opioid: [[1, 2, 'de 12 em 12 horas', '1 de 12/12 h'], [1, 3, 'de 8 em 8 horas', '1 de 8/8 h'], [1, 4, 'de 6 em 6 horas', '1 de 6/6 h']],
      default: [[1, 1, 'à noite', '1 à noite'], [1, 2, 'de 12 em 12 horas', '1 de 12/12 h'], [1, 3, 'de 8 em 8 horas', '1 de 8/8 h'], [0.5, 1, 'à noite', '½ à noite']],
    }[kind(sub)];
    // Twice a day in the morning plan is immediate-release methylphenidate only; the others there are once daily.
    const twice = sub.keys.includes('metilfenidato') && !/liberacao/.test(f);
    return plans.filter(([dose, times, when]) => (dose === 1 || halves) && (!when.includes('meio-dia') || twice)).map(([dose, times, when, label]) => ({label,
      text: `Tomar ${dose === 1 ? 1 : 'meio'} ${unit} ${via} ${when}.`, quantity: Math.ceil(dose * times * DAYS)}));
  }
  if (/solucao oral|suspensao oral|gotas/.test(f)) return [
    {label: 'gotas à noite', text: 'Tomar __ gotas por via oral à noite.'},
    {label: 'gotas de 12/12 h', text: 'Tomar __ gotas por via oral de 12 em 12 horas.'},
    {label: 'gotas de 8/8 h', text: 'Tomar __ gotas por via oral de 8 em 8 horas.'}];
  if (f.includes('adesivo')) return [
    {label: 'trocar a cada 72 h', text: 'Aplicar 1 adesivo na pele íntegra e trocar a cada 72 horas.', quantity: Math.ceil(DAYS / 3)},
    {label: 'trocar a cada 7 dias', text: 'Aplicar 1 adesivo na pele íntegra e trocar a cada 7 dias.', quantity: Math.ceil(DAYS / 7)}];
  return [];
}

