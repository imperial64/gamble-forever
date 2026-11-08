"""Rewrite every addon PNG that is not 8-bit RGB/RGBA as 8-bit RGBA.

WoW Forever draws low-bit-depth palette PNGs (Kenney's cards are 2-bit indexed) as solid green.
Run: python scripts/fix-png.py
"""
import pathlib
from PIL import Image

media = pathlib.Path(__file__).resolve().parent.parent / "addons" / "GambleForever" / "media"
for p in sorted(media.rglob("*.png")):
    head = p.read_bytes()[24:26]
    if head[0] == 8 and head[1] in (2, 6):
        continue
    Image.open(p).convert("RGBA").save(p, optimize=True)
    print("converted", p.relative_to(media))
