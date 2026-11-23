// Classic script in <head>, before first paint: a return from the SSO login (result=sso) or from VIDaaS
// (result=returned) shows the transition card at once instead of flashing the landing page. entrada.js takes over.
(function () {
  var result = new URLSearchParams(location.search).get('result');
  if (result === 'sso' || result === 'returned') document.documentElement.setAttribute('data-transition', result);
  // Loading the prescriptions page should take a second or two: after 15 s the card offers a reload instead of spinning forever.
  setTimeout(function () {
    if (document.documentElement.getAttribute('data-transition') === 'loading') document.documentElement.setAttribute('data-transition-slow', '');
  }, 15000);
})();
