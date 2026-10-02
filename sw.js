const CACHE_NAME = 'moamen-notifications-v2';

self.addEventListener('push', event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; }
  catch (e) { data = { title: 'مؤمن أحمد', body: event.data ? event.data.text() : '' }; }

  const title = data.title || 'مؤمن أحمد';
  const options = {
    body: data.body || 'لديك تحديث جديد من المنصة.',
    icon: data.icon || '/assets/icon-512.png',
    badge: data.badge || '/assets/favicon-32.png',
    image: data.image || undefined,
    dir: 'rtl',
    lang: 'ar',
    tag: data.tag || 'moamen-site-update',
    renotify: true,
    requireInteraction: Boolean(data.requireInteraction),
    vibrate: [80, 40, 80],
    timestamp: Date.now(),
    actions: [{ action: 'open', title: 'فتح التحديث' }],
    data: { url: data.url || '/tools-exams.html' }
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const targetUrl = new URL(event.notification.data?.url || '/', self.location.origin).href;
  event.waitUntil((async () => {
    const windows = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    const sameOrigin = windows.find(client => new URL(client.url).origin === self.location.origin);
    if (sameOrigin) {
      await sameOrigin.focus();
      if ('navigate' in sameOrigin) await sameOrigin.navigate(targetUrl);
    } else {
      await clients.openWindow(targetUrl);
    }
  })());
});

self.addEventListener('notificationclose', () => {});
