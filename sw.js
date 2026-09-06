self.addEventListener('push', event => {
  let data = {};
  try{ data = event.data.json(); }catch(e){ data = { title: 'مؤمن أحمد', body: event.data ? event.data.text() : '' }; }
  event.waitUntil(
    self.registration.showNotification(data.title || 'مؤمن أحمد', {
      body: data.body || '',
      icon: '/assets/icon-512.png',
      image: '/assets/icon-512.png',
      badge: '/assets/favicon-32.png',
      dir: 'rtl',
      lang: 'ar',
      tag: data.tag || 'moamen-site-update',
      renotify: true,
      vibrate: [80, 40, 80],
      data: { url: data.url || '/tools-exams.html' }
    })
  );
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data.url || '/'));
});
