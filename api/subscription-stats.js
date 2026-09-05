const { createClient } = require('@supabase/supabase-js');

module.exports = async (req, res) => {
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });
  const passphrase = req.headers['x-admin-passphrase'];
  const url = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !serviceKey) return res.status(500).json({ error: 'Server statistics storage is not configured' });
  if (typeof passphrase !== 'string' || !passphrase || passphrase.length > 256) return res.status(401).json({ error: 'Unauthorized' });

  const supabase = createClient(url, serviceKey);
  try {
    const { data: authRows, error: authError } = await supabase.rpc('list_exam_slugs', { p_passphrase: passphrase });
    if (authError || !Array.isArray(authRows)) return res.status(401).json({ error: 'Unauthorized' });

    const { data: allSubs, error: allError } = await supabase
      .from('push_subscriptions').select('created_at, status').limit(10000);
    if (allError) throw allError;
    const subs = allSubs || [];
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const sevenDaysAgo = new Date(today); sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);
    const active = s => s.status === 'active';
    const createdOnOrAfter = (s, date) => new Date(s.created_at) >= date;
    const total = subs.filter(active).length;
    const todayCount = subs.filter(s => active(s) && createdOnOrAfter(s, today)).length;
    const last7days = subs.filter(s => active(s) && createdOnOrAfter(s, sevenDaysAgo)).length;
    const unsubscribed = subs.filter(s => s.status === 'unsubscribed').length;

    const { data: recent, error: recentError } = await supabase
      .from('push_subscriptions').select('id, user_name, user_email, created_at, status')
      .eq('status', 'active').order('created_at', { ascending: false }).limit(20);
    if (recentError) throw recentError;

    const daily = {};
    for (let i = 13; i >= 0; i--) {
      const date = new Date(today); date.setDate(date.getDate() - i);
      daily[date.toISOString().slice(0, 10)] = 0;
    }
    subs.forEach(s => {
      if (!active(s)) return;
      const key = new Date(s.created_at).toISOString().slice(0, 10);
      if (Object.prototype.hasOwnProperty.call(daily, key)) daily[key]++;
    });

    res.status(200).json({
      total, today: todayCount, last7days, unsubscribed,
      recent: recent || [],
      dailyStats: Object.entries(daily).map(([date, count]) => ({ date, count }))
    });
  } catch (error) {
    console.error('Error fetching subscription stats:', error);
    res.status(500).json({ error: 'Unable to load subscription statistics' });
  }
};
