#!/usr/bin/env python3
# bmp2raw.py — extract palette + pixels from an 8bpp BMP
# Output format:
#   768 bytes  — palette: 256 × (R, G, B), each component >> 2 (6-bit, 0..63)
#   W × H bytes — pixels: top-to-bottom, left-to-right, one byte per index
#
# Usage: python3 bmp2raw.py   (reads tux-8.bmp, writes tux-8.raw)

from PIL import Image

INPUT  = "tux-8.bmp"
OUTPUT = "tux-8.raw"

img = Image.open(INPUT)
assert img.mode == "P", f"Expected 8bpp palette image, got {img.mode}"

# Palette: Pillow returns a flat list of 768 bytes (R,G,B × 256)
palette = img.getpalette()  # [R0,G0,B0, R1,G1,B1, ...]
palette_6bit = bytes(c >> 2 for c in palette)  # scale to 6-bit for VGA DAC

# Pixels: getdata() yields indices top-to-bottom (Pillow already handles BMP flip)
pixels = bytes(img.getdata())

with open(OUTPUT, "wb") as f:
    f.write(palette_6bit)
    f.write(pixels)

print(f"Written {len(palette_6bit)} + {len(pixels)} = {len(palette_6bit)+len(pixels)} bytes to {OUTPUT}")
print(f"Image size: {img.size[0]}x{img.size[1]}")
