"""Split render canvases into PZ 2x cells, rebuild composites from the cells and check them against the
full renders; compare the vanilla calibration renders with the shipped 2D sprites.
用法：python assemble_previews.py      (after render_tiles.py; needs Pillow)
Outputs: cells/<N|W>/{cabinet,cabinet_arm,lane1,lane2,lane3}_<state>.png (128x256, tile top corner (64,192),
floor diamond bottom vertex (64,255)), *_z1.png (same tile one level up, only when the geometry is taller
than one level), previews/<layout>_<state>_cells.png, cells/cells.txt.
"""
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

HERE = Path(__file__).resolve().parent
STATES = ("closed", "a30", "a60", "open")
OFFSETS = {"N": lambda k: (k, 0), "W": lambda k: (0, -k)}   # PZ (dx, dy) of tile k from the cabinet tile
OX, OY, CW, CH = 128, 480, 448, 704                           # full render: tile 0 top corner, canvas size
report = []


def say(s):
    print(s)
    report.append(s)


def alpha_bbox(img):
    return img.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()


def diamond(d, x, y, colour):
    d.polygon([(x, y), (x + 64, y + 32), (x, y + 64), (x - 64, y + 32)], outline=colour)


# 1. calibration against vanilla sprites (fixtures_doors_fences_01_1 = N closed, _0 = W closed)
say("== calibration (render of vanilla glb with vanilla spriteModels values vs Tiles2x sprite), bbox in 128x256 cell")
for name in (f"fixtures_doors_fences_01_{i}" for i in range(4)):   # 1/0 = N/W closed, 3/2 = N/W open
    r = Image.open(HERE / "vanilla_dump" / "calib" / f"{name}_render.png").convert("RGBA")
    s = Image.open(HERE / "vanilla_dump" / "sprites" / f"{name}.png").convert("RGBA")
    say(f"{name}: render bbox {alpha_bbox(r)}  sprite bbox {alpha_bbox(s)}")
    sheet = Image.new("RGBA", (128 * 3, 256), (96, 96, 96, 255))
    for i, img in enumerate((s, r)):
        sheet.alpha_composite(img, (128 * i, 0))
    over = Image.new("RGBA", (128, 256), (96, 96, 96, 255))
    over.alpha_composite(Image.merge("RGBA", (*Image.new("RGB", (128, 256), (255, 60, 60)).split(),
                                              s.getchannel("A").point(lambda a: a // 2))))
    over.alpha_composite(Image.merge("RGBA", (*Image.new("RGB", (128, 256), (60, 200, 255)).split(),
                                              r.getchannel("A").point(lambda a: a // 2))))
    sheet.alpha_composite(over, (256, 0))
    d = ImageDraw.Draw(sheet)
    for i in range(3):
        diamond(d, 128 * i + 64, 192, (255, 255, 0, 255))
    sheet.save(HERE / "vanilla_dump" / "calib" / f"{name}_compare.png")

# 2. cells + rebuilt composites
say("\n== cells: 128x256, tile top corner (64,192); bbox = opaque rect inside the cell")
for layout, off in OFFSETS.items():
    for state in STATES:
        comp = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
        for name, k, src in (("cabinet", 0, "cabinet"), ("cabinet_arm", 0, f"cabinet_arm_{state}"),
                             *((f"lane{k}", k, f"lane{k}_{state}") for k in (1, 2, 3))):
            canvas = Image.open(HERE / "cells" / "_canvas" / f"{layout}_{src}.png").convert("RGBA")
            lower = canvas.crop((0, 192, 128, 448))
            upper = canvas.crop((0, 0, 128, 256))
            upper.paste((0, 0, 0, 0), (0, 192, 128, 256))
            out = HERE / "cells" / layout
            out.mkdir(parents=True, exist_ok=True)
            lower.save(out / f"{name}_{state}.png")
            up_box = alpha_bbox(upper)
            z1 = out / f"{name}_{state}_z1.png"
            if up_box:
                upper.save(z1)
            elif z1.exists():
                z1.unlink()
            say(f"{layout} {name}_{state}: bbox {alpha_bbox(lower)}" + (f"  z+1 bbox {up_box}" if up_box else ""))
            dx, dy = off(k)
            tx, ty = OX + (dx - dy) * 64, OY + (dx + dy) * 32
            comp.alpha_composite(lower, (tx - 64, ty - 192))
            if up_box:
                comp.alpha_composite(upper, (tx - 64, ty - 384))
        full = Image.open(HERE / "previews" / f"{layout}_{state}_full.png").convert("RGBA")
        diff = ImageChops.difference(full.getchannel("A"), comp.getchannel("A")).point(lambda a: 255 if a > 32 else 0)
        say(f"   {layout} {state}: cells vs full render -> {sum(1 for p in diff.getdata() if p)} alpha-mismatch px")
        bg = Image.new("RGBA", (CW, CH), (58, 60, 64, 255))
        d = ImageDraw.Draw(bg)
        for gx in range(-1, 5):
            for gy in range(-4, 2):
                diamond(d, OX + (gx - gy) * 64, OY + (gx + gy) * 32, (80, 84, 90, 255))
        for k in range(4):
            dx, dy = off(k)
            diamond(d, OX + (dx - dy) * 64, OY + (dx + dy) * 32, (200, 170, 60, 255))
        bg.alpha_composite(comp)
        bg.save(HERE / "previews" / f"{layout}_{state}_cells.png")
(HERE / "cells" / "cells.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
