# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Knox Pass boom barrier + door-post reader + roll doors: Blender cells/exports + vanilla sprites -> .pack + .tiles +
spriteModels.txt + model/entity scripts in MOD/.

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
                  base + pose (+ CLOSE_OFFSET while the door is closed). spriteModels-only: no 2D cell, no properties
                  (SpriteModels.toScriptManager registers them by name, SpriteModels.java:81-96)
    + MIRROR (80)    S / E = the N / W barrier turned 180 deg (cabinet at the other end): 80-82 S lanes, 83-85 E lanes,
                  86 S cabinet, 87 E cabinet, 88-93 open lanes, poses 96-104 / 112-120 / 128-136 / 144-152
    + PLACEHOLDER (160)  build-only lane tiles of real lanes 0..5 and 80..85 (160-165, 240-245): doorN/doorW but NO
                  GarageDoor / doorTrans / spriteModel, so mods that take over ISBuildIsoEntity:setInfo for GarageDoor
                  sprites leave our build alone; Lua OnCreate swaps each for the real lane door

Every index up to the highest (245) is a tiledef entry (IsoWorld.java:700-716 makes a sprite per entry); the ones not
listed above carry no properties and no 2D cell.

lane1 = GarageDoor 1 = chain anchor (min x for N-edge doors, max y for W-edge doors: IsoDoor.getGarageDoorPrev/Next,
IsoDoor.java:3241-3342). N/W: lane1 is next to the cabinet. S/E: doors exist only on N/W edges, so after the 180 deg
turn the gate line is the SOUTH edge of the entity row / EAST edge of the column and Lua builds the real lane doors one
row south (N-edge doors of row y+1) / one column east (W-edge doors of column x+1); lane1 is the far end:

    S entity row  x0..x0+3: 240 241 242 86 (lane1 lane2 lane3 cabinet); real S lane k door at (x0+k-1, y+1)
    E entity rows y0..y0+3: 87 245 244 243 (cabinet lane3 lane2 lane1); real E lane k door at (x+1, y0+4-k)

lane1 carries the arm model (arm, STOP sign, pivot lamp, tip post); lane2 carries the road-paint model (stop lines +
KNOX PASS on both sides of the gate line); lane3 carries an empty model. Every model's origin is the cabinet tile
centre (spriteModels translate = offset from the lane to the cabinet). 2D cells of N/W lanes and of the placeholders
(arm segments in the entity row/column) only show in the build-cursor ghost (ISBuildIsoEntity.lua:823-837 draws 2D
only) and in the non-FBO fallback (IsoObject.java:6301-6302); the real S/E lanes sit one row/column away from the
visible barrier, so their 2D cells are empty.

Lamp colour = texture of the spriteModel being drawn: both IsoObjectModelDrawer.renderMain overloads (static and
animated, IsoObjectModelDrawer.java:134-139, 285-290) bind spriteModel.textureName over the model script texture
(:563-566), and IsoObject.renderModel passes the object's current getSpriteModel() even while an animation plays
(IsoObject.java:6280-6298, 6368-6385). So the open tile (sprite switched before the Open clip plays) and the opening
poses draw green, the closed tile and closing poses draw the red default. Vanilla does the same on animated doors
(spriteModels.txt:774-822, texture = fixtures_doors_02_22).

Door-post reader (tileset MinidoracatKnoxPass_reader, tileset number 2 in the same .tiles / pack / file number):

    index = colour * 8 + variant; colour = scripts/blender/build.py COLORS order (0 Cream .. 6 Red, = Lua KP.COLORS)
    variant 0 N door, post at its west end   1 N door, post at its east end   2 W door, north end   3 W door, south end

One static model (knoxpass_reader_post.glb, both faces of the wall line) on the tile whose NW corner is the post,
rotated per variant (READER_XFORM; render_tiles.py READER_XFORM draws the 2D cells with the same values); the tile's
spriteModel texture = that colour's reader item texture (same UV layout, the lamp-colour mechanism above). The tiles
carry NO properties at all: no collision / door / solid flags (IsoChunk physics shapes and IsoSprite.shouldHaveCollision
read only flags, IsoChunk.java:2056-2111, IsoSprite.java:2083-2092; AutoDrive classifySprite then returns COST_NONE,
MDAD_Sensor.lua:390-457), no IsMoveAble (not pick-up-able), not an IsoThumpable (not dismantlable). Placement,
removal and self-repair: server/MinidoracatKnoxPass/ReaderPost.lua.
2D cells: every colour's sprite points at the Cream cell of its variant (same pack rect). The game draws the 3D model;
the 2D cell only shows in the non-FBO fallback (IsoObject.java:6301-6302), and these tiles are placed by Lua, never
through the build cursor ghost, so per-colour cells would only grow the pack page.

Roll doors (tileset MinidoracatKnoxPass_rolldoor, tileset number 3): build-only placeholders for vanilla roller garage
doors; Lua OnCreate (MinidoracatKnoxPass.RollDoor.onCreate) swaps each for an IsoDoor with the vanilla sprite.

    index = style * 64 + slot; style 0 Industry (industry_trucks_01), 1 Green / 2 White (walls_garage_01)
    slots 0-2 N, 3-5 W (3 wide: GarageDoor 1,2,3); 8-11 N, 12-15 W (4 wide: 1,2,2,3); 16-21 N, 22-27 W
    (6 wide: 1,2,2,2,2,3); 32-40 N, 41-49 W (9 wide: 1, 2 x7, 3). The engine chain takes any number of middle
    pieces: getGarageDoorNext looks for the next piece with GarageDoor >= its own (IsoDoor.java:3282-3321)

