import { createHash, timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const DOCUMENT_ID = '7f389c5a0d6841d8b249679cc1542ef8';
const DEMO_CODE = 'DEMO724913';
const MAX_BODY_BYTES = 512;
const PDF_PATH = fileURLToPath(new URL('./documento.pdf', import.meta.url));

function digest(value) { return createHash('sha256').update(value).digest(); }
function authorized(doc, code) {
  if (typeof doc !== 'string' || typeof code !== 'string' || doc.length !== 32 || !/^\d{6}$/.test(code)) return false;
  return timingSafeEqual(digest(doc), digest(DOCUMENT_ID)) && timingSafeEqual(digest(`DEMO${code}`), digest(DEMO_CODE));
}
function headers(response) {
  response.setHeader('Cache-Control', 'no-store, max-age=0');
  response.setHeader('X-Robots-Tag', 'noindex, nofollow, noarchive');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Referrer-Policy', 'no-referrer');
}
function fail(response, status = 404) {
  headers(response);
  response.statusCode = status;
  response.setHeader('Content-Type', 'application/json; charset=utf-8');
  response.end('{"error":"Não foi possível liberar o documento."}');
}
async function parseJson(request) {
  const type = request.headers['content-type'] || '';
  const length = Number(request.headers['content-length'] || 0);
  if (!/^application\/json(?:\s*;|$)/i.test(type) || !Number.isFinite(length) || length > MAX_BODY_BYTES) throw new Error('invalid');
  if (request.body !== undefined) {
    const raw = typeof request.body === 'string' ? request.body : JSON.stringify(request.body);
    if (Buffer.byteLength(raw) > MAX_BODY_BYTES) throw new Error('too-large');
    return JSON.parse(raw);
  }
  let total = 0;
  const chunks = [];
  for await (const chunk of request) {
    total += chunk.length;
    if (total > MAX_BODY_BYTES) throw new Error('too-large');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

export default async function handler(request, response) {
  if (request.method !== 'POST') return fail(response, 404);
  let body;
  try { body = await parseJson(request); } catch { return fail(response); }
  if (!authorized(body?.doc, body?.code)) return fail(response);
  try {
    const pdf = await readFile(PDF_PATH);
    headers(response);
    response.statusCode = 200;
    response.setHeader('Content-Type', 'application/pdf');
    response.setHeader('Content-Disposition', 'inline; filename="documento-medico-amostra.pdf"');
    response.setHeader('Content-Length', pdf.length);
    response.end(pdf);
  } catch { fail(response); }
}
