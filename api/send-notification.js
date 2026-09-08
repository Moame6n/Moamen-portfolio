const webpush = require('web-push');
const { createClient } = require('@supabase/supabase-js');

module.exports = async (req, res) => {
  if(req.method !== 'POST'){
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const secret = req.headers['x-notify-secret'];
  let authorized = Boolean(secret && secret === process.env.NOTIFY_SECRET);
  if(!authorized){
    const authorization = req.headers.authorization || '';
    const token = authorization.startsWith('Bearer ') ? authorization.slice(7).trim() : '';
    if(token){
      const authClient = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);
      const { data: userData, error: userError } = await authClient.auth.getUser(token);
      if(!userError && userData.user){
        const { data: adminRow, error: adminError } = await authClient
          .from('private_admin_users').select('user_id').eq('user_id', userData.user.id).maybeSingle();
        authorized = !adminError && Boolean(adminRow);
      }
    }
  }
  if(!authorized) return res.status(401).json({ error: 'Unauthorized' });

  const { title, body, url, tag } = req.body || {};
  if(typeof title !== 'string' || typeof body !== 'string' || title.length < 1 || title.length > 120 || body.length < 1 || body.length > 500){
    res.status(400).json({ error: 'title and body are required' });
    return;
  }
  if(url !== undefined && (typeof url !== 'string' || !/^\/(?!\/)/.test(url) || url.length > 500)) {
    res.status(400).json({ error: 'Invalid notification URL' });
    return;
  }
  if(tag !== undefined && (typeof tag !== 'string' || !/^[a-z0-9-]{1,80}$/i.test(tag))) {
    res.status(400).json({ error: 'Invalid notification tag' });
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

  const payload = JSON.stringify({ title, body, url: url || '/tools-exams.html', tag: tag || 'moamen-site-update' });
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