Every entity needs its own sprites (SpriteConfigManager rejects duplicates), hence one slot per piece. Props doorN/doorW
CustomName only (no GarageDoor: the setInfo takeover above). 2D cell = the vanilla closed 2x sprite (slots with the
same piece share one pack rect); no spriteModels. Entities: entity_knoxpass_rolldoor.txt, icons rolldoor_<style>_<w>.png.

Pack: one page, unique 2D cells laid out in sequence (8 per row); sprites with the same source cell share a rect.
"""
from __future__ import annotations

import argparse
import importlib.util
import io
import re
import shutil
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pzfmt  # noqa: E402
import build_model_gates as MG  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
BLENDER = REPO / "scripts" / "blender" / "barrier"
CELLS = BLENDER / "cells"
OUT = REPO / "MOD/MinidoracatKnoxPassFor42/Contents/mods/MinidoracatKnoxPassFor42"
MEDIA = OUT / "42" / "media"
COMMON = OUT / "common" / "media"
MODELS_SCRIPT = MEDIA / "scripts" / "models_knoxpass_barrier.txt"
ENTITY_SCRIPT = MEDIA / "scripts" / "entities" / "entity_knoxpass_barrier.txt"
ROLLDOOR_SCRIPT = MEDIA / "scripts" / "entities" / "entity_knoxpass_rolldoor.txt"
GAME = Path("D:/SteamLibrary/steamapps/common/ProjectZomboid/media")   # same install as blender/barrier/*.py

PACK = "MinidoracatKnoxPass"
TILEDEF = "MinidoracatKnoxPass_tiles"
FILE_NUMBER = 7430                           # 100..8189, unique across enabled mods (ChooseGameInfo.java:311,
                                             # ZomboidFileSystem.java:1000-1002); not used by any of the 418
                                             # local Workshop items; family Economy uses 7429
TILESET = "MinidoracatKnoxPass_barrier"
CELL_W, CELL_H = 128, 256
NAME = "Knox Pass Boom Barrier"
READER_TILESET = "MinidoracatKnoxPass_reader"
READER_MODEL = "MinidoracatKnoxPass_ReaderPost"
# translate = host tile NW corner (the post); rotate turns model +X (into the door opening) per variant:
# 0 east, 1 west, 2 south, 3 north (engine formula: render_tiles.py pz_matrix; see the barrier XFORM note below)
READER_T = (-0.5, 0.0, -0.5)
READER_XFORM = {0: (0.0, 180.0, 0.0), 1: (0.0, 0.0, 0.0), 2: (0.0, 90.0, 0.0), 3: (0.0, -90.0, 0.0)}
_spec = importlib.util.spec_from_file_location("kpbuild", REPO / "scripts" / "blender" / "build.py")
KP = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(KP)                   # the one colour table (build.py COLORS)
READER_STRIDE = 8                              # index = colour * 8 + variant (one row per colour)
READER_TILES = {c * READER_STRIDE + v: (c, v) for c in range(len(KP.COLORS)) for v in READER_XFORM}

MIRROR = 80                  # Lua KP.BARRIER_MIRROR: S / E tile = N / W tile + 80
PLACEHOLDER = 160            # Lua KP.BARRIER_PLACEHOLDER: build-only lane tile = real lane tile + 160

ROLLDOOR_TILESET = "MinidoracatKnoxPass_rolldoor"     # Lua KP.ROLLDOOR_TILESET, tileset number 3
ROLLDOOR_NAME = "Knox Pass Roll Door"
# style: (entity token, vanilla tileset, GarageDoor 1 sprite index of the N piece, of the W piece); GD k = base + k - 1
ROLLDOOR_STYLES = (("Industry", "industry_trucks_01", 35, 32), ("Green", "walls_garage_01", 19, 16),
                   ("White", "walls_garage_01", 51, 48))
ROLLDOOR_STRIDE = 64                                  # Lua Barrier.lua R.sprite: index = style * 64 + slot
ROLLDOOR_PIECES = {3: (1, 2, 3), 4: (1, 2, 2, 3), 6: (1, 2, 2, 2, 2, 3), 9: (1, 2, 2, 2, 2, 2, 2, 2, 3)}
ROLLDOOR_SLOTS = {3: (0, 3), 4: (8, 12), 6: (16, 22), 9: (32, 41)}   # width -> first N slot, first W slot


def reader_tex(c: int) -> str:
    return f"WorldItems/MinidoracatKnoxPassReader{KP.suffix(KP.COLORS[c][0])}"


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
        "Facing": edge,
        "CustomName": NAME,
        "firerequirement": "900000",
    }


# index -> (cell files composited bottom-up under cells/, props)
def layout() -> dict[int, tuple[tuple[str, ...], dict]]:
    t: dict[int, tuple[tuple[str, ...], dict]] = {}
    for base, edge in ((0, "N"), (3, "W")):
        for k in (1, 2, 3):
            t[base + k - 1] = ((f"{edge}/lane{k}_closed.png",), lane_props(edge, k, False))
            t[base + k - 1 + 8] = ((f"{edge}/lane{k}_open.png",), lane_props(edge, k, True))
            # S / E real lanes: same chain edge as N / W, one row / column off the visible barrier -> empty 2D
            t[MIRROR + base + k - 1] = ((), lane_props(edge, k, False))
            t[MIRROR + base + k - 1 + 8] = ((), lane_props(edge, k, True))
    # the pivot lamp and the arm root sit in the cabinet tile but belong to the arm model: the cabinet cell is the
    # depth-correct cabinet + closed arm render (render_tiles.py cabinet_ghost)
    for i, edge in ((6, "N"), (7, "W"), (MIRROR + 6, "S"), (MIRROR + 7, "E")):
        t[i] = ((f"{edge}/cabinet_ghost_closed.png",), cabinet_props(edge))
    # placeholders: N / W reuse the lane cells; S / E show the arm in the entity row / column (render_tiles.py S / E)
    for real in (0, 1, 2, 3, 4, 5):
        edge, k = "NNNWWW"[real], real % 3 + 1
        cells = {0: t[real][0], MIRROR: (f"{'S' if edge == 'N' else 'E'}/lane{k}_closed.png",)}
        for m, rels in cells.items():
            t[PLACEHOLDER + m + real] = (rels, {f"door{edge}": "", "CustomName": NAME, "firerequirement": "900000"})
    return t


# index -> (vanilla sprite drawn as its 2D cell, props). No GarageDoor (setInfo takeover), no wall flags: Lua swaps the
# placeholder for an IsoDoor with the vanilla sprite, which carries the vanilla door properties.
def rolldoor_layout() -> dict[int, tuple[str, dict]]:
    t = {}
    for s, (_, ts, n_base, w_base) in enumerate(ROLLDOOR_STYLES):
        for w, (n0, w0) in ROLLDOOR_SLOTS.items():
            for j, gd in enumerate(ROLLDOOR_PIECES[w]):
                for slot, edge, base in ((n0 + j, "N", n_base), (w0 + j, "W", w_base)):
                    t[s * ROLLDOOR_STRIDE + slot] = (f"{ts}_{base + gd - 1}",
                                                     {f"door{edge}": "", "CustomName": ROLLDOOR_NAME})
    return t


# spriteModels transforms. Starting point = vanilla wood fence gate (spriteModels.txt:1170-1220);
# IsoObjectModelDrawer.renderMain applies translate(-tx/1.5, ty/1.5, tz/1.5)*rotateXYZ(rx,-ry,rz) at the tile centre.
# Values from blender/render_tiles.py, which places the glbs with the engine formula validated against the
# vanilla fence gate (closed tiles within 1-2 px of the shipped 2D sprites; cells/cells.txt). Static models
# (cabinet, empty) were not calibrated; confirm live with the SpriteModel editor (IngameState.java:1455).
# lane k hosts a model whose origin is the cabinet tile centre: translate = (dx, 0, dy) from the lane to the cabinet.
# S / E (rotate +180 deg): rotate (0,0,0) maps model +X -> PZ west, +Y -> south; (0,90,0) +X -> south, +Y -> east.
# Their real lanes sit one row south / column east of the cabinet row / column (module docstring), hence the -1.
XFORM = {
    "N": {"rotate": (0.0, 180.0, 0.0), "cabinet": (0.0, 0.0, 0.0), "arm": (-1.0, 0.0, 0.0), "lines": (-2.0, 0.0, 0.0)},
    "W": {"rotate": (0.0, -90.0, 0.0), "cabinet": (0.0, 0.0, 0.0), "arm": (0.0, 0.0, 1.0), "lines": (0.0, 0.0, 2.0)},
    "S": {"rotate": (0.0, 0.0, 0.0), "cabinet": (0.0, 0.0, 0.0), "arm": (3.0, 0.0, -1.0), "lines": (2.0, 0.0, -1.0)},
    "E": {"rotate": (0.0, 90.0, 0.0), "cabinet": (0.0, 0.0, 0.0), "arm": (-1.0, 0.0, -3.0), "lines": (-1.0, 0.0, -2.0)},
}
FRAMES = 8                                   # SP stepper poses per direction (Open clip, t = k/FRAMES)
FRAME_BASE = 16
CLOSE_OFFSET = 32                            # closing (red) poses = opening pose index + 32
GREEN = "IsoObject/MinidoracatKnoxPass_barrier_green"   # media/textures/<GREEN>.png (IsoObjectModelDrawer.java:138)
# edge -> (closed lane1 index, cabinet index, first opening pose index)
EDGES = {"N": (0, 6, FRAME_BASE), "W": (3, 7, FRAME_BASE + 16),
         "S": (MIRROR, MIRROR + 6, MIRROR + FRAME_BASE), "E": (MIRROR + 3, MIRROR + 7, MIRROR + FRAME_BASE + 16)}


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
    for edge, (base, cab, _) in EDGES.items():
        x = XFORM[edge]
        # closed lane1 shows frame 0 of Open (arm down, red lamp); open lane1 shows frame 0 of Close (arm up, green)
        body += sm_tile(base, "MinidoracatKnoxPass_BarrierArm", x["arm"], x["rotate"], "Open")
        body += sm_tile(base + 8, "MinidoracatKnoxPass_BarrierArm", x["arm"], x["rotate"], "Close", texture=GREEN)
        for idx in (base + 1, base + 9):
            body += sm_tile(idx, "MinidoracatKnoxPass_BarrierLines", x["lines"], x["rotate"], None)
        for idx in (base + 2, base + 10):
            body += sm_tile(idx, "MinidoracatKnoxPass_BarrierEmpty", (0, 0, 0), (0, 0, 0), None)
        body += sm_tile(cab, "MinidoracatKnoxPass_BarrierCabinet", x["cabinet"], x["rotate"], None)
    for edge, (_, _, pose) in EDGES.items():
        x = XFORM[edge]
        for off, tex in ((0, GREEN), (CLOSE_OFFSET, None)):
            for f in range(FRAMES + 1):
                body += sm_tile(pose + off + f, "MinidoracatKnoxPass_BarrierArm", x["arm"], x["rotate"],
                                "Open", f / FRAMES, tex)
    tiles = "".join(sm_tile(i, READER_MODEL, READER_T, READER_XFORM[v], None, texture=reader_tex(c))
                    for i, (c, v) in READER_TILES.items())
    return ("spriteModel\n{\n    VERSION = 1,\n\n    tileset\n    {\n"
            f"        name = {TILESET},\n\n" + body + "    }\n\n    tileset\n    {\n"
            f"        name = {READER_TILESET},\n\n" + tiles + "    }\n"
            + "".join("\n" + t for t in MG.sprite_model_tilesets()) + "}\n")


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


# entity faces: rows top -> bottom (north -> south), sprites west -> east
BARRIER_FACES = {"N": ((6, 160, 161, 162),), "W": ((165,), (164,), (163,), (7,)),
                 "S": ((240, 241, 242, 86),), "E": ((87,), (245,), (244,), (243,))}


def faces(tileset: str, rows_by_face: dict) -> str:
    out = []
    for f, rows in rows_by_face.items():
        body = "".join(f"                    row = {' '.join(f'{tileset}_{i}' for i in r)},\n" for r in rows)
        out.append(f"            face {f}\n            {{\n                layer\n                {{\n{body}"
                   "                }\n            }\n")
    return "\n".join(out)


def entity_script() -> str:
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
            health = 1000,
            skillBaseHealth = 0,
            dontNeedFrame = true,
            OnCreate = MinidoracatKnoxPass.Barrier.onCreate,

{faces(TILESET, BARRIER_FACES)}        }}

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


# width -> (time, xp, blowtorch uses, welding rods, sheet metal, metal pipes, hinges); recipe syntax and timed action
# from vanilla generated/entities/walls/entity_metal_doorlvl2.txt. 6 and 9 wide = 2 and 3 cars (2026-10-08 user design)
ROLLDOOR_RECIPE = {3: (300, 30, 6, 6, 4, 4, 4), 4: (400, 40, 8, 8, 5, 5, 5), 6: (600, 60, 12, 12, 8, 8, 8),
                   9: (900, 90, 18, 18, 12, 12, 12)}


def rolldoor_entities() -> dict[str, tuple[int, int, dict]]:
    """entity name -> (style, width, faces); never "GarageDoor" in a name (other mods match on it)."""
    out = {}
    for s, (style, *_) in enumerate(ROLLDOOR_STYLES):
        for w, (n0, w0) in ROLLDOOR_SLOTS.items():
            n = len(ROLLDOOR_PIECES[w])
            out[f"MinidoracatKnoxPassRollDoor{style}{w}"] = (s, w, {
                "N": (tuple(s * ROLLDOOR_STRIDE + n0 + j for j in range(n)),),
                "W": tuple((s * ROLLDOOR_STRIDE + w0 + j,) for j in reversed(range(n)))})   # anchor (GD1) = max y
    return out


def rolldoor_icon(s: int, w: int) -> Path:
    return MEDIA / "ui" / "MinidoracatKnoxPass" / f"rolldoor_{ROLLDOOR_STYLES[s][0].lower()}_{w}.png"


def rolldoor_script() -> str:
    skins, ents = [], []
    for name, (s, w, fc) in rolldoor_entities().items():
        style = f"ES_{name}"
        time, xp, torch, rods, sheet, pipe, hinge = ROLLDOOR_RECIPE[w]
        skins.append(f"""        entity {style}
        {{
            LuaWindowClass = ISEntityWindow,
            DisplayName = IGUI_KnoxPass_RollDoor_{ROLLDOOR_STYLES[s][0]}{w},
            Icon = {rolldoor_icon(s, w).relative_to(MEDIA.parent).as_posix()},
        }}
