#!/usr/bin/env python3
"""Генерация темовых launcher-иконок Togetherly из логотипа-монограммы «TY».

Для каждой темы: фон = primaryLight темы, буквы «TY» (вырезанные маской из
logo.jpg) перекрашены в тёмный акцент темы. Кладёт square + round PNG во все
mipmap-плотности Android. Запуск из корня проекта: python3 tool/gen_app_icons.py
"""
from PIL import Image, ImageDraw
import os

SRC = "assets/images/logo/logo.jpg"
RES = "android/app/src/main/res"

# Плотности Android (имя каталога -> размер ребра в px).
DENSITIES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# (id, bg primaryLight, letter dark-accent) — все 13 тем app_theme.dart.
THEMES = [
    ("pink",       (254, 234, 241), (62, 31, 62)),
    ("purple",     (230, 230, 250), (53, 47, 68)),
    ("blue",       (234, 242, 250), (77, 112, 153)),
    ("green",      (235, 245, 230), (78, 118, 73)),
    ("midnight",   (229, 233, 242), (27, 31, 58)),
    ("orange",     (253, 243, 238), (207, 126, 94)),
    ("lavender",   (245, 239, 251), (142, 111, 184)),
    ("cherry",     (251, 234, 239), (126, 42, 69)),
    ("mint",       (230, 247, 240), (74, 154, 128)),
    ("sunset",     (255, 235, 226), (255, 111, 97)),
    ("monochrome", (239, 239, 239), (58, 58, 58)),
    ("forest",     (228, 239, 229), (40, 76, 50)),
    ("ocean",      (225, 241, 244), (31, 90, 110)),
]

# Порог маски: L<=120 -> буквы непрозрачны, L>=170 -> фон прозрачен, между -> ramp.
LO, HI = 120, 170


def letter_alpha(src_path):
    """Альфа-маска букв: 255 на тёмных буквах, 0 на светлом фоне, ramp на краях."""
    lum = Image.open(src_path).convert("L")
    return lum.point(lambda v: 255 if v <= LO else (0 if v >= HI else
                     int(255 * (HI - v) / (HI - LO))))


def build_master(alpha, bg, letter):
    """Полноразмерная (1024) иконка темы: буквы letter на фоне bg."""
    size = alpha.size
    base = Image.new("RGBA", size, bg + (255,))
    letters = Image.new("RGBA", size, letter + (255,))
    letters.putalpha(alpha)
    base.alpha_composite(letters)
    return base


def round_crop(img):
    """Круглая версия иконки (для launcher'ов, требующих roundIcon)."""
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).ellipse([0, 0, img.size[0] - 1, img.size[1] - 1], fill=255)
    out = img.copy()
    out.putalpha(mask)
    return out


def main():
    alpha = letter_alpha(SRC)
    for tid, bg, letter in THEMES:
        master = build_master(alpha, bg, letter)
        rmaster = round_crop(master)
        for folder, px in DENSITIES.items():
            d = os.path.join(RES, folder)
            os.makedirs(d, exist_ok=True)
            master.resize((px, px), Image.LANCZOS).save(
                os.path.join(d, f"ic_launcher_{tid}.png"))
            rmaster.resize((px, px), Image.LANCZOS).save(
                os.path.join(d, f"ic_launcher_{tid}_round.png"))
        print(f"  {tid}: ok")
    print(f"Готово: {len(THEMES)} тем x {len(DENSITIES)} плотностей x 2 (square+round)")


if __name__ == "__main__":
    main()
