const webpush = require('web-push');
const { createClient } = require('@supabase/supabase-js');

module.exports = async (req, res) => {
  if(req.method !== 'POST'){
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const secret = req.headers['x-notify-secret'];
  if(!secret || secret !== process.env.NOTIFY_SECRET){
    res.status(401).json({ error: 'Unauthorized' });
    return;
  }

  const { title, body, url } = req.body || {};
  if(!title || !body){
    res.status(400).json({ error: 'title and body are required' });
    return;
  }

  webpush.setVapidDetails(
    'mailto:moamenahmd85@gmail.com',
    process.env.VAPID_PUBLIC_KEY,
    process.env.VAPID_PRIVATE_KEY
  );

  const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);
  const { data: subs, error } = await supabase.from('push_subscriptions').select('*');

  if(error){
    res.status(500).json({ error: error.message });
    return;
  }

  const payload = JSON.stringify({ title, body, url: url || '/tools-exams.html' });
  let sent = 0, failed = 0, removed = 0;

  await Promise.all((subs || []).map(async (sub) => {
    try{
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
        payload
      );
      sent++;
    }catch(err){
      failed++;
      // subscription is dead (user unsubscribed / uninstalled) — clean it up
      if(err.statusCode === 404 || err.statusCode === 410){
        await supabase.from('push_subscriptions').delete().eq('id', sub.id);
        removed++;
      }
    }
  }));

  res.status(200).json({ sent, failed, removed, total: (subs || []).length });
};
