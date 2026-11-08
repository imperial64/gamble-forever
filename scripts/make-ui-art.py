"""Generates the lobby and button art in the mockup's style (dark wood, gold trim, parchment,
red and gold buttons). Writes into addons/GambleForever/media/ui/.
Run once: python scripts/make-ui-art.py
"""
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent.parent / "addons" / "GambleForever" / "media" / "ui"
GOLD, GOLD_DK, INK = (201, 162, 39), (138, 106, 18), (14, 8, 4)


def rounded_mask(w, h, r, inset=0):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle((inset, inset, w - 1 - inset, h - 1 - inset), r, fill=255)
    return m


def vgradient(w, h, stops):
    """stops: list of (position 0..1, rgb)"""
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        p = y / max(1, h - 1)
        for i in range(len(stops) - 1):
            (p0, c0), (p1, c1) = stops[i], stops[i + 1]
            if p0 <= p <= p1:
                k = (p - p0) / max(1e-6, p1 - p0)
                c = tuple(int(c0[j] + (c1[j] - c0[j]) * k) for j in range(3))
                break
        for x in range(w):
            px[x, y] = c + (255,)
    return img


def wood(w, h, base=(58, 34, 17), seed=3):
    random.seed(seed)
    img = Image.new("RGBA", (w, h), base + (255,))
    d = ImageDraw.Draw(img)
    for _ in range(w * h // 700):
        x, y, c = random.randint(0, w), random.randint(0, h), random.randint(-16, 16)
        d.line((x, y, x + random.randint(30, 140), y + random.randint(-2, 2)),
               fill=(base[0] + c, base[1] + c // 2, base[2] + c // 3, 255), width=random.randint(1, 2))
    return img.filter(ImageFilter.GaussianBlur(.8))


def framed(img, r, lines):
    """Rounded shape with stacked border lines: lines = [(inset, width, rgb)]"""
    w, h = img.size
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out.paste(img, (0, 0), rounded_mask(w, h, r))
    d = ImageDraw.Draw(out)
    for inset, width, rgb in lines:
        d.rounded_rectangle((inset, inset, w - 1 - inset, h - 1 - inset), max(2, r - inset), outline=rgb + (255,), width=width)
    return out


def button(name, stops, w=256, h=64):
    body = vgradient(w, h, stops)
    hl = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(hl).rounded_rectangle((6, 5, w - 7, h // 2), 8, fill=(255, 255, 255, 38))
    body = Image.alpha_composite(body, hl)
    framed(body, 12, [(0, 2, INK), (2, 3, GOLD), (5, 1, GOLD_DK)]).save(OUT / f"{name}.png")


def parchment(w=512, h=512):
    random.seed(11)
    img = Image.new("RGBA", (w, h), (233, 217, 172, 255))
    px = img.load()
    for y in range(h):
        for x in range(w):
            dx, dy = (x - w / 2) / (w / 2), (y - h / 2) / (h / 2)
            edge = max(abs(dx), abs(dy)) ** 7   # darkens only near the edges, follows the rectangle
            n = random.randint(-7, 7)
            px[x, y] = (int(236 - 52 * edge) + n, int(220 - 62 * edge) + n, int(176 - 78 * edge) + n // 2, 255)
    blot = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    bd = ImageDraw.Draw(blot)
    for _ in range(40):
        x, y, r = random.randint(0, w), random.randint(0, h), random.randint(10, 60)
        bd.ellipse((x - r, y - r, x + r, y + r), fill=(120, 80, 30, random.randint(6, 16)))
    img = Image.alpha_composite(img, blot.filter(ImageFilter.GaussianBlur(14)))
    return framed(img, 10, [(0, 3, (60, 36, 12)), (5, 1, (150, 110, 50))])


def main():
    OUT.mkdir(parents=True, exist_ok=True)

    # lobby frame: 1024x640 matches the 768x480 lobby exactly, so the trim does not stretch
    f = framed(wood(1024, 640), 22, [(0, 4, INK), (4, 4, GOLD), (8, 2, GOLD_DK), (14, 2, (90, 66, 20))])
    d = ImageDraw.Draw(f)
    for cx, cy in ((26, 26), (997, 26), (26, 613), (997, 613)):
        d.polygon([(cx, cy - 9), (cx + 9, cy), (cx, cy + 9), (cx - 9, cy)], fill=GOLD + (255,), outline=INK + (255,))
    f.save(OUT / "frame.png")

    parchment().save(OUT / "parch.png")

    button("btn_red", [(0, (214, 52, 38)), (.55, (128, 18, 12)), (1, (70, 8, 5))])
    button("btn_gold", [(0, (240, 196, 80)), (.55, (166, 116, 12)), (1, (96, 64, 4))])
    button("btn_dark", [(0, (92, 60, 32)), (.55, (52, 32, 16)), (1, (28, 16, 8))])

    inset = vgradient(256, 64, [(0, (18, 10, 5)), (1, (40, 25, 12))])
    framed(inset, 8, [(0, 2, GOLD_DK), (2, 1, INK)]).save(OUT / "inset.png")

    framed(wood(1024, 96, seed=5), 16, [(0, 3, INK), (3, 3, GOLD), (6, 1, GOLD_DK)]).save(OUT / "bar.png")
    print("wrote", ", ".join(p.name for p in sorted(OUT.glob("*.png"))))


if __name__ == "__main__":
    main()
