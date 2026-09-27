# Генерация иконки через BuyTokens (qwen-image-3.0-pro, chat-completions API).
# Сохраняет в App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
# Uso: python tools/gen_icon_api.py [prompt]
import json
import re
import sys
import urllib.request
from pathlib import Path

CREDS = Path.home() / '.dsh' / '.credentials.yaml'
API = 'https://tokify.sale/v1/chat/completions'
MODEL = 'qwen-image-3.0-pro'

prompt = sys.argv[1] if len(sys.argv) > 1 else (
    'Minimalist iOS app icon, flat vector, blueprint aesthetic. Thin light-blue '
    'drafting grid (graph paper) on a deep navy gradient background. Centered '
    'simple line-art arch bridge: one clean arc resting exactly on a horizontal '
    'deck line, two short vertical supports down to a ground line. Consistent '
    'stroke weight, crisp white lines, no text, no shading, flat design, '
    'generous margins, high contrast'
)

key = re.search(r'BUYTOKENS_API_KEY:\s*(\S+)', CREDS.read_text(encoding='utf-8')).group(1)

body = json.dumps({
    'model': MODEL,
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': 4096,
}).encode()

req = urllib.request.Request(API, data=body, headers={
    'Authorization': f'Bearer {key}',
    'Content-Type': 'application/json',
})
with urllib.request.urlopen(req, timeout=600) as r:
    j = json.load(r)

content = j['choices'][0]['message']['content']
print('model replied:', content[:200])
link = re.search(r'https?://\S+\.(?:png|jpe?g)', content, re.I)
if not link:
    sys.exit('no image link in response')

with urllib.request.urlopen(link.group(0), timeout=120) as r:
    data = r.read()

out = Path('App/Assets.xcassets/AppIcon.appiconset/icon-1024.png')
out.write_bytes(data)
print(f'saved {out} ({len(data)} bytes)')
preview = Path('tools/icon_preview.png')
preview.write_bytes(data)
