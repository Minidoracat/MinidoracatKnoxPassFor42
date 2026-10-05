"""Knox Pass boom barrier texture atlas: layout (imported by build_barrier.py inside Blender) + painter.
用法（系統 Python + Pillow）：python atlas.py
    -> textures/knoxpass_barrier.png        (lamp lens red: closed tiles, closing poses, model script default)
    -> textures/knoxpass_barrier_green.png  (lamp lens green: open tiles and opening poses, spriteModels texture =)
Layout is pure data so Blender's bundled Python can import it without Pillow.
Text uses Barlow SemiBold (SIL OFL 1.1, fonts/OFL.txt).
"""
from pathlib import Path

SIZE = 512
PX_PER_M = 400                       # cabinet faces: 0.32 / 0.36 m x 1.10 m -> 128 / 144 x 440 px
CAB_W, CAB_D, CAB_H = 0.32, 0.36, 1.10
ARM_LEN = 3.19                       # pivot (x=0.27) -> tip x=3.46, + 0.03 end cap stays inside 4 tiles
ARM_H, ARM_T = 0.16, 0.10            # arm cross-section (was 0.085 x 0.05: a hairline at default zoom)
BAND = 0.40                          # red / white bands from the pivot end, red first
SIGN_U = 1.73                        # STOP sign centre along the arm from the pivot (x = 2.0, middle of the 3 lanes)
SIGN_APOTHEM = 0.275                 # octagon centre -> flat side; 0.55 m across the flats
REFLECTORS = (0.60, 2.20, 3.00)      # red reflector dots (arm u, centres of white bands clear of the sign)
REFLECTOR_D = 0.07

