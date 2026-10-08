"""Knox Pass two-story roll-up door: shared geometry numbers + texture atlas layout (imported by Blender scripts,
no Pillow needed) + painter (system Python + Pillow).
用法：uv run --with pillow python atlas.py
    -> textures/knoxpass_roll2f_{industry,green,white}.png  (512x512, same UV layout; colours sampled from the
       vanilla one-story roll door sprites in Tiles2x.pack via scripts/build_barrier_tiles.py vanilla_cells, read-only)

Model space (Blender, 1 unit = 1 tile, Z up; one story = 2.44949): origin = centre of lane tile 1 on the floor,
+X = along the lanes (lane k centre at x = k - 1), +Y = toward the door line (tile edge at y = +0.5), -Y = the side
the game camera sees (N face: south, W face: east). Everything stays inside the lane tiles: x in [-0.5, L - 0.5],
y in [-0.1, 0.5].
"""
from pathlib import Path

STORY = 2.44949
Z_TOP = 2 * STORY - 0.01             # housing top 1 cm under the level-2 floor
HOUSE_H = 0.60
HOUSE_B = Z_TOP - HOUSE_H            # housing bottom = clear opening height (4.29; a box truck is ~2.9)
HOUSE_Y0 = -0.10                     # housing front face (camera side)
# housing cross-section (y, z), counter-clockwise seen from +X: back (door line), top, chamfered top-front edge, front,
# front-bottom lip, bottom; extruded over the full width (x in [-0.5, L - 0.5])
HOUSE_PROFILE = ((0.5, HOUSE_B), (0.5, Z_TOP), (HOUSE_Y0 + 0.16, Z_TOP), (HOUSE_Y0 + 0.05, Z_TOP - 0.06),
                 (HOUSE_Y0, Z_TOP - 0.17), (HOUSE_Y0, HOUSE_B + 0.03), (HOUSE_Y0 + 0.03, HOUSE_B))
DRUM_R = 0.20
DRUM_Y, DRUM_Z = 0.20, Z_TOP - 0.30  # drum axis inside the housing; every wrapped slat stays >= 0.07 off its walls
CURTAIN_Y = DRUM_Y + DRUM_R          # curtain plane: tangent to the drum's back side (0.4)
SLAT_H, SLAT_T = 0.14, 0.02          # one corrugation rib per slat (vanilla ribs ~11 px at 2x = 0.14 tile)
SLATS = 32                           # closed curtain s in [0, 4.48]: top end already inside the housing
TRAVEL = HOUSE_B + 0.03              # open: slat 0 (bottom bar) starts 3 cm above the housing bottom
RAIL_W, RAIL_Y0 = 0.10, 0.33         # guide rails: x in [-0.5, -0.4] and [L-0.6, L-0.5], y in [0.33, 0.5]
CURTAIN_INSET = 0.05                 # curtain ends run 5 cm into the rail channel
BAR_H, BAR_T = 0.08, 0.06            # bottom bar on slat 0
U_SPAN = 9.0                         # u = (x + 0.5) / 9: same texel density on every width (widest door = 1.0)
WIDTHS = (3, 4, 6, 9)
STYLES = ("Industry", "Green", "White")
# style -> (vanilla tileset, GarageDoor 1 sprite index of the N piece) = build_barrier_tiles.ROLLDOOR_STYLES
VANILLA = {"Industry": ("industry_trucks_01", 35), "Green": ("walls_garage_01", 19), "White": ("walls_garage_01", 51)}

SIZE = 512
SLAT_PX = 10
CURTAIN = (0, 0, 512, SLATS * SLAT_PX)   # slat i -> rows of rib i counted from the region bottom
HOUSING = (0, 328, 512, 424)             # housing profile faces, bottom (v=0) -> top (v=1) by profile length
BAR = (0, 432, 512, 448)                 # bottom bar front / back
RAIL = (0, 456, 32, 512)                 # rail faces: u across the rail, v up
SWATCH = 16
SWATCH_NAMES = ("rail_side", "end", "dark", "rubber")
SWATCHES = {name: (48 + i * 24, 464) for i, name in enumerate(SWATCH_NAMES)}


def swatch_uv(name):
    x, y = SWATCHES[name]
    return ((x + SWATCH / 2) / SIZE, 1 - (y + SWATCH / 2) / SIZE)


