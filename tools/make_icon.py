# Иконка: чертёжная сетка + максимально простой знак — мост.
# Суть WSBridge = мост. Две опоры + пролёт дугой. Всё.
# Светлая (светлый фон) и тёмная (тёмный) версии. SS-суперсэмплинг.
# Uso: python tools/make_icon.py
from PIL import Image, ImageDraw, ImageFilter

import json

SS = 4
SIZE = 1024
W = SIZE * SS

LIGHT = {
    'bg1': (232, 240, 250), 'bg2': (196, 214, 236),   # светлая: голубой чертёж
    'grid': (150, 175, 205),
    'ink': (28, 58, 110),                              # чертёжные чернила
    'out': 'App/Assets.xcassets/AppIcon.appiconset/icon-1024.png',
}
DARK = {
    'bg1': (10, 20, 42), 'bg2': (16, 32, 64),
    'grid': (58, 92, 150),
    'ink': (225, 238, 255),                            # белый на тёмном
    'out': 'App/Assets.xcassets/AppIcon.appiconset/icon-1024-dark.png',
}


def draw_icon(p):
    grad = Image.new('RGB', (256, 256))
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510
            c = tuple(int(p['bg1'][i] + (p['bg2'][i] - p['bg1'][i]) * t) for i in range(3))
            grad.putpixel((x, y), c)
    img = grad.resize((W, W), Image.BILINEAR)

    d = ImageDraw.Draw(img)
    step = 128 * SS
    for i in range(0, W + step, step):
        w = 2 * SS if (i // step) % 4 == 0 else SS
        d.line([(i, 0), (i, W)], fill=p['grid'], width=w)
        d.line([(0, i), (W, i)], fill=p['grid'], width=w)

    # ЗНАК: арочный мост. Дуга опирается точно на полотно (центр эллипса = полотно).
    cx = W // 2
    span = 520 * SS          # полупролёт
    rise = 300 * SS          # высота арки над полотном
    deck = (W // 2) + 140 * SS   # полотно чуть ниже центра
    spring = deck + 170 * SS     # земля

    ink = p['ink']
    lw = 16 * SS

    # дуга: полуэллипс от (cx-span, deck) до (cx+span, deck), макушка на deck-rise
    d.arc([cx - span, deck - 2 * rise, cx + span, deck],
          start=180, end=360, fill=ink, width=lw)

    # полотно — соединяет пятки дуги
    d.line([(cx - span, deck), (cx + span, deck)], fill=ink, width=lw)

    # опоры: вниз от пяток до земли
    for x in (cx - span, cx + span):
        d.line([(x, deck), (x, spring)], fill=ink, width=lw)
    # земля
    d.line([(cx - span - 100 * SS, spring), (cx + span + 100 * SS, spring)], fill=ink, width=lw)

    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(p['out'])
    print('saved', p['out'])


draw_icon(LIGHT)
draw_icon(DARK)

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
