// SPDX-FileCopyrightText: 2026 Carlos Pedrotti
// SPDX-License-Identifier: Apache-2.0
import {PDFDocument, PDFName, PDFHexString, PDFString} from 'pdf-lib';
import {drawAppearance} from './appearance.mjs';
// PDF library owns the object tree, xref and AcroForm. Only fixed-size placeholders
// are patched after serialization. Never rewrite the PDF after signing.
export async function prepareSignature(bytes, {appearance} = {}) {
  if (bytes.length > 20 * 1024 * 1024 || !Buffer.from(bytes).subarray(0, 5).equals(Buffer.from('%PDF-')) || /\/ByteRange\b/.test(Buffer.from(bytes).toString('latin1'))) throw Error('PDF não aceito para assinatura.');
  const doc = await PDFDocument.load(bytes, {updateMetadata: false});
  if (doc.isEncrypted || doc.getPageCount() === 0 || doc.catalog.has(PDFName.of('AcroForm'))) throw Error('PDF não aceito para assinatura.');
  const ctx = doc.context, page = appearance ? await drawAppearance(doc,appearance) : doc.getPage(0), capacity = 32768;
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