""")
        ents.append(f"""    entity {name}
    {{
        component UiConfig
        {{
            xuiSkin = default,
            entityStyle = {style},
            uiEnabled = false,
        }}

        component SpriteConfig
        {{
            dontNeedFrame = true,
            OnCreate = MinidoracatKnoxPass.RollDoor.onCreate,

{faces(ROLLDOOR_TILESET, fc)}        }}

        component CraftRecipe
        {{
            timedAction = BuildWallMetal,
            time = {time},
            category = Welding,
            SkillRequired = MetalWelding:3,
            xpAward = MetalWelding:{xp},
            inputs
            {{
                item {torch} [Base.BlowTorch] flags[DontRecordInput],
                item {rods} [Base.WeldingRods] flags[DontRecordInput],
                item {sheet} [Base.SheetMetal],
                item {pipe} [Base.MetalPipe],
                item {hinge} [Base.Hinge],
            }}
        }}
    }}
""")
    return "module Base\n{\n    xuiSkin default\n    {\n" + "\n".join(skins) + "    }\n\n" + "\n".join(ents) + "}\n"


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


def vanilla_cells(names: set[str]) -> dict[str, Image.Image]:
    """Full 128x256 cells of vanilla 2x sprites from Tiles2x.pack (blender/barrier/extract_vanilla_sprites.py reader,
    TexturePackPage.java:103-151); decodes only the pages that hold one of the names."""
    data = (GAME / "texturepacks" / "Tiles2x.pack").read_bytes()
    r = pzfmt._R(data, 4)
    assert r.i() == 1
    out = {}
    for _ in range(r.i()):
        r.s()
        n, _mask = r.i(), r.i()
        hits = [e for e in ((r.s(), *[r.i() for _ in range(8)]) for _ in range(n)) if e[0] in names]
        plen = r.i()
        if hits:
            page = Image.open(io.BytesIO(data[r.p:r.p + plen])).convert("RGBA")
            for name, x, y, w, h, ox, oy, fx, fy in hits:
                assert (fx, fy) == (CELL_W, CELL_H), (name, fx, fy)
                out[name] = Image.new("RGBA", (fx, fy), (0, 0, 0, 0))
                out[name].paste(page.crop((x, y, x + w, y + h)), (ox, oy))
        r.p += plen
    if names - out.keys():
        raise SystemExit(f"vanilla sprites not in Tiles2x.pack: {sorted(names - out.keys())}")
    return out


def sprite_sources() -> dict[str, tuple[str, ...] | str]:
    """pack sprite name -> 2D source: files under cells/ composited (() = transparent) or a vanilla sprite name.
    Sprites with the same source share one pack rect. Every tile with properties gets an entry."""
    src: dict = {f"{TILESET}_{i}": rels for i, (rels, _) in layout().items()}
    # reader: every colour points at the Cream cell of its variant (docstring: 2D is fallback only)
    src |= {f"{READER_TILESET}_{i}": (f"reader/reader_{v}.png",) for i, (_, v) in READER_TILES.items()}
    src |= {f"{ROLLDOOR_TILESET}_{i}": sprite for i, (sprite, _) in rolldoor_layout().items()}
    src |= {f"{ts}_{i}": rels for ts, t in MG.layout().items() for i, (rels, _) in t.items()}
    return src


def source_cells(keys) -> dict:
    van = vanilla_cells({k for k in keys if isinstance(k, str)})
    return {k: van[k] if isinstance(k, str) else load_cell(k) for k in keys}


def tileset(name: str, number: int, props: dict[int, dict], count: int | None = None) -> dict:
    n = count or max(props) + 1
    return {"name": name, "image": f"{name}.png", "w": 8, "h": -(-n // 8), "number": number,
            "tiles": [props.get(i, {}) for i in range(n)]}


def tilesets() -> list[dict]:
    mg = MG.layout()
    return [tileset(TILESET, 1, {i: p for i, (_, p) in layout().items()}),
            tileset(READER_TILESET, 2, dict.fromkeys(range(max(READER_TILES) + 1), {})),
            tileset(ROLLDOOR_TILESET, 3, {i: p for i, (_, p) in rolldoor_layout().items()}),
            *(tileset(name, number, {i: p for i, (_, p) in mg[name].items()}, count)
              for name, number, count in MG.tileset_specs())]


def fit_icon(img: Image.Image, size: int) -> Image.Image:
    img = img.crop(img.getbbox())
    s = (size - 2) / max(img.size)
    img = img.resize((max(1, round(img.width * s)), max(1, round(img.height * s))), Image.LANCZOS)
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(img, ((size - img.width) // 2, (size - img.height) // 2), img)
    return icon


def rolldoor_door(s: int, w: int, van: dict[str, Image.Image]) -> Image.Image:
    """The closed N pieces as one door: next piece +64 px right, +32 px down at 2x."""
    _, ts, n_base, _ = ROLLDOOR_STYLES[s]
    img = Image.new("RGBA", (CELL_W + 64 * (w - 1), CELL_H + 32 * (w - 1)), (0, 0, 0, 0))
    for j, gd in enumerate(ROLLDOOR_PIECES[w]):
        img.alpha_composite(van[f"{ts}_{n_base + gd - 1}"], (64 * j, 32 * j))
    return img


PAGE_CELLS = 8 * 16          # cells per pack page: 1024 x 4096 px at most


def build() -> None:
    src = sprite_sources()
    keys = list(dict.fromkeys(src.values()))                 # unique cells, first-seen order
    cells = source_cells(keys)
    # pages of unique cells in sequence, 8 per row (sheet keeps full cells; entries store the trimmed rect)
    sheets, rect = [], {}
    for p0 in range(0, len(keys), PAGE_CELLS):
        chunk = keys[p0:p0 + PAGE_CELLS]
        sheet = Image.new("RGBA", (CELL_W * 8, CELL_H * -(-len(chunk) // 8)), (0, 0, 0, 0))
        for j, k in enumerate(chunk):
            x, y = j % 8 * CELL_W, j // 8 * CELL_H
            sheet.paste(cells[k], (x, y))
            x0, y0, x1, y1 = cells[k].getbbox() or (0, 0, 1, 1)   # fully transparent cell keeps a 1x1 rect
            rect[k] = (len(sheets), (x + x0, y + y0, x1 - x0, y1 - y0, x0, y0, CELL_W, CELL_H))
        sheets.append(sheet)
    entries = [[] for _ in sheets]
    for name, k in src.items():
        entries[rect[k][0]].append((name, *rect[k][1]))
    (MEDIA / "texturepacks").mkdir(parents=True, exist_ok=True)
    (MEDIA / "texturepacks" / f"{PACK}.pack").write_bytes(
        pzfmt.write_pack([(f"{PACK}{i}", sheet, entries[i]) for i, sheet in enumerate(sheets)]))
    (MEDIA / f"{TILEDEF}.tiles").write_bytes(pzfmt.write_tiles(tilesets()))
    COMMON.mkdir(parents=True, exist_ok=True)
    (COMMON / "spriteModels.txt").write_text(sprite_models(), encoding="ascii", newline="\n")
    ENTITY_SCRIPT.parent.mkdir(parents=True, exist_ok=True)
    MODELS_SCRIPT.write_text(MODEL_SCRIPT, encoding="ascii", newline="\n")
    ENTITY_SCRIPT.write_text(entity_script(), encoding="ascii", newline="\n")
    ROLLDOOR_SCRIPT.write_text(rolldoor_script(), encoding="ascii", newline="\n")
    MG.write()
    # meshes (media/models_X, .fbx -> .glb -> .x lookup: FileTask_AbstractLoadModel.java:89-110), model textures and
    # the r4 build-menu icons (rendered by the Blender deliverables)
    for src_path, dst in assets() + MG.assets():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src_path, dst)
    # build-menu icons (xuiSkin Icon = file path, 64 px) and the kit's item icon (Icon = X -> textures/Item_X.png,
    # 32 px like the other Knox Pass items): barrier from the transparent N closed render, roll doors from the
    # vanilla closed N pieces
    full = Image.open(BLENDER / "previews" / "N_closed_full.png").convert("RGBA")
    icons = [(ICON, fit_icon(full, 64)), (KIT_ICON, fit_icon(full, 32))]
    icons += [(rolldoor_icon(s, w), fit_icon(rolldoor_door(s, w, cells), 64))
              for s, w, _ in rolldoor_entities().values()]
    for path, icon in icons:
        path.parent.mkdir(parents=True, exist_ok=True)
        icon.save(path, optimize=True)
    print(f"wrote {len(src)} sprites ({len(keys)} cells, {len(sheets)} pages), tiledef {TILEDEF} {FILE_NUMBER}, "
          f"spriteModels, model + entity scripts, {len(assets() + MG.assets())} assets, {len(icons)} icons; "
          f"mod.info needs: pack={PACK} / tiledef={TILEDEF} {FILE_NUMBER}")


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


def sm_blocks(text: str) -> dict[int, dict[str, str]]:
    """spriteModels tileset block -> {index: {key: value}}."""
    return {int(c) + 8 * int(r): dict(re.findall(r"(\w+) = ([^,\n]+),", b))
            for c, r, b in re.findall(r"xy = (\d+) (\d+),(.*?)\n        }", text, re.S)}


def entity_faces(body: str, tileset: str) -> dict[str, list[tuple[int, ...]]]:
    out = {}
    for f, layer in re.findall(r"face (\w+)\s*\{\s*layer\s*\{(.*?)\}", body, re.S):
        rows = re.findall(r"row = ([^,]+),", layer)
        assert all(t.startswith(f"{tileset}_") for r in rows for t in r.split()), rows
        out[f] = [tuple(int(t.rsplit("_", 1)[1]) for t in r.split()) for r in rows]
    return out


def check() -> None:
    # ---- the contract, written out literally (Lua Core.lua / Barrier.lua depend on these numbers) ----
    lanes = (("N", 1), ("N", 2), ("N", 3), ("W", 1), ("W", 2), ("W", 3))          # real lane index 0..5
    lane = lambda e, k, o: {f"door{e}": "", "GarageDoor": str(k + 3 * o), "doorTrans": "",  # noqa: E731
                            "CustomName": NAME, "firerequirement": "900000"}
    cabinet = lambda f: {"solid": "", "BlocksPlacement": "", "Facing": f,  # noqa: E731
                         "CustomName": NAME, "firerequirement": "900000"}
    want_props, want_2d = {}, {}
    for i, (e, k) in enumerate(lanes):
        for m in (0, 80):                       # 80 = S / E (KP.BARRIER_MIRROR): same chain edge, empty 2D
            want_props[m + i], want_props[m + i + 8] = lane(e, k, 0), lane(e, k, 1)
            want_props[160 + m + i] = {f"door{e}": "", "CustomName": NAME, "firerequirement": "900000"}
        want_2d |= {i: (f"{e}/lane{k}_closed.png",), i + 8: (f"{e}/lane{k}_open.png",), 80 + i: (), 88 + i: (),
                    160 + i: (f"{e}/lane{k}_closed.png",), 240 + i: (f"{'S' if e == 'N' else 'E'}/lane{k}_closed.png",)}
    for i, f in ((6, "N"), (7, "W"), (86, "S"), (87, "E")):
        want_props[i], want_2d[i] = cabinet(f), (f"{f}/cabinet_ghost_closed.png",)
    assert MIRROR == 80 and PLACEHOLDER == 160
    assert {i: p for i, (_, p) in layout().items()} == want_props, "barrier props differ from the contract"
    assert {i: r for i, (r, _) in layout().items()} == want_2d, "barrier 2D cells differ from the contract"
    # roll doors: style -> (vanilla tileset, N GD1 sprite, W GD1 sprite); slot -> (edge, GarageDoor k)
    styles = (("Industry", "industry_trucks_01", 35, 32), ("Green", "walls_garage_01", 19, 16),
              ("White", "walls_garage_01", 51, 48))
    stride = 64
    pieces = {3: (1, 2, 3), 4: (1, 2, 2, 3), 6: (1, 2, 2, 2, 2, 3), 9: (1, 2, 2, 2, 2, 2, 2, 2, 3)}
    first = {3: (0, 3), 4: (8, 12), 6: (16, 22), 9: (32, 41)}
    slots = {}
    for wd, (n0, w0) in first.items():
        for j, k in enumerate(pieces[wd]):
            slots[n0 + j], slots[w0 + j] = ("N", k), ("W", k)
    want_rd = {s * stride + slot: (f"{ts}_{(n if e == 'N' else w) + k - 1}", {f"door{e}": "", "CustomName": ROLLDOOR_NAME})
               for s, (_, ts, n, w) in enumerate(styles) for slot, (e, k) in slots.items()}
    assert rolldoor_layout() == want_rd, "roll door layout differs from the contract"
    # vanilla pieces really are closed garage doors of that edge and chain position
    vt = {t["name"]: t["tiles"] for t in pzfmt.read_tiles((GAME / "newtiledefinitions.tiles").read_bytes(), 10**5, 10**5)}
    for i, (sprite, _) in want_rd.items():
        ts, idx = sprite.rsplit("_", 1)
        e, k = slots[i % stride]
        vp = vt[ts][int(idx)]
        assert f"door{e}" in vp and vp.get("GarageDoor") == str(k), (sprite, vp)

    # ---- .tiles ----
    tsets = pzfmt.read_tiles((MEDIA / f"{TILEDEF}.tiles").read_bytes())
    assert tsets == tilesets(), "tiledef is stale: rerun the builder"
    assert [(t["name"], t["w"], t["h"], t["number"], len(t["tiles"])) for t in tsets[:3]] == [
        (TILESET, 8, 31, 1, 246), (READER_TILESET, 8, len(KP.COLORS), 2, max(READER_TILES) + 1),
        (ROLLDOOR_TILESET, 8, 23, 3, 2 * 64 + 50)], tsets   # last slot: White (style 2) 9-wide W piece 9 = 128 + 49
    assert {i: p for i, p in enumerate(tsets[0]["tiles"]) if p} == want_props
    assert {i: p for i, p in enumerate(tsets[2]["tiles"]) if p} == {i: p for i, (_, p) in want_rd.items()}
    assert not any(tsets[1]["tiles"]), "reader tiles must carry no properties"
    for i in range(6):
        for m in (0, 80):   # chain pieces: no wall / collision / cut flags (module comment above lane_props)
            assert not ({"WallN", "WallW", "collideN", "collideW", "solid", "solidtrans", "DoorWallN", "DoorWallW",
                         "cutN", "cutW"} & tsets[0]["tiles"][m + i].keys())
    for t in tsets[0]["tiles"][160:] + tsets[2]["tiles"]:   # placeholders: no GarageDoor (setInfo takeover)
        assert "GarageDoor" not in t and "doorTrans" not in t, t

    # ---- .pack: pages of at most PAGE_CELLS cells, every sprite = its source pixels, shared sources share one rect ----
    pages = pzfmt.read_pack((MEDIA / "texturepacks" / f"{PACK}.pack").read_bytes())
    assert all(p["mask"] == 1 for p in pages) and [p["name"] for p in pages] == [f"{PACK}{i}" for i in range(len(pages))]
    sheets = [p["image"].convert("RGBA") for p in pages]
    names = {e[0]: (i, e[1:]) for i, p in enumerate(pages) for e in p["entries"]}
    src = sprite_sources()
    assert len(names) == sum(len(p["entries"]) for p in pages) and names.keys() == src.keys(), \
        sorted(names.keys() ^ src.keys())
    vis = lambda im: [p if p[3] else (0, 0, 0, 0) for p in im.get_flattened_data()]  # noqa: E731
    cells = source_cells(set(src.values()))
    rects: dict = {}
    for name, key in src.items():
        pg, (x, y, w, h, ox, oy, fx, fy) = names[name]
        assert (fx, fy) == (CELL_W, CELL_H)
        cell = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
        cell.paste(sheets[pg].crop((x, y, x + w, y + h)), (ox, oy))
        assert vis(cell) == vis(cells[key]), f"{name}: pixels differ from {key}"
        assert rects.setdefault(key, names[name]) == names[name], f"{name}: not sharing the rect of {key}"
    for i in range(6):
        assert names[f"{TILESET}_{160 + i}"] == names[f"{TILESET}_{i}"]
        assert not cells[src[f"{TILESET}_{80 + i}"]].getbbox() and not cells[src[f"{TILESET}_{88 + i}"]].getbbox()
    per_page = [sum(1 for pg, _ in rects.values() if pg == i) for i in range(len(pages))]
    assert per_page[:-1] == [PAGE_CELLS] * (len(pages) - 1) and 0 < per_page[-1] <= PAGE_CELLS, per_page
    assert all(s.width == 8 * CELL_W and s.height == CELL_H * -(-n // 8) for s, n in zip(sheets, per_page))
    for ts in tsets:   # pack sprites = tiledef indices that are meant to have 2D (readers: the coloured variants)
        want = (set(READER_TILES) if ts["name"] == READER_TILESET else set(MG.pillar_tiles())
                if ts["name"] == MG.PILLAR_TILESET else {i for i, p in enumerate(ts["tiles"]) if p})
        assert {int(n.rsplit("_", 1)[1]) for n in names if n.rsplit("_", 1)[0] == ts["name"]} == want, ts["name"]

    # ---- spriteModels ----
    sm_all = (COMMON / "spriteModels.txt").read_text(encoding="ascii")
    assert sm_all == sprite_models(), "spriteModels.txt is stale: rerun the builder"
    assert sm_all.count("{") == sm_all.count("}") and "VERSION = 1" in sm_all
    _, sm, sm_reader, *_ = sm_all.split("    tileset\n")    # per-tileset blocks: indices restart at 0 in each
    assert f"name = {TILESET}," in sm and f"name = {READER_TILESET}," in sm_reader

    def smw(model, t, r, anim=None, at=0.0, tex=None):
        d = {"modelScript": f"Base.MinidoracatKnoxPass_{model}", "translate": fmt3(t), "rotate": fmt3(r),
             "scale": "1.0000"} | ({"texture": GREEN} if tex else {})
        return d | ({"animation": anim, "animationTime": f"{at:.4f}"} if anim else {})
    want_sm = {}
    # lane1 index, cabinet, first opening pose, rotate, arm translate, lines translate (lane -> cabinet tile)
    for base, cab, pose, rot, arm, lines in ((0, 6, 16, (0, 180, 0), (-1, 0, 0), (-2, 0, 0)),
                                             (3, 7, 32, (0, -90, 0), (0, 0, 1), (0, 0, 2)),
                                             (80, 86, 96, (0, 0, 0), (3, 0, -1), (2, 0, -1)),
                                             (83, 87, 112, (0, 90, 0), (-1, 0, -3), (-1, 0, -2))):
        want_sm[base], want_sm[base + 8] = smw("BarrierArm", arm, rot, "Open"), smw("BarrierArm", arm, rot, "Close", 0, 1)
        want_sm[base + 1] = want_sm[base + 9] = smw("BarrierLines", lines, rot)
        want_sm[base + 2] = want_sm[base + 10] = smw("BarrierEmpty", (0, 0, 0), (0, 0, 0))
        want_sm[cab] = smw("BarrierCabinet", (0, 0, 0), rot)
        for f in range(9):   # opening poses green, closing (+32) red
            want_sm[pose + f] = smw("BarrierArm", arm, rot, "Open", f / 8, 1)
            want_sm[pose + 32 + f] = smw("BarrierArm", arm, rot, "Open", f / 8)
    assert sm_blocks(sm) == want_sm, "barrier spriteModels differ from the contract"
    models = set(re.findall(r"model (\w+)", MODEL_SCRIPT))
    assert {b["modelScript"].split(".")[1] for b in want_sm.values()} <= models
    assert MODELS_SCRIPT.read_text(encoding="ascii") == MODEL_SCRIPT, "model script is stale"
    assert (MEDIA / "textures" / f"{GREEN}.png").exists()
    # reader: one static model per tile on the post (host NW corner), rotated per variant, colour texture, no animation
    assert sm_blocks(sm_reader) == {i: {"modelScript": f"Base.{READER_MODEL}", "texture": reader_tex(c),
                                        "translate": fmt3(READER_T), "rotate": fmt3(READER_XFORM[v]), "scale": "1.0000"}
                                    for i, (c, v) in READER_TILES.items()}
    for c in range(len(KP.COLORS)):
        assert (MEDIA / "textures" / f"{reader_tex(c)}.png").exists(), reader_tex(c)
    assert READER_MODEL in models and re.search(rf"model {READER_MODEL}\s*{{[^}}]*static = true,", MODEL_SCRIPT)

    # ---- entities ----
    ent = ENTITY_SCRIPT.read_text(encoding="ascii")
    assert ent == entity_script(), "entity script is stale"
    assert "health = 1000," in ent and "OnCreate = MinidoracatKnoxPass.Barrier.onCreate," in ent
    assert entity_faces(ent, TILESET) == {"N": [(6, 160, 161, 162)], "W": [(165,), (164,), (163,), (7,)],
                                          "S": [(240, 241, 242, 86)], "E": [(87,), (245,), (244,), (243,)]}
    rd = ROLLDOOR_SCRIPT.read_text(encoding="ascii")
    assert rd == rolldoor_script(), "roll door entity script is stale"
    assert "GarageDoor" not in rd
    skins = dict(re.findall(r"entity (ES_\w+)\s*\{(.*?)\}", rd, re.S))
    ents = dict(re.findall(r"^    entity (\w+)\n    \{(.*?)^    \}", rd, re.S | re.M))
    recipe = {3: (300, 30, 6, 6, 4, 4, 4), 4: (400, 40, 8, 8, 5, 5, 5), 6: (600, 60, 12, 12, 8, 8, 8),
              9: (900, 90, 18, 18, 12, 12, 12)}
    assert len(ents) == len(skins) == 12
    for s, (style, *_) in enumerate(styles):
        for w, (n0, w0) in first.items():
            name = f"MinidoracatKnoxPassRollDoor{style}{w}"
            body, skin = ents[name], skins[f"ES_{name}"]
            icon = f"media/ui/MinidoracatKnoxPass/rolldoor_{style.lower()}_{w}.png"
            assert (f"LuaWindowClass = ISEntityWindow," in skin and f"DisplayName = IGUI_KnoxPass_RollDoor_{style}{w}," in skin
                    and f"Icon = {icon}," in skin), skin
            with Image.open(MEDIA.parent / icon) as im:
                assert im.size == (64, 64) and im.getbbox(), icon
            assert entity_faces(body, ROLLDOOR_TILESET) == {
                "N": [tuple(s * stride + n0 + j for j in range(w))],
                "W": [(s * stride + w0 + j,) for j in reversed(range(w))]}
            time, xp, torch, rods, sheet_n, pipe, hinge = recipe[w]
            for line in (f"entityStyle = ES_{name},", "uiEnabled = false,", "dontNeedFrame = true,",
                         "OnCreate = MinidoracatKnoxPass.RollDoor.onCreate,", "timedAction = BuildWallMetal,",
                         f"time = {time},", "category = Welding,", "SkillRequired = MetalWelding:3,",
                         f"xpAward = MetalWelding:{xp},", f"item {torch} [Base.BlowTorch] flags[DontRecordInput],",
                         f"item {rods} [Base.WeldingRods] flags[DontRecordInput],", f"item {sheet_n} [Base.SheetMetal],",
                         f"item {pipe} [Base.MetalPipe],", f"item {hinge} [Base.Hinge],"):
                assert line in body, (name, line)
            assert len(re.findall(r"^\s*item ", body, re.M)) == 5, name
    # every entity sprite is a real sprite, none repeats within or across entities (SpriteConfigManager)
    toks = re.findall(rf"(?:{TILESET}|{ROLLDOOR_TILESET})_\d+", ent + rd)
    rd_sprites = 3 * 2 * sum(len(p) for p in pieces.values())   # styles x faces x pieces of every width
    assert len(toks) == len(set(toks)) == 16 + rd_sprites and set(toks) <= names.keys(), toks

    # ---- copied assets, icons, mod.info ----
    for src_path, dst in assets():
        assert dst.read_bytes() == src_path.read_bytes(), f"{dst.name} differs from {src_path}"
    assert ICON.exists() and KIT_ICON.exists()
    info = (OUT / "42" / "mod.info").read_text(encoding="utf-8").splitlines()
    assert f"pack={PACK}" in info and f"tiledef={TILEDEF} {FILE_NUMBER}" in info, "mod.info lacks pack=/tiledef="
    r4 = MG.check({t["name"]: t for t in tsets}, sm_all, set(names))
    print(f"OK: pack {len(names)} sprites / {len(rects)} cells ({len(pages)} pages), tiledef "
          + " + ".join(f"{t['name']} {len(t['tiles'])}" for t in tsets)
          + f" tiles, spriteModels {sm_all.count('tile' + chr(10))} tiles, entities 16 + {rd_sprites} sprites, "
          f"{r4}, assets, icons and mod.info match")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    (check if ap.parse_args().check else build)()
