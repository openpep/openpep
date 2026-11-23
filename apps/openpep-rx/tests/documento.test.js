import assert from 'node:assert/strict';
import test from 'node:test';
import { Readable } from 'node:stream';

const built = new URL('../.vercel/output/functions/api/documento.func/index.mjs', import.meta.url);
const { default: handler } = await import(built.href);
const doc = '7f389c5a0d6841d8b249679cc1542ef8';

function request(method, body, contentType = 'application/json') {
  const raw = Buffer.from(body);
  const stream = Readable.from([raw]);
  stream.method = method;
  stream.headers = { 'content-type': contentType, 'content-length': String(raw.length) };
  return stream;
}
function response() {
  return { headers: {}, statusCode: 0, setHeader(name, value) { this.headers[name.toLowerCase()] = value; }, end(value = '') { this.body = Buffer.isBuffer(value) ? value : Buffer.from(value); } };
}

test('rejects wrong code without revealing document state', async () => {
  const out = response();
  await handler(request('POST', JSON.stringify({ doc, code: '000000' })), out);
  assert.equal(out.statusCode, 404);
  assert.match(out.body.toString(), /Não foi possível liberar o documento/);
});
test('serves bundled PDF only for the demo code', async () => {
  const out = response();
  await handler(request('POST', JSON.stringify({ doc, code: '724913' })), out);
  assert.equal(out.statusCode, 200);
  assert.equal(out.headers['content-type'], 'application/pdf');
  assert.equal(out.body.subarray(0, 5).toString(), '%PDF-');
});
test('rejects non-POST methods', async () => {
  const out = response();
  await handler(request('GET', ''), out);
  assert.equal(out.statusCode, 404);
});
test('rejects unknown document, query-only code, oversized and non-JSON requests', async () => {
  for (const [body,type] of [
    [JSON.stringify({doc:'0'.repeat(32),code:'724913'}),'application/json'],
    [JSON.stringify({doc}),'application/json'],
    [JSON.stringify({doc,code:'724913',extra:'x'.repeat(600)}),'application/json'],
    [JSON.stringify({doc,code:'724913'}),'text/plain']
  ]) {
    const req=request('POST',body,type); req.url='/api/documento?code=724913';
    const out=response(); await handler(req,out);
    assert.equal(out.statusCode,404); assert.equal(out.headers['cache-control'],'no-store, max-age=0');
    assert.equal(out.body.subarray(0,5).toString() === '%PDF-',false);
  }
});
test('accepts Vercel pre-parsed JSON and returns the exact source PDF', async()=>{
  const {readFile}=await import('node:fs/promises');
  const req=request('POST','');req.body={doc,code:'724913'};
  const out=response();await handler(req,out);
  assert.equal(out.statusCode,200);
  assert.deepEqual(out.body,await readFile(new URL('../fixtures/documento.pdf',import.meta.url)));
});
test('static output excludes private sample PDF, access code and backend; only explicit public fixture is downloadable',async()=>{
  const {readdir,readFile}=await import('node:fs/promises');
  const staticDir=new URL('../.vercel/output/static/',import.meta.url);
  const files=await readdir(staticDir);
  assert(!files.some(f=>f.endsWith('.mjs')));
  assert.deepEqual(files.filter(f => f.endsWith('.pdf')), ['assinatura-local.pdf']);
  assert.deepEqual(await readFile(new URL('assinatura-local.pdf', staticDir)), await readFile(new URL('../fixtures/assinatura-local.pdf', import.meta.url)));
  for(const file of files.filter(f=>/\.(js|html|css)$/.test(f))) {
    const text=await readFile(new URL(file,staticDir),'utf8');
    assert(!/724913|Rafael Martins|7f389c5a0d6841d8b249679cc1542ef8/.test(text));
  }
});
