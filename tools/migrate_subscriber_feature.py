from pathlib import Path
import subprocess

root = Path('/home/ubuntu/Moamen-portfolio')
admin = root / 'admin/index.html'
parent = subprocess.check_output(['git', 'show', 'd8295d9^:admin/index.html'], cwd=root, text=True)

# Restore the last intact dashboard, then add the new feature without deleting existing panels.
text = parent

text = text.replace(
'''      <button class="dash-tab" id="tabBattleResults" type="button">سجل المباريات</button>\n''',
'''      <button class="dash-tab" id="tabBattleResults" type="button">سجل المباريات</button>\n      <button class="dash-tab" id="tabSubscribers" type="button">📬 إحصائيات المشتركين</button>\n''')

panel = '''\n    <div id="subscribersPanel" style="display:none;">\n      <div class="stats-row">\n        <div class="stat-card"><div class="num" id="subStatTotal">0</div><div class="lbl">المشتركون النشطون</div></div>\n        <div class="stat-card"><div class="num" id="subStatToday">0</div><div class="lbl">اشتركوا اليوم</div></div>\n        <div class="stat-card"><div class="num" id="subStatWeek">0</div><div class="lbl">آخر 7 أيام</div></div>\n        <div class="stat-card"><div class="num" id="subStatUnsubscribed">0</div><div class="lbl">ألغوا الاشتراك</div></div>\n      </div>\n      <div class="builder-card">\n        <h3>نمو الاشتراكات (آخر 14 يوم)</h3>\n        <div id="subscribersDailyChart" class="daily-chart" aria-label="رسم نمو الاشتراكات"></div>\n        <div style="font-size:11px; color:var(--muted); margin-top:8px;">كل عمود = عدد الاشتراكات في اليوم</div>\n      </div>\n      <div class="builder-card">\n        <h3>آخر المشتركين الجدد</h3>\n        <div id="recentSubscribersList"></div>\n      </div>\n    </div>\n'''
text = text.replace('''    <div id="battleResultsPanel" style="display:none;">''', panel + '''\n    <div id="battleResultsPanel" style="display:none;">''')

text = text.replace(
'''  document.getElementById('tabBattleResults').addEventListener('click', () => switchTab('battleresults'));\n''',
'''  document.getElementById('tabBattleResults').addEventListener('click', () => switchTab('battleresults'));\n  document.getElementById('tabSubscribers').addEventListener('click', () => switchTab('subscribers'));\n''')

old = '''  document.getElementById('battleResultsPanel').style.display = tab === 'battleresults' ? 'block' : 'none';\n  if(tab === 'analytics') loadAnalytics();'''
new = '''  document.getElementById('battleResultsPanel').style.display = tab === 'battleresults' ? 'block' : 'none';\n  document.getElementById('subscribersPanel').style.display = tab === 'subscribers' ? 'block' : 'none';\n  if(tab === 'subscribers') loadSubscriberStats();\n  if(tab === 'analytics') loadAnalytics();'''
assert old in text
text = text.replace(old, new)

# Add subscriber styles before the existing closing style tag.
styles = '''\n  .sub-item{padding:12px;border-bottom:1px solid var(--border-soft);display:flex;justify-content:space-between;align-items:center}\n  .sub-item:last-child{border-bottom:none}.sub-item-info{flex:1}.sub-item-name{font-size:13.5px;font-weight:600;color:var(--text)}\n  .sub-item-email{font-size:11.5px;color:var(--text-soft);margin-top:3px;font-family:var(--mono)}.sub-item-date{font-size:11px;color:var(--muted);margin-top:2px}\n  .sub-item-badge{display:inline-block;padding:3px 10px;border-radius:12px;font-size:10.5px;font-weight:700;background:rgba(61,220,151,.12);color:var(--emerald)}\n'''
text = text.replace('</style>', styles + '</style>', 1)

# Add the safe client loader just before the final script close.
loader = r'''
async function loadSubscriberStats(){
  const list = document.getElementById('recentSubscribersList');
  try {
    const res = await fetch('/api/subscription-stats', { headers: { 'x-admin-passphrase': passphrase } });
    if(!res.ok) throw new Error('تعذر تحميل الإحصائيات');
    const stats = await res.json();
    document.getElementById('subStatTotal').textContent = stats.total || 0;
    document.getElementById('subStatToday').textContent = stats.today || 0;
    document.getElementById('subStatWeek').textContent = stats.last7days || 0;
    document.getElementById('subStatUnsubscribed').textContent = stats.unsubscribed || 0;
    const chart = document.getElementById('subscribersDailyChart');
    chart.innerHTML = '';
    const days = stats.dailyStats || [];
    const maxCount = Math.max(...days.map(d => Number(d.count) || 0), 1);
    days.forEach(day => {
      const bar = document.createElement('div');
      bar.className = 'daily-bar';
      bar.style.height = `${((Number(day.count) || 0) / maxCount) * 100}%`;
      bar.title = `${day.date}: ${day.count} اشتراك`;
      chart.appendChild(bar);
    });
    if(!stats.recent || !stats.recent.length){ list.innerHTML = '<div class="empty-state">لا توجد اشتراكات مسجلة بعد</div>'; return; }
    list.innerHTML = stats.recent.map(sub => `<div class="sub-item"><div class="sub-item-info"><div class="sub-item-name">${escapeHtml(sub.user_name || 'مستخدم مجهول')}</div>${sub.user_email ? `<div class="sub-item-email">${escapeHtml(sub.user_email)}</div>` : ''}<div class="sub-item-date">${new Date(sub.created_at).toLocaleString('ar-EG')}</div></div><span class="sub-item-badge">✓ نشط</span></div>`).join('');
  } catch(err) {
    console.error(err);
    list.innerHTML = '<div class="empty-state">تعذر تحميل الإحصائيات حاليًا</div>';
  }
}
'''
text = text.replace('\n</script>\n\n</body>', loader + '\n</script>\n\n</body>')

admin.write_text(text)

# Restore the existing public page while adding a non-invasive notification entry point.
index = root / 'index.html'
index_text = index.read_text()
if '/assets/notifications.js' not in index_text:
    index_text = index_text.replace('</body>', '<script src="/assets/notifications.js" defer></script>\n</body>')
    index.write_text(index_text)

# Also expose the control on the main exams landing page if present.
exam = root / 'tools-exams.html'
if exam.exists() and '/assets/notifications.js' not in exam.read_text():
    e = exam.read_text().replace('</body>', '<script src="/assets/notifications.js" defer></script>\n</body>')
    exam.write_text(e)

print('restored dashboard and integrated subscriber tab')
