#!/usr/bin/env python3
"""Generate the app icon for every platform from one drawing.

The mark is a tabletop die: a lacquered felt-green field (the table the games
are played on), an ivory face, a gold rim and five ink pips — the palette from
lib/ui/theme.dart, so the icon matches the app it opens.

Everything comes out of one anti-aliased master render per variant, which is
box-filtered down to each required size, so the small sizes stay crisp:

  web/favicon.png                             rounded, transparent corners
  web/icons/Icon-192|512.png                  full bleed (masked by the OS)
  web/icons/Icon-maskable-192|512.png         full bleed, content inside mask
  android/.../mipmap-*/ic_launcher.png        rounded, one file per density
  android/.../mipmap-*/ic_launcher_foreground.png  adaptive-icon foreground
  android/.../mipmap-anydpi-v26/ic_launcher.xml    adaptive-icon wiring
  ios/.../AppIcon.appiconset/*.png            opaque (iOS rejects alpha)
  macos/Runner/Assets.xcassets/.../app_icon_*.png  rounded
  windows/runner/resources/app_icon.ico       16/32/48 DIB + 256 PNG entries

Usage: python3 tools/gen_app_icons.py
"""
import math
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------- palette

FELT = (0x12, 0x35, 0x24)        # AppColors.felt, the table
FELT_GLOW = (0x1B, 0x4A, 0x33)   # AppColors.feltLight, a lamp over it
IVORY = (0xF5, 0xEF, 0xE0)       # AppColors.ivory, the die face
GOLD = (0xD9, 0xA4, 0x41)        # AppColors.gold, the rim
INK = (0x26, 0x22, 0x1A)         # AppColors.ink, the pips

# --------------------------------------------------------------- geometry
# Fractions of the canvas, so one set of numbers covers every size.
CORNER = 0.225     # background corner radius
PLATE = 0.170      # gold rim: outer edge
FACE = 0.205       # ivory face: outer edge
FACE_R = 0.16      # ivory face: corner radius, of its own side
PIP_OFF = 0.115    # centre-to-centre offset of the four corner pips
PIP_R = 0.055      # pip radius

ROUND = 'round'    # rounded corners, transparent outside
BLEED = 'bleed'    # full-bleed opaque square (iOS, maskable, web square)
NONE = 'none'      # no field at all: adaptive-icon foreground layer

SS_Y = 4           # vertical sub-samples per pixel row (x is exact)
MASTER = 1024      # largest master render; smaller sizes are filtered from it

# ------------------------------------------------------------- rasterizer


def _rounded_span(y, x0, y0, x1, y1, r):
    """Horizontal span [a, b] of a rounded rect on scanline `y`, else None."""
    if y < y0 or y > y1:
        return None
    if r <= 0 or min(y - y0, y1 - y) >= r:
        return (x0, x1)
    dy = r - min(y - y0, y1 - y)
    inner = r * r - dy * dy
    if inner <= 0:
        return None
    half = math.sqrt(inner)
    return (x0 + r - half, x1 - r + half)


def _circle_span(y, cx, cy, r):
    dy = y - cy
    if abs(dy) >= r:
        return None
    half = math.sqrt(r * r - dy * dy)
    return (cx - half, cx + half)


def _put(row, i, color, cov):
    """Composite `color` at coverage `cov` (0..1) over pixel `i`, straight alpha."""
    o = 4 * i
    sa = min(max(cov, 0.0), 1.0) * 255.0
    if sa <= 0:
        return
    da = row[o + 3]
    if da == 255:
        if sa >= 255.0:
            row[o], row[o + 1], row[o + 2] = color
        else:
            k = sa / 255.0
            for c in range(3):
                row[o + c] = int(row[o + c] + (color[c] - row[o + c]) * k + 0.5)
        return
    if da == 0:
        row[o], row[o + 1], row[o + 2] = color
        row[o + 3] = int(sa + 0.5)
        return
    out_a = sa + da * (255.0 - sa) / 255.0
    for c in range(3):
        row[o + c] = int(
            (color[c] * sa * 255.0 + row[o + c] * da * (255.0 - sa))
            / (255.0 * out_a) + 0.5)
    row[o + 3] = int(out_a + 0.5)


