"""Coin art for Coinflip: two faces (heads = crown, tails = skull) and the coin's edge.
Drawn at 4x and scaled down for smooth edges. Writes 128x128 RGBA PNGs into
addons/GambleForever/media/coin_heads.png, coin_tails.png, coin_edge.png.
Run once: python scripts/make-coin-art.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent.parent / "addons" / "GambleForever" / "media"
S, N = 512, 128          # drawing size, shipped size
C = S // 2
LIGHT, MID, DARK, DEEP = (255, 226, 120), (214, 160, 40), (150, 104, 18), (92, 60, 8)


def disc_mask(r):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).ellipse((C - r, C - r, C + r, C + r), fill=255)
    return m


def shaded_disc(r, hi, lo):
    """Gold disc lit from the top left."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    px = img.load()
    for y in range(S):
        for x in range(S):
            dx, dy = x - C, y - C
            if dx * dx + dy * dy <= r * r:
                k = min(1, max(0, ((dx + dy) / (2 * r)) + .5))   # 0 top left .. 1 bottom right
                px[x, y] = tuple(int(hi[j] + (lo[j] - hi[j]) * k) for j in range(3)) + (255,)
    return img


def crown(d, fill):
    d.polygon([(150, 330), (150, 200), (205, 260), (256, 165), (307, 260), (362, 200), (362, 330)], fill=fill)
    d.rectangle((150, 338, 362, 368), fill=fill)
    for x, y in ((150, 192), (256, 156), (362, 192)):
        d.ellipse((x - 16, y - 16, x + 16, y + 16), fill=fill)


def skull(d, fill, hole):
    d.ellipse((160, 140, 352, 320), fill=fill)
    d.rounded_rectangle((200, 280, 312, 372), 18, fill=fill)
    d.ellipse((190, 215, 242, 270), fill=hole)
    d.ellipse((270, 215, 322, 270), fill=hole)
    d.polygon([(256, 280), (240, 312), (272, 312)], fill=hole)
    for x in (222, 247, 272):
        d.rectangle((x, 340, x + 14, 372), fill=hole)


def emboss(draw_fn, *colours):
    """Raised emblem: a light copy offset up-left, a dark copy down-right, the emblem on top."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    for (ox, oy), col in (((-5, -5), LIGHT), ((6, 6), DEEP), ((0, 0), colours[0])):
        part = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        draw_fn(ImageDraw.Draw(part), col + (255,), *[c + (255,) for c in colours[1:]])
        layer.alpha_composite(part, (ox, oy))
    return layer


def face(emblem):
    img = shaded_disc(250, LIGHT, DARK)
    d = ImageDraw.Draw(img)
    # reeded rim and a raised inner ring
    d.ellipse((C - 250, C - 250, C + 250, C + 250), outline=DEEP + (255,), width=10)
    d.ellipse((C - 214, C - 214, C + 214, C + 214), outline=LIGHT + (255,), width=6)
    d.ellipse((C - 206, C - 206, C + 206, C + 206), outline=DARK + (255,), width=4)
    inner = shaded_disc(203, MID, DARK)
    img.alpha_composite(inner)
    img.alpha_composite(emblem)
    img.putalpha(disc_mask(250))
    return img.resize((N, N), Image.LANCZOS)


def edge():
    img = Image.new("RGBA", (S, S), DARK + (255,))
    d = ImageDraw.Draw(img)
    for x in range(0, S, 16):
        d.rectangle((x, 0, x + 7, S), fill=MID + (255,))
    img = img.filter(ImageFilter.GaussianBlur(2))
    img.putalpha(disc_mask(250))
    return img.resize((N, N), Image.LANCZOS)


def main():
    face(emboss(crown, MID)).save(OUT / "coin_heads.png")
    face(emboss(skull, MID, DEEP)).save(OUT / "coin_tails.png")
    edge().save(OUT / "coin_edge.png")
    print("wrote coin_heads.png, coin_tails.png, coin_edge.png")


if __name__ == "__main__":
    main()
