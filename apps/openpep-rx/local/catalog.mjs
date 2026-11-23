// SPDX-License-Identifier: AGPL-3.0-or-later
import {readFile} from 'node:fs/promises';
import {merge, classifyMedication} from '../medicamentos.js';
const read = async name => JSON.parse(await readFile(new URL('../data/' + name, import.meta.url), 'utf8'));
export const catalog = merge(...await Promise.all(['medicamentos-controlados.json', 'medicamentos-retencao.json', 'medicamentos-rce.json', 'medicamentos-especiais.json'].map(read)));
export function checkMedicationTypes(body) {
  const medications = body.medicamentos || [body.medicamento];
  for (const medication of medications) {
    const decision = classifyMedication(catalog, medication);
    if (decision.type && decision.type !== body.tipo) throw Error(`${medication.nome}: a apresentação selecionada usa ${decision.type}. Separe medicamentos de tipos diferentes.`);
    if (decision.ambiguous) throw Error(`${medication.nome}: selecione uma apresentação da base para definir o tipo de receita.`);
  }
}