def region_uv(region, u, v):
    """Face-local (u, v) in 0..1 (v up) -> atlas UV; 0.5 px inset avoids bleeding."""
    x0, y0, x1, y1 = region
    return ((x0 + 0.5 + u * (x1 - x0 - 1)) / SIZE, 1 - (y1 - 0.5 - v * (y1 - y0 - 1)) / SIZE)


def classify(u, v):
    px, py = u * SIZE, (1 - v) * SIZE
    for name, (x0, y0, x1, y1) in (("CURTAIN", CURTAIN), ("HOUSING", HOUSING), ("BAR", BAR), ("RAIL", RAIL)):
        if x0 <= px <= x1 and y0 <= py <= y1:
            return name
    for name, (x, y) in SWATCHES.items():
        if x <= px <= x + SWATCH and y <= py <= y + SWATCH:
            return name
    return "?"


# ---------------------------------------------------------------- painter (Pillow)
def sample_palette():
    """style -> colours sampled from the vanilla closed N pieces (GarageDoor 1 / 2 at 2x): curtain light/mid/dark
    (luminance 88-100 / 40-60 / 0-12 percentile over the curtain), header (wall above the door -> housing),
    post (frame -> rails), bottom (floor strip -> bar)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("bbt", Path(__file__).resolve().parents[2] / "build_barrier_tiles.py")
    bbt = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bbt)
    names = {f"{ts}_{n + k}" for ts, n in VANILLA.values() for k in (0, 1)}
    cells = bbt.vanilla_cells(names)

    def pick(name, xs, hzs):
        px = cells[name].load()
        out = []
        for x in xs:                       # N edge of the cell: ground y = 192 + (x - 64) / 2 (top -> right corner)
            for hz in hzs:
                r, g, b, a = px[x, int(192 + (x - 64) * 0.5 - hz)]
                if a > 250:
                    out.append((r, g, b))
        out.sort(key=lambda c: 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2])
        return out

    def avg(cols, a, b):
        s = cols[int(a * len(cols)):max(int(b * len(cols)), int(a * len(cols)) + 1)]
        return tuple(round(sum(c[i] for c in s) / len(s)) for i in range(3))

    pal = {}
    for style, (ts, n) in VANILLA.items():
        cur = pick(f"{ts}_{n + 1}", range(74, 118), range(12, 150))
        pal[style] = {
            "light": avg(cur, 0.88, 1.0), "mid": avg(cur, 0.4, 0.6), "dark": avg(cur, 0.0, 0.12),
            "header": (hd := avg(pick(f"{ts}_{n + 1}", range(74, 118), range(172, 186)), 0.4, 0.6)),
            "header_dark": tuple(round(c * 0.72) for c in hd),      # Industry / White headers are one flat grey
            "post": avg(pick(f"{ts}_{n}", range(64, 69), range(10, 180)), 0.4, 0.6),
            "post_dark": avg(pick(f"{ts}_{n}", range(64, 69), range(10, 180)), 0.0, 0.12),
            "bottom": avg(pick(f"{ts}_{n + 1}", range(74, 118), range(0, 8)), 0.0, 0.3),
        }
    return pal


def paint(out: Path, style: str, p: dict):
    import random
    from PIL import Image, ImageDraw

    def mix(a, b, t):
        return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

    img = Image.new("RGB", (SIZE, SIZE), p["mid"])
    d = ImageDraw.Draw(img)
    # curtain: one rib per slat, 10 px: gap line, highlight, body fading to the shadow under the rib
    x0, y0, x1, y1 = CURTAIN
    rib = [p["dark"], p["light"], p["light"], mix(p["light"], p["mid"], 0.4), p["mid"], p["mid"],
           mix(p["mid"], p["dark"], 0.3), mix(p["mid"], p["dark"], 0.55), mix(p["mid"], p["dark"], 0.8), p["dark"]]
    for i in range(SLATS):
        top = y1 - (i + 1) * SLAT_PX
        for r, c in enumerate(rib):
            d.line((x0, top + r, x1 - 1, top + r), fill=c)
    # wear: Industry grimy toward the floor (vanilla industry sprite), White clean, Green light scuffs
    rnd = random.Random(42)
    if style != "White":
        dirt = mix(p["bottom"], p["dark"], 0.5) if style == "Industry" else mix(p["light"], p["mid"], 0.5)
        count = 2600 if style == "Industry" else 500
        for _ in range(count):
            y = y1 - 1 - int((rnd.random() ** 2.2) * (y1 - y0))      # denser near the bottom slats
            x = rnd.randrange(x0, x1)
            w = rnd.randint(2, 7)
            px = img.getpixel((x, y))
            img.putpixel((x, y), mix(px, dirt, 0.55))
            for k in range(1, w):
                if x + k < x1:
                    img.putpixel((x + k, y), mix(img.getpixel((x + k, y)), dirt, 0.35))
    # housing: vertical gradient (light on top), dark lip at the bottom; Green = cream corrugated like the vanilla
    # header, Industry / White = grey panels with a seam every 1.5 tiles
    hx0, hy0, hx1, hy1 = HOUSING
    for y in range(hy0, hy1):
        t = (y - hy0) / (hy1 - hy0 - 1)
        d.line((hx0, y, hx1 - 1, y), fill=mix(mix(p["header"], (255, 255, 255), 0.18), p["header"], min(1, t * 1.6)))
    d.rectangle((hx0, hy1 - 6, hx1 - 1, hy1 - 1), fill=p["header_dark"])
    tile = (hx1 - hx0) / U_SPAN
    if style == "Green":
        step = tile / 6
        k = 0
        while k * step < hx1 - hx0:
            x = round(hx0 + k * step)
            d.line((x, hy0, x, hy1 - 7), fill=p["header_dark"])
            d.line((x + 2, hy0, x + 2, hy1 - 7), fill=mix(p["header"], (255, 255, 255), 0.35))
            k += 1
    else:
        k = 1
        while k * 1.5 * tile < hx1 - hx0:
            x = round(hx0 + k * 1.5 * tile)
            d.line((x, hy0, x, hy1 - 7), fill=p["header_dark"])
            k += 1
    # bottom bar: metal top half, rubber seal bottom half
    bx0, by0, bx1, by1 = BAR
    d.rectangle((bx0, by0, bx1 - 1, by0 + 7), fill=mix(p["post"], p["post_dark"], 0.5))
    d.line((bx0, by0, bx1 - 1, by0), fill=p["post"])
    d.rectangle((bx0, by0 + 8, bx1 - 1, by1 - 1), fill=(38, 38, 40))
    # rails: post colour, dark channel edges
    rx0, ry0, rx1, ry1 = RAIL
    d.rectangle((rx0, ry0, rx1 - 1, ry1 - 1), fill=p["post"])
    d.rectangle((rx0, ry0, rx0 + 2, ry1 - 1), fill=p["post_dark"])
    d.rectangle((rx1 - 3, ry0, rx1 - 1, ry1 - 1), fill=p["post_dark"])
    sw = {"rail_side": mix(p["post"], p["post_dark"], 0.5), "end": mix(p["header"], p["header_dark"], 0.5),
          "dark": (40, 40, 42), "rubber": (30, 30, 32)}
    for name, (x, y) in SWATCHES.items():
        d.rectangle((x, y, x + SWATCH - 1, y + SWATCH - 1), fill=sw[name])
    out.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGBA").save(out, optimize=True)      # opaque RGBA like the barrier atlas
    print(f"wrote {out} {img.size}")


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    pal = sample_palette()
    for style in STYLES:
        print(style, {k: "#%02x%02x%02x" % v for k, v in pal[style].items()})
        paint(here / "textures" / f"knoxpass_roll2f_{style.lower()}.png", style, pal[style])
    # geometry invariants the model relies on
    assert SLATS * SLAT_H > HOUSE_B, "closed curtain top must already be inside the housing"
    assert TRAVEL + SLAT_H < DRUM_Z, "slat 0 (bottom bar) must stay on the straight part (never wraps the drum)"
    assert min(DRUM_Y - HOUSE_Y0, 0.5 - DRUM_Y, DRUM_Z - HOUSE_B, Z_TOP - DRUM_Z) - DRUM_R >= 0.07
    assert classify(*region_uv(CURTAIN, 0.5, 0.5)) == "CURTAIN" and classify(*swatch_uv("end")) == "end"
