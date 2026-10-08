"""Knox Pass gate texture atlases (one 512x512 per look, shared by that look's leaf and post models): layout
(imported by build_gate.py inside Blender) + PIL painter.
用法：uv run --with pillow python atlas.py      -> textures/MinidoracatKnoxPass_gate_{A..E}.png

Regions repeat per world unit (build_gate.py splits faces at unit boundaries): PANEL = 1 x 1 unit of leaf infill,
PANEL2 = 1 x 1 unit of post surface, STRIP = 1 unit along x x the full height of a rail / band.
Only look A has transparent pixels (chain-link wires on alpha 0, binary alpha): the door shader discards
texSample.a < 0.01 (media/shaders/door.frag), the same cut-out the vanilla wire fence gates use
(MODELS_fixtures_doors_fences_01.png, 64 % alpha 0, shader = door). Everything else is opaque.
"""
import random
from pathlib import Path

SIZE = 512
PANEL = (0, 0, 256, 256)
PANEL2 = (256, 0, 512, 256)
STRIP = (0, 264, 256, 328)
SWATCH = 16
NAMES = ("frame", "post", "cap", "footing", "hinge", "rib", "bar", "rail", "edge", "brace", "band", "top", "stone_cap")
SWATCHES = {name: (8 + (i % 16) * 24, 352 + (i // 16) * 24) for i, name in enumerate(NAMES)}

# per look: swatch colours (sRGB) and panel / post / strip paint styles
COLORS = {
    "A": {"frame": "#55595d", "post": "#4a4e52", "cap": "#3a3d40", "footing": "#8e8b85", "hinge": "#26282a",
          "edge": "#55595d", "brace": "#505458"},
    "B": {"frame": "#36422f", "post": "#4a4e52", "cap": "#3a3d40", "footing": "#8e8b85", "hinge": "#26282a",
          "rib": "#5d6d55", "edge": "#3b4736"},
    "C": {"frame": "#202124", "post": "#2b2c2f", "cap": "#3a3b3e", "footing": "#8e8b85", "hinge": "#151517",
          "bar": "#1c1d1f", "rail": "#232427", "top": "#2a2b2e"},
    "D": {"frame": "#6e6152", "post": "#5c5043", "cap": "#4a4036", "footing": "#8e8b85", "hinge": "#1e1f21",
          "rail": "#76695a", "brace": "#7a6d5d", "edge": "#5d5245", "top": "#665a4b"},
    "E": {"frame": "#3f2a1c", "post": "#8a857b", "cap": "#9c978c", "stone_cap": "#a6a196", "hinge": "#232325",
          "band": "#2b2b2e", "edge": "#3a2619", "top": "#45301f"},
}
for c in COLORS.values():                  # every look carries every swatch (unused ones grey)
    for n in NAMES:
        c.setdefault(n, "#808080")


def swatch_uv(name):
    x, y = SWATCHES[name]
    return ((x + SWATCH / 2) / SIZE, 1 - (y + SWATCH / 2) / SIZE)


def region_uv(region, u, v):
    """Face-local (u, v) in 0..1 (v up) inside a region; 0.5 px inset."""
    x0, y0, x1, y1 = region
    return ((x0 + 0.5 + u * (x1 - x0 - 1)) / SIZE, 1 - (y1 - 0.5 - v * (y1 - y0 - 1)) / SIZE)


def classify(u, v):
    px, py = u * SIZE, (1 - v) * SIZE
    for name, (x0, y0, x1, y1) in (("PANEL", PANEL), ("PANEL2", PANEL2), ("STRIP", STRIP)):
        if x0 <= px <= x1 and y0 <= py <= y1:
            return name
    for name, (x, y) in SWATCHES.items():
        if x <= px <= x + SWATCH and y <= py <= y + SWATCH:
            return name
    return "?"


def _rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def _jit(rgb, rnd, k):
    """Same brightness offset on every channel (independent offsets turned planks red / green)."""
    o = rnd.randint(-k, k)
    return tuple(max(0, min(255, c + o)) for c in rgb)


def paint(look, out):
    from PIL import Image, ImageDraw

    rnd = random.Random(f"knoxpass-gate-{look}")
    col = COLORS[look]
    img = Image.new("RGBA", (SIZE, SIZE), col["frame"])
    d = ImageDraw.Draw(img)
    for name, (x, y) in SWATCHES.items():
        d.rectangle((x, y, x + SWATCH - 1, y + SWATCH - 1), fill=col[name])

    def planks(region, n, base, seam, grain, knots):
        x0, y0, x1, y1 = region
        w = (x1 - x0) / n
        for i in range(n):
            a, b = round(x0 + i * w), round(x0 + (i + 1) * w)
            c = _jit(_rgb(base), rnd, 10)
            d.rectangle((a, y0, b - 1, y1 - 1), fill=c)
            for _ in range(9):                                     # grain: thin darker / lighter vertical lines
                gx = rnd.randint(a + 3, b - 4)
                d.line((gx, y0, gx + rnd.randint(-2, 2), y1 - 1), fill=_jit(_rgb(grain), rnd, 8), width=1)
            for _ in range(knots):
                kx, ky = rnd.randint(a + 8, b - 9), rnd.randint(y0 + 10, y1 - 11)
                d.ellipse((kx - 4, ky - 6, kx + 4, ky + 6), fill=_jit(_rgb(seam), rnd, 6))
            d.rectangle((a, y0, a + 2, y1 - 1), fill=seam)        # seam / gap at the plank's left edge

    if look == "A":   # chain-link: 45 deg wire lattice, 0.125 unit mesh (32 px), wires 4 px, transparent between
        d.rectangle(PANEL, fill=(0, 0, 0, 0))
        px = img.load()
        x0, y0, x1, y1 = PANEL
        for y in range(y0, y1):
            for x in range(x0, x1):
                a, b = (x + y) % 32, (x - y) % 32
                if a < 4 or b < 4:
                    shade = 132 + (12 if a < 2 or b < 2 else 0) + rnd.randint(-6, 6)
                    px[x, y] = (shade - 8, shade - 4, shade, 255)
        # post steel: vertical streaks
        d.rectangle(PANEL2, fill=col["post"])
        for _ in range(60):
            gx = rnd.randint(256, 511)
            d.line((gx, 0, gx, 255), fill=_jit(_rgb(col["post"]), rnd, 9))
    elif look == "B":  # faded green plate: faint full-height weathering streaks (tiles seamlessly per unit)
        d.rectangle(PANEL, fill="#43513f")
        for _ in range(90):
            gx = rnd.randint(0, 255)
            d.line((gx, 0, gx, 255), fill=_jit((69, 83, 65), rnd, 4))
        d.rectangle(PANEL2, fill=col["post"])
        for _ in range(60):
            gx = rnd.randint(256, 511)
            d.line((gx, 0, gx, 255), fill=_jit(_rgb(col["post"]), rnd, 9))
    elif look == "C":
        d.rectangle(PANEL, fill=col["bar"])
        d.rectangle(PANEL2, fill=col["post"])
        for _ in range(60):
            gx = rnd.randint(256, 511)
            d.line((gx, 0, gx, 255), fill=_jit(_rgb(col["post"]), rnd, 7))
    elif look == "D":  # weathered grey-brown planks: 5 per unit, dark gaps; timber post grain; rail grain
        planks(PANEL, 5, "#716454", "#2b241e", "#5f5346", 1)
        planks(PANEL2, 2, "#5e5244", "#3a3129", "#4f4439", 1)
        x0, y0, x1, y1 = STRIP
        d.rectangle((x0, y0, x1 - 1, y1 - 1), fill=col["rail"])
        for _ in range(14):
            gy = rnd.randint(y0 + 2, y1 - 3)
            d.line((x0, gy, x1 - 1, gy + rnd.randint(-2, 2)), fill=_jit((96, 84, 70), rnd, 8))
        d.rectangle((x0, y0, x1 - 1, y0 + 2), fill="#4a3f34")
        d.rectangle((x0, y1 - 3, x1 - 1, y1 - 1), fill="#4a3f34")
    elif look == "E":  # dark oak: 4 planks per unit; iron band with 5 studs per unit; stone blocks 0.25 unit high
        planks(PANEL, 4, "#4c3423", "#1d120b", "#3b281a", 1)
        x0, y0, x1, y1 = PANEL2
        d.rectangle((x0, y0, x1 - 1, y1 - 1), fill="#5d5951")             # mortar
        for r in range(4):
            off = 0 if r % 2 == 0 else 43
            ya, yb = y0 + r * 64, y0 + (r + 1) * 64
            for c in range(-1, 4):
                xa, xb = x0 + off + c * 85, x0 + off + (c + 1) * 85
                xa, xb = max(x0, xa), min(x1, xb)
                if xb - xa < 6:
                    continue
                base = _jit((140, 134, 123), rnd, 14)
                d.rectangle((xa + 3, ya + 3, xb - 3, yb - 3), fill=base)
                d.line((xa + 3, ya + 3, xb - 3, ya + 3), fill=tuple(min(255, v + 22) for v in base), width=2)
        px = img.load()
        for _ in range(5000):                                              # speckle
            x, y = rnd.randint(x0, x1 - 1), rnd.randint(y0, y1 - 1)
            r_, g_, b_, a_ = px[x, y]
            k = rnd.randint(-12, 12)
            px[x, y] = (max(0, min(255, r_ + k)), max(0, min(255, g_ + k)), max(0, min(255, b_ + k)), a_)
        x0, y0, x1, y1 = STRIP
        d.rectangle((x0, y0, x1 - 1, y1 - 1), fill=col["band"])
        d.rectangle((x0, y0, x1 - 1, y0 + 3), fill="#3b3b3f")
        d.rectangle((x0, y1 - 4, x1 - 1, y1 - 1), fill="#1a1a1c")
        for k in range(5):
            cx, cy = x0 + 26 + k * 51, (y0 + y1) // 2
            d.ellipse((cx - 9, cy - 9, cx + 9, cy + 9), fill="#1a1a1b")
            d.ellipse((cx - 7, cy - 8, cx + 7, cy + 6), fill="#5e554c")
            d.ellipse((cx - 4, cy - 6, cx + 1, cy - 1), fill="#857a6d")
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, optimize=True)
    print(f"wrote {out} {img.size}")


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    import sys

    sys.path.insert(0, str(here))
    import spec

    for look in spec.LOOKS:
        paint(look, here / "textures" / f"{spec.texture(look)}.png")
