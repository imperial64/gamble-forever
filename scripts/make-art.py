"""Generates the table art the addon ships: addons/Deathroll/media/table.png.

A top-down oval card table: felt with grain and a soft light pool, a wooden rail with a gold
inlay, transparent outside the rail. 1024x512 so the client can use it as one texture.
Run once: python scripts/make-art.py
"""
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

W, H = 1024, 512
OUT = Path(__file__).resolve().parent.parent / "addons" / "Deathroll" / "media" / "table.png"


def ellipse_mask(inset, blur=0):
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).ellipse((inset, inset, W - inset, H - inset), fill=255)
    return m.filter(ImageFilter.GaussianBlur(blur)) if blur else m


def main():
    random.seed(7)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    # wooden rail: dark brown with grain streaks
    wood = Image.new("RGBA", (W, H), (78, 46, 24, 255))
    d = ImageDraw.Draw(wood)
    for _ in range(900):
        x = random.randint(0, W)
        y = random.randint(0, H)
        c = random.randint(-22, 22)
        d.line((x, y, x + random.randint(20, 90), y + random.randint(-3, 3)),
               fill=(78 + c, 46 + c // 2, 24 + c // 3, 255), width=random.randint(1, 3))
    wood = wood.filter(ImageFilter.GaussianBlur(1.2))
    img.paste(wood, (0, 0), ellipse_mask(6, 1.5))

    # gold inlay ring, then a thin dark gap
    ring = Image.new("RGBA", (W, H), (201, 162, 39, 255))
    img.paste(ring, (0, 0), ellipse_mask(40, .8))
    img.paste(Image.new("RGBA", (W, H), (26, 14, 7, 255)), (0, 0), ellipse_mask(45, .8))

    # felt: green with noise grain and a light pool towards the top centre
    felt = Image.new("RGBA", (W, H), (18, 92, 56, 255))
    px = felt.load()
    for y in range(H):
        for x in range(W):
            dx, dy = (x - W / 2) / (W / 2), (y - H * .42) / (H / 2)
            light = max(0.0, 1 - (dx * dx + dy * dy) ** .5)
            n = random.randint(-9, 9)
            px[x, y] = (int(14 + 22 * light) + n // 2, int(70 + 60 * light) + n, int(42 + 34 * light) + n // 2, 255)
    img.paste(felt, (0, 0), ellipse_mask(50, 1))

    # inner shadow under the rail
    shade = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shade)
    sd.ellipse((50, 50, W - 50, H - 50), outline=(0, 0, 0, 170), width=26)
    shade = shade.filter(ImageFilter.GaussianBlur(14))
    shade.putalpha(Image.composite(shade.getchannel("A"), Image.new("L", (W, H), 0), ellipse_mask(50)))
    img = Image.alpha_composite(img, shade)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(OUT)

    # glow.png: soft white radial glow, tinted in game (seat spotlight, turn and win glows)
    g = Image.new("L", (256, 256), 0)
    gp = g.load()
    for y in range(256):
        for x in range(256):
            r = (((x - 127.5) / 128) ** 2 + ((y - 127.5) / 128) ** 2) ** .5
            gp[x, y] = int(255 * max(0.0, 1 - r) ** 2)
    glow = Image.new("RGBA", (256, 256), (255, 255, 255, 0))
    glow.putalpha(g)
    glow.save(OUT.parent / "glow.png")
    print(OUT.parent / "glow.png")


if __name__ == "__main__":
    main()
