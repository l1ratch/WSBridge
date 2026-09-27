# Рисует app-icon 1024x1024: молния на сине-зелёном градиенте, без белых полей.
# Заменяет App/Assets.xcassets/AppIcon.appiconset/icon-1024.png
# Uso: python tools/make_icon.py
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # supersampling: рисуем в 4x, ресайзим вниз — гладкие края

# Диагональный градиент тёмно-синий -> зелёный: строим быстро через
# ресайз маленького градиента.
grad = Image.new('RGB', (256, 256))
c1, c2 = (10, 30, 70), (10, 145, 88)
for y in range(256):
    for x in range(256):
        row = tuple(int(c1[i] + (c2[i] - c1[i]) * (x + y) / 511) for i in range(3))
        grad.putpixel((x, y), row)
img = grad.resize((SIZE * SS, SIZE * SS), Image.BILINEAR)

W = SIZE * SS

# мягкая подсветка сверху-слева
glow = Image.new('L', (W, W), 0)
ImageDraw.Draw(glow).ellipse([-280 * SS, -340 * SS, 720 * SS, 660 * SS], fill=60)
glow = glow.filter(ImageFilter.GaussianBlur(150))
img = Image.composite(Image.new('RGB', (W, W), (200, 255, 230)), img,
                      glow.point(lambda p: p // 3))

# молния ~80% высоты, по центру
bolt = [(582, 96), (330, 560), (476, 560), (418, 928), (694, 430), (532, 430)]
bolt = [(x * SS, y * SS) for x, y in bolt]

bolt_mask = Image.new('L', (W, W), 0)
ImageDraw.Draw(bolt_mask).polygon(bolt, fill=255)

# мягкое зелёное свечение под молнией
blur = bolt_mask.filter(ImageFilter.GaussianBlur(36))
img = Image.composite(Image.new('RGB', (W, W), (130, 255, 180)), img,
                      blur.point(lambda p: p * 45 // 100))

# белая молния
img.paste((255, 255, 255), (0, 0), bolt_mask)

img = img.resize((SIZE, SIZE), Image.LANCZOS)
img.save('App/Assets.xcassets/AppIcon.appiconset/icon-1024.png')
img.resize((256, 256)).save('tools/icon_preview.png')
print('saved icon + preview')