def _paint_span(row, size, a, b, color, weight=1.0):
    """Fill [a, b] of one row with an opaque colour, exact AA on both edges."""
    lo = max(0, int(math.floor(a)))
    hi = min(size, int(math.ceil(b)))
    if hi <= lo:
        return
    inner_lo = max(lo, int(math.ceil(a)))
    inner_hi = min(hi, int(math.floor(b)) + 1)
    if inner_hi > inner_lo:
        row[4 * inner_lo:4 * inner_hi] = bytes(color + (255,)) * (inner_hi - inner_lo)
    for i in (lo, hi - 1):
        if inner_lo <= i < inner_hi:
            continue
        cov = (min(i + 1, b) - max(i, a)) * weight
        if cov > 0:
            _put(row, i, color, cov)


def _paint_shape_row(row, size, y, y0, y1, r, color, span):
    """Paint one row of a flat shape; only its curves need sub-sampling."""
    if y + 1 <= y0 + r or y >= y1 - r:
        for k in range(SS_Y):
            sp = span(y + (k + 0.5) / SS_Y)
            if sp:
                _paint_span(row, size, sp[0], sp[1], color, 1.0 / SS_Y)
    else:
        sp = span(y + 0.5)
        if sp:
            _paint_span(row, size, sp[0], sp[1], color)


def _felt_at(x, y, size):
    """Table felt with a lamp glow above the centre."""
    dx, dy = (x / size - 0.5) * 1.15, y / size - 0.42
    t = min(max(1.0 - math.sqrt(dx * dx + dy * dy) / 0.75, 0.0), 1.0)
    return tuple(int(FELT[c] + (FELT_GLOW[c] - FELT[c]) * t + 0.5) for c in range(3))


def _paint_field(row, size, y, band):
    """The felt field: full width, or a rounded square when `band` > 0."""
    if band == 0.0 or (y >= band and y + 1 <= size - band):
        row[:] = bytes(b for x in range(size)
                       for b in _felt_at(x + 0.5, y + 0.5, size) + (255,))
        return
    for k in range(SS_Y):  # curved band: sub-sample so the corner stays smooth
        yy = y + (k + 0.5) / SS_Y
        sp = _rounded_span(yy, 0.0, 0.0, size, size, band)
        if sp is None:
            continue
        for i in range(max(0, int(sp[0])), min(size, int(math.ceil(sp[1])))):
            cov = (min(i + 1, sp[1]) - max(i, sp[0])) / SS_Y
            if cov > 0:
                _put(row, i, _felt_at(i + 0.5, yy, size), cov)


def render(size, background=ROUND, content_scale=1.0):
    """One master render: the felt field (unless NONE) plus the die mark."""
    buf = bytearray(4 * size * size)
    stride = 4 * size
    cs = content_scale

    def n(v):  # canvas fraction -> pixels, scaled about the centre
        return (0.5 + (v - 0.5) * cs) * size

    px0, px1 = n(PLATE), n(1 - PLATE)
    fx0, fx1 = n(FACE), n(1 - FACE)
    plate_r = FACE_R * (px1 - px0)
    face_r = FACE_R * (fx1 - fx0)
    pip_r = PIP_R * size * cs
    pips = [(n(0.5 + dx), n(0.5 + dy)) for dx, dy in
            ((-PIP_OFF, -PIP_OFF), (PIP_OFF, -PIP_OFF), (0, 0),
             (-PIP_OFF, PIP_OFF), (PIP_OFF, PIP_OFF))]

    band = CORNER * size if background == ROUND else 0.0
    for y in range(size):
        base = y * stride
        row = buf[base:base + stride]
        if background != NONE:
            _paint_field(row, size, y, band)
        _paint_shape_row(row, size, y, px0, px1, plate_r, GOLD,
                         lambda yy: _rounded_span(yy, px0, px0, px1, px1, plate_r))
        _paint_shape_row(row, size, y, fx0, fx1, face_r, IVORY,
                         lambda yy: _rounded_span(yy, fx0, fx0, fx1, fx1, face_r))
        for cx, cy in pips:
            _paint_shape_row(
                row, size, y, cy - pip_r, cy + pip_r, pip_r, INK,
                lambda yy, cx=cx, cy=cy: _circle_span(yy, cx, cy, pip_r))
        buf[base:base + stride] = row
    return buf


