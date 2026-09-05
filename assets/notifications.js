(() => {
  'use strict';

  // Set this in assets/supabase-config.js after generating VAPID keys.
  const vapidPublicKey = window.PUSH_VAPID_PUBLIC_KEY || '';
  if (!vapidPublicKey || !('serviceWorker' in navigator) || !('PushManager' in window)) return;

  function urlBase64ToUint8Array(value) {
    const padding = '='.repeat((4 - (value.length % 4)) % 4);
    const base64 = (value + padding).replace(/-/g, '+').replace(/_/g, '/');
    return Uint8Array.from(atob(base64), char => char.charCodeAt(0));
  }

  function getButton() {
    let button = document.querySelector('[data-enable-notifications]');
    if (button) return button;
    button = document.createElement('button');
    button.type = 'button';
    button.dataset.enableNotifications = 'true';
    button.textContent = 'تفعيل إشعارات الموقع';
    button.style.cssText = 'position:fixed;bottom:18px;left:18px;z-index:9999;padding:10px 14px;border:1px solid #3ddc97;border-radius:8px;background:#10251e;color:#fff;cursor:pointer;font-family:inherit;';
    document.body.appendChild(button);
    return button;
  }

  async function log(action, subscription) {
    const response = await fetch('/api/subscription-log', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action, subscription })
    });
    if (!response.ok) throw new Error('subscription logging failed');
  }

  async function enable(button) {
    button.disabled = true;
    const original = button.textContent;
    try {
      const permission = await Notification.requestPermission();
      if (permission !== 'granted') throw new Error('permission denied');
      const registration = await navigator.serviceWorker.register('/sw.js');
      let subscription = await registration.pushManager.getSubscription();
      if (!subscription) {
        subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(vapidPublicKey)
        });
      }
      await log('subscribe', subscription.toJSON());
      button.textContent = 'الإشعارات مفعلة';
      button.dataset.enabled = 'true';
    } catch (error) {
      console.warn('Notifications are unavailable:', error);
      button.textContent = original;
      button.disabled = false;
    }
  }

  window.addEventListener('DOMContentLoaded', () => {
    if (document.getElementById('notifyBellBtn')) return;
    const button = getButton();
    button.addEventListener('click', () => enable(button));
  });
})();
