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

// Silent page-view logging for the admin analytics tab. Fails silently if
// Supabase config isn't loaded yet or the request fails — never blocks the page.
(function(){
  function track(){
    try{
      if(window.location.pathname.startsWith('/admin')) return;
      if(typeof SUPABASE_URL === 'undefined' || typeof SUPABASE_ANON_KEY === 'undefined') return;
      fetch(`${SUPABASE_URL}/rest/v1/page_views`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
          'Prefer': 'return=minimal'
        },
        body: JSON.stringify({
          path: window.location.pathname,
          referrer: document.referrer || null,
          user_agent: navigator.userAgent
        })
      }).catch(() => {});
    }catch(e){}
  }
  if(document.readyState === 'complete'){ track(); }
  else { window.addEventListener('load', track); }
})();
