# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Knox Pass boom barrier + door-post reader: Blender cells/exports -> .pack + .tiles + spriteModels.txt + model/entity
scripts in MOD/.

    uv run scripts/build_barrier_tiles.py           # (re)build the barrier assets into the MOD tree
    uv run scripts/build_barrier_tiles.py --check   # reverse-read what is shipped and assert it

Sources: scripts/blender/barrier/ (cells/, export/*.glb, textures/, previews/N_closed_full.png); rebuild them with
the order in that folder's build_barrier.py docstring when the model changes.

Layout (tileset MinidoracatKnoxPass_barrier, 8 columns because spriteModels index = col + row*8,
SpriteModelsFile.java:225; IsoDoor garage open sprite = closed index + 8, IsoDoor.java:793-805):

    row 0 (closed)  0 N lane1  1 N lane2  2 N lane3  3 W lane1  4 W lane2  5 W lane3  6 N cabinet  7 W cabinet
    row 1 (open)    8 N lane1  9 N lane2 10 N lane3 11 W lane1 12 W lane2 13 W lane3
    16..24 / 32..40  N / W opening poses (Open clip, t = k/8, green lamp texture)
    48..56 / 64..72  N / W closing poses (same geometry, red lamp = model script texture); BarrierAnim picks
                  base + pose (+ CLOSE_OFFSET while the door is closed). spriteModels-only: no sprite, no tiledef entry
                  (SpriteModels.toScriptManager registers them by name, SpriteModels.java:81-96, initSprites skips
                  missing sprites, SpriteModelsFile.java:271-279)

lane1 = GarageDoor 1 = chain anchor, the tile next to the cabinet (anchor sits at min x for N, max y for W:
IsoDoor.getGarageDoorPrev/Next, IsoDoor.java:3241-3342). lane1 carries the arm model (arm, STOP sign, pivot lamp,
tip post); lane2 carries the road-paint model (stop lines + KNOX PASS on both sides of the gate line); lane3 carries
an empty model. Their 2D cells (arm segments) only show in the build-cursor ghost (ISBuildIsoEntity.lua:823-837 draws
2D only) and in the non-FBO fallback (IsoObject.java:6301-6302).

Lamp colour = texture of the spriteModel being drawn: both IsoObjectModelDrawer.renderMain overloads (static and
animated, IsoObjectModelDrawer.java:134-139, 285-290) bind spriteModel.textureName over the model script texture
(:563-566), and IsoObject.renderModel passes the object's current getSpriteModel() even while an animation plays
(IsoObject.java:6280-6298, 6368-6385). So the open tile (sprite switched before the Open clip plays) and the opening
poses draw green, the closed tile and closing poses draw the red default. Vanilla does the same on animated doors
(spriteModels.txt:774-822, texture = fixtures_doors_02_22).

Door-post reader (tileset MinidoracatKnoxPass_reader, tileset number 2 in the same .tiles / pack / file number):

    0 N door, post at its west end   1 N door, post at its east end   2 W door, north end   3 W door, south end

One static model (knoxpass_reader_post.glb, both faces of the wall line) on the tile whose NW corner is the post,
rotated per variant (READER_XFORM; render_tiles.py READER_XFORM draws the 2D cells with the same values). The tiles
carry NO properties at all: no collision / door / solid flags (IsoChunk physics shapes and IsoSprite.shouldHaveCollision
read only flags, IsoChunk.java:2056-2111, IsoSprite.java:2083-2092; AutoDrive classifySprite then returns COST_NONE,
MDAD_Sensor.lua:390-457), no IsMoveAble (not pick-up-able), not an IsoThumpable (not dismantlable). Placement,
removal and self-repair: server/MinidoracatKnoxPass/ReaderPost.lua.
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pzfmt  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
BLENDER = REPO / "scripts" / "blender" / "barrier"
CELLS = BLENDER / "cells"
OUT = REPO / "MOD/MinidoracatKnoxPassFor42/Contents/mods/MinidoracatKnoxPassFor42"
MEDIA = OUT / "42" / "media"
COMMON = OUT / "common" / "media"
MODELS_SCRIPT = MEDIA / "scripts" / "models_knoxpass_barrier.txt"
ENTITY_SCRIPT = MEDIA / "scripts" / "entities" / "entity_knoxpass_barrier.txt"

PACK = "MinidoracatKnoxPass"
TILEDEF = "MinidoracatKnoxPass_tiles"
FILE_NUMBER = 7430                           # 100..8189, unique across enabled mods (ChooseGameInfo.java:311,
                                             # ZomboidFileSystem.java:1000-1002); not used by any of the 418
                                             # local Workshop items; family Economy uses 7429
TILESET = "MinidoracatKnoxPass_barrier"
CELL_W, CELL_H = 128, 256
NAME = "Knox Pass Boom Barrier"
READER_TILESET = "MinidoracatKnoxPass_reader"
READER_CELLS = CELLS / "reader"
READER_MODEL = "MinidoracatKnoxPass_ReaderPost"
# translate = host tile NW corner (the post); rotate turns model +X (into the door opening) per variant:
# 0 east, 1 west, 2 south, 3 north (engine formula: render_tiles.py pz_matrix; see the barrier XFORM note below)
READER_T = (-0.5, 0.0, -0.5)
READER_XFORM = {0: (0.0, 180.0, 0.0), 1: (0.0, 0.0, 0.0), 2: (0.0, 90.0, 0.0), 3: (0.0, -90.0, 0.0)}

# closed: doorN/doorW (tile type -> IsoDoor on load, IsoWorld.java:752-764; CellLoader.java:93-105),
# GarageDoor k (chain, IsoDoor.java:3212-3238), doorTrans (sight passes, IsoDoor.java:1107).
# DoorWallN/W (vehicle WallN/WallW shape while !open, IsoChunk.java:2068-2092; AutoDrive closedDoor) is NOT
# written here: loading it from a .tiles also sets sprite.cutN/cutW (IsoWorld.java:928-941), the lanes become an
# exterior wall for cutaway, and a cut-away garage door draws only its 2D sprite, never the 3D arm
# (IsoGridSquare.java:1318-1319, 2301-2309, 2392-2394; barrier-mp 2026-10-05: open/animating arm invisible near
# the line). Core.lua sets the DoorWall flag and key at OnLoadedTileDefinitions instead, without cutN/cutW.
# NO WallN/WallW/collide/solid on chain pieces: shouldHaveCollision would make AutoDrive treat it as a wall
# (MDAD_Sensor.lua:425 before :436-437) and solid would make isDoorObstructed true (IsoDoor.java:2743).
# open: same + GarageDoor k+3 (setOpenDoorProperties adds the open flag, IsoWorld.java:1488-1493).


def lane_props(edge: str, k: int, is_open: bool) -> dict:
    return {
        f"door{edge}": "",
        "GarageDoor": str(k + 3 if is_open else k),
        "doorTrans": "",
        "CustomName": NAME,
        "firerequirement": "900000",
    }


# cabinet: separate solid object; solid -> Bullet Solid shape (IsoChunk.java:2056-2062), pedestrians blocked,
# AutoDrive COST_HARD (shouldHaveCollision, IsoSprite.java:2083-2092).
def cabinet_props(edge: str) -> dict:
    return {
        "solid": "",
        "BlocksPlacement": "",
        "Facing": "N" if edge == "N" else "W",
        "CustomName": NAME,
        "firerequirement": "900000",
    }


# index -> (cell files composited bottom-up, props)
def layout() -> dict[int, tuple[tuple[str, ...], dict]]:
    t: dict[int, tuple[tuple[str, ...], dict]] = {}
    for base, edge in ((0, "N"), (3, "W")):
        for k in (1, 2, 3):
            t[base + k - 1] = ((f"{edge}/lane{k}_closed.png",), lane_props(edge, k, False))
            t[base + k - 1 + 8] = ((f"{edge}/lane{k}_open.png",), lane_props(edge, k, True))
    # the pivot lamp and the arm root sit in the cabinet tile but belong to the arm model: the cabinet cell is the
    # depth-correct cabinet + closed arm render (render_tiles.py cabinet_ghost)
    t[6] = (("N/cabinet_ghost_closed.png",), cabinet_props("N"))
    t[7] = (("W/cabinet_ghost_closed.png",), cabinet_props("W"))
    return t


# spriteModels transforms. Starting point = vanilla wood fence gate (spriteModels.txt:1170-1220);
# IsoObjectModelDrawer.renderMain applies translate(-tx/1.5, ty/1.5, tz/1.5)*rotateXYZ(rx,-ry,rz) at the tile centre.
# Values from blender/render_tiles.py, which places the glbs with the engine formula validated against the
# vanilla fence gate (closed tiles within 1-2 px of the shipped 2D sprites; cells/cells.txt). Static models
# (cabinet, empty) were not calibrated; confirm live with the SpriteModel editor (IngameState.java:1455).
# lane k hosts a model whose origin is the cabinet tile centre, k tiles back along the run.
XFORM = {
    "N": {"rotate": (0.0, 180.0, 0.0), "cabinet": (0.0, 0.0, 0.0), "arm": (-1.0, 0.0, 0.0), "lines": (-2.0, 0.0, 0.0)},
    "W": {"rotate": (0.0, -90.0, 0.0), "cabinet": (0.0, 0.0, 0.0), "arm": (0.0, 0.0, 1.0), "lines": (0.0, 0.0, 2.0)},
}
FRAMES = 8                                   # SP stepper poses per direction (Open clip, t = k/FRAMES)
FRAME_BASE = 16
CLOSE_OFFSET = 32                            # closing (red) poses = opening pose index + 32
GREEN = "IsoObject/MinidoracatKnoxPass_barrier_green"   # media/textures/<GREEN>.png (IsoObjectModelDrawer.java:138)


def fmt3(v) -> str:
    return " ".join(f"{x:.4f}" for x in v)


def sm_tile(index: int, model: str, translate, rotate, anim: str | None, t: float | None = None,
            texture: str | None = None) -> str:
    lines = [f"            xy = {index % 8} {index // 8},", f"            modelScript = Base.{model},"]
    if texture:
        lines.append(f"            texture = {texture},")
    lines += [f"            translate = {fmt3(translate)},", f"            rotate = {fmt3(rotate)},",
              "            scale = 1.0000,"]
    if anim:
        lines.append(f"            animation = {anim},")
        lines.append(f"            animationTime = {0.0 if t is None else t:.4f},")
    return "        tile\n        {\n" + "\n".join(lines) + "\n        }\n"


def sprite_models() -> str:
    body = ""
    for base, edge, cab in ((0, "N", 6), (3, "W", 7)):
        x = XFORM[edge]
        # closed lane1 shows frame 0 of Open (arm down, red lamp); open lane1 shows frame 0 of Close (arm up, green)
        body += sm_tile(base, "MinidoracatKnoxPass_BarrierArm", x["arm"], x["rotate"], "Open")
        body += sm_tile(base + 8, "MinidoracatKnoxPass_BarrierArm", x["arm"], x["rotate"], "Close", texture=GREEN)
        for idx in (base + 1, base + 9):
            body += sm_tile(idx, "MinidoracatKnoxPass_BarrierLines", x["lines"], x["rotate"], None)
        for idx in (base + 2, base + 10):
            body += sm_tile(idx, "MinidoracatKnoxPass_BarrierEmpty", (0, 0, 0), (0, 0, 0), None)
        body += sm_tile(cab, "MinidoracatKnoxPass_BarrierCabinet", x["cabinet"], x["rotate"], None)
    for d, edge in enumerate(("N", "W")):
        x = XFORM[edge]
        for off, tex in ((0, GREEN), (CLOSE_OFFSET, None)):
            for f in range(FRAMES + 1):
                body += sm_tile(FRAME_BASE + d * 16 + off + f, "MinidoracatKnoxPass_BarrierArm", x["arm"], x["rotate"],
                                "Open", f / FRAMES, tex)
    tiles = "".join(sm_tile(i, READER_MODEL, READER_T, rot, None) for i, rot in READER_XFORM.items())
    return ("spriteModel\n{\n    VERSION = 1,\n\n    tileset\n    {\n"
            f"        name = {TILESET},\n\n" + body + "    }\n\n    tileset\n    {\n"
            f"        name = {READER_TILESET},\n\n" + tiles + "    }\n}\n")


MODEL_SCRIPT = """module Base
{
    model MinidoracatKnoxPass_BarrierArm
    {
        mesh = IsoObject/MinidoracatKnoxPass_barrier_arm,
        animationsMesh = MinidoracatKnoxPass_BarrierArm,
        texture = IsoObject/MinidoracatKnoxPass_barrier,
        shader = door,
        static = false,
        scale = 1.0,
        undoCoreScale = true,
    }

    animationsMesh MinidoracatKnoxPass_BarrierArm
    {
        meshFile = IsoObject/MinidoracatKnoxPass_barrier_arm,
        keepMeshAnimations = true,
    }

    model MinidoracatKnoxPass_BarrierCabinet
    {
        mesh = IsoObject/MinidoracatKnoxPass_barrier_cabinet,
        texture = IsoObject/MinidoracatKnoxPass_barrier,
        static = true,
        scale = 1.0,
        undoCoreScale = true,
    }

    model MinidoracatKnoxPass_BarrierLines
    {
        mesh = IsoObject/MinidoracatKnoxPass_barrier_lines,
        texture = IsoObject/MinidoracatKnoxPass_barrier,
        static = true,
        scale = 1.0,
        undoCoreScale = true,
    }

    model MinidoracatKnoxPass_BarrierEmpty
    {
        mesh = IsoObject/MinidoracatKnoxPass_barrier_empty,
        texture = IsoObject/MinidoracatKnoxPass_barrier,
        static = true,
        scale = 1.0,
        undoCoreScale = true,
    }

    model MinidoracatKnoxPass_ReaderPost
    {
        mesh = IsoObject/MinidoracatKnoxPass_reader_post,
        texture = WorldItems/MinidoracatKnoxPassReader,
        static = true,
        scale = 1.0,
        undoCoreScale = true,
    }
}
"""


def entity_script() -> str:
    s = lambda i: f"{TILESET}_{i}"  # noqa: E731
    return f"""module Base
{{
    xuiSkin default
    {{
        entity ES_MinidoracatKnoxPassBarrier
        {{
            LuaWindowClass = ISEntityWindow,
            DisplayName = IGUI_KnoxPass_Barrier_Name,
            Icon = media/ui/MinidoracatKnoxPass/barrier_icon.png,
        }}
    }}

    entity MinidoracatKnoxPassBoomBarrier
    {{
        component UiConfig
        {{
            xuiSkin = default,
            entityStyle = ES_MinidoracatKnoxPassBarrier,
            uiEnabled = false,
        }}

        component SpriteConfig
        {{
            health = 600,
            skillBaseHealth = 0,
            dontNeedFrame = true,
            OnCreate = MinidoracatKnoxPass.Barrier.onCreate,

            face N
            {{
                layer
                {{
                    row = {s(6)} {s(0)} {s(1)} {s(2)},
                }}
            }}

            face W
            {{
                layer
                {{
                    row = {s(5)},
                    row = {s(4)},
                    row = {s(3)},
                    row = {s(7)},
                }}
            }}
        }}

        component CraftRecipe
        {{
            timedAction = BuildWoodenStructureMedium,
            time = 150,
            category = Furniture,
            Tags = Furniture,
            inputs
            {{
                item 1 tags[base:screwdriver] mode:keep flags[Prop1;MayDegradeVeryLight],
                item 1 [MinidoracatKnoxPass.BoomBarrierKit],
            }}
        }}
    }}
}}
"""


def fit_cell(img: Image.Image) -> Image.Image:
    """Cells come from render_tiles.py already 128 px wide and floor-anchored; taller cells keep their bottom."""
    img = img.convert("RGBA")
    if img.width != CELL_W:
        raise SystemExit(f"cell width {img.width}, expected {CELL_W}")
    if img.height == CELL_H:
        return img
    cell = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
    # ponytail: taller cells are cropped to the vanilla 128x256 frame (only open-state arm tops are lost,
    # and open 2D cells are seen only with the debug non-FBO renderer); keep taller frames if that matters.
    cell.paste(img.crop((0, img.height - CELL_H, CELL_W, img.height)) if img.height > CELL_H else img,
               (0, max(0, CELL_H - img.height)))
    return cell


def load_cell(rels: tuple[str, ...]) -> Image.Image:
    cell = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
    for rel in rels:
        p = CELLS / rel
        if not p.exists():
            raise SystemExit(f"missing cell {p} (run scripts/blender/barrier/render_tiles.py first)")
        cell.alpha_composite(fit_cell(Image.open(p)))
    return cell


def reader_cell(i: int) -> Image.Image:
    p = READER_CELLS / f"reader_{i}.png"
    if not p.exists():
        raise SystemExit(f"missing cell {p} (run scripts/blender/barrier/render_tiles.py -- reader first)")
    return fit_cell(Image.open(p))


def build() -> None:
    tiles = layout()
    n = max(tiles) + 1
    cells = {i: load_cell(rels) for i, (rels, _) in tiles.items()}
    # one page: barrier 8 x 2 grid + reader row 2 (sheet keeps full cells; entries store the trimmed rect)
    sheet = Image.new("RGBA", (CELL_W * 8, CELL_H * 3), (0, 0, 0, 0))
    entries = []
    placed = [(f"{TILESET}_{i}", i % 8, i // 8, c) for i, c in sorted(cells.items())]
    placed += [(f"{READER_TILESET}_{i}", i, 2, reader_cell(i)) for i in READER_XFORM]
    for name, col, row, c in placed:
        sheet.paste(c, (col * CELL_W, row * CELL_H))
        bbox = c.getbbox() or (0, 0, 1, 1)   # fully transparent cell keeps a 1x1 rect
        x0, y0, x1, y1 = bbox
        entries.append((name, col * CELL_W + x0, row * CELL_H + y0, x1 - x0, y1 - y0, x0, y0, CELL_W, CELL_H))
    (MEDIA / "texturepacks").mkdir(parents=True, exist_ok=True)
    (MEDIA / "texturepacks" / f"{PACK}.pack").write_bytes(pzfmt.write_pack([(f"{PACK}0", sheet, entries)]))
    props = [tiles[i][1] if i in tiles else {} for i in range(n)]
    (MEDIA / f"{TILEDEF}.tiles").write_bytes(pzfmt.write_tiles([
        {"name": TILESET, "image": f"{TILESET}.png", "w": 8, "h": 2, "number": 1, "tiles": props},
        {"name": READER_TILESET, "image": f"{READER_TILESET}.png", "w": 8, "h": 1, "number": 2,
         "tiles": [{} for _ in READER_XFORM]}]))
    COMMON.mkdir(parents=True, exist_ok=True)
    (COMMON / "spriteModels.txt").write_text(sprite_models(), encoding="ascii", newline="\n")
    ENTITY_SCRIPT.parent.mkdir(parents=True, exist_ok=True)
    MODELS_SCRIPT.write_text(MODEL_SCRIPT, encoding="ascii", newline="\n")
    ENTITY_SCRIPT.write_text(entity_script(), encoding="ascii", newline="\n")
    # meshes (media/models_X, .fbx -> .glb -> .x lookup: FileTask_AbstractLoadModel.java:89-110) and model texture
    for src, dst in assets():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
    # build-menu icon (xuiSkin Icon = file path, 64 px) and the kit's item icon (Icon = X -> textures/Item_X.png,
    # 32 px like the other Knox Pass items), both from the transparent N closed render
    full = Image.open(BLENDER / "previews" / "N_closed_full.png").convert("RGBA")
    full = full.crop(full.getbbox())
    for path, size in ((ICON, 64), (KIT_ICON, 32)):
        s = (size - 2) / max(full.size)
        img = full.resize((max(1, round(full.width * s)), max(1, round(full.height * s))), Image.LANCZOS)
        icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        icon.paste(img, ((size - img.width) // 2, (size - img.height) // 2), img)
        path.parent.mkdir(parents=True, exist_ok=True)
        icon.save(path, optimize=True)
    print(f"wrote {len(entries)} sprites, tiledef {TILEDEF} {FILE_NUMBER}, spriteModels, model + entity scripts, "
          f"5 glb, 2 textures, icons; mod.info needs: pack={PACK} / tiledef={TILEDEF} {FILE_NUMBER}")


ICON = MEDIA / "ui" / "MinidoracatKnoxPass" / "barrier_icon.png"
KIT_ICON = MEDIA / "textures" / "Item_MinidoracatKnoxPassBarrierKit.png"


def assets() -> list[tuple[Path, Path]]:
    out = [(BLENDER / "export" / f"knoxpass_barrier_{p}.glb",
            MEDIA / "models_X" / "IsoObject" / f"MinidoracatKnoxPass_barrier_{p}.glb")
           for p in ("arm", "cabinet", "lines", "empty")]
    for suffix in ("", "_green"):
        out.append((BLENDER / "textures" / f"knoxpass_barrier{suffix}.png",
                    MEDIA / "textures" / "IsoObject" / f"MinidoracatKnoxPass_barrier{suffix}.png"))
    out.append((BLENDER / "export" / "knoxpass_reader_post.glb",
                MEDIA / "models_X" / "IsoObject" / "MinidoracatKnoxPass_reader_post.glb"))
    return out


def check() -> None:
    tiles = layout()
    pages = pzfmt.read_pack((MEDIA / "texturepacks" / f"{PACK}.pack").read_bytes())
    assert len(pages) == 1 and pages[0]["mask"] == 1, pages
    page = pages[0]
    names = {e[0]: e for e in page["entries"]}
    tsets = pzfmt.read_tiles((MEDIA / f"{TILEDEF}.tiles").read_bytes())
    assert [(t["name"], t["w"], t["number"]) for t in tsets] == [(TILESET, 8, 1), (READER_TILESET, 8, 2)], tsets
    ts = tsets[0]
    vis = lambda im: [p if p[3] else (0, 0, 0, 0) for p in im.get_flattened_data()]  # noqa: E731

    def shipped(name: str) -> Image.Image:
        assert name in names, f"{name} missing from pack"
        _, x, y, w, h, ox, oy, fx, fy = names[name]
        assert (fx, fy) == (CELL_W, CELL_H)
        cell = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
        cell.paste(page["image"].convert("RGBA").crop((x, y, x + w, y + h)), (ox, oy))
        return cell

    for i, (rels, props) in tiles.items():
        name = f"{TILESET}_{i}"
        assert ts["tiles"][i] == props, (name, ts["tiles"][i])
        cell, src = shipped(name), load_cell(rels)
        if src.getbbox():
            assert vis(cell) == vis(src), f"{name}: pixels differ from {rels}"
        sid = pzfmt.sprite_id(FILE_NUMBER, ts["number"], i)
        print(f"  {name:32s} id {sid:8d} bbox {cell.getbbox()}  {props.get('GarageDoor', 'cabinet')}")
    # reader: 4 sprites, NO properties at all (no collision/door/solid/moveable flag), pixels = the rendered cells
    rs = tsets[1]
    assert rs["tiles"] == [{} for _ in READER_XFORM], rs["tiles"]
    for i in READER_XFORM:
        name = f"{READER_TILESET}_{i}"
        cell = shipped(name)
        assert cell.getbbox() and vis(cell) == vis(reader_cell(i)), f"{name}: pixels differ from cells/reader"
        print(f"  {name:32s} id {pzfmt.sprite_id(FILE_NUMBER, rs['number'], i):8d} bbox {cell.getbbox()}  props none")
    # garage rules: open = closed + 8 with GarageDoor + 3 (IsoDoor.java:793-805, 3212-3238)
    for i in (0, 1, 2, 3, 4, 5):
        c, o = ts["tiles"][i], ts["tiles"][i + 8]
        assert int(o["GarageDoor"]) == int(c["GarageDoor"]) + 3
        assert not ({"WallN", "WallW", "collideN", "collideW", "solid", "solidtrans", "DoorWallN", "DoorWallW",
                     "cutN", "cutW"} & c.keys())
    # spriteModels: every referenced closed/open/cabinet index exists in the tiledef; model names are scripted
    sm_all = (COMMON / "spriteModels.txt").read_text(encoding="ascii")
    assert sm_all == sprite_models(), "spriteModels.txt is stale: rerun the builder"
    _, sm, sm_reader = sm_all.split("    tileset\n")    # per-tileset blocks: indices restart at 0 in each
    assert f"name = {TILESET}," in sm and f"name = {READER_TILESET}," in sm_reader
    assert MODELS_SCRIPT.read_text(encoding="ascii") == MODEL_SCRIPT, "model script is stale"
    ent = ENTITY_SCRIPT.read_text(encoding="ascii")
    assert ent == entity_script(), "entity script is stale"
    assert sm_all.count("{") == sm_all.count("}") and "VERSION = 1" in sm_all
    models = set(re.findall(r"model (\w+)", MODEL_SCRIPT))
    for col, row, model in re.findall(r"xy = (\d+) (\d+),\s*modelScript = Base\.(\w+)", sm):
        idx = int(col) + 8 * int(row)
        assert model in models, model
        assert idx in tiles or idx >= FRAME_BASE, idx
    for idx in tiles:
        assert f"xy = {idx % 8} {idx // 8}," in sm, f"tile {idx} has no spriteModel"
    # lamp: green texture exactly on the open anchors and the opening poses, red default on closed + closing poses
    blocks = {int(c) + 8 * int(r): b for c, r, b in re.findall(r"xy = (\d+) (\d+),(.*?)\n        }", sm, re.S)}
    poses = lambda off: {FRAME_BASE + d * 16 + off + f for d in (0, 1) for f in range(FRAMES + 1)}  # noqa: E731
    green, red = {8, 11} | poses(0), {0, 3} | poses(CLOSE_OFFSET)
    arms = {i for i, b in blocks.items() if "BarrierArm" in b}
    assert arms == green | red and not green & red, sorted(arms)
    for i in arms:
        assert (f"texture = {GREEN}," in blocks[i]) == (i in green), (i, blocks[i])
    assert all("BarrierLines" in blocks[i] for i in (1, 9, 4, 12)) and all("BarrierEmpty" in blocks[i] for i in (2, 10, 5, 13))
    assert (MEDIA / "textures" / f"{GREEN}.png").exists()
    # reader: one static model per variant on the post (host NW corner), rotated per edge/end, no animation
    rblocks = {int(c) + 8 * int(r): b for c, r, b in re.findall(r"xy = (\d+) (\d+),(.*?)\n        }", sm_reader, re.S)}
    assert sorted(rblocks) == sorted(READER_XFORM), sorted(rblocks)
    for i, rot in READER_XFORM.items():
        b = rblocks[i]
        assert (f"modelScript = Base.{READER_MODEL}," in b and f"translate = {fmt3(READER_T)}," in b
                and f"rotate = {fmt3(rot)}," in b and "animation" not in b), (i, b)
    assert READER_MODEL in models
    assert re.search(rf"model {READER_MODEL}\s*{{[^}}]*static = true,", MODEL_SCRIPT)
    assert (MEDIA / "textures" / "WorldItems" / "MinidoracatKnoxPassReader.png").exists()
    # entity: every sprite token is a tiledef sprite, no duplicates (SpriteConfigManager duplicate rule)
    toks = re.findall(rf"{TILESET}_(\d+)", ent)
    assert len(toks) == len(set(toks)) == 8 and all(int(t) in tiles for t in toks), toks
    for src, dst in assets():
        assert dst.read_bytes() == src.read_bytes(), f"{dst.name} differs from {src}"
    assert ICON.exists() and KIT_ICON.exists()
    info = (OUT / "42" / "mod.info").read_text(encoding="utf-8").splitlines()
    assert f"pack={PACK}" in info and f"tiledef={TILEDEF} {FILE_NUMBER}" in info, "mod.info lacks pack=/tiledef="
    print(f"OK: pack {len(page['entries'])} entries ({page['image'].size}), tiledef {len(ts['tiles'])} + "
          f"{len(rs['tiles'])} tiles, spriteModels {sm_all.count('tile' + chr(10))} tiles, entity 8 sprites, "
          "assets and mod.info match")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    (check if ap.parse_args().check else build)()
