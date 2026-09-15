#!/usr/bin/env python3
"""Builds the app icon and the menu bar icon from Artwork/icon-artwork.png. Requires Pillow.

    python3 Artwork/make-icons.py                    # regenerate from Artwork/icon-artwork.png
    python3 Artwork/make-icons.py --import new.png   # replace the artwork (metadata dropped), then regenerate

The artwork is an RGBA PNG. Its alpha channel is the laptop drawing (the screen fading in from the top);
both icons are made from it. Its color channels (a white laptop with a blown-out glow) aren't used.

Outputs, committed to the repo so building the app doesn't need Python:
  Resources/MenuBarIconTemplate.png, @2x   template image = black + the drawing. macOS tints it to match
                                           the menu bar (dark on light, light on dark, and selected).
  Resources/AppIcon.icns                   the same drawing in white, with a soft glow of its own light, on a
                                           black macOS icon shape (824 px body on a 1024 px canvas, rounded
                                           corners, drop shadow). Small sizes get thicker lines so the bezel
                                           stays visible.
  Artwork/app-icon.png                     the 1024 px app icon, for the README.
Every PNG is written from raw pixels, so it carries no metadata (only IHDR, IDAT and IEND chunks).
"""
import argparse
import math
import os
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARTWORK = os.path.join(ROOT, "Artwork", "icon-artwork.png")
RESOURCES = os.path.join(ROOT, "Resources")
LANCZOS = Image.Resampling.LANCZOS
ICON_SIZE = 1024
GLYPH_WIDTH = 600                                           # laptop ≈ 73 % of the 824 px icon body


def save(img, path):
    """Writes the pixels only: no EXIF, ICC profile or text carried over from the source."""
    Image.frombytes(img.mode, img.size, img.tobytes()).save(path, format="PNG", optimize=True)


def laptop_bbox(art):
    return art.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()


def menu_bar_icon(art):
    glyph = art.getchannel("A").crop(laptop_bbox(art))
    for scale, suffix in ((1, ""), (2, "@2x")):
        width, height = 24 * scale, 16 * scale              # 24 × 16 pt: a wide glyph, like the battery's
        inner = round(glyph.height * width / glyph.width)
        # Thicken the thin bezel before shrinking so it stays about 1 pt wide.
        big = glyph.resize((width * 8, inner * 8), LANCZOS).filter(ImageFilter.MaxFilter(5))
        mask = Image.new("L", (width, height), 0)
        mask.paste(big.resize((width, inner), LANCZOS), (0, (height - inner) // 2))
        black = Image.new("L", (width, height), 0)
        save(Image.merge("RGBA", (black, black, black, mask)), os.path.join(RESOURCES, f"MenuBarIconTemplate{suffix}.png"))


def drawing(art, width, thicken=0):
    """The laptop drawing, `width` px wide, its lines widened by `thicken` px on each side."""
    glyph = art.getchannel("A").crop(laptop_bbox(art))
    glyph = glyph.resize((width, round(glyph.height * width / glyph.width)), LANCZOS)
    for _ in range(thicken):
        glyph = glyph.filter(ImageFilter.MaxFilter(3))
    return glyph


def bezel_width(glyph):
    """Width of the left bezel, measured a quarter of the way down (where the screen is still dark)."""
    row = [glyph.getpixel((x, glyph.height // 4)) for x in range(glyph.width)]
    start = next(i for i, v in enumerate(row) if v > 128)
    return next(i for i in range(start, len(row)) if row[i] <= 128) - start


def rounded_mask(size, box, radius, supersample=4):
    big = Image.new("L", (size * supersample, size * supersample), 0)
    ImageDraw.Draw(big).rounded_rectangle([v * supersample for v in box], radius=radius * supersample, fill=255)
    return big.resize((size, size), LANCZOS)


def app_icon_master(art, thicken=0):
    size, inset, radius = ICON_SIZE, 100, 185               # macOS icon grid: 824 × 824 body, ~185 px corners
    body = rounded_mask(size, (inset, inset, size - inset, size - inset), radius)

    # Face: near-black, a touch lighter at the top.
    shade = Image.linear_gradient("L").resize((size, size)).point(lambda v: 22 - v * 18 // 255)
    face = Image.merge("RGB", (shade, shade, shade))
    # The laptop in white — the menu bar icon's drawing — with a soft halo from its own light.
    glyph = drawing(art, GLYPH_WIDTH, thicken)
    light = Image.new("L", (size, size), 0)
    light.paste(glyph, ((size - glyph.width) // 2, (size - glyph.height) // 2))
    halo = light.filter(ImageFilter.GaussianBlur(30)).point(lambda v: v * 60 // 255)
    face = Image.composite(Image.new("RGB", (size, size), (255, 255, 255)), face, ImageChops.lighter(light, halo))
    # Faint light edge, so the dark icon keeps its outline on a dark desktop.
    edge = ImageChops.subtract(body, body.filter(ImageFilter.MinFilter(5))).point(lambda v: v * 40 // 255)
    face = Image.composite(Image.new("RGB", (size, size), (255, 255, 255)), face, edge)

    shadow = Image.new("L", (size, size), 0)
    shadow.paste(body, (0, 12))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14)).point(lambda v: v * 90 // 255)
    icon = Image.merge("RGBA", (Image.new("L", (size, size), 0),) * 3 + (shadow,))
    face = face.convert("RGBA")
    face.putalpha(body)
    icon.alpha_composite(face)
    return icon


def app_icon(art):
    bezel = bezel_width(drawing(art, GLYPH_WIDTH))          # at 1024 px
    masters = {}

    def master(pixels):
        # Keep the bezel ≈ 0.9 px wide once shrunk to `pixels`: thicker lines at small sizes only.
        thicken = max(0, math.ceil((0.9 * ICON_SIZE / pixels - bezel) / 2))
        if thicken not in masters:
            masters[thicken] = app_icon_master(art, thicken)
        return masters[thicken]

    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
                save(master(pixels).resize((pixels, pixels), LANCZOS), os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(RESOURCES, "AppIcon.icns")], check=True)
    save(master(ICON_SIZE), os.path.join(ROOT, "Artwork", "app-icon.png"))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--import", dest="source", help="new artwork PNG to import (its metadata is dropped)")
    args = parser.parse_args()
    if args.source:
        save(Image.open(args.source).convert("RGBA"), ARTWORK)
        print(f"Imported {args.source} → Artwork/icon-artwork.png")
    art = Image.open(ARTWORK).convert("RGBA")
    os.makedirs(RESOURCES, exist_ok=True)
    menu_bar_icon(art)
    app_icon(art)
    print("Wrote Resources/MenuBarIconTemplate.png, Resources/MenuBarIconTemplate@2x.png, Resources/AppIcon.icns, Artwork/app-icon.png")


if __name__ == "__main__":
    main()
