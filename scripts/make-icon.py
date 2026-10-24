#!/usr/bin/env python3
"""Generate the app icon PNG (1024x1024) with Pillow when available, else a
pure-stdlib fallback. Output: dist/AppIcon-1024.png. bundle.sh turns it into an
.icns with iconutil on macOS."""
import math
import os
import struct
import sys
import zlib

SIZE = 1024
OUT = sys.argv[1] if len(sys.argv) > 1 else "dist/AppIcon-1024.png"

def write_png(path, size, pixel):
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            r, g, b, a = pixel(x, y)
            row += bytes((r, g, b, a))
        rows.append(bytes(row))
    raw = b"".join(rows)
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)

def rounded_rect_alpha(x, y, size, radius):
    # macOS-style squircle-ish rounded rect occupying the central 82% like Apple's icon grid
    inset = size * 0.09
    x0, y0, x1, y1 = inset, inset, size - inset, size - inset
    if x < x0 or x > x1 or y < y0 or y > y1:
        return 0.0
    cx = min(max(x, x0 + radius), x1 - radius)
    cy = min(max(y, y0 + radius), y1 - radius)
    d = math.hypot(x - cx, y - cy)
    return max(0.0, min(1.0, radius - d + 0.5))

def pixel(x, y):
    a = rounded_rect_alpha(x + 0.5, y + 0.5, SIZE, SIZE * 0.2)
    if a <= 0:
        return (0, 0, 0, 0)
    t = y / SIZE
    # deep indigo to violet gradient
    r = int(28 + (86 - 28) * t)
    g = int(20 + (34 - 20) * t)
    b = int(64 + (160 - 64) * t)
    # upward chevron (the "up" in Upstage) in warm white
    cx, cy = SIZE / 2, SIZE * 0.56
    w = SIZE * 0.26
    th = SIZE * 0.075
    # two strokes from (cx - w, cy + w*0.75) to (cx, cy - w*0.75) and mirrored
    def dist_to_seg(px, py, ax, ay, bx, by):
        vx, vy = bx - ax, by - ay
        wx, wy = px - ax, py - ay
        c1 = vx * wx + vy * wy
        c2 = vx * vx + vy * vy
        tt = max(0.0, min(1.0, c1 / c2))
        return math.hypot(px - (ax + tt * vx), py - (ay + tt * vy))
    d1 = dist_to_seg(x, y, cx - w, cy + w * 0.75, cx, cy - w * 0.75)
    d2 = dist_to_seg(x, y, cx + w, cy + w * 0.75, cx, cy - w * 0.75)
    d = min(d1, d2)
    stroke = max(0.0, min(1.0, th / 2 - d + 0.5))
    # a thin horizontal "stage" bar under the chevron
    bar_y = cy + w * 0.75 + th * 1.3
    bar = 1.0 if (abs(y - bar_y) < th * 0.35 and abs(x - cx) < w * 1.1) else 0.0
    s = max(stroke, bar)
    r = int(r + (250 - r) * s)
    g = int(g + (244 - g) * s)
    b = int(b + (236 - b) * s)
    return (r, g, b, int(255 * a))

try:
    from PIL import Image, ImageDraw  # type: ignore
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    px = img.load()
    for yy in range(SIZE):
        for xx in range(SIZE):
            px[xx, yy] = pixel(xx, yy)
    os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
    img.save(OUT)
except Exception:
    write_png(OUT, SIZE, pixel)
print(OUT)
