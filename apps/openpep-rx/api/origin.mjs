// Public address of the cockpit (CRX_ORIGIN, default: the current .br domain). It is printed on every prescription
// (link and QR) and registered as a callback with the institutional SSO and the SNCR (client_url): before
// changing it, register the new callbacks there. The browser pages get the same value at build time (build.mjs).
export const DEFAULT_ORIGIN = 'https://rx-hml.openpep.com.br';
export function originFrom(value) {
  if (!value) return DEFAULT_ORIGIN;
  const u = new URL(value);
  if (u.protocol !== 'https:' || u.port || u.username || u.password || u.search || u.hash || !['', '/'].includes(u.pathname)) throw Error('CRX_ORIGIN inválido: use https://host, sem caminho.');
  return u.origin;
}
export const ORIGIN = originFrom(process.env.CRX_ORIGIN);
export const HOST = new URL(ORIGIN).host;
