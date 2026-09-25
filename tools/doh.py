# Обход отравленного DNS: DoH (Cloudflare/Google/Quad9).
# Uso: python tools/doh.py [resolver] [domain ...]
import json
import sys
import urllib.request

RESOLVERS = {
    'cf': 'https://cloudflare-dns.com/dns-query',
    'google': 'https://dns.google/resolve',
    'quad9': 'https://dns.quad9.net:5053/dns-query',
}
args = sys.argv[1:]
resolver = RESOLVERS.get(args[0], args[0]) if args and (args[0] in RESOLVERS or args[0].startswith('http')) else RESOLVERS['cf']
if args and (args[0] in RESOLVERS or args[0].startswith('http')):
    args = args[1:]
domains = args or [
    'kws2.web.telegram.org', 'kws2-1.web.telegram.org',
    'kws1.web.telegram.org', 'kws4.web.telegram.org',
]
for d in domains:
    url = f'{resolver}?name={d}&type=A'
    req = urllib.request.Request(url, headers={'accept': 'application/dns-json'})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.load(r)
        ips = [a['data'] for a in data.get('Answer', []) if a.get('type') == 1]
        print(f'{d}: {ips or "NO ANSWER (status %s)" % data.get("Status")}')
    except Exception as e:
        print(f'{d}: ERR {type(e).__name__}: {e}')
