self.addEventListener('push', event => {
  let data = {};
  try{ data = event.data.json(); }catch(e){ data = { title: 'إشعار جديد', body: event.data ? event.data.text() : '' }; }
  event.waitUntil(
    self.registration.showNotification(data.title || 'مؤمن أحمد', {
      body: data.body || '',
      icon: '/assets/icon-512.png',
      badge: '/assets/favicon-32.png',
      data: { url: data.url || '/tools-exams.html' }
    })
  );
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data.url || '/'));
});
