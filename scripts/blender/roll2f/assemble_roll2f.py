# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Two-story roll door: 2D cells, entity icons, preview sheets and manifest.json from the Blender renders.
用法：uv run assemble_roll2f.py        (after render_roll2f.py)

cells/<style>/<N|W>/lane_{first,mid,last}.png  128x256 build-ghost cells = LOWER STORY of the closed door sliced to one
    lane tile and cut at z = one story (canvas rows 192..447 of cells/_canvas). A 128x256 cell holds one story
    (IsoObject.java:2173-2174 anchor, rows 0..191 above the floor) and build_barrier_tiles.fit_cell crops taller cells,
    so the upper story (curtain top, rails, drum housing) is not in the 2D ghost. Cutting along the story line (not the
    cell's top row) gives the same sloped top edge as a one-story vanilla wall, so the ghost reads as a roll door:
    ribbed curtain, bottom bar on the floor, guide rail on the two end lanes. Cells come from the 3-wide model
    (lane 1 / 2 / 3) and are shared by every width: middle lanes 2..L-1 differ only in curtain grime texels, which a
    tinted build ghost cannot show.
icons/rolldoor2f_<style>_<w>.png  64x64 entity icons (closed N render, build_barrier_tiles.fit_icon)
previews/sheet_<w>.png            game-camera closed / half / open x Industry / Green / White, half scale
previews/ghost_<face>_<style>_<w>.png  the placeholder cells laid out as the build cursor draws them
manifest.json                     everything the integrator needs (see the "_doc" keys)
"""
import importlib.util
import json
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
_spec = importlib.util.spec_from_file_location("atlas", HERE / "atlas.py")
A = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(A)
_spec = importlib.util.spec_from_file_location("bbt", REPO / "scripts" / "build_barrier_tiles.py")
BBT = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(BBT)                      # read-only: fit_icon

FACES = ("N", "W")
ROTATE = {"N": [0.0, 180.0, 0.0], "W": [0.0, -90.0, 0.0]}
HEALTH = {3: 1500, 4: 1500, 6: 2000, 9: 2500}
LANE_CELL = ("lane_first", "lane_mid", "lane_last")
FRAMES = 8


def rel(p: Path) -> str:
    return p.relative_to(REPO).as_posix()


def lane_cell(k: int, width: int) -> str:
    return LANE_CELL[0] if k == 1 else LANE_CELL[2] if k == width else LANE_CELL[1]


def cells():
    for style in A.STYLES:
        for face in FACES:
            out = HERE / "cells" / style.lower() / face
            out.mkdir(parents=True, exist_ok=True)
            for k, name in zip((1, 2, 3), LANE_CELL):
                canvas = Image.open(HERE / "cells" / "_canvas" / f"{style.lower()}_{face}_lane{k}.png").convert("RGBA")
                cell = canvas.crop((0, 192, 128, 448))
                assert cell.getchannel("A").getbbox(), (style, face, k)
                cell.save(out / f"{name}.png")


def ghost(face, style, width):
    """Placeholder cells in placement order at their 2x screen offsets (lane k +64,+32 per step for N; W runs
    north = +64,-32), over a tile grid."""
    step = (64, 32) if face == "N" else (64, -32)
    w, h = 128 + 64 * (width - 1) + 40, 256 + 32 * (width - 1) + 40
    img = Image.new("RGBA", (w, h), (58, 60, 64, 255))
    d = ImageDraw.Draw(img)
    oy = 20 if face == "N" else 20 + 32 * (width - 1)
    for k in range(1, width + 1):
        x, y = 20 + step[0] * (k - 1), oy + step[1] * (k - 1)
        d.polygon([(x + 64, y + 192), (x + 128, y + 224), (x + 64, y + 256), (x, y + 224)], outline=(200, 170, 60, 255))
    for k in (range(1, width + 1) if face == "N" else range(width, 0, -1)):   # draw back to front
        x, y = 20 + step[0] * (k - 1), oy + step[1] * (k - 1)
        img.alpha_composite(Image.open(HERE / "cells" / style.lower() / face / f"{lane_cell(k, width)}.png"), (x, y))
    img.save(HERE / "previews" / f"ghost_{face}_{style.lower()}_{width}.png")


def icons():
    out = {}
    for style in A.STYLES:
        for w in A.WIDTHS:
            src = Image.open(HERE / "previews" / f"icon_{style.lower()}_{w}.png").convert("RGBA")
            p = HERE / "icons" / f"rolldoor2f_{style.lower()}_{w}.png"
            p.parent.mkdir(parents=True, exist_ok=True)
            BBT.fit_icon(src, 64).save(p, optimize=True)
            out[f"MinidoracatKnoxPassRollDoor2F{style}{w}"] = p
    return out


def sheets():
    for w in A.WIDTHS:
        imgs = [[Image.open(HERE / "previews" / f"game_N_{s.lower()}_{w}_{st}.png").convert("RGB")
                 for st in ("closed", "half", "open")] for s in A.STYLES]
        cw = max(i.width for row in imgs for i in row)
        ch = max(i.height for row in imgs for i in row)
        sheet = Image.new("RGB", (cw * 3, ch * 3), (40, 40, 40))
        for r, row in enumerate(imgs):
            for c, im in enumerate(row):
                sheet.paste(im, (c * cw, r * ch))
        sheet.resize((sheet.width // 2, sheet.height // 2), Image.LANCZOS).save(HERE / "previews" / f"sheet_{w}.png")


def manifest(icon_paths):
    tex = {s: {"source": rel(HERE / "textures" / f"knoxpass_roll2f_{s.lower()}.png"),
               "ship": f"media/textures/IsoObject/MinidoracatKnoxPass_roll2f_{s.lower()}.png",
               "spriteModels_texture": f"IsoObject/MinidoracatKnoxPass_roll2f_{s.lower()}",
               "vanilla_colour_source": f"{A.VANILLA[s][0]}_{A.VANILLA[s][1]} / _{A.VANILLA[s][1] + 1} (Tiles2x)"}
           for s in A.STYLES}
    models = {str(w): {
        "source": rel(HERE / "export" / f"knoxpass_roll2f_{w}.glb"),
        "ship": f"media/models_X/IsoObject/MinidoracatKnoxPass_roll2f_{w}.glb",
        "model_script": f"MinidoracatKnoxPass_Roll2F{w}",
        "model_script_fields": {"mesh": f"IsoObject/MinidoracatKnoxPass_roll2f_{w}",
                                "animationsMesh": f"MinidoracatKnoxPass_Roll2F{w}",
                                "texture": tex["Industry"]["spriteModels_texture"], "shader": "door",
                                "static": False, "scale": 1.0, "undoCoreScale": True},
        "animationsMesh": {"name": f"MinidoracatKnoxPass_Roll2F{w}", "meshFile": f"IsoObject/MinidoracatKnoxPass_roll2f_{w}",
                           "keepMeshAnimations": True},
    } for w in A.WIDTHS}
    sm = lambda w, s, anim, t: {"modelScript": f"Base.MinidoracatKnoxPass_Roll2F{w}",  # noqa: E731
                                "texture": tex[s]["spriteModels_texture"], "animation": anim,
                                "animationTime": round(t, 4), "scale": 1.0}
    blocks = []
    for si, s in enumerate(A.STYLES):
        for wi, w in enumerate(A.WIDTHS):
            for fi, f in enumerate(FACES):
                b = (si * 4 + wi) * 2 + fi
                base = b * 64
                spm = {"0": sm(w, s, "Open", 0.0), "8": sm(w, s, "Close", 0.0)}
                for k in range(FRAMES + 1):
                    spm[str(32 + k)] = sm(w, s, "Open", k / FRAMES)
                    spm[str(48 + k)] = sm(w, s, "Open", k / FRAMES)
                for v in spm.values():
                    v |= {"translate": [0.0, 0.0, 0.0], "rotate": ROTATE[f]}
                blocks.append({
                    "block": b, "style": s, "width": w, "face": f, "first_index": base,
                    "style_tileset": f"MinidoracatKnoxPass_roll2f_{s.lower()}", "style_block": wi * 2 + fi,
                    "style_first_index": (wi * 2 + fi) * 64,
                    "entity": f"MinidoracatKnoxPassRollDoor2F{s}{w}",
                    "placeholder_cells": {str(16 + k - 1): rel(HERE / "cells" / s.lower() / f / f"{lane_cell(k, w)}.png")
                                          for k in range(1, w + 1)},
                    "spriteModels": spm,
                })
    return {
        "_doc": "roll2f (two-story roll-up door) model deliverables; contract = r4-contract.md. Paths under 'source' are "
                "repo-relative, 'ship' is relative to MOD/.../42/. index = block * 64 + slot; spriteModels xy = "
                "index % 8, index // 8. Rebuild: README.md.",
        "kind": "roll2f", "tileset": "MinidoracatKnoxPass_roll2f", "tileset_number": 5,
        "block_formula": "block = (styleIdx * 4 + widthIdx) * 2 + faceIdx (global); integration splits per style "
                         "(tiledef max 512 tiles per tileset, IsoWorld.java:639-640): tileset style_tileset, "
                         "style_block = widthIdx * 2 + faceIdx, index = style_block * 64 + slot (fields per block)",
        "placeholder_cell_dedupe": "lane_mid is one file per style+face, used for every middle lane of every width",
        "styles": list(A.STYLES), "widths": list(A.WIDTHS), "faces": list(FACES), "ends": None,
        "health": {str(w): HEALTH[w] for w in A.WIDTHS},
        "model_space": "Blender metres = tile units, Z up, one story = 2.44949. Origin = centre of lane tile 1 (the "
                       "chain anchor, slot 0) on the floor; +X along the lanes (lane k centre x = k - 1); door line = "
                       "tile edge y = +0.5; the drum housing sticks out to y = -0.10 on the camera side. Footprint "
                       f"x in [-0.5, L - 0.5], y in [-0.10, 0.5], z in [0, {A.Z_TOP:.3f}] (top of the 2nd story - 1 cm). "
                       f"Clear opening when open: width L - 0.2 between the rails, height {A.HOUSE_B:.3f} "
                       "(housing bottom).",
        "faces_xform": {f: {"translate": [0.0, 0.0, 0.0], "rotate": ROTATE[f],
                            "_doc": ("Blender +X = PZ east, +Y = PZ north (door on the N edge of the lanes)" if f == "N"
                                     else "Blender +X = PZ north, +Y = PZ west (door on the W edge; lane 1 = max y)")}
                        for f in FACES},
        "models": models, "textures": tex,
        "texture_note": "one model per width; the model script texture is Industry, every spriteModels tile sets its "
                        "style texture explicitly (same UV layout, IsoObjectModelDrawer binds spriteModel.textureName)",
        "rig": {"armature": "Dummy01", "bones": ["PostBone"] + [f"Slat{i:02d}" for i in range(A.SLATS)],
                "PostBone": "static: guide rails + drum housing",
                "SlatNN": f"curtain slat NN (0 = bottom, carries the bottom bar), {A.SLAT_H} high; translation + "
                          "rotation keys only (bone scale is ignored by AnimationPlayer)",
                "matrix_palette": f"{A.SLATS + 2} of 60 (Dummy01 + PostBone + slats; door.vert MatrixPalette[60])"},
        "clips": {"Open": "closed -> open, 6.0 s (frames 1-145 @ 24 fps, keys every 2nd frame, times 0.042..6.042 s "
                          "like the barrier arm); engine speedDelta 1.5 -> ~4.0 s. Curtain travel = TRAVEL * ease(t), "
                          "ease (scripts/blender/ease.py): trapezoidal speed, 20 % accelerate / 20 % decelerate, "
                          "baked into the keys (pose slots sample the clip at linear t = k/8 and get the eased pose)",
                  "Close": "exact reverse of Open, same length: travel = TRAVEL * ease(1 - t)"},
        "slots": {"0": "closed lane 1 (GarageDoor 1): spriteModel Open t=0 (closed)",
                  "1, 2": "closed middle / last lane: no spriteModel, no 2D cell (transparent)",
                  "8": "open lane 1 (GarageDoor 4): spriteModel Close t=0 (open)",
                  "9, 10": "open middle / last lane: no spriteModel, no 2D cell",
                  "16 .. 16+L-1": "build-only placeholder for lane k = slot - 15: 2D cell = placeholder_cells",
                  "32 .. 40": "opening poses: Open t = (slot-32)/8",
                  "48 .. 56": "closing poses: same geometry as 32..40 (Open t = (slot-48)/8), same style texture",
                  "3, 4": "unused (no end tiles)"},
        "placeholder_cells_note": "128x256, lower story of the closed door sliced to the lane tile (upper story is "
                                  "not drawn in 2D; see assemble_roll2f.py docstring); lane_first / lane_mid / "
                                  "lane_last from the 3-wide model shared by all widths",
        "blocks": blocks,
        "icons": {e: {"source": rel(p), "ship": f"media/ui/MinidoracatKnoxPass/{p.name}"} for e, p in icon_paths.items()},
        "previews": sorted(rel(p) for p in (HERE / "previews").glob("*.png")),
        "verify": rel(HERE / "export" / "knoxpass_roll2f_verify.txt"),
    }


if __name__ == "__main__":
    cells()
    for f in FACES:
        for s in A.STYLES:
            for w in (4, 9):
                ghost(f, s, w)
    icon_paths = icons()
    sheets()
    m = manifest(icon_paths)
    for b in m["blocks"]:
        assert all((REPO / p).exists() for p in b["placeholder_cells"].values()), b["block"]
    assert len(m["blocks"]) == 24 and sorted(b["block"] for b in m["blocks"]) == list(range(24))
    (HERE / "manifest.json").write_text(json.dumps(m, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote cells, {len(icon_paths)} icons, sheets, manifest.json ({len(m['blocks'])} blocks)")