# ----------------------------------------------------------- file formats


def encode_png(width, height, rgba, alpha=True):
    """PNG writer, RGB when `alpha` is False (iOS and web squares want none)."""
    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    scan = bytearray()
    for y in range(height):
        base = 4 * y * width
        scan += b'\x00'
        if alpha:
            scan += rgba[base:base + 4 * width]
        else:
            src = rgba[base:base + 4 * width]
            scan += bytes(b for i in range(width) for b in src[4 * i:4 * i + 3])
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8,
                                         6 if alpha else 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes(scan), 9))
            + chunk(b'IEND', b''))


def _ico_dib(rgba, size):
    """A 32-bit bottom-up DIB icon entry, with a fully opaque AND mask."""
    rows = bytearray()
    for y in range(size - 1, -1, -1):
        base = 4 * y * size
        row = rgba[base:base + 4 * size]
        rows += bytes(b for x in range(size)
                      for b in (row[4 * x + 2], row[4 * x + 1],
                                row[4 * x], row[4 * x + 3]))
    rows += bytes(((size + 31) // 32) * 4 * size)
    return (struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0,
                        size * size * 4, 0, 0, 0, 0) + bytes(rows))


def encode_ico(entries):
    """Container over [(size, payload)]; 256 px entries are stored as PNG."""
    out = struct.pack('<HHH', 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    blobs = b''
    for size, payload in entries:
        out += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32,
                           len(payload), offset)
        blobs += payload
        offset += len(payload)
    return out + blobs


# ------------------------------------------------------------ downscaling


def resample(src, ssize, dsize):
    """Exact area average of a square RGBA buffer, on premultiplied values."""
    if ssize == dsize:
        return src
    out = bytearray(4 * dsize * dsize)
    scale = ssize / dsize
    for dy in range(dsize):
        sy0, sy1 = dy * scale, (dy + 1) * scale
        y0, y1 = int(math.floor(sy0)), int(math.ceil(sy1))
        wy = [min(y1, yy + 1) - max(y0, yy) for yy in range(y0, y1)]
        for dx in range(dsize):
            sx0, sx1 = dx * scale, (dx + 1) * scale
            x0, x1 = int(math.floor(sx0)), int(math.ceil(sx1))
            wx = [min(x1, xx + 1) - max(x0, xx) for xx in range(x0, x1)]
            acc = [0.0, 0.0, 0.0]
            alpha = total = 0.0
            for j, yy in enumerate(range(y0, y1)):
                base = 4 * yy * ssize
                for i, xx in enumerate(range(x0, x1)):
                    w = wy[j] * wx[i]
                    o = base + 4 * xx
                    a = src[o + 3]
                    total += w
                    alpha += a * w
                    if a:
                        acc[0] += src[o] * a * w
                        acc[1] += src[o + 1] * a * w
                        acc[2] += src[o + 2] * a * w
            o = 4 * (dy * dsize + dx)
            out[o + 3] = int(alpha / total + 0.5)
            if alpha:
                for c in range(3):
                    out[o + c] = int(acc[c] / alpha + 0.5)
    return out


def pyramid(rgba, size, floor=16):
    """Cache of halved renders: any smaller size filters from the level above."""
    levels = {size: rgba}
    while size > floor:
        levels[size // 2] = resample(levels[size], size, size // 2)
        size //= 2
    return levels


# ----------------------------------------------------------------- targets

IOS_ICONS = (
    ('Icon-App-20x20@1x.png', 20), ('Icon-App-20x20@2x.png', 40),
    ('Icon-App-20x20@3x.png', 60), ('Icon-App-29x29@1x.png', 29),
    ('Icon-App-29x29@2x.png', 58), ('Icon-App-29x29@3x.png', 87),
    ('Icon-App-40x40@1x.png', 40), ('Icon-App-40x40@2x.png', 80),
    ('Icon-App-40x40@3x.png', 120), ('Icon-App-60x60@2x.png', 120),
    ('Icon-App-60x60@3x.png', 180), ('Icon-App-76x76@1x.png', 76),
    ('Icon-App-76x76@2x.png', 152), ('Icon-App-83.5x83.5@2x.png', 167),
    ('Icon-App-1024x1024@1x.png', 1024),
)
ANDROID_LAUNCHER = (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96),
                    ('xxhdpi', 144), ('xxxhdpi', 192))
ANDROID_FOREGROUND = (('mdpi', 108), ('hdpi', 162), ('xhdpi', 216),
                      ('xxhdpi', 324), ('xxxhdpi', 432))
WEB_SIZES = (192, 512)
MACOS_SIZES = (16, 32, 64, 128, 256, 512, 1024)
FAVICON = 32

MASKABLE_CONTENT = 0.86    # keeps the die inside whatever shape is applied
FOREGROUND_CONTENT = 0.74  # of the 108 dp canvas, inside the 72 dp safe zone

ADAPTIVE_XML = '''<?xml version="1.0" encoding="utf-8"?>
<!-- Adaptive launcher icon: the felt field with the die layer on top. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
'''
COLORS_XML = '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- AppColors.felt: the field behind the adaptive launcher icon. -->
    <color name="ic_launcher_background">#123524</color>
</resources>
'''


def main():
    written = []

    def write(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        written.append(path)

    masters = {}

    def sampled(background, content_scale, canvas, size):
        key = (background, content_scale, canvas)
        if key not in masters:
            masters[key] = pyramid(render(canvas, background, content_scale), canvas)
        levels = masters[key]
        for level in sorted(levels):
            if level >= size:
                return resample(levels[level], level, size)
        return resample(levels[canvas], canvas, size)

    def opaque(buf, where):
        if any(buf[i] != 255 for i in range(3, len(buf), 4)):
            raise SystemExit(f'{where}: this size must not carry transparency')

    web = ROOT / 'web'
    android = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'
    ios = ROOT / 'ios' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'
    macos = ROOT / 'macos' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'

    # Browsers do not mask a favicon, so that one rounds its own corners.
    write(web / 'favicon.png',
          encode_png(FAVICON, FAVICON, sampled(ROUND, 1.0, MASTER, FAVICON)))
    for size in WEB_SIZES:
        buf = sampled(BLEED, 1.0, MASTER, size)
        opaque(buf, f'Icon-{size}')
        write(web / 'icons' / f'Icon-{size}.png',
              encode_png(size, size, buf, alpha=False))
        buf = sampled(BLEED, MASKABLE_CONTENT, 512, size)
        opaque(buf, f'Icon-maskable-{size}')
        write(web / 'icons' / f'Icon-maskable-{size}.png',
              encode_png(size, size, buf))

    # Android: the legacy launcher PNGs plus the adaptive-icon layers.
    for density, size in ANDROID_LAUNCHER:
        write(android / f'mipmap-{density}/ic_launcher.png',
              encode_png(size, size, sampled(ROUND, 1.0, MASTER, size)))
    for density, canvas in ANDROID_FOREGROUND:
        write(android / f'mipmap-{density}/ic_launcher_foreground.png',
              encode_png(canvas, canvas,
                         sampled(NONE, FOREGROUND_CONTENT, 512, canvas)))
    write(android / 'mipmap-anydpi-v26/ic_launcher.xml', ADAPTIVE_XML.encode())
    write(android / 'values/colors.xml', COLORS_XML.encode())

    # iOS rejects an alpha channel, so these go out opaque and full bleed.
    for name, size in IOS_ICONS:
        buf = sampled(BLEED, 1.0, MASTER, size)
        opaque(buf, name)
        write(ios / name, encode_png(size, size, buf, alpha=False))

    # macOS bakes the rounded shape into the art itself.
    for size in MACOS_SIZES:
        write(macos / f'app_icon_{size}.png',
              encode_png(size, size, sampled(ROUND, 1.0, MASTER, size)))

    # Windows: BMP entries for the small sizes, PNG for the 256 px one.
    ico = [(size, _ico_dib(sampled(ROUND, 1.0, MASTER, size), size))
           for size in (16, 32, 48)]
    ico.append((256, encode_png(256, 256, sampled(ROUND, 1.0, MASTER, 256))))
    write(ROOT / 'windows' / 'runner' / 'resources' / 'app_icon.ico',
          encode_ico(ico))

    for path in written:
        print(f'wrote {path.relative_to(ROOT)} ({path.stat().st_size} B)')
    return 0


if __name__ == '__main__':
    sys.exit(main())

