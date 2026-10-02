(() => {
  'use strict';

  const vapidPublicKey = window.PUSH_VAPID_PUBLIC_KEY || '';
  const DISMISS_KEY = 'moamen_notify_prompt_dismissed_v2';
  const DISMISS_DAYS = 7;
  const state = { registration: null, subscription: null, panel: null, busy: false };

  const supported = () => Boolean(
    vapidPublicKey && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window
  );

  function urlBase64ToUint8Array(value) {
    const padding = '='.repeat((4 - (value.length % 4)) % 4);
    const base64 = (value + padding).replace(/-/g, '+').replace(/_/g, '/');
    return Uint8Array.from(atob(base64), char => char.charCodeAt(0));
  }

  function isIOS() {
    return /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream;
  }

  function isStandalone() {
    return window.navigator.standalone === true || window.matchMedia('(display-mode: standalone)').matches;
  }

  function showToast(message, type = 'info') {
    let toast = document.getElementById('notifyToast');
    if (!toast) {
      toast = document.createElement('div');
      toast.id = 'notifyToast';
      toast.className = 'notify-toast';
      document.body.appendChild(toast);
    }
    toast.className = `notify-toast is-visible ${type}`;
    toast.textContent = message;
    clearTimeout(toast._timer);
    toast._timer = setTimeout(() => toast.classList.remove('is-visible'), 4200);
  }

  async function log(action, subscription) {
    const response = await fetch('/api/subscription-log', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action, subscription })
    });
    if (!response.ok) throw new Error('تعذر حفظ حالة الإشعارات');
  }

  function permissionText() {
    if (Notification.permission === 'denied') return 'الإشعارات مرفوضة من المتصفح. افتح إعدادات الموقع واسمح بها ثم حاول مرة أخرى.';
    if (Notification.permission === 'granted') return 'الإشعارات مسموحة، لكن هذا الجهاز غير مسجل حاليًا لاستقبال تحديثات المنصة.';
    return 'فعّلها ليصلك الاختبار الجديد، التحديات، البطولات والتنبيهات المهمة بدون إزعاج زائد.';
  }

  function closePanel() {
    if (!state.panel) return;
    state.panel.classList.remove('is-open');
    setTimeout(() => state.panel?.remove(), 180);
    state.panel = null;
  }

  function openPanel(anchor) {
    closePanel();
    const panel = document.createElement('div');
    panel.className = 'notify-panel';
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-label', 'إعدادات إشعارات المنصة');
    const active = Boolean(state.subscription);
    panel.innerHTML = `
      <div class="notify-panel-head">
        <div><span class="notify-panel-kicker">مركز التنبيهات</span><strong>إشعارات المنصة</strong></div>
        <button type="button" class="notify-panel-close" aria-label="إغلاق">×</button>
      </div>
      <div class="notify-panel-status ${active ? 'active' : ''}"><span class="notify-status-dot"></span><span>${active ? 'الإشعارات مفعّلة على هذا الجهاز' : 'الإشعارات غير مفعّلة'}</span></div>
      <p class="notify-panel-copy">${active ? 'ستصلك التحديثات المهمة مع رابط مباشر للمحتوى، ويمكنك إيقافها في أي وقت.' : permissionText()}</p>
      ${active ? '<button type="button" class="notify-panel-action danger" data-notify-action="disable">إيقاف الإشعارات</button>' : '<button type="button" class="notify-panel-action" data-notify-action="enable">تفعيل الإشعارات</button>'}
      <div class="notify-panel-note">نرسل تنبيهات مفيدة فقط، ولا نشارك بيانات اشتراك جهازك مع أي جهة خارجية.</div>`;
    document.body.appendChild(panel);
    state.panel = panel;
    const rect = anchor.getBoundingClientRect();
    const left = Math.max(12, Math.min(window.innerWidth - 336, rect.left + rect.width - 316));
    panel.style.top = `${Math.min(window.innerHeight - 260, rect.bottom + 10)}px`;
    panel.style.left = `${left}px`;
    requestAnimationFrame(() => panel.classList.add('is-open'));
    panel.querySelector('.notify-panel-close').addEventListener('click', closePanel);
    panel.querySelector('[data-notify-action]')?.addEventListener('click', async e => {
      if (e.currentTarget.dataset.notifyAction === 'enable') await enableNotifications(anchor);
      else await disableNotifications(anchor);
    });
  }

  function updateBellState(subscribed, pending = false) {
    const button = document.getElementById('notifyBellBtn');
    if (!button) return;
    button.classList.toggle('subscribed', subscribed);
    button.classList.toggle('is-pending', pending);
    button.setAttribute('aria-pressed', String(subscribed));
    button.title = subscribed ? 'إشعارات المنصة مفعّلة — إدارة الإعدادات' : 'إدارة إشعارات المنصة';
    button.setAttribute('aria-label', subscribed ? 'إشعارات المنصة مفعّلة' : 'إدارة إشعارات المنصة');
  }

  async function getRegistration() {
    if (!state.registration) state.registration = await navigator.serviceWorker.register('/sw.js');
    return state.registration;
  }

  async function syncState() {
    if (!supported()) return false;
    try {
      const registration = await getRegistration();
      state.subscription = await registration.pushManager.getSubscription();
      updateBellState(Boolean(state.subscription));
      return Boolean(state.subscription);
    } catch (error) {
      console.warn('Notification state unavailable:', error);
      updateBellState(false);
      return false;
    }
  }

  async function enableNotifications(anchor) {
    if (state.busy) return;
    state.busy = true;
    updateBellState(false, true);
    try {
      if (isIOS() && !isStandalone()) {
        showToast('على آيفون: أضف الموقع إلى الشاشة الرئيسية من Safari أولًا.', 'warning');
        return;
      }
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') {
        showToast(permission === 'denied' ? 'الإشعارات مرفوضة من إعدادات المتصفح.' : 'لم يتم تفعيل الإشعارات.', 'warning');
        return;
      }
      const registration = await getRegistration();
      let subscription = await registration.pushManager.getSubscription();
      if (!subscription) subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlBase64ToUint8Array(vapidPublicKey) });
      const json = subscription.toJSON();
      await log('subscribe', json);
      state.subscription = subscription;
      updateBellState(true);
      closePanel();
      showToast('تم تفعيل الإشعارات بنجاح. ستصلك التحديثات المهمة هنا.', 'success');
    } catch (error) {
      console.warn('Notification enable failed:', error);
      showToast('تعذر تفعيل الإشعارات الآن. حاول مرة أخرى.', 'error');
      await syncState();
    } finally {
      state.busy = false;
      updateBellState(Boolean(state.subscription));
    }
  }

  async function disableNotifications(anchor) {
    if (state.busy || !state.subscription) return;
    if (!window.confirm('هل تريد إيقاف إشعارات المنصة على هذا الجهاز؟')) return;
    state.busy = true;
    updateBellState(true, true);
    try {
      await log('unsubscribe', state.subscription.toJSON());
      await state.subscription.unsubscribe();
      state.subscription = null;
      updateBellState(false);
      closePanel();
      showToast('تم إيقاف الإشعارات. يمكنك تفعيلها من الجرس في أي وقت.', 'info');
    } catch (error) {
      console.warn('Notification disable failed:', error);
      showToast('تعذر إيقاف الإشعارات الآن.', 'error');
      await syncState();
    } finally {
      state.busy = false;
      updateBellState(Boolean(state.subscription));
    }
  }

  function mountBell() {
    const button = document.getElementById('notifyBellBtn');
    if (!button) return false;
    button.addEventListener('click', () => openPanel(button));
    return true;
  }

  function mountFallbackPrompt() {
    if (localStorage.getItem(DISMISS_KEY) && Number(localStorage.getItem(DISMISS_KEY)) > Date.now()) return;
    const prompt = document.createElement('aside');
    prompt.className = 'notify-setup-prompt';
    prompt.setAttribute('aria-label', 'تفعيل إشعارات المنصة');
    prompt.innerHTML = `<button type="button" class="notify-setup-close" aria-label="إغلاق">×</button><div class="notify-setup-icon">◔</div><div><strong>خليك على اطلاع</strong><p>فعّل تنبيهات المنصة ليصلك كل جديد.</p></div><button type="button" class="notify-setup-action">تفعيل</button>`;
    document.body.appendChild(prompt);
    prompt.querySelector('.notify-setup-close').addEventListener('click', () => { localStorage.setItem(DISMISS_KEY, String(Date.now() + DISMISS_DAYS * 86400000)); prompt.remove(); });
    prompt.querySelector('.notify-setup-action').addEventListener('click', async () => { await enableNotifications(null); prompt.remove(); });
    setTimeout(() => prompt.classList.add('is-visible'), 900);
  }

  function init() {
    if (!supported()) return;
    const hasBell = mountBell();
    syncState().then(enabled => { if (!hasBell && !enabled) setTimeout(mountFallbackPrompt, 800); });
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') syncState(); });
    document.addEventListener('click', e => { if (state.panel && !state.panel.contains(e.target) && !e.target.closest('#notifyBellBtn')) closePanel(); });
    document.addEventListener('keydown', e => { if (e.key === 'Escape') closePanel(); });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init, { once: true });
  else init();
})();
