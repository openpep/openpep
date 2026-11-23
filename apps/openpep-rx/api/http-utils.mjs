// SPDX-License-Identifier: AGPL-3.0-or-later
import {createHash} from 'node:crypto';
import {ServiceError} from './store.mjs';
export const hash = value => createHash('sha256').update(value).digest('hex');
export async function bounded(response, max = 6000000) {
  let size = 0; const chunks = [];
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > max) throw new ServiceError('response-size');
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}
