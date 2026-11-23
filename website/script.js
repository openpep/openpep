// SPDX-FileCopyrightText: 2026 Carlos Pedrotti and OpenPEP contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
const tabs = [...document.querySelectorAll('[role="tab"]')];
function selectTab(tab) {
  tabs.forEach(item => {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
  });
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', event => {
    const targets = { ArrowRight: (index + 1) % tabs.length, ArrowLeft: (index + tabs.length - 1) % tabs.length, Home: 0, End: tabs.length - 1 };
    if (!(event.key in targets)) return;
    event.preventDefault();
    const next = tabs[targets[event.key]];
    selectTab(next); next.focus();
  });
});
const menuButton = document.getElementById('menu-toggle');
const menu = document.getElementById('mobile-menu');
function closeMenu() { menu.hidden = true; menuButton.setAttribute('aria-expanded', 'false'); menuButton.setAttribute('aria-label', 'Abrir menu'); }
menuButton.addEventListener('click', () => { const open = menu.hidden; menu.hidden = !open; menuButton.setAttribute('aria-expanded', String(open)); menuButton.setAttribute('aria-label', open ? 'Fechar menu' : 'Abrir menu'); });
menu.querySelectorAll('a').forEach(a => a.addEventListener('click', closeMenu));
document.addEventListener('keydown', e => { if(e.key === 'Escape' && !menu.hidden) { closeMenu(); menuButton.focus(); } });
matchMedia('(min-width: 768px)').addEventListener('change', event => { if(event.matches) closeMenu(); });
// A brief fly-by leaves the page interactive; motion preference always wins.
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const flight = document.getElementById('flight');
let flyby;
async function fly() {
  if (reducedMotion.matches || !flight.animate) return;
  try { await flight.querySelector('img').decode(); } catch { return; }
  if (reducedMotion.matches || window.scrollY > 80) return;
  flight.hidden = false;
  const w = innerWidth, h = Math.min(innerHeight, 900), size = flight.offsetWidth;
  // The image contains a complete wingbeat from the approved film.
  // Keep forward speed steady and follow a shallow, continuous flight arc.
  const path = Array.from({ length: 25 }, (_, index) => {
    const t = index / 24;
    const arc = Math.sin(Math.PI * t);
    const x = -size + (w + size * 2) * t;
    const y = h * (.34 - .14 * arc);
    const roll = -7 * Math.cos(Math.PI * t);
    const scale = .85 + .12 * arc;
    return { transform: `translate(${x}px, ${y}px) rotate(${roll}deg) scale(${scale})`, offset: t };
  });
  flyby = flight.animate(path, { duration: 3000, easing: 'linear', fill: 'both' });
  flyby.finished.then(() => { flight.hidden = true; }).catch(() => { flight.hidden = true; });
}
reducedMotion.addEventListener('change', event => { if(event.matches) { flyby?.cancel(); flight.hidden = true; } });
if(document.readyState === 'complete') fly(); else window.addEventListener('load', fly, {once:true});
