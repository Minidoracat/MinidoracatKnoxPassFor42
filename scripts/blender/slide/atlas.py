"""Knox Pass sliding gate texture atlases: the two-story gates' layout and painter (../gate/atlas.py) plus two swatches
for the drive cabinet, and the two looks only the sliding gates have.
用法：uv run --with pillow python atlas.py      -> textures/MinidoracatKnoxPass_slide_<look>.png (spec.LOOKS)

A-D and ABlack are the gates' atlases with the cabinet swatches added (same seed: the same pixels elsewhere).
F = safety yellow frame, chain-link panel, STRIP = black / yellow hazard stripes (the kick strip).
G = dark frame, chain-link panel, STRIP = concertina wire loops on alpha 0.
Binary alpha like look A's chain-link (the door shader discards a < 0.01).
"""
import importlib.util
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GATE = HERE.parent / "gate"
MOTOR = {"motor": "#1d2b4a", "motor_trim": "#e8a33d"}   # the boom barrier cabinet's navy and amber (../barrier/atlas.py)
NEW = {
    "F": {"frame": "#c9a01e", "post": "#4a4e52", "cap": "#3a3d40", "footing": "#8e8b85", "hinge": "#26282a",
          "edge": "#c9a01e", "brace": "#b38d18", "rail": "#c9a01e", "bar": "#8a8d90"},
    "G": {"frame": "#2f3236", "post": "#2b2e32", "cap": "#222427", "footing": "#8e8b85", "hinge": "#151517",
          "edge": "#2f3236", "brace": "#2c2f33", "rail": "#2f3236", "bar": "#9a9da0"},
}


def extend(A):
    """Add the cabinet swatches to a loaded ../gate/atlas.py module (build_slide.py calls this for the UVs)."""
    if "motor" not in A.NAMES:
        A.NAMES = A.NAMES + tuple(MOTOR)
        A.SWATCHES = {name: (8 + (i % 16) * 24, 352 + (i // 16) * 24) for i, name in enumerate(A.NAMES)}
        for c in A.COLORS.values():
            c.update(MOTOR)


def paint(A, look, out):
    if look not in NEW:
        return A.paint(look, out)
    from PIL import Image, ImageDraw

    rnd = random.Random(f"knoxpass-slide-{look}")
    col = {n: (NEW[look] | MOTOR).get(n, "#808080") for n in A.NAMES}
    img = Image.new("RGBA", (A.SIZE, A.SIZE), col["frame"])
    d = ImageDraw.Draw(img)
    for name, (x, y) in A.SWATCHES.items():
        d.rectangle((x, y, x + A.SWATCH - 1, y + A.SWATCH - 1), fill=col[name])
    d.rectangle(A.PANEL, fill=(0, 0, 0, 0))                       # chain-link, as look A
    px = img.load()
    x0, y0, x1, y1 = A.PANEL
    for y in range(y0, y1):
        for x in range(x0, x1):
            a, b = (x + y) % 32, (x - y) % 32
            if a < 4 or b < 4:
                s = 132 + (12 if a < 2 or b < 2 else 0) + rnd.randint(-6, 6)
                px[x, y] = (s - 8, s - 4, s, 255)
    d.rectangle(A.PANEL2, fill=col["post"])                       # post steel: vertical streaks
    for _ in range(60):
        gx = rnd.randint(256, 511)
        d.line((gx, 0, gx, 255), fill=A._jit(A._rgb(col["post"]), rnd, 9))
    x0, y0, x1, y1 = A.STRIP
    if look == "F":                                               # hazard stripes, 45 deg, 2 per unit
        for y in range(y0, y1):
            for x in range(x0, x1):
                px[x, y] = (26, 26, 28, 255) if (x + y) % 64 < 32 else (222, 178, 24, 255)
    else:                                                         # concertina wire: 8 loops per unit, barbs
        strip = Image.new("RGBA", (x1 - x0, y1 - y0), (0, 0, 0, 0))
        sd = ImageDraw.Draw(strip)
        for k in range(-1, 9):
            sd.ellipse((k * 32, 4, k * 32 + 44, y1 - y0 - 5), outline=(150, 153, 156, 255), width=3)
        for xx in range(0, x1 - x0, 16):
            sd.line((xx - 3, 2, xx + 3, 9), fill=(170, 173, 176, 255), width=2)
            sd.line((xx - 3, y1 - y0 - 9, xx + 3, y1 - y0 - 2), fill=(170, 173, 176, 255), width=2)
        strip.putalpha(strip.getchannel("A").point(lambda v: 255 if v >= 128 else 0))
        img.paste(strip, (x0, y0))
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, optimize=True)
    print(f"wrote {out} {img.size}")


if __name__ == "__main__":
    sys.dont_write_bytecode = True       # importing ../gate/atlas.py must not leave __pycache__ there
    sys.path.insert(0, str(GATE))        # first: the gate atlas imports its own "spec"
    import atlas as A  # noqa: E402

    extend(A)
    sp = importlib.util.spec_from_file_location("knoxpass_slide_spec", HERE / "spec.py")
    S = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(S)
    for look in S.LOOKS:
        paint(A, look, HERE / "textures" / f"{S.texture(look)}.png")
        im = __import__("PIL.Image").Image.open(HERE / "textures" / f"{S.texture(look)}.png").convert("RGBA")
        assert {v for _, v in im.getchannel("A").getcolors()} <= {0, 255}, look     # binary alpha
        for name, hexa in MOTOR.items():
            x, y = A.SWATCHES[name]
            assert im.getpixel((x + 8, y + 8))[:3] == A._rgb(hexa), (look, name)
        assert (im.getchannel("A").getextrema()[0] == 0) == (S.geometry(look) in S.CUTOUT), look
