#!/usr/bin/env python3
"""Generate Chrome extension icons without any third-party deps.

Draws a rounded red square with white die pips (like the game's dice) and
writes valid RGBA PNGs at 16/32/48/128 px.
"""
import struct
import sys
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / 'extension' / 'icons'

RED = (219, 68, 55, 255)        # board red
RED_DARK = (176, 48, 38, 255)   # subtle edge shading
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)

PIP_LAYOUTS = {
    1: [(0, 0)],
    3: [(-1, -1), (0, 0), (1, 1)],
    5: [(-1, -1), (1, -1), (0, 0), (-1, 1), (1, 1)],
}


def rounded_radius(size: int) -> float:
    return size * 0.22


def inside_rounded(x: float, y: float, size: int, r: float) -> bool:
    """True if (x+0.5, y+0.5) is inside the rounded square."""
    px, py = x + 0.5, y + 0.5
    if r * 2 <= size:
        x0, y0, x1, y1 = r, r, size - r, size - r
    else:  # degenerate to a pill
        x0 = x1 = size / 2
        y0, y1 = r, size - r
    dx = max(x0 - px, 0.0, px - x1)
    dy = max(y0 - py, 0.0, py - y1)
    return dx * dx + dy * dy <= r * r


def draw_pip(pixels, size, cx, cy, radius, color=WHITE):
    for y in range(max(0, int(cy - radius - 1)), min(size, int(cy + radius + 2))):
        for x in range(max(0, int(cx - radius - 1)), min(size, int(cx + radius + 2))):
            px, py = x + 0.5, y + 0.5
            if (px - cx) ** 2 + (py - cy) ** 2 <= radius * radius:
                pixels[y * size + x] = color


def make_icon(size: int) -> bytes:
    pixels = [CLEAR] * (size * size)
    r = rounded_radius(size)
    # base with a soft darker bottom-right edge for depth
    for y in range(size):
        for x in range(size):
            if inside_rounded(x, y, size, r):
                shade = (x + y) / (2 * size)
                t = 0 if shade < 0.62 else (shade - 0.62) / 0.38
                base = RED
                edge = RED_DARK
                pixels[y * size + x] = tuple(
                    int(base[i] + (edge[i] - base[i]) * t) for i in range(3)
                ) + (255,)
    # center 3-pip die face
    face = size * 0.52
    left = (size - face) / 2
    step = face / 2
    prad = size * (0.10 if size >= 32 else 0.12)
    for gx, gy in PIP_LAYOUTS[3]:
        draw_pip(pixels, size, left + (gx + 1) * step, left + (gy + 1) * step, prad)
    return encode_png(size, size, pixels)


def encode_png(width: int, height: int, pixels) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    raw = b''.join(
        b'\x00' + b''.join(struct.pack('4B', *pixels[y * width + x])
                           for x in range(width))
        for y in range(height))
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9))
            + chunk(b'IEND', b''))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 48, 128):
        (OUT / f'icon{size}.png').write_bytes(make_icon(size))
        print(f'wrote {OUT / f"icon{size}.png"}')
    return 0 if True else 1


if __name__ == '__main__':
    sys.exit(main())
