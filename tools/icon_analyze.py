# Анализ пользовательской иконки: где контент, где пустые поля.
# Uso: python tools/icon_analyze.py [path]
from PIL import Image
import sys

p = sys.argv[1] if len(sys.argv) > 1 else 'tools/user_icon.png'
im = Image.open(p).convert('RGB')
w, h = im.size
px = im.load()

# Ищем bounding box «нестандартного» цвета: фон делим на доминирующие цвета по углам.
corners = [px[0, 0], px[w-1, 0], px[0, h-1], px[w-1, h-1]]
print('corners:', corners)

def bg_diff(c, ref):
    return sum(abs(a - b) for a, b in zip(c, ref))

# ref = медиана углов (просто усредняем)
ref = tuple(sum(c[i] for c in corners) // 4 for i in range(3))
print('ref bg:', ref)

TOL = 30
xs, ys = [], []
for y in range(0, h, 4):
    for x in range(0, w, 4):
        if bg_diff(px[x, y], ref) > TOL:
            xs.append(x)
            ys.append(y)
if xs:
    print(f'content bbox: x {min(xs)}..{max(xs)}, y {min(ys)}..{max(ys)}')
    print(f'margins: left={min(xs)} top={min(ys)} right={w-1-max(xs)} bottom={h-1-max(ys)}')
    print(f'content size: {max(xs)-min(xs)+1}x{max(ys)-min(ys)+1} of {w}x{h}')
else:
    print('no content found — однородная картинка')
