"""Game-view previews of the door-post reader on vanilla doors: vanilla Tiles2x 2D sprites on an iso grid + the
reader cell (render_tiles.py `-- reader`, same PZ 2x projection as the in-game 3D model) on its host tile.
用法：uv run --with pillow python reader_previews.py
Outputs: previews/reader_<scene>.png (game default zoom) and reader_<scene>_x2.png (nearest x2, for reading).
The reader is pasted last: in these scenes nothing stands in front of the near-face plate (doors closed).
Host tile and variant per scene follow ReaderPost.lua spot(): single door = hinge post (N west / W north end,
Tiles2x open sprites hang the leaf there), double door piece 1 = its outer end (N west / W south), garage piece 1 =
N west / W south end (IsoDoor.java:120-129, 3241-3280).
"""
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
SPRITES = HERE / "vanilla_dump" / "doors"

# (name, [(x, y, sprite)], (host x, host y, variant)); W runs list north -> south
SCENES = {
    "fence_gate_W": ([*((0, y, "fencing_01_2") for y in (-3, -2, -1)), (0, 0, "fixtures_doors_fences_01_0"),
                      *((0, y, "fencing_01_2") for y in (1, 2))], (0, 0, 2)),
    "double_gate_N": ([*((x, 0, "fencing_01_1") for x in (-3, -2, -1)),
                       *((x, 0, f"fixtures_doors_fences_01_{s}") for x, s in ((0, 34), (1, 35), (2, 42), (3, 43))),
                       *((x, 0, "fencing_01_1") for x in (4, 5))], (0, 0, 0)),
    "garage_W": ([*((0, y, "walls_exterior_house_01_0") for y in (-4, -3)),
                  *((0, y, f"walls_garage_01_{s}") for y, s in ((-2, 2), (-1, 1), (0, 0))),
                  *((0, y, "walls_exterior_house_01_0") for y in (1, 2, 3))], (0, 1, 3)),
}


def main():
    names = sorted({s for tiles, _ in SCENES.values() for _, _, s in tiles})
    missing = [n for n in names if not (SPRITES / f"{n}.png").exists()]
    if missing:
        subprocess.run([sys.executable, str(HERE / "extract_vanilla_sprites.py"), str(SPRITES), *missing], check=True)
    for scene, (tiles, (hx, hy, variant)) in SCENES.items():
        W, H, ox, oy = 832, 640, 400, 300            # tile (0,0) top corner at (ox, oy)
        img = Image.new("RGBA", (W, H), (70, 78, 62, 255))
        d = ImageDraw.Draw(img)
        for gx in range(-7, 9):
            for gy in range(-7, 9):
                x, y = ox + (gx - gy) * 64, oy + (gx + gy) * 32
                d.polygon([(x, y), (x + 64, y + 32), (x, y + 64), (x - 64, y + 32)], outline=(84, 92, 74, 255))
        layers = sorted(tiles, key=lambda t: t[0] + t[1]) + [(hx, hy, None)]
        for x, y, sprite in layers:
            cell = Image.open(HERE / "cells" / "reader" / f"reader_{variant}.png" if sprite is None
                              else SPRITES / f"{sprite}.png").convert("RGBA")
            img.alpha_composite(cell, (ox + (x - y) * 64 - 64, oy + (x + y) * 32 - 192))
        img.save(HERE / "previews" / f"reader_{scene}.png")
        img.resize((W * 2, H * 2), Image.NEAREST).save(HERE / "previews" / f"reader_{scene}_x2.png")
        print(f"previews/reader_{scene}.png")


main()
