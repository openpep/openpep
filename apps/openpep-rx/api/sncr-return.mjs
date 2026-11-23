import { readFile } from 'node:fs/promises';
import sncr from './sncr.mjs';
import {ORIGIN} from './origin.mjs';
// Keep the established canonical root callback when migrating to the Ed.3 gateway.
// Handle its top-level return in the server before any HTML/assets are rendered.
export default async function handler(req, res) {
  const url = new URL(req.url, ORIGIN);
  if (['session_id', 'error', 'state'].some(key => url.searchParams.has(key))) {
    req.url = `/api/sncr/callback${url.search}`;
    return sncr(req, res);
  }
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  if (req.method !== 'GET' && req.method !== 'HEAD') { res.statusCode = 405; return res.end(); }
  if (req.method === 'HEAD') return res.end();
  return res.end(await readFile(new URL('./home.html', import.meta.url)));
}
