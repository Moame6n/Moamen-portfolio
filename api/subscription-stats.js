const { createClient } = require('@supabase/supabase-js');

module.exports = async (req, res) => {
  if(req.method !== 'GET'){
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

  try {
    // إحصائيات عامة
    const { data: allSubs, error: allSubsError } = await supabase
      .from('push_subscriptions')
      .select('created_at, status');

    if(allSubsError) throw allSubsError;

    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const sevenDaysAgo = new Date(today);
    sevenDaysAgo.setDate(sevenDaysAgo.getDate() - 7);

    const totalActive = (allSubs || []).filter(s => s.status === 'active').length;
    const todayCount = (allSubs || []).filter(s => {
      const created = new Date(s.created_at);
      return created >= today && s.status === 'active';
    }).length;
    const last7Days = (allSubs || []).filter(s => {
      const created = new Date(s.created_at);
      return created >= sevenDaysAgo && s.status === 'active';
    }).length;
    const unsubscribed = (allSubs || []).filter(s => s.status === 'unsubscribed').length;

    // آخر المشتركين الجدد
    const { data: recentSubs, error: recentError } = await supabase
      .from('push_subscriptions')
      .select('id, user_name, user_email, created_at, status')
      .eq('status', 'active')
      .order('created_at', { ascending: false })
      .limit(20);

    if(recentError) throw recentError;

    // البيانات اليومية (آخر 14 يوم) 
    const dailyData = {};
    for(let i = 0; i < 14; i++) {
      const date = new Date(today);
      date.setDate(date.getDate() - i);
      const dateStr = date.toISOString().split('T')[0];
      dailyData[dateStr] = 0;
    }

    (allSubs || []).forEach(sub => {
      const created = new Date(sub.created_at);
      const dateStr = created.toISOString().split('T')[0];
      if(dateStr in dailyData && sub.status === 'active') {
        dailyData[dateStr]++;
      }
    });

    const dailyStats = Object.entries(dailyData)
      .reverse()
      .map(([date, count]) => ({ date, count }));

    res.status(200).json({
      total: totalActive,
      today: todayCount,
      last7days: last7Days,
      unsubscribed: unsubscribed,
      recent: recentSubs || [],
      dailyStats: dailyStats
    });
  } catch(err) {
    console.error('Error fetching subscription stats:', err);
    res.status(500).json({ error: err.message });
  }
};
