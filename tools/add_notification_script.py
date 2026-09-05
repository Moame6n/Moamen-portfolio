from pathlib import Path

root = Path('/home/ubuntu/Moamen-portfolio')
for path in root.rglob('*.html'):
    if '.git' in path.parts or 'admin' in path.parts:
        continue
    text = path.read_text()
    tag = '<script src="/assets/notifications.js" defer></script>'
    if tag in text or '</body>' not in text:
        continue
    path.write_text(text.replace('</body>', tag + '\n</body>', 1))
    print(path.relative_to(root))
