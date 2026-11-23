// Rebuild the two synthetic PDFs served by the document and signature test routes.
import { readFile, writeFile } from 'node:fs/promises';
import { PDFDocument, StandardFonts, rgb } from 'pdf-lib';

const mark = await readFile(new URL('../assets/openpep-mark.png', import.meta.url));
const ink = rgb(.12, .18, .24), blue = rgb(.15, .36, .63);
for (const [name, title, lines] of [
  ['documento', 'Notificação de Receita B', [
    ['Emitente fictício', 'Profissional Exemplo · CRM fictício 00000/SP'],
    ['Paciente fictício', 'Pessoa Exemplo'],
    ['Número simulado', 'SIM-NRB-00001'],
    ['Prescrição de exemplo', 'Medicamento fictício · apresentação demonstrativa'],
    ['Acesso ao documento', 'Amostra para testar a abertura do PDF com código.'],
  ]],
  ['assinatura-local', 'Documento de teste de assinatura', [
    ['Finalidade', 'Verificar o fluxo de assinatura digital VIDaaS local.'],
    ['Referência de teste', 'OPENPEP-RX-LOCAL-001 · Paciente fictício'],
    ['Autoria', 'O certificado utilizado identifica o titular da assinatura de teste.'],
  ]],
]) {
  const pdf = await PDFDocument.create();
  pdf.setTitle(title);
  pdf.setAuthor('OpenPEP-Rx');
  pdf.setCreator('OpenPEP-Rx');
  const fixtureDate = new Date('2026-01-01T00:00:00Z');
  pdf.setCreationDate(fixtureDate);
  pdf.setModificationDate(fixtureDate);
  const normal = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const page = pdf.addPage([595, 842]);
  page.drawImage(await pdf.embedPng(mark), {x: 44, y: 751, width: 48, height: 48});
  const draw = (text, y, size, font = normal, color = ink, x = 44) =>
    page.drawText(text, {x, y, size, font, color});
  draw('OpenPEP', 770, 19, bold, ink, 104);
  draw('Prescrição', 752, 11, normal, blue, 104);
  page.drawLine({start: {x: 44, y: 726}, end: {x: 551, y: 726}, thickness: 1, color: blue});
  draw(title, 678, 24, bold);
  draw('AMOSTRA FICTÍCIA · SEM VALIDADE CLÍNICA', 649, 11, bold, blue);
  let y = 579;
  for (const [label, value] of lines) {
    draw(label, y, 11, bold);
    draw(value, y - 24, 12);
    y -= 78;
  }
  draw('Uso exclusivo em demonstrações de software.', 52, 10);
  await writeFile(new URL('../fixtures/' + name + '.pdf', import.meta.url), await pdf.save());
}
