"""Render the TapCore logo (a tap point with ripple rings) to every PNG size the project needs.

Run on Windows or any machine with Pillow:  python assets/make_icons.py
Outputs (committed to git, so build.sh does not need Pillow):
  assets/icon-1024.png                 master image
  app/AppIcon60x60@2x.png, @3x.png     TapCore.app home-screen icon
  docs/CydiaIcon.png                   Sileo/Cydia repo icon
  docs/icon-512.png                    package icon shown in Sileo
"""
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024          # master size
SS = 4            # supersampling factor for smooth edges

BG_TOP = (15, 23, 42)       # slate-900
BG_BOTTOM = (8, 13, 24)
CYAN = (34, 211, 238)
INDIGO = (99, 102, 241)
GREEN = (52, 211, 153)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def render():
    n = S * SS
    img = Image.new("RGB", (n, n), BG_BOTTOM)
    d = ImageDraw.Draw(img)
    for y in range(n):
        d.line([(0, y), (n, y)], fill=lerp(BG_TOP, BG_BOTTOM, y / n))

    cx, cy = n * 0.5, n * 0.5

    # soft glow behind the tap point
    glow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    r = n * 0.30
    gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=CYAN + (70,))
    glow = glow.filter(ImageFilter.GaussianBlur(n * 0.06))
    img.paste(glow, (0, 0), glow)

    # ripple rings: outer indigo -> inner cyan, fading outwards
    rings = [(0.40, 0.030, INDIGO, 150), (0.29, 0.036, lerp(INDIGO, CYAN, 0.55), 220), (0.185, 0.042, CYAN, 255)]
    ring_layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring_layer)
    for rr, w, col, a in rings:
        R = n * rr
        rd.ellipse([cx - R, cy - R, cx + R, cy + R], outline=col + (a,), width=int(n * w))
    img.paste(ring_layer, (0, 0), ring_layer)

    # tap point
    R = n * 0.085
    d = ImageDraw.Draw(img)
    d.ellipse([cx - R, cy - R, cx + R, cy + R], fill=GREEN)
    R2 = n * 0.035
    d.ellipse([cx - R2 - n * 0.02, cy - R2 - n * 0.02, cx + R2 - n * 0.02, cy + R2 - n * 0.02],
              fill=(167, 243, 208))

    img = img.resize((S, S), Image.LANCZOS)
    return img


def save(img, rel, size, rounded=False):
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    out = img.resize((size, size), Image.LANCZOS)
    if rounded:
        out = out.convert("RGBA")
        out.putalpha(rounded_mask(size, int(size * 0.225)))
    out.save(path, optimize=True)
    print("wrote", rel, size)


if __name__ == "__main__":
    master = render()
    save(master, "assets/icon-1024.png", 1024)
    # iOS masks app icons itself: keep them square and opaque
    save(master, "app/AppIcon60x60@2x.png", 120)
    save(master, "app/AppIcon60x60@3x.png", 180)
    save(master, "docs/CydiaIcon.png", 180, rounded=True)
    save(master, "docs/icon-512.png", 512, rounded=True)
