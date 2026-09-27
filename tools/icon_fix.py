# Чинит пользовательскую иконку: обрезает белые поля, растягивает контент на
# весь холст 1024. Uso: python tools/icon_fix.py [in] [out]
from PIL import Image
import sys

src = sys.argv[1] if len(sys.argv) > 1 else 'tools/user_icon.png'
dst = sys.argv[2] if len(sys.argv) > 2 else 'App/Assets.xcassets/AppIcon.appiconset/icon-1024.png'

im = Image.open(src).convert('RGB')
w, h = im.size
px = im.load()
ref = (255, 255, 255)
TOL = 30

xs, ys = [], []
for y in range(0, h, 4):
    for x in range(0, w, 4):
        if sum(abs(a - b) for a, b in zip(px[x, y], ref)) > TOL:
            xs.append(x)
            ys.append(y)

l, t, r, b = min(xs), min(ys), max(xs), max(ys)
# квадратный кроп с центрированием (iOS любит квадрат)
cw, ch = r - l + 1, b - t + 1
side = max(cw, ch)
# +2.5% запас, чтобы элементы у края (щит) не резались
side = int(side * 1.025)
cx, cy = (l + r) // 2, (t + b) // 2
l = max(0, cx - side // 2)
t = max(0, cy - side // 2)
r = min(w, l + side)
b = min(h, t + side)
print(f'crop: {l},{t} {r}x{b} (side {r-l}x{b-t})')

crop = im.crop((l, t, r, b))
# растягиваем на полный холст — от краёв до краёв
out = crop.resize((1024, 1024), Image.LANCZOS)
out.save(dst)
out.resize((256, 256)).save('tools/icon_preview.png')
print('saved', dst)
