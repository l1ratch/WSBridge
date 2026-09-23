import json, urllib.request, os, tempfile

h = {'Accept': 'application/vnd.github+json', 'User-Agent': 'wsbridge'}
d = json.load(urllib.request.urlopen(urllib.request.Request(
    'https://api.github.com/repos/l1ratch/WSBridge/actions/runs/35901100479/jobs',
    headers=h), timeout=30))
job = d['jobs'][0]
url = f"https://api.github.com/repos/l1ratch/WSBridge/actions/jobs/{job['id']}/logs"
log = urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=60).read().decode('utf-8', errors='replace')
path = os.path.join(tempfile.gettempdir(), 'wsbridge_ci_log.txt')
open(path, 'w', encoding='utf-8').write(log)
print('saved:', path, 'len:', len(log))
lines = [l for l in log.splitlines() if 'error:' in l.lower() or 'fatal' in l.lower()]
print('\n'.join(lines[:50]))
