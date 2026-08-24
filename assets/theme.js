// Applies saved theme immediately (called inline in <head> before paint),
// and exposes toggleTheme() for the nav button.
(function(){
  const saved = localStorage.getItem('site_theme');
  if(saved === 'light'){
    document.documentElement.setAttribute('data-theme', 'light');
  }
})();

function toggleTheme(){
  const root = document.documentElement;
  const isLight = root.getAttribute('data-theme') === 'light';
  if(isLight){
    root.removeAttribute('data-theme');
    localStorage.setItem('site_theme', 'dark');
  } else {
    root.setAttribute('data-theme', 'light');
    localStorage.setItem('site_theme', 'light');
  }
}
