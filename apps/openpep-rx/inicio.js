// SPDX-License-Identifier: AGPL-3.0-or-later
const local = document.documentElement.dataset.local === 'true';
const origin = local ? location.origin : 'http://127.0.0.1:4197';
for (const link of document.querySelectorAll('[data-rx-page]')) link.href = new URL(link.dataset.rxPage, origin + '/').href;
