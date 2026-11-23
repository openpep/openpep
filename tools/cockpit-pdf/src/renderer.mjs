// SPDX-FileCopyrightText: 2026 Carlos Pedrotti
// SPDX-License-Identifier: Apache-2.0
import {PDFDocument, PDFName, PDFNumber, PDFHexString, PDFString} from 'pdf-lib';
import {prescriptionContent, prescriptionPDF} from './receita-doc.mjs';
import {termoPDF, TERM_TYPES} from './termo-doc.mjs';

export async function render(input, fonts) {
  const checked = prescriptionContent(input.body, input.date);
  if (checked.error) throw Error(checked.error);
  // Only the explicit production environment drops the trial marks.
  const production = input.environment === 'production';
  const options = {id: input.id, tipo: checked.tipo, numero: input.number || null,
    conteudo: checked.conteudo, prescritor: input.prescriber, emitidaEm: input.date, fonts, previa: !production};
  return {pdf: await prescriptionPDF(options),
    term: TERM_TYPES.includes(checked.tipo) ? await termoPDF(options) : null,
    source: JSON.stringify({id:input.id, ambiente: production ? 'production' : 'homologation', numero:input.number || null, data:input.date, tipo: checked.tipo, conteudo: checked.conteudo, prescritor: input.prescriber, catalogo:(input.body.medicamentos ?? [input.body.medicamento]).map(m => m.catalog ?? null), receituarioAjustado:(input.body.medicamentos ?? [input.body.medicamento]).map(m => m.recipeOverride ?? null), preenchimentoAssistido:(input.body.medicamentos ?? [input.body.medicamento]).map(m => m.assistance ?? null)})};
}

// PDF library owns the object tree, xref and AcroForm. Only fixed-size placeholders
// are patched after serialization. Never rewrite the PDF after signing.
export async function prepareSignature(bytes) {
  const doc = await PDFDocument.load(bytes, {updateMetadata: false});
  if (doc.isEncrypted || doc.getPageCount() === 0 || doc.catalog.has(PDFName.of('AcroForm'))) throw Error('PDF não aceito para assinatura.');
  const ctx = doc.context, page = doc.getPage(0), capacity = 32768;
  const sig = ctx.register(ctx.obj({Type: 'Sig', Filter: 'Adobe.PPKLite', SubFilter: 'adbe.pkcs7.detached',
    ByteRange: [0, 9999999999, 9999999999, 9999999999], Contents: PDFHexString.of('0'.repeat(capacity * 2))}));
  const widget = ctx.register(ctx.obj({Type: 'Annot', Subtype: 'Widget', FT: 'Sig', Rect: [0, 0, 0, 0],
    T: PDFString.of('OpenPEPLocalSignature'), V: sig, F: 132, P: page.ref}));
  page.node.addAnnot(widget);
  doc.catalog.set(PDFName.of('AcroForm'), ctx.obj({Fields: [widget], SigFlags: 3}));
  let out = await doc.save({useObjectStreams: false});
  const text = Array.from(out, b => String.fromCharCode(b)).join('');
  const marker = '/ByteRange [ 0 9999999999 9999999999 9999999999 ]';
  const at = text.indexOf(marker), contentMarker = '/Contents <' + '0'.repeat(capacity * 2) + '>';
  const content = text.indexOf(contentMarker);
  if (at < 0 || at !== text.lastIndexOf(marker) || content < 0 || content !== text.lastIndexOf(contentMarker)) throw Error('Campo de assinatura ambíguo.');
  const start = content + '/Contents '.length, end = start + capacity * 2 + 2;
  const range = [0, start, end, out.length - end];
  const replacement = `/ByteRange [ ${range.join(' ')} ]`;
  if (replacement.length > marker.length) throw Error('PDF grande demais.');
  out.set(new TextEncoder().encode(replacement.padEnd(marker.length, ' ')), at);
  return {pdf: out, range};
}

const base64 = bytes => { let out = ''; for (let i = 0; i < bytes.length; i += 8192) out += String.fromCharCode(...bytes.subarray(i, i + 8192)); return btoa(out); };
const unbase64 = value => Uint8Array.from(atob(value), c => c.charCodeAt(0));
export async function nativeRender(input, fontData) {
  const fonts = Object.fromEntries(Object.entries(fontData).map(([k,v]) => [k, unbase64(v)]));
  const result = await render(input, fonts);
  return {pdf: base64(result.pdf), term: result.term ? base64(result.term) : null, source: result.source};
}
export async function nativePrepare(pdf) {
  const prepared = await prepareSignature(unbase64(pdf));
  return {pdf: base64(prepared.pdf), range: prepared.range};
}
