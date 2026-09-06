const { createClient } = require('@supabase/supabase-js');

function bad(res, status, error) {
  res.status(status).json({ error });
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') return bad(res, 405, 'Method not allowed');
  const { action, subscription, userName, userEmail } = req.body || {};
  const endpoint = subscription && subscription.endpoint;
  const p256dh = subscription && subscription.keys && subscription.keys.p256dh;
  const auth = subscription && subscription.keys && subscription.keys.auth;

  if (!['subscribe', 'unsubscribe'].includes(action)) return bad(res, 400, 'Invalid action');
  if (typeof endpoint !== 'string' || endpoint.length < 20 || endpoint.length > 2048 || !/^https:\/\//i.test(endpoint)) return bad(res, 400, 'Invalid subscription endpoint');
  if (action === 'subscribe' && (typeof p256dh !== 'string' || typeof auth !== 'string' || p256dh.length > 512 || auth.length > 256)) return bad(res, 400, 'Invalid subscription keys');
  if (typeof userName === 'string' && userName.length > 160) return bad(res, 400, 'Invalid user name');
  if (typeof userEmail === 'string' && userEmail.length > 320) return bad(res, 400, 'Invalid user email');

  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return bad(res, 500, 'Server subscription storage is not configured');
  const supabase = createClient(url, key);
  const now = new Date().toISOString();

  try {
    if (action === 'subscribe') {
      const { error } = await supabase.from('push_subscriptions').upsert({
        endpoint,
        p256dh,
        auth,
        user_name: typeof userName === 'string' ? userName.slice(0, 160) : 'مستخدم مجهول',
        user_email: typeof userEmail === 'string' ? userEmail.slice(0, 320) : null,
        status: 'active',
        updated_at: now
      }, { onConflict: 'endpoint' });
      if (error) throw error;
    } else {
      const { error } = await supabase.from('push_subscriptions')
        .update({ status: 'unsubscribed', updated_at: now })
        .eq('endpoint', endpoint);
      if (error) throw error;
    }

    const { error: eventError } = await supabase.from('subscription_events').insert({ endpoint, action });
    if (eventError) console.warn('subscription_events is not available yet:', eventError.message);
    res.status(200).json({ success: true });
  } catch (error) {
    console.error('Error logging subscription:', error);
    bad(res, 500, 'Unable to save subscription');
  }
};
