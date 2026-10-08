"""Write manifest.json (everything build_barrier_tiles.py needs to wire barrier2 in) + the 64 px entity icons.
用法：uv run --with pillow python manifest.py      (after build_barrier2.py and render_barrier2.py)

Indices follow the r4 contract: block = widthIdx * 2 + faceIdx (widths 6, 9; faces N, W), index = block * 64 + slot,
spriteModels xy = index % 8, index // 8. Paths are repo-relative.
"""
import json
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
REL = HERE.relative_to(REPO).as_posix()
WIDTHS, FACES = (6, 9), ("N", "W")
HEALTH = {6: 1500, 9: 2000}
FRAMES = 8
TEX, GREEN = "IsoObject/MinidoracatKnoxPass_barrier", "IsoObject/MinidoracatKnoxPass_barrier_green"
CABINET = "MinidoracatKnoxPass_BarrierCabinet"
# face -> spriteModels rotate, lane-1 translate (lane 1 tile -> end-A tile = model origin); render_barrier2.py FACES
XFORM = {"N": ((0.0, 180.0, 0.0), (-1.0, 0.0, 0.0)), "W": ((0.0, -90.0, 0.0), (0.0, 0.0, 1.0))}


def model(L):
    return f"MinidoracatKnoxPass_Barrier2Boom{L}"


def sm(model_name, translate, rotate, anim=None, t=None, texture=None):
    d = {"modelScript": f"Base.{model_name}", "translate": list(translate), "rotate": list(rotate), "scale": 1.0}
    if texture:
        d["texture"] = texture
    if anim:
        d |= {"animation": anim, "animationTime": t}
    return d


