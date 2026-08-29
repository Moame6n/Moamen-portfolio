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
//
// Mirrors how Google Analytics defines these:
// - client_id: a permanent random ID stored in this browser — identifies a "User"
// - session_id: reused while the visitor stays active; a NEW one is generated
//   only after 30 minutes of inactivity — identifies a "Session" (a "visit")
// Neither ID contains any personal info, just a random string.
function getClientId(){
  let id = localStorage.getItem('_ga_client_id');
  if(!id){
    id = 'c_' + crypto.randomUUID();
    localStorage.setItem('_ga_client_id', id);
  }
  return id;
}
function getSessionId(){
  const now = Date.now();
  const lastActivity = parseInt(localStorage.getItem('_ga_last_activity') || '0', 10);
  let sid = localStorage.getItem('_ga_session_id');
  const THIRTY_MIN = 30 * 60 * 1000;
  if(!sid || (now - lastActivity) > THIRTY_MIN){
    sid = 's_' + crypto.randomUUID();
    localStorage.setItem('_ga_session_id', sid);
  }
  localStorage.setItem('_ga_last_activity', String(now));
  return sid;
}

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
          user_agent: navigator.userAgent,
          client_id: getClientId(),
          session_id: getSessionId()
        })
      }).catch(() => {});
    }catch(e){}
  }
  if(document.readyState === 'complete'){ track(); }
  else { window.addEventListener('load', track); }
})();
