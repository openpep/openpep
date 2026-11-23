// Phone field with the country flag and dial code (intl-tel-input, MIT), bundled into /telefone.js by build.mjs.
// Brazil comes first. Numbers leave in E.164 (+5511912345678), the ITU standard for international numbers, and are
// shown in each country's own format: for Brazil (11) 91234-5678. Validation uses libphonenumber's metadata
// (/vendor/intl-tel-input/utils.js), loaded on demand.
import intlTelInput from 'intl-tel-input';
import pt from 'intl-tel-input/locale/pt';

// Brazil in the national pattern while typing: (11) 91234-5678, or (11) 2151-1234 for landlines. The library keeps
// the international layout next to a separate dial code, so the Brazilian mask is applied on top of it.
const brazilMask = d => d.length <= 2 ? (d ? `(${d}` : '') : d.length <= 6 ? `(${d.slice(0, 2)}) ${d.slice(2)}`
  : d.length <= 10 ? `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}` : `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7, 11)}`;
const ORDER = ['br', 'pt', 'us', 'ar', 'uy', 'py', 'cl', 'bo', 'co', 'pe', 'es', 'it', 'fr', 'de', 'gb', 'jp'];

// mobile: only numbers that can have WhatsApp (mobile, or fixed-or-mobile where the plan does not tell them apart).
export function phoneField(input, {mobile = false} = {}) {
  const iti = intlTelInput(input, {
    initialCountry: 'br', countryOrder: ORDER, countryNameLocale: 'pt-BR', uiTranslations: pt,
    separateDialCode: true, strictMode: true, formatAsYouType: true,
    allowedNumberTypes: mobile ? ['MOBILE', 'FIXED_LINE_OR_MOBILE'] : null,
    placeholderNumberType: mobile ? 'MOBILE' : 'FIXED_LINE',
    customPlaceholder: (example, country) => country.iso2 === 'br' ? (mobile ? '(11) 91234-5678' : '(11) 2151-1234') : example,
    loadUtils: () => import('/vendor/intl-tel-input/utils.js'),
  });
  const brazil = () => iti.getSelectedCountry()?.iso2 === 'br';
  const mask = () => { if (!brazil()) return; const v = brazilMask(input.value.replace(/\D/g, '').slice(0, 11)); if (v !== input.value) input.value = v; };
  input.addEventListener('input', mask); input.addEventListener('countrychange', mask);
  return {
    ready: iti.promise,
    empty: () => !input.value.trim(),
    valid: () => Boolean(iti.isValidNumber()),
    // Digits only, with the country code: what wa.me expects.
    digits: () => iti.getNumber('E164').replace(/\D/g, ''),
    // As printed on the prescription: national format in Brazil, international otherwise.
    printed: () => iti.getNumber(brazil() ? 'NATIONAL' : 'INTERNATIONAL'),
    set: value => { iti.setNumber(value || ''); mask(); },
    clear: () => { iti.setNumber(''); iti.setSelectedCountry('br'); },
    disable: disabled => iti.setDisabled(disabled),
  };
}
