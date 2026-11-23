// SPDX-License-Identifier: AGPL-3.0-or-later
// Delivery details stay local and are never part of the signed PDF.
export function normalizeContact(value = {}) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw Error('Confira os dados de contato.');
  const {phone = '', email = ''} = value;
  if (typeof phone !== 'string' || typeof email !== 'string' || phone.length > 40 || /[^0-9 +().-]/.test(phone)) throw Error('Confira o celular com DDD e código do país.');
  const digits = phone.replace(/\D/g, ''), full = [10,11].includes(digits.length) ? '55' + digits : digits;
  if (phone.trim() && !/^[1-9]\d{9,14}$/.test(full)) throw Error('Confira o celular com DDD e código do país.');
  const address = email.trim();
  if (/[\r\n]/.test(email) || address && (!/^[A-Za-z0-9.!#$%&'*+\/=^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(address) || address.length > 254)) throw Error('Confira o endereço de e-mail.');
  return {phone:full, email:address};
}
