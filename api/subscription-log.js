const { createClient } = require('@supabase/supabase-js');

module.exports = async (req, res) => {
  if(req.method !== 'POST'){
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const { action, subscription, userName, userEmail } = req.body || {};
  
  if(!action || !subscription) {
    res.status(400).json({ error: 'action and subscription are required' });
    return;
  }

  if(!['subscribe', 'unsubscribe'].includes(action)) {
    res.status(400).json({ error: 'Invalid action' });
    return;
  }

  const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

  try {
    if(action === 'subscribe') {
      // إدراج أو تحديث الاشتراك
      const { error: upsertError } = await supabase
        .from('push_subscriptions')
        .upsert({
          endpoint: subscription.endpoint,
          p256dh: subscription.keys?.p256dh,
          auth: subscription.keys?.auth,
          user_name: userName || 'مستخدم مجهول',
          user_email: userEmail || null,
          status: 'active',
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString()
        }, {
          onConflict: 'endpoint'
        });

      if(upsertError) throw upsertError;
      res.status(200).json({ success: true, message: 'تم الاشتراك بنجاح' });
    } else {
      // تحديث الحالة إلى unsubscribed
      const { error: updateError } = await supabase
        .from('push_subscriptions')
        .update({ 
          status: 'unsubscribed',
          updated_at: new Date().toISOString()
        })
        .eq('endpoint', subscription.endpoint);

      if(updateError) throw updateError;
      res.status(200).json({ success: true, message: 'تم إلغاء الاشتراك' });
    }
  } catch(err) {
    console.error('Error logging subscription:', err);
    res.status(500).json({ error: err.message });
  }
};