# Regions (x0, y0, x1, y1) in image pixels, origin top-left.
FRONT = (0, 0, 128, 440)             # cabinet +-Y faces (traffic sides): big KNOX PASS plate, service door
SIDE = (136, 0, 280, 440)            # cabinet +-X faces: vertical KNOX PASS
SIGN = (288, 0, 416, 128)            # STOP octagon, square = 2 x circumradius
ARM = (0, 456, 512, 488)             # arm +-Y faces: bands + reflectors
ARM_TOP = (0, 496, 512, 512)         # arm +-Z faces: bands only
SWATCH = 16
NAVY, AMBER = "#1d2b4a", "#e8a33d"   # brand: scripts/blender/build.py COLORS Cream text colour, cover accent colour
LAMP = {"red": "#ff3324", "green": "#2bea5a"}
COLORS = {                           # sRGB hex
    "navy": NAVY,
    "navy_light": "#2c3f68",
    "navy_dark": "#121b30",
    "amber": AMBER,
    "cap": "#2f3236",
    "dark": "#25282c",
    "white": "#f2f2ef",
    "red": "#c62828",
    "dome": "#ebe9e3",
    "lamp": LAMP["red"],             # repainted per output file
    "paint_white": "#e8e8e2",        # road paint
}
SWATCHES = {name: (288 + (i % 8) * 24, 136 + (i // 8) * 24) for i, name in enumerate(COLORS)}


def swatch_uv(name):
    """UV (u, v) of a swatch centre; v measured from the bottom like Blender UVs."""
    x, y = SWATCHES[name]
    return ((x + SWATCH / 2) / SIZE, 1 - (y + SWATCH / 2) / SIZE)


def region_uv(region, u, v):
    """Map face-local (u, v) in 0..1 (v up) into a region; 0.5 px inset avoids bleeding."""
    x0, y0, x1, y1 = region
    px = x0 + 0.5 + u * (x1 - x0 - 1)
    py = y1 - 0.5 - v * (y1 - y0 - 1)
    return (px / SIZE, 1 - py / SIZE)


def classify(u, v):
    """Name of the region or swatch a UV falls in (verify_export.py measures parts by it)."""
    px, py = u * SIZE, (1 - v) * SIZE
    for name, (x0, y0, x1, y1) in (("FRONT", FRONT), ("SIDE", SIDE), ("SIGN", SIGN), ("ARM", ARM), ("ARM_TOP", ARM_TOP)):
        if x0 <= px <= x1 and y0 <= py <= y1:
            return name
    for name, (x, y) in SWATCHES.items():
        if x <= px <= x + SWATCH and y <= py <= y + SWATCH:
            return name
    return "?"


def paint(out: Path, lamp: str):
    from PIL import Image, ImageDraw, ImageFont

    here = Path(__file__).resolve().parent
    ttf = str(here / "fonts" / "Barlow-SemiBold.ttf")
    img = Image.new("RGBA", (SIZE, SIZE), NAVY)   # opaque: no alpha bleed into mips
    d = ImageDraw.Draw(img)
    for name, (x, y) in SWATCHES.items():
        d.rectangle((x, y, x + SWATCH - 1, y + SWATCH - 1), fill=LAMP[lamp] if name == "lamp" else COLORS[name])

    def fit(text, w, h):
        """Largest Barlow size whose ink box fits w x h px."""
        size = 200
        while size > 6:
            font = ImageFont.truetype(ttf, size)
            l, t, r, b = d.textbbox((0, 0), text, font=font)
            if r - l <= w and b - t <= h:
                return font
            size -= 1
        return ImageFont.truetype(ttf, 6)

    def centred(draw, text, font, cx, cy, fill):
        l, t, r, b = draw.textbbox((0, 0), text, font=font)
        draw.text((cx - (l + r) / 2, cy - (t + b) / 2), text, font=font, fill=fill)

    def cabinet_face(region):
        x0, y0, x1, y1 = region
        d.rectangle((x0, y0, x1 - 1, y1 - 1), fill=NAVY)
        zy = lambda z: y1 - round(z * PX_PER_M)  # noqa: E731  z (m, up from floor) -> y px
        d.rectangle((x0, zy(1.10), x1 - 1, zy(1.03)), fill=AMBER)          # top band under the cap
        d.rectangle((x0, zy(0.075), x1 - 1, zy(0.035)), fill=AMBER)        # kick stripe
        return zy

    # +-Y faces: amber plate 0.29 x 0.36 m with KNOX / PASS in navy (one line would be ~4 px tall in game)
    zy = cabinet_face(FRONT)
    fx0, _, fx1, _ = FRONT
    m = round(0.015 * PX_PER_M)
    top, bot = zy(0.98), zy(0.62)
    d.rectangle((fx0 + m, top, fx1 - 1 - m, bot), fill=AMBER, outline=COLORS["navy_dark"], width=2)
    pw, ph = (fx1 - fx0 - 2 * m) * 0.84, (bot - top) * 0.40
    font = min((fit(w, pw, ph) for w in ("KNOX", "PASS")), key=lambda f: f.size)
    cx = (fx0 + fx1) / 2
    centred(d, "KNOX", font, cx, top + (bot - top) * 0.28, NAVY)
    centred(d, "PASS", font, cx, top + (bot - top) * 0.72, NAVY)
    a, b = cx - 0.12 * PX_PER_M, cx + 0.12 * PX_PER_M - 1                  # service door 0.24 x 0.40
    d.rectangle((a, zy(0.54), b, zy(0.14)), fill=COLORS["navy_light"], outline=COLORS["navy_dark"], width=2)
    for k in range(3):                                                      # vents
        z = 0.22 + k * 0.035
        d.rectangle((a + 12, zy(z + 0.006), b - 12, zy(z - 0.006)), fill=COLORS["navy_dark"])

    # +-X faces: vertical KNOX PASS in amber, reading bottom -> top
    zy = cabinet_face(SIDE)
    sx0, _, sx1, _ = SIDE
    lw, lh = zy(0.14) - zy(0.96), round((sx1 - sx0) * 0.62)
    label = Image.new("RGBA", (lw, lh), (0, 0, 0, 0))
    ld = ImageDraw.Draw(label)
    centred(ld, "KNOX PASS", fit("KNOX PASS", lw * 0.96, lh * 0.9), lw / 2, lh / 2, AMBER)
    label = label.rotate(90, expand=True)
    img.alpha_composite(label, (round((sx0 + sx1 - label.width) / 2), zy(0.96)))

    # STOP octagon: circumradius = half the region, flat top (vertices at 22.5 + 45k deg, as build_barrier.sign)
    import math
    gx0, gy0, gx1, gy1 = SIGN
    d.rectangle((gx0, gy0, gx1 - 1, gy1 - 1), fill=COLORS["red"])
    c, r = ((gx0 + gx1) / 2, (gy0 + gy1) / 2), (gx1 - gx0) / 2
    octa = lambda rr: [(c[0] + rr * math.cos(math.radians(22.5 + 45 * k)),  # noqa: E731
                        c[1] - rr * math.sin(math.radians(22.5 + 45 * k))) for k in range(8)]
    d.polygon(octa(r), fill=COLORS["white"])
    d.polygon(octa(r * 0.88), fill=COLORS["red"])
    apo = r * math.cos(math.radians(22.5))
    centred(d, "STOP", fit("STOP", apo * 2 * 0.74, apo * 0.62), c[0], c[1], COLORS["white"])

    # Arm: x along the arm (pivot end left), y across the face. Bands everywhere, reflectors on the side faces.
    for region, dots in ((ARM, True), (ARM_TOP, False)):
        x0, y0, x1, y1 = region
        upx = (x1 - x0) / ARM_LEN
        d.rectangle((x0, y0, x1 - 1, y1 - 1), fill=COLORS["white"])
        k = 0
        while k * BAND < ARM_LEN:
            if k % 2 == 0:
                d.rectangle((x0 + round(k * BAND * upx), y0, min(x1, x0 + round((k + 1) * BAND * upx)) - 1, y1 - 1),
                            fill=COLORS["red"])
            k += 1
        if dots:
            rx, ry = REFLECTOR_D / 2 * upx, REFLECTOR_D / 2 * (y1 - y0) / ARM_H
            for u in REFLECTORS:
                assert int(u // BAND) % 2 == 1, f"reflector {u} is not on a white band"
                cx, cy = x0 + u * upx, (y0 + y1) / 2
                d.ellipse((cx - rx - 1, cy - ry - 1, cx + rx + 1, cy + ry + 1), fill="#7a1010")
                d.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill="#ff2a2a")
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, optimize=True)
    print(f"wrote {out} {img.size}")


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    paint(here / "textures" / "knoxpass_barrier.png", "red")
    paint(here / "textures" / "knoxpass_barrier_green.png", "green")
    assert classify(*swatch_uv("lamp")) == "lamp" and classify(*region_uv(SIGN, 0.5, 0.5)) == "SIGN"
    assert all(abs(u - SIGN_U) > SIGN_APOTHEM + 0.1 for u in REFLECTORS), "reflector hidden under the STOP sign"
