# Финальный фикс пользовательской иконки:
# 1. Точный bbox контента (TOL=8 — ловит даже светлые элементы)
# 2. Кроп строго по контенту
# 3. Оставшиеся белые пиксели (углы за скруглением) → доминантный тёмный цвет
# 4. iOS применит свой squircle-mask — белых краёв не будет в принципе.
# Uso: python tools/icon_fix.py [in] [out]
from collections import Counter

from PIL import Image
import sys

src = sys.argv[1] if len(sys.argv) > 1 else 'tools/user_icon.png'
dst = sys.argv[2] if len(sys.argv) > 2 else 'App/Assets.xcassets/AppIcon.appiconset/icon-1024.png'

im = Image.open(src).convert('RGB')
w, h = im.size
px = im.load()
WHITE = (255, 255, 255)
TOL = 8

def is_white(c):
    return all(abs(a - b) < TOL for a, b in zip(c, WHITE))

# bbox контента
xs, ys = [], []
for y in range(0, h, 2):
    for x in range(0, w, 2):
        if not is_white(px[x, y]):
            xs.append(x)
            ys.append(y)

l, t, r, b = min(xs), min(ys), max(xs), max(ys)
# квадратный кроп с центрированием
side = max(r - l + 1, b - t + 1)
cx, cy = (l + r) // 2, (t + b) // 2
l = max(0, cx - side // 2)
t = max(0, cy - side // 2)
r = min(w, l + side)
b = min(h, t + side)
print(f'crop: {l},{t} -> {r},{b} ({r-l}x{b-t})')

crop = im.crop((l, t, r, b))
out = crop.resize((1024, 1024), Image.LANCZOS)
opx = out.load()

# Доминантный тёмный цвет (не белый, не светлый) — для закраски углов
counter = Counter()
for y in range(0, 1024, 8):
    for x in range(0, 1024, 8):
        c = opx[x, y]
        if sum(c) < 500:  # тёмные пиксели
            counter[tuple(v // 8 * 8 for v in c)] += 1  # квантуем для группировки
dominant = counter.most_common(1)[0][0] if counter else (11, 31, 71)
print(f'dominant dark: {dominant}')

# Заменяем белый фон, связанный с краями (flood-fill от углов),
# на доминантный тёмный. Белые элементы внутри (самолётик, замок) не трогаем.
from collections import deque

visited = [[False] * 1024 for _ in range(1024)]
queue = deque()

# Стартуем со всех белых пикселей на границе
for x in range(1024):
    for y in (0, 1023):
        if all(v > 240 for v in opx[x, y]):
            queue.append((x, y))
            visited[y][x] = True
for y in range(1024):
    for x in (0, 1023):
        if all(v > 240 for v in opx[x, y]) and not visited[y][x]:
            queue.append((x, y))
            visited[y][x] = True

replaced = 0
while queue:
    x, y = queue.popleft()
    opx[x, y] = dominant
    replaced += 1
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nx, ny = x + dx, y + dy
        if 0 <= nx < 1024 and 0 <= ny < 1024 and not visited[ny][nx]:
            if all(v > 240 for v in opx[nx, ny]):
                visited[ny][nx] = True
                queue.append((nx, ny))

print(f'replaced {replaced} background pixels')

out.save(dst)
out.resize((256, 256)).save('tools/icon_preview.png')
print(f'saved {dst}')
