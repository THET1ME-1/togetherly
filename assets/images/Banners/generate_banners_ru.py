from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os
import random

BANNER_W, BANNER_H = 1080, 1920
SCREENSHOTS = r"C:\Users\Alex\Documents\GitHub\love_app\assets\images\Screenshots"
OUTPUT = r"C:\Users\Alex\Documents\GitHub\love_app\assets\images\Banners\ru"
FONTS = r"C:\Windows\Fonts"


def fnt(size, bold=False):
    names = (
        ["segoeuib.ttf", "calibrib.ttf", "arialbd.ttf"] if bold
        else ["segoeui.ttf", "calibri.ttf", "arial.ttf"]
    )
    for n in names:
        try:
            return ImageFont.truetype(os.path.join(FONTS, n), size)
        except Exception:
            pass
    return ImageFont.load_default()


def gradient_bg(w, h, c1, c2):
    img = Image.new("RGB", (w, h))
    pixels = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        r = int(c1[0] + (c2[0] - c1[0]) * t)
        g = int(c1[1] + (c2[1] - c1[1]) * t)
        b = int(c1[2] + (c2[2] - c1[2]) * t)
        for x in range(w):
            pixels[x, y] = (r, g, b)
    return img


def make_phone(sc_path, pw=490, ph=1000):
    border = 20
    cr = 52
    img = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, pw - 1, ph - 1], cr, fill=(36, 36, 40))

    sx1, sy1 = border, border
    sx2, sy2 = pw - border, ph - border
    sw, sh = sx2 - sx1, sy2 - sy1

    try:
        sc = Image.open(sc_path).convert("RGBA").resize((sw, sh), Image.LANCZOS)
        img.paste(sc, (sx1, sy1))
    except Exception as e:
        print(f"    [warn] screenshot load: {e}")
        d.rectangle([sx1, sy1, sx2, sy2], fill=(240, 240, 240))

    # Round-corner mask
    mask = Image.new("L", (pw, ph), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, pw - 1, ph - 1], cr, fill=255)
    img.putalpha(mask)

    # Frame overlay
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, pw - 1, ph - 1], cr, fill=None, outline=(36, 36, 40), width=border)

    # Notch
    nw, nh = 95, 22
    d.rounded_rectangle([(pw - nw) // 2, 5, (pw + nw) // 2, 5 + nh], 11, fill=(36, 36, 40))

    # Home indicator
    hw = 85
    d.rounded_rectangle([(pw - hw) // 2, ph - 11, (pw + hw) // 2, ph - 7], 3, fill=(80, 80, 86))

    return img


def make_shadow(w, h, blur=32, opacity=85):
    pad = blur * 3
    s = Image.new("RGBA", (w + pad, h + pad), (0, 0, 0, 0))
    ImageDraw.Draw(s).rounded_rectangle([blur, blur, w + blur, h + blur], 52, fill=(0, 0, 0, opacity))
    return s.filter(ImageFilter.GaussianBlur(blur))


def soft_blob(size, color, alpha=160, blur=90):
    b = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(b).ellipse([0, 0, size - 1, size - 1], fill=(*color, alpha))
    return b.filter(ImageFilter.GaussianBlur(blur))


def create_banner(cfg):
    img = gradient_bg(BANNER_W, BANNER_H, cfg["bg1"], cfg["bg2"]).convert("RGBA")

    acc = cfg["acc"]
    blob_c = tuple(min(255, c + 35) for c in cfg["bg1"])

    # Decorative blobs
    b1 = soft_blob(950, blob_c, 190, 100)
    img.paste(b1, (-220, -260), b1)

    b2 = soft_blob(650, blob_c, 140, 80)
    img.paste(b2, (BANNER_W - 350, BANNER_H - 580), b2)

    # Scattered accent dots
    random.seed(cfg["id"] * 37 + 11)
    dot_c = tuple(min(255, int(c * 0.08 + 235)) for c in acc)
    for _ in range(22):
        x = random.randint(25, BANNER_W - 25)
        y = random.randint(70, 870)
        r = random.randint(6, 20)
        dot = Image.new("RGBA", (r * 2, r * 2), (0, 0, 0, 0))
        ImageDraw.Draw(dot).ellipse([0, 0, r * 2 - 1, r * 2 - 1], fill=(*dot_c, 80))
        img.paste(dot, (x - r, y - r), dot)

    d = ImageDraw.Draw(img)

    # ── App logo ──────────────────────────────────────────
    lf = fnt(72, bold=True)
    d.text((BANNER_W // 2, 128), "TY", fill=acc, font=lf, anchor="mm")
    bb = d.textbbox((0, 0), "TY", font=lf)
    lw = bb[2] - bb[0]
    light_acc = tuple(min(255, c + 55) for c in acc)
    d.line(
        [(BANNER_W // 2 - lw // 2 - 8, 163), (BANNER_W // 2 + lw // 2 + 8, 163)],
        fill=light_acc, width=3,
    )

    # ── Title ─────────────────────────────────────────────
    tf = fnt(100, bold=True)
    ty = 220
    for line in cfg["title"].split("\n"):
        bb = d.textbbox((0, 0), line, font=tf)
        lh = bb[3] - bb[1]
        d.text((BANNER_W // 2, ty), line, fill=cfg["title_c"], font=tf, anchor="mm")
        ty += lh + 20

    # ── Subtitle ──────────────────────────────────────────
    sf = fnt(43)
    sy = ty + 52
    for line in cfg["sub"].split("\n"):
        bb = d.textbbox((0, 0), line, font=sf)
        lh = bb[3] - bb[1]
        d.text((BANNER_W // 2, sy), line, fill=cfg["sub_c"], font=sf, anchor="mm")
        sy += lh + 12

    # ── Badge ─────────────────────────────────────────────
    bf = fnt(36, bold=True)
    btxt = cfg["badge"]
    bbb = d.textbbox((0, 0), btxt, font=bf)
    bw = bbb[2] - bbb[0] + 72
    bh = bbb[3] - bbb[1] + 32
    bx = BANNER_W // 2 - bw // 2
    by = sy + 62

    badge_img = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))
    ImageDraw.Draw(badge_img).rounded_rectangle([0, 0, bw - 1, bh - 1], bh // 2, fill=(*acc, 255))
    img.paste(badge_img, (bx, by), badge_img)

    d = ImageDraw.Draw(img)
    d.text((BANNER_W // 2, by + bh // 2), btxt, fill=(255, 255, 255), font=bf, anchor="mm")

    # ── Phone ─────────────────────────────────────────────
    ph_w, ph_h = 490, 1000
    ph_x = (BANNER_W - ph_w) // 2
    ph_y = by + bh + 78

    # Shadow
    shd = make_shadow(ph_w, ph_h)
    img.paste(shd, (ph_x - 35, ph_y - 20), shd)

    # Mockup
    sc_path = os.path.join(SCREENSHOTS, cfg["screen"])
    phone = make_phone(sc_path, ph_w, ph_h)
    img.paste(phone, (ph_x, ph_y), phone)

    return img.convert("RGB")


# ── Banner configs (Russian) ──────────────────────────────
CONFIGS = [
    {
        "id": 1, "screen": "01 profile.jpg", "filename": "banner_ru_01_timer.png",
        "title": "Таймер\nлюбви",
        "sub": "Считайте каждый момент —\nсекунды, дни и годы вместе",
        "badge": "Главный экран",
        "bg1": (255, 212, 222), "bg2": (255, 244, 248),
        "acc": (208, 68, 98), "title_c": (52, 12, 28), "sub_c": (108, 48, 68),
    },
    {
        "id": 2, "screen": "02 widjets.jpg", "filename": "banner_ru_02_widgets.png",
        "title": "Виджеты\nна экран",
        "sub": "Дни вместе прямо на\nрабочем столе телефона",
        "badge": "Виджеты",
        "bg1": (216, 205, 248), "bg2": (238, 234, 255),
        "acc": (110, 76, 178), "title_c": (30, 12, 60), "sub_c": (80, 50, 120),
    },
    {
        "id": 3, "screen": "03 connection.jpg", "filename": "banner_ru_03_connection.png",
        "title": "Будьте\nна связи",
        "sub": "Подключитесь к партнёру\nчерез QR-код или ссылку",
        "badge": "Подключение",
        "bg1": (196, 220, 245), "bg2": (226, 242, 255),
        "acc": (58, 112, 170), "title_c": (10, 38, 70), "sub_c": (48, 88, 130),
    },
    {
        "id": 4, "screen": "04 profile.jpg", "filename": "banner_ru_04_profile.png",
        "title": "История\nотношений",
        "sub": "Статистика, воспоминания\nи дни вместе в одном месте",
        "badge": "Профиль",
        "bg1": (255, 220, 205), "bg2": (255, 245, 236),
        "acc": (190, 96, 56), "title_c": (50, 20, 6), "sub_c": (120, 65, 40),
    },
    {
        "id": 5, "screen": "05 calendar.jpg", "filename": "banner_ru_05_mood.png",
        "title": "Календарь\nнастроений",
        "sub": "Следите за эмоциями\nдруг друга каждый день",
        "badge": "Настроения",
        "bg1": (230, 230, 255), "bg2": (246, 246, 255),
        "acc": (86, 86, 190), "title_c": (20, 20, 70), "sub_c": (65, 65, 136),
    },
    {
        "id": 6, "screen": "06 driwing.jpg", "filename": "banner_ru_06_drawing.png",
        "title": "Рисуйте\nвместе",
        "sub": "Общий холст для двоих —\nдарите рисунки и признания",
        "badge": "Рисование",
        "bg1": (255, 225, 235), "bg2": (255, 247, 251),
        "acc": (210, 46, 90), "title_c": (50, 6, 20), "sub_c": (130, 45, 75),
    },
]

os.makedirs(OUTPUT, exist_ok=True)

for cfg in CONFIGS:
    print(f"  Generating {cfg['filename']}...", end=" ", flush=True)
    b = create_banner(cfg)
    out_path = os.path.join(OUTPUT, cfg["filename"])
    b.save(out_path, "PNG")
    print(f"saved ({b.size[0]}x{b.size[1]})")

print(f"\nAll 6 banners saved to: {OUTPUT}")
