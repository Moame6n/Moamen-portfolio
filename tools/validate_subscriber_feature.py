from pathlib import Path
import re
import subprocess

root = Path('/home/ubuntu/Moamen-portfolio')
admin = (root / 'admin/index.html').read_text()
checks = {
    'original create panel restored': 'id="createPanel"' in admin and 'newExamTitle' in admin,
    'original analytics panel restored': 'id="analyticsPanel"' in admin and 'loadAnalytics' in admin,
    'subscriber tab present': 'id="tabSubscribers"' in admin,
    'subscriber panel present': 'id="subscribersPanel"' in admin,
    'subscriber loader present': 'function loadSubscriberStats' in admin,
    'subscriber API header present': "x-admin-passphrase" in admin,
    'all legacy tab ids use correct casing': all(x in admin for x in ['tabBattleBank', 'tabBattleResults']),
}
for name, ok in checks.items():
    print(('OK  ' if ok else 'FAIL') + name)
    if not ok:
        raise SystemExit(1)

inline_scripts = re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>', admin, re.S)
for i, script in enumerate(inline_scripts):
    path = root / 'tools' / f'.admin-inline-{i}.js'
    path.write_text(script)
    result = subprocess.run(['node', '--check', str(path)], capture_output=True, text=True)
    path.unlink()
    if result.returncode:
        print(result.stderr)
        raise SystemExit(1)
print(f'OK  checked {len(inline_scripts)} inline dashboard scripts')

for path in (root / 'api').glob('*.js'):
    result = subprocess.run(['node', '--check', str(path)], capture_output=True, text=True)
    if result.returncode:
        print(result.stderr)
        raise SystemExit(1)
print('OK  checked API JavaScript syntax')