def block(wi, fi):
    L, face = WIDTHS[wi], FACES[fi]
    b = wi * 2 + fi
    rot, t1 = XFORM[face]
    zero = (0.0, 0.0, 0.0)
    slots = {0: sm(model(L), t1, rot, "Open", 0.0), 8: sm(model(L), t1, rot, "Close", 0.0, GREEN),
             3: sm(CABINET, zero, rot), 4: sm(CABINET, zero, rot)}
    for k in range(FRAMES + 1):
        slots[32 + k] = sm(model(L), t1, rot, "Open", k / FRAMES, GREEN)   # opening poses: green lamp
        slots[48 + k] = sm(model(L), t1, rot, "Open", k / FRAMES)          # closing poses: red (model default)
    cells = {3: f"{REL}/cells/{L}{face}/endA.png", 4: f"{REL}/cells/{L}{face}/endB.png"}
    cells |= {16 + k - 1: f"{REL}/cells/{L}{face}/lane{k}.png" for k in range(1, L + 1)}
    for p in cells.values():
        assert Image.open(REPO / p).size == (128, 256), p
    lanes = list(range(16, 16 + L))
    rows = [[3, *lanes, 4]] if face == "N" else [[4], *([s] for s in reversed(lanes)), [3]]
    return {
        "block": b, "width": L, "face": face, "first_index": b * 64,
        "entity_face_rows_slots": rows,
        "spriteModels": {str(b * 64 + s): {"slot": s, "xy": [(b * 64 + s) % 8, (b * 64 + s) // 8], **v}
                         for s, v in sorted(slots.items())},
        "cells": {str(b * 64 + s): {"slot": s, "file": p} for s, p in sorted(cells.items())},
        "no_2d_cell_slots": [0, 1, 2, 8, 9, 10] + list(range(32, 41)) + list(range(48, 57)),
        "previews": [f"{REL}/previews/{L}{face}_{s}_game.png" for s in ("closed", "half", "open")],
    }


def fit_icon(img, size=64):   # = scripts/build_barrier_tiles.py fit_icon
    img = img.crop(img.getbbox())
    s = (size - 2) / max(img.size)
    img = img.resize((max(1, round(img.width * s)), max(1, round(img.height * s))), Image.LANCZOS)
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(img, ((size - img.width) // 2, (size - img.height) // 2), img)
    return icon


entities = {}
for L in WIDTHS:
    icon = HERE / "icons" / f"boom_barrier_{L}.png"
    icon.parent.mkdir(exist_ok=True)
    fit_icon(Image.open(HERE / "previews" / f"{L}N_icon_src.png").convert("RGBA")).save(icon, optimize=True)
    entities[f"MinidoracatKnoxPassBoomBarrier{L}"] = {
        "width": L, "health": HEALTH[L], "icon": f"{REL}/icons/{icon.name}",
        "icon_ship": f"media/ui/MinidoracatKnoxPass/{icon.name}"}

models = {}
for L in WIDTHS:
    m = (L + 1) / 2
    models[model(L)] = {
        "glb": f"{REL}/export/knoxpass_barrier2_boom{L}.glb",
        "ship": f"media/models_X/IsoObject/MinidoracatKnoxPass_barrier2_boom{L}.glb",
        "model_script": {"mesh": f"IsoObject/MinidoracatKnoxPass_barrier2_boom{L}", "animationsMesh": model(L),
                         "animationsMesh_meshFile": f"IsoObject/MinidoracatKnoxPass_barrier2_boom{L}",
                         "keepMeshAnimations": True, "texture": TEX, "shader": "door", "static": False,
                         "scale": 1.0, "undoCoreScale": True},
        "origin": "end-A cabinet tile centre on the floor; +X along the lane row (lane k centre x = k, end B x = L+1), "
                  "+Y toward the gate edge (y = +0.5); glb +Y up (Khronos exporter), 1 unit = 1 tile",
        "armature": "Dummy01",
        "bones": {"PostBone": {"head": [0, 0, 0], "moves": False,
                               "carries": "both pivot lamps, rest posts, road paint"},
                  "DoorBone": {"head": [0.27, 0.30, 1.0], "moves": True, "carries": "boom A (tip +X), STOP sign"},
                  "DoorBoneB": {"head": [round(2 * m - 0.27, 4), 0.30, 1.0], "moves": True,
                                "carries": "boom B (tip -X), STOP sign"}},
        "clips": {"Open": {"seconds": 6.0, "fps": 24, "frames": [1, 145], "deg": [0.0, 86.0]},
                  "Close": {"seconds": 6.0, "fps": 24, "frames": [1, 145], "deg": [86.0, 0.0]},
                  "curve": "ease (scripts/blender/ease.py): angle = 86 * ease(t), baked on every frame; Close = "
                           "Open reversed; shared with MinidoracatKnoxPass_BarrierArm",
                  "note": "both booms together, same angles/timing as MinidoracatKnoxPass_BarrierArm"},
        "boom_reach": {"pivot_to_cap_end": round(m - 0.015 - 0.27, 3), "booms_meet_x": m,
                       "rest_posts_x": [3 * c + 0.5 for c in range(1, L // 3)],
                       "stop_sign_x": [2.0, round(2 * m - 2.0, 3)]},
    }

manifest = {
    "kind": "barrier2", "tileset": "MinidoracatKnoxPass_barrier2", "tileset_number": 4,
    "widths": list(WIDTHS), "faces": list(FACES), "block_rule": "block = widthIdx * 2 + faceIdx; index = block*64+slot",
    "textures": {
        "default_red": TEX, "green": GREEN,
        "ship": [], "note": "same atlas and UV layout as the single barrier; both PNGs are already shipped from "
                            "scripts/blender/barrier/textures/knoxpass_barrier{,_green}.png - nothing new to copy"},
    "models": models,
    "cabinet": {"modelScript": f"Base.{CABINET}", "ship": "already shipped (MinidoracatKnoxPass_barrier_cabinet.glb)",
                "endA": "slot 3, translate 0 0 0, rotate = the face's rotate (same as the single barrier N/W cabinet)",
                "endB": "slot 4, translate 0 0 0, rotate = the face's rotate: the cabinet mesh is mirror-symmetric "
                        "along the row, so no 180 deg turn is needed (a 180 deg turn would move it 0.6 tile off the "
                        "gate-line side); boom B's pivot lamp is part of the boom model"},
    "faces_xform": {f: {"rotate": list(r), "lane1_translate": list(t), "endA_translate": [0, 0, 0],
                        "endB_translate": [0, 0, 0]} for f, (r, t) in XFORM.items()},
    "lane_slots_1_2_spriteModel": None,
    "blocks": [block(wi, fi) for wi in range(len(WIDTHS)) for fi in range(len(FACES))],
    "entities": entities,
    "verify": f"{REL}/export/verify.txt",
}
(HERE / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n", encoding="utf-8")
print(f"wrote {HERE / 'manifest.json'} + {len(entities)} icons")
