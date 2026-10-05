"""Knox Pass boom barrier texture atlas: layout (imported by build_barrier.py inside Blender) + painter.
用法（系統 Python + Pillow）：python atlas.py      -> textures/knoxpass_barrier.png
Layout is pure data so Blender's bundled Python can import it without Pillow.
Text uses Barlow SemiBold (SIL OFL 1.1, fonts/OFL.txt).
"""
from pathlib import Path

SIZE = 512
PX_PER_M = 400                       # front face: 0.32 m x 1.10 m -> 128 x 440 px
CAB_W, CAB_D, CAB_H = 0.32, 0.36, 1.10
ARM_LEN = 3.26                       # pivot (x=0.20) -> tip x=3.46, stays inside 4 tiles
ARM_BLOCKS = (0.45, 1.30, 2.15, 3.00)  # red block centres from the pivot end (design concept)
ARM_BLOCK_W = 0.24

# Regions (x0, y0, x1, y1) in image pixels, origin top-left.
FRONT = (0, 0, 128, 440)             # cabinet front face (-Y): nameplate, service door, vents
ARM = (0, 456, 512, 488)             # arm faces along its length: white with red blocks
SWATCH = 16
COLORS = {                           # sRGB hex, design doc variant A
    "orange": "#e2731c",             # RAL 2000-ish cabinet / tip post
    "orange_dark": "#c8621a",
    "cap": "#2f3236",
    "dark": "#25282c",
    "white": "#f2f2ef",
    "red": "#c62828",
    "dome": "#ebe9e3",
    "navy": "#1d2b4a",
}
SWATCHES = {name: (144 + (i % 4) * 24, 8 + (i // 4) * 24) for i, name in enumerate(COLORS)}


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


def paint(out: Path):
    from PIL import Image, ImageDraw, ImageFont

    here = Path(__file__).resolve().parent
    img = Image.new("RGBA", (SIZE, SIZE), COLORS["orange"])  # opaque: no alpha bleed into mips
    d = ImageDraw.Draw(img)
    for name, (x, y) in SWATCHES.items():
        d.rectangle((x, y, x + SWATCH - 1, y + SWATCH - 1), fill=COLORS[name])

    # Front face; z (m, up from floor) -> y px.
    fx0, fy0, fx1, fy1 = FRONT
    d.rectangle((fx0, fy0, fx1 - 1, fy1 - 1), fill=COLORS["orange"])

    def zy(z):
        return fy1 - round(z * PX_PER_M)

    def xr(w):  # centred horizontal span of width w metres
        half = round(w * PX_PER_M / 2)
        cx = (fx0 + fx1) // 2
        return cx - half, cx + half - 1

    a, b = xr(0.24)                                   # service door 0.24 x 0.58
    d.rectangle((a, zy(0.76), b, zy(0.18)), fill=COLORS["orange_dark"], outline="#a9521a", width=2)
    a, b = xr(0.18)                                   # three vent slots
    for k in range(3):
        z = 0.30 + k * 0.035
        d.rectangle((a, zy(z + 0.006), b, zy(z - 0.006)), fill=COLORS["dark"])
    a, b = xr(0.22)                                   # nameplate 0.22 x 0.066 at z 0.97
    top, bot = zy(0.97 + 0.033), zy(0.97 - 0.033)
    d.rectangle((a, top, b, bot), fill=COLORS["navy"])
    font = ImageFont.truetype(str(here / "fonts" / "Barlow-SemiBold.ttf"), 40)
    text = "KNOX PASS"
    l, t, r, btm = d.textbbox((0, 0), text, font=font)
    target_w = (b - a) * 0.84                          # fit text to 84 % of the plate width
    size = max(6, int(40 * target_w / (r - l)))
    font = ImageFont.truetype(str(here / "fonts" / "Barlow-SemiBold.ttf"), size)
    l, t, r, btm = d.textbbox((0, 0), text, font=font)
    d.text(((a + b) / 2 - (l + r) / 2, (top + bot) / 2 - (t + btm) / 2), text, font=font, fill=COLORS["white"])
    d.rectangle((fx0, fy0, fx1 - 1, fy0 + 3), fill="#b85e17")   # shade just under the cap

    # Arm strip: x along the arm (pivot end left), height = arm depth.
    x0, y0, x1, y1 = ARM
    d.rectangle((x0, y0, x1 - 1, y1 - 1), fill=COLORS["white"])
    for c in ARM_BLOCKS:
        u0 = x0 + round((c - ARM_BLOCK_W / 2) / ARM_LEN * (x1 - x0))
        u1 = x0 + round((c + ARM_BLOCK_W / 2) / ARM_LEN * (x1 - x0))
        d.rectangle((u0, y0, u1 - 1, y1 - 1), fill=COLORS["red"])
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, optimize=True)
    print(f"wrote {out} {img.size}")


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    paint(here / "textures" / "knoxpass_barrier.png")
    assert swatch_uv("orange")[0] < 1 and region_uv(FRONT, 1, 1)[1] <= 1
