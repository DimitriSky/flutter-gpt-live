#!/usr/bin/env python3
"""Generates the GPT Live app icon (console style: dark device body,
speaker-grille dot field, signal-orange core, green power LED).

Usage: python3 scripts/make_icon.py   (from the project root; needs Pillow)
Writes macOS AppIcon set, Android legacy + adaptive launcher icons and a
1024 px master PNG at app/assets/icon/app_icon.png.
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent / "app"
SS = 4  # supersampling factor

DECK = (29, 29, 27)
DECK_TOP = (46, 46, 42)
IDLE = (62, 61, 56)
SIGNAL = (238, 90, 31)
GO = (47, 170, 99)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def grille(size, level=0.6, idle=IDLE, lit=SIGNAL, scale=1.0, mono=False):
    """Transparent layer with the dot grille centred in a size x size canvas."""
    s = size * SS
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d, g = ImageDraw.Draw(layer), ImageDraw.Draw(glow)
    c = s / 2
    radius = 0.34 * s * scale
    spacing = radius / 5.2
    dot = spacing * 0.3
    reach = radius * level
    steps = int(radius // spacing)
    for yi in range(-steps, steps + 1):
        for xi in range(-steps, steps + 1):
            x, y = xi * spacing, yi * spacing
            dist = math.hypot(x, y)
            if dist > radius - dot:
                continue
            t = max(0.0, min(1.0, (reach - dist) / spacing + 1))
            r = dot * (1 + 0.28 * t)
            if mono:
                colour = (255, 255, 255, round(90 + 165 * t))
            else:
                colour = lerp(idle, lit, t) + (255,)
            d.ellipse((c + x - r, c + y - r, c + x + r, c + y + r), fill=colour)
            if t > 0 and not mono:
                gr = r * 2.2
                g.ellipse((c + x - gr, c + y - gr, c + x + gr, c + y + gr),
                          fill=lit + (round(70 * t),))
    if not mono:
        ring_w = max(SS, round(0.009 * s * scale))
        rr = radius + spacing * 0.75
        d.ellipse((c - rr, c - rr, c + rr, c + rr), outline=lit + (110,), width=ring_w)
    glow = glow.filter(ImageFilter.GaussianBlur(s * 0.02))
    return Image.alpha_composite(glow, layer)


def led(canvas, cx, cy, r):
    s = canvas.size[0]
    halo = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse((cx - r * 3, cy - r * 3, cx + r * 3, cy + r * 3), fill=GO + (120,))
    halo = halo.filter(ImageFilter.GaussianBlur(r * 1.4))
    canvas.alpha_composite(halo)
    ImageDraw.Draw(canvas).ellipse((cx - r, cy - r, cx + r, cy + r), fill=GO + (255,))


def body(s, radius):
    """Dark rounded body with a soft top-light gradient and a hairline bevel."""
    grad = Image.new("RGBA", (s, s))
    gd = ImageDraw.Draw(grad)
    for y in range(s):
        gd.line((0, y, s, y), fill=lerp(DECK_TOP, DECK, min(1, y / (s * 0.7))) + (255,))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, s - 1, s - 1), radius, fill=255)
    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    bevel = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(bevel).rounded_rectangle(
        (0, 0, s - 1, s - 1), radius, outline=(255, 255, 255, 34), width=max(SS, s // 170))
    return Image.alpha_composite(out, bevel)


def art(size, radius_ratio):
    """Full icon artwork (body + grille + LED) in a size x size square."""
    s = size * SS
    img = body(s, round(s * radius_ratio))
    img.alpha_composite(grille(size))
    led(img, s * 0.83, s * 0.17, s * 0.026)
    return img


def down(img, size):
    return img.resize((size, size), Image.LANCZOS)


def macos(master_px=1024):
    # Apple's macOS grid: 824 px body inside a 1024 canvas, ~185 px corner radius.
    canvas_s = master_px * SS
    inner = round(824 / 1024 * master_px)
    tile = art(inner, 185 / 824)
    canvas = Image.new("RGBA", (canvas_s, canvas_s), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (canvas_s, canvas_s), (0, 0, 0, 0))
    off = (canvas_s - inner * SS) // 2
    ImageDraw.Draw(shadow).rounded_rectangle(
        (off, off + 12 * SS, off + inner * SS, off + inner * SS + 12 * SS),
        185 * SS * inner / 824, fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * SS))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(tile, (off, off))
    master = down(canvas, master_px)
    target = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for px in (16, 32, 64, 128, 256, 512, 1024):
        master.resize((px, px), Image.LANCZOS).save(target / f"app_icon_{px}.png")
    return master


ANDROID = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def android():
    res = ROOT / "android/app/src/main/res"
    legacy = down(art(192, 0.22), 192)  # rounded square, 48 dp at xxxhdpi = 192 px
    for name, k in ANDROID.items():
        legacy.resize((round(48 * k),) * 2, Image.LANCZOS).save(res / f"mipmap-{name}/ic_launcher.png")
        # Adaptive layers are 108 dp; the launcher mask keeps the central ~66 dp.
        px = round(108 * k)
        fg = Image.new("RGBA", (px * SS, px * SS), (0, 0, 0, 0))
        fg.alpha_composite(grille(px, scale=0.72))
        s = px * SS
        led(fg, s * 0.69, s * 0.31, s * 0.018)
        down(fg, px).save(res / f"mipmap-{name}/ic_launcher_foreground.png")
        mono = grille(px, scale=0.72, mono=True)
        down(mono, px).save(res / f"mipmap-{name}/ic_launcher_monochrome.png")
    anydpi = res / "mipmap-anydpi-v26"
    anydpi.mkdir(exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
        '</adaptive-icon>\n')
    (res / "values/ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <color name="ic_launcher_background">#1D1D1B</color>\n</resources>\n')


if __name__ == "__main__":
    master = macos()
    out = ROOT / "assets/icon"
    out.mkdir(parents=True, exist_ok=True)
    down(art(1024, 0.22), 1024).save(out / "app_icon.png")
    android()
    print("icons written")
