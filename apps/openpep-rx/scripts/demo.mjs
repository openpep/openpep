// SPDX-License-Identifier: AGPL-3.0-or-later
import { createServer } from 'node:http';
import { loadPrescriptionModule, modulePath } from '../openpep-module.mjs';

const {assets} = await loadPrescriptionModule();
const port = Number(process.env.PORT || 4196);
const server = createServer((req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
  if (!['GET', 'HEAD'].includes(req.method)) {
    res.writeHead(405, {Allow: 'GET, HEAD'}).end();
    return;
  }
  if (req.url === '/' || req.url === modulePath.slice(0, -1)) {
    res.writeHead(302, {Location: modulePath}).end();
    return;
  }
  const asset = assets.get(req.url);
  if (!asset) {
    res.writeHead(404).end();
    return;
  }
  res.writeHead(200, {'Content-Type': asset.type}).end(req.method === 'HEAD' ? undefined : asset.content);
});
server.listen(port, '127.0.0.1', () => {
  console.log(`OpenPEP-Rx · http://127.0.0.1:${server.address().port}${modulePath}`);
});
