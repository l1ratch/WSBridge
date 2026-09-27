# Иконка-блюпринт: чертёжная сетка + мост. Две версии: светлая (тёмно-синий
# чертёж) и тёмная (чуть светлее сетка на почти-чёрном). SS-суперсэмплинг.
# Uso: python tools/make_icon.py
from PIL import Image, ImageDraw, ImageFilter

SS = 4
SIZE = 1024
W = SIZE * SS

BLUEPRINT = {
    # светлая тема: классический чертёж
    'bg1': (11, 31, 71), 'bg2': (24, 74, 145),
    'grid': (86, 156, 224),
    'main': (255, 255, 255),
    'accent': (74, 222, 128),
    'out': 'App/Assets.xcassets/AppIcon.appiconset/icon-1024.png',
}
DARK = {
    # тёмная тема: приглушённый ночной чертёж
    'bg1': (5, 12, 28), 'bg2': (13, 34, 70),
    'grid': (56, 96, 158),
    'main': (226, 240, 255),
    'accent': (94, 234, 148),
    'out': 'App/Assets.xcassets/AppIcon.appiconset/icon-1024-dark.png',
}


def draw_icon(p):
    # фон: диагональный градиент
    grad = Image.new('RGB', (256, 256))
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510
            c = tuple(int(p['bg1'][i] + (p['bg2'][i] - p['bg1'][i]) * t) for i in range(3))
            grad.putpixel((x, y), c)
    img = grad.resize((W, W), Image.BILINEAR)

    d = ImageDraw.Draw(img)
    step = 128 * SS  # крупные клетки

    # чертёжная сетка
    for i in range(0, W + step, step):
        w = 2 * SS if (i // step) % 4 == 0 else SS
        d.line([(i, 0), (i, W)], fill=p['grid'], width=w)
        d.line([(0, i), (W, i)], fill=p['grid'], width=w)

    # вторичная мелкая сетка
    half = step // 2
    for i in range(0, W + half, half):
        d.line([(i, 0), (i, W)], fill=p['grid'], width=1)
        d.line([(0, i), (W, i)], fill=p['grid'], width=1)

    # центральная точка-перекрестие
    cx, cy = W // 2, W // 2

    # мост: два устоя + пролёт (схематично, «чертёжно»)
    mw = 560 * SS          # ширина моста
    mh = 96 * SS           # высота балки
    top = cy - 40 * SS     # балка чуть выше центра — визуальный центр масс
    x0, x1 = cx - mw // 2, cx + mw // 2
    bcol = p['main']

    # балка пролёта
    d.rectangle([x0, top, x1, top + mh], outline=bcol, width=10 * SS)

    # линия основания (земля) — опоры на ней стоят
    ground = top + mh + 240 * SS
    d.line([(x0 - 100 * SS, ground), (x1 + 100 * SS, ground)], fill=bcol, width=5 * SS)

    # опоры-устои: от балки до земли
    leg_w = 56 * SS
    for lx in (x0, x1):
        d.rectangle([lx - leg_w // 2, top + mh, lx + leg_w // 2, ground],
                    outline=bcol, width=8 * SS)

    # раскосы-ферма: СТРОГО между низом балки и землёй
    truss_bottom = ground - 20 * SS
    n = 7
    seg = (x1 - x0) // n
    for i in range(1, n):
        px = x0 + seg * i
        d.line([(px, top + mh), (px - seg // 2, truss_bottom)], fill=bcol, width=4 * SS)
        d.line([(px, top + mh), (px + seg // 2, truss_bottom)], fill=bcol, width=4 * SS)
        # вертикальная стойка тоже
        d.line([(px, top + mh), (px, truss_bottom)], fill=bcol, width=4 * SS)

    # молния-импульс над мостом: акцент, кончик у центра балки
    bolt = [
        (cx + 34 * SS, cy - 400 * SS), (cx - 58 * SS, cy - 170 * SS),
        (cx - 8 * SS, cy - 170 * SS), (cx - 30 * SS, top - 14 * SS),
        (cx + 82 * SS, cy - 240 * SS), (cx + 24 * SS, cy - 240 * SS),
    ]
    # свечение акцента
    bm = Image.new('L', (W, W), 0)
    ImageDraw.Draw(bm).polygon(bolt, fill=255)
    glow = Image.new('RGB', (W, W), p['accent'])
    img = Image.composite(glow, img, bm.filter(ImageFilter.GaussianBlur(24 * SS)).point(lambda v: v * 35 // 100))
    d = ImageDraw.Draw(img)
    d.polygon(bolt, fill=p['accent'])

    # размерные линии-штрихи: над балкой и под землёй, ярче
    tick = p['grid']
    for y in (top - 60 * SS, ground + 50 * SS):
        d.line([(x0 - 140 * SS, y), (x1 + 140 * SS, y)], fill=tick, width=3 * SS)
        for dx in range(-140 * SS, 140 * SS + 1, 28 * SS):
            d.line([(cx + dx, y - 10 * SS), (cx + dx, y + 10 * SS)], fill=tick, width=3 * SS)

    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(p['out'])
    print('saved', p['out'])


draw_icon(BLUEPRINT)
draw_icon(DARK)

# Contents.json с dark-вариантом
import json
cfg = {
    'images': [
        {'filename': 'icon-1024.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
        {'filename': 'icon-1024-dark.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024',
         'appearances': [{'appearance': 'luminosity', 'value': 'dark'}]},
    ],
    'info': {'author': 'xcode', 'version': 1},
}
with open('App/Assets.xcassets/AppIcon.appiconset/Contents.json', 'w') as f:
    json.dump(cfg, f, indent=2)
print('Contents.json updated')
