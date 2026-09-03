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

// Shared login-state helper — any page that also loads the supabase-js CDN
// script can call this to find out if the current visitor is logged in, and
// attach their user_id to whatever they're about to save (exam attempt,
// download, tool use, battle result). Returns null for anonymous visitors —
// everything keeps working exactly as before for them.
let _sbClient = null;
function getSbClient(){
  if(!_sbClient && typeof supabase !== 'undefined' && typeof SUPABASE_URL !== 'undefined'){
    _sbClient = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false, storageKey: 'sb-moamen-auth' }
    });
  }
  return _sbClient;
}
async function getCurrentUserId(){
  try{
    const client = getSbClient();
    if(!client) return null;
    const { data: { session } } = await client.auth.getSession();
    return session ? session.user.id : null;
  }catch(e){ return null; }
}

// Auto-log tool usage for any real tool page (not the reserved _BASE.html
// scaffold) — every current and future tool gets this for free, no per-tool
// code needed.
(function(){
  const path = window.location.pathname;
  if(!path.startsWith('/tools/') || path.endsWith('_BASE.html')) return;

  function logToolUsage(){
    getCurrentUserId().then(uid => {
      const slug = path.split('/').pop().replace('.html', '');
      const title = document.title.split('|')[0].trim();
      fetch(`${SUPABASE_URL}/rest/v1/tool_usage`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
          'Prefer': 'return=minimal'
        },
        body: JSON.stringify({ user_id: uid, tool_slug: slug, tool_title: title })
      }).catch(() => {});
    });
  }
  if(document.readyState === 'complete'){ logToolUsage(); }
  else { window.addEventListener('load', logToolUsage); }
})();

// Fills in the small circular account widget in the header (if present on
// this page) — shows the logged-in user's avatar/initial + a dropdown with
// profile/logout links, or just links straight to /profile.html when logged out.
async function initAccountWidget(){
  const btn = document.getElementById('accountAvatarBtn');
  const dropdown = document.getElementById('accountDropdown');
  if(!btn) return;

  const client = getSbClient();
  if(!client){ btn.onclick = () => window.location.href = '/profile.html'; return; }

  const { data: { session } } = await client.auth.getSession();
  if(!session){
    btn.onclick = () => window.location.href = '/profile.html';
    return;
  }

  const { data: profile } = await client.from('profiles').select('full_name, avatar_url').eq('id', session.user.id).single();
  const name = (profile && profile.full_name) ? profile.full_name : session.user.email;

  const imgEl = document.getElementById('navAvatarImg');
  const initialEl = document.getElementById('navAvatarInitial');
  if(profile && profile.avatar_url){
    imgEl.src = profile.avatar_url;
    imgEl.style.display = 'block';
    initialEl.style.display = 'none';
  } else {
    initialEl.innerHTML = `<span style="font-weight:700; font-size:13px; color:var(--emerald);">${name.charAt(0)}</span>`;
  }

  const nameEl = document.getElementById('accountDropdownName');
  if(nameEl) nameEl.textContent = name;

  btn.onclick = (e) => { e.stopPropagation(); dropdown.classList.toggle('open'); };
  document.addEventListener('click', () => dropdown.classList.remove('open'));

  const logoutBtn = document.getElementById('navLogoutBtn');
  if(logoutBtn){
    logoutBtn.onclick = async () => { await client.auth.signOut(); window.location.reload(); };
  }
}
if(document.readyState === 'complete'){ initAccountWidget(); }
else { window.addEventListener('load', initAccountWidget); }
