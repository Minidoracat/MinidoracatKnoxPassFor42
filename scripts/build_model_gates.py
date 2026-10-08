"""Knox Pass model gates (r4): double boom barrier, two-story roll doors, two-story double-leaf gates.

Imported by build_barrier_tiles.py, which owns the single .pack / .tiles / spriteModels.txt of the MOD. Sources are the
Blender deliverables under scripts/blender/<kind>/ (manifest.json; rebuild order in each folder's README.md).

Tilesets (tiledef file 7430). A mod tiledef holds at most 512 tiles per tileset (IsoWorld.java:639-640), so every
style / look gets its own tileset:

    4      MinidoracatKnoxPass_barrier2                       blocks 6N 6W 9N 9W
    5-7    MinidoracatKnoxPass_roll2f_industry/green/white    blocks 3N 3W 4N 4W 6N 6W 9N 9W
    8-12   MinidoracatKnoxPass_gate_a .. _e                   blocks 6N 6W 6S 6E 9N 9W 9S 9E

index = block * 64 + slot, block = widthIdx * len(faces) + faceIdx. Slots (Lua Core.lua KP.GATE_SLOT):

    0 1 2   lane closed: GarageDoor 1 (chain anchor, carries the animated model) / every middle piece / last piece
    8 9 10  lane open: GarageDoor 4 / 5 / 6 (engine open sprite = closed + 8, IsoDoor.java:793-805)
    3 4     end A (lane-1 side) / end B: solid IsoThumpable (cabinet or post), static model
    16..    build placeholder of lane k = 16 + k - 1: doorN/W + CustomName only, NO GarageDoor (mods that take over
            ISBuildIsoEntity:setInfo for GarageDoor sprites leave the build alone); Lua OnCreate swaps it for the lane
    32..40  opening poses (Open clip at k/8), 48..56 closing poses: spriteModels only, SP stepper (BarrierAnim.lua)

Entity faces: N / S one row west -> east [A] P1 .. PL [B]; W / E rows north -> south [B] PL .. P1 [A]. Doors exist only
on N / W square edges, so the S / E real lanes sit one row south / column east of the placed row (Barrier.lua).
Lane tiles carry no DoorWall in the .tiles (Core.lua adds the flag at runtime, see build_barrier_tiles.py lane_props).

Speed (per gate, Lua KP.fastTwin): every animated model has a <name>Fast twin (Blender KNOXPASS_FAST=1 *_fast.glb, same
model, clips 3.75 s instead of 6.0 s -> 2.5 s / 4 s in game). Virtual tilesets MinidoracatKnoxPassFast_<style> (no
tiledef, spriteModels only) hold lane 1 closed / open with the twin; BarrierAnim.lua sets them as the anchor's
spriteModel override, and the engine plays the clip of whatever getSpriteModel() returns.
"""
from __future__ import annotations

import importlib.util
import json
import re
from dataclasses import dataclass, field
from functools import cache
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "scripts" / "blender"
OUT = REPO / "MOD/MinidoracatKnoxPassFor42/Contents/mods/MinidoracatKnoxPassFor42"
MEDIA = OUT / "42" / "media"
MODELS_SCRIPT = MEDIA / "scripts" / "models_knoxpass_gates.txt"
CORE_LUA = MEDIA / "lua" / "shared" / "MinidoracatKnoxPass" / "Core.lua"

STRIDE = 64
OPEN = 8
END_A, END_B = 3, 4
PLACEHOLDER = 16
POSE_OPEN, POSE_CLOSE, POSES = 32, 48, 8
ONCREATE = "MinidoracatKnoxPass.ModelGate.onCreate"
FIRE = "900000"
# 加速版：車道 1 關／開兩格（錨點靜止時的 sprite），clip 秒數（Blender CLIP_S；KNOXPASS_FAST=1）
FAST_SLOTS = (0, OPEN)
CLIP_S, FAST_CLIP_S = 6.0, 3.75


def fast_tileset(name: str) -> str:
    """Virtual tileset of the fast twins: same index, prefix MinidoracatKnoxPassFast_ (Lua KP.fastTwin)."""
    return name.replace("MinidoracatKnoxPass_", "MinidoracatKnoxPassFast_", 1)


def _fast_model(m: tuple) -> tuple:
    name, mesh, tex, animated, src, ship = m
    return (name + "Fast", mesh + "_fast", tex, animated, src.with_name(src.stem + "_fast.glb"),
            ship.removesuffix(".glb") + "_fast.glb")


def clip_seconds(glb: Path) -> set[float]:
    """Length of each animation clip in a .glb (seconds: last key - first key over its samplers)."""
    raw = glb.read_bytes()
    j = json.loads(raw[20:20 + int.from_bytes(raw[12:16], "little")])
    acc = j["accessors"]
    return {round(max(acc[s["input"]]["max"][0] for s in a["samplers"])
                  - min(acc[s["input"]]["min"][0] for s in a["samplers"]), 3) for a in j.get("animations", [])}


@dataclass
class Block:
    tileset: str
    block: int                  # block inside the tileset
    width: int
    face: str
    entity: str
    sm: dict[int, tuple]        # slot -> (model, translate, rotate, texture | None, animation | None, time | None)
    cells: dict[int, Path]      # slot -> 2D cell (ends and placeholders)


@dataclass
class Kind:
    key: str
    name: str                   # tile CustomName
    widths: tuple
    faces: tuple
    ends: bool
    tilesets: list              # (tileset, tileset number, variant)
    see_through: frozenset      # variants whose closed lanes pass sight (doorTrans, IsoDoor.java:1107)
    blocks: list = field(default_factory=list)
    models: list = field(default_factory=list)    # (name, mesh, texture, animated, source, ship under media/)
    textures: list = field(default_factory=list)  # (source, ship under media/)
    icons: dict = field(default_factory=dict)     # entity -> (source, ship under media/)
    entities: dict = field(default_factory=dict)  # entity -> (variant, width, health)


def _ship(p: str) -> str:
    return p[len("media/"):] if p.startswith("media/") else p


def _sm(model: str, d: dict) -> tuple:
    return (model.removeprefix("Base."), tuple(d["translate"]), tuple(d["rotate"]), d.get("texture"),
            d.get("animation"), d.get("animationTime"))


def _manifest(kind: str) -> dict:
    return json.loads((SRC / kind / "manifest.json").read_text(encoding="utf-8"))


def _barrier2() -> Kind:
    m = _manifest("barrier2")
    k = Kind("barrier2", "Knox Pass Double Boom Barrier", (6, 9), ("N", "W"), True,
             [("MinidoracatKnoxPass_barrier2", 4, None)], frozenset({None}))
    names = {v["width"]: n for n, v in m["entities"].items()}
    for b in m["blocks"]:
        k.blocks.append(Block("MinidoracatKnoxPass_barrier2", b["block"], b["width"], b["face"], names[b["width"]],
                              {e["slot"]: _sm(e["modelScript"], e) for e in b["spriteModels"].values()},
                              {int(c["slot"]): REPO / c["file"] for c in b["cells"].values()}))
    for name, v in m["models"].items():
        ms = v["model_script"]
        k.models.append((name, ms["mesh"], ms["texture"], not ms["static"], REPO / v["glb"], _ship(v["ship"])))
    for name, v in m["entities"].items():
        k.icons[name] = (REPO / v["icon"], _ship(v["icon_ship"]))
        k.entities[name] = (None, v["width"], v["health"])
    return k


def _roll2f() -> Kind:
    m = _manifest("roll2f")
    styles = m["styles"]
    k = Kind("roll2f", "Knox Pass Two-Story Roll Door", tuple(m["widths"]), tuple(m["faces"]), False,
             [(f"MinidoracatKnoxPass_roll2f_{s.lower()}", 5 + i, s) for i, s in enumerate(styles)], frozenset())
    for b in m["blocks"]:
        k.blocks.append(Block(b["style_tileset"], b["style_block"], b["width"], b["face"], b["entity"],
                              {int(s): _sm(e["modelScript"], e) for s, e in b["spriteModels"].items()},
                              {int(s): REPO / p for s, p in b["placeholder_cells"].items()}))
        k.entities[b["entity"]] = (b["style"], b["width"], m["health"][str(b["width"])])
    for v in m["models"].values():
        f = v["model_script_fields"]
        k.models.append((v["model_script"], f["mesh"], f["texture"], not f["static"], REPO / v["source"], _ship(v["ship"])))
    k.textures = [(REPO / v["source"], _ship(v["ship"])) for v in m["textures"].values()]
    k.icons = {n: (REPO / v["source"], _ship(v["ship"])) for n, v in m["icons"].items()}
    return k


GATE_LOOKS = ("A", "B", "C", "D", "E")


def _gate() -> Kind:
    m = _manifest("gate")
    k = Kind("gate", "Knox Pass Gate", (6, 9), ("N", "W", "S", "E"), True,
             [(m["tilesets"][lk]["name"], 8 + i, lk) for i, lk in enumerate(GATE_LOOKS)], frozenset({"A", "C"}))
    for b in m["blocks"]:
        slots = {int(s): v for s, v in b["slots"].items()}
        k.blocks.append(Block(b["tileset"], b["blockInTileset"], b["width"], b["face"], b["entity"],
                              {s: _sm(v["spriteModel"]["model"], v["spriteModel"]) for s, v in slots.items()
                               if v.get("spriteModel")},
                              {s: REPO / v["cell"] for s, v in slots.items() if v.get("cell")}))
    for v in m["models"].values():
        ms = v["modelScript"]
        k.models.append((ms["name"], ms["mesh"], ms["texture"], True, REPO / v["src"], _ship(v["ship"])))
    for v in m["posts"].values():
        ms = v["modelScript"]
        k.models.append((ms["name"], ms["mesh"], ms["texture"], False, REPO / v["src"], _ship(v["ship"])))
    for lk, v in m["reader_mount"].items():   # placed by ReaderPost.lua on end A (texture per reader colour)
        k.models.append((f"MinidoracatKnoxPass_ReaderPillar{lk}", v["modelScript"]["mesh"],
                         "WorldItems/MinidoracatKnoxPassReader", False, REPO / v["src"], _ship(v["ship"])))
    k.textures = [(REPO / v["src"], _ship(v["ship"])) for v in m["textures"].values()]
    for n, v in m["entities"].items():
        k.icons[n] = (REPO / v["icon"], _ship(v["ship"]))
        k.entities[n] = (v["look"], v["width"], v["health"])
    return k


@cache
def kinds() -> tuple[Kind, ...]:
    out = _barrier2(), _roll2f(), _gate()
    for kind in out:
        kind.models += [_fast_model(m) for m in kind.models if m[3]]
    return out


def variant_of(kind: Kind, tileset: str):
    return next(v for t, _, v in kind.tilesets if t == tileset)


# ---- recipes ----------------------------------------------------------------------------------------------------
# 2026-10-08 design (temp/design-knoxpass-r4): barrier2 = boom barrier kit + parts; roll2f = the one-story roll door of
# the same width x2 (build_barrier_tiles.py ROLLDOOR_RECIPE), time x1.5, MetalWelding 4; gate 9 wide = 6 wide x1.5,
# iron looks MetalWelding 5 (vanilla double wire gate is 5), wood looks Woodwork 5, E also welds its iron bands.
ROLL_ONE_STORY = {3: (300, 6, 6, 4, 4, 4), 4: (400, 8, 8, 5, 5, 5), 6: (600, 12, 12, 8, 8, 8), 9: (900, 18, 18, 12, 12, 12)}
SCREWDRIVER = "item 1 tags[base:screwdriver] mode:keep flags[Prop1;MayDegradeVeryLight]"
HAMMER = "item 1 tags[base:hammer] mode:keep flags[Prop1;MayDegradeVeryLight]"


def _item(n: int, full: str, tool: bool = False) -> str:
    return f"item {n} [{full}]" + (" flags[DontRecordInput]" if tool else "")


def recipe(kind: Kind, variant, width: int) -> tuple[dict, list[str]]:
    """(header fields in order, input lines)."""
    if kind.key == "barrier2":
        n = {6: 1, 9: 1.5}[width]
        return ({"timedAction": "BuildWoodenStructureMedium", "time": {6: 250, 9: 350}[width], "category": "Furniture",
                 "Tags": "Furniture"},
                [SCREWDRIVER, _item(1, "MinidoracatKnoxPass.BoomBarrierKit"), _item(round(4 * n), "Base.MetalPipe"),
                 _item(round(2 * n), "Base.SheetMetal"), _item(2, "Base.Wire")])
    if kind.key == "roll2f":
        time, torch, rods, sheet, pipe, hinge = ROLL_ONE_STORY[width]
        return ({"timedAction": "BuildWallMetal", "time": time * 3 // 2, "category": "Welding",
                 "SkillRequired": "MetalWelding:4", "xpAward": f"MetalWelding:{time * 3 // 20}"},
                [_item(torch * 2, "Base.BlowTorch", True), _item(rods * 2, "Base.WeldingRods", True),
                 _item(sheet * 2, "Base.SheetMetal"), _item(pipe * 2, "Base.MetalPipe"), _item(hinge * 2, "Base.Hinge")])
    s = {6: 2, 9: 3}[width]                  # halves: 6 wide = 2, 9 wide = 3
    time = {6: 900, 9: 1200}[width]
    xp = time // 10
    if variant in ("A", "B", "C"):
        extra = {"A": [_item(4 * s, "Base.Wire")], "B": [_item(4 * s, "Base.SheetMetal")], "C": []}[variant]
        return ({"timedAction": "BuildWallMetal", "time": time, "category": "Welding",
                 "SkillRequired": "MetalWelding:5", "xpAward": f"MetalWelding:{xp}"},
                [_item(10 * s, "Base.BlowTorch", True), _item(10 * s, "Base.WeldingRods", True),
                 _item((12 if variant == "C" else 8) * s, "Base.MetalPipe"), _item(2 * s, "Base.Hinge")] + extra)
    if variant == "D":
        return ({"timedAction": "BuildWallHammer", "time": time, "category": "Carpentry",
                 "SkillRequired": "Woodwork:5", "xpAward": f"Woodwork:{xp}"},
                [HAMMER, _item(12 * s, "Base.Plank"), _item(16 * s, "Base.Nails"), _item(2 * s, "Base.Hinge")])
    return ({"timedAction": "BuildWallHammer", "time": time, "category": "Carpentry",
             "SkillRequired": "Woodwork:5;MetalWelding:2", "xpAward": f"Woodwork:{xp};MetalWelding:{5 * s * 2}"},
            [HAMMER, _item(2 * s, "Base.BlowTorch", True), _item(2 * s, "Base.WeldingRods", True),
             _item(16 * s, "Base.Plank"), _item(16 * s, "Base.Nails"), _item(2 * s, "Base.Hinge"),
             _item(3 * s, "Base.IronBand"), _item(4 * s, "Base.Stone2")])


def display_key(kind: Kind, variant, width: int) -> str:
    return {"barrier2": f"IGUI_KnoxPass_Barrier2_{width}", "roll2f": f"IGUI_KnoxPass_Roll2F_{variant}{width}",
            "gate": f"IGUI_KnoxPass_Gate_{variant}{width}"}[kind.key]


# ---- tiles ------------------------------------------------------------------------------------------------------
def edge_of(face: str) -> str:
    return "N" if face in ("N", "S") else "W"


def slot_props(kind: Kind, variant, b: Block, slot: int) -> dict:
    edge = edge_of(b.face)
    if slot % OPEN in (0, 1, 2) and slot < 16:
        p = {f"door{edge}": "", "GarageDoor": str(slot % OPEN + 1 + (3 if slot >= OPEN else 0))}
        if variant in kind.see_through:
            p["doorTrans"] = ""
        return p | {"CustomName": kind.name, "firerequirement": FIRE}
    if kind.ends and slot in (END_A, END_B):
        return {"solid": "", "BlocksPlacement": "", "Facing": b.face, "CustomName": kind.name, "firerequirement": FIRE}
    if PLACEHOLDER <= slot < PLACEHOLDER + b.width:
        return {f"door{edge}": "", "CustomName": kind.name, "firerequirement": FIRE}
    return {}


# Reader on a gate post (ReaderPost.lua): the door-post reader would sit inside the 0.34-0.60 tile thick posts, so each
# look has its own model on the post faces, hosted on end A. Tiles carry no properties (like the reader tileset) and
# a transparent pack entry; Lua places them. index = colour * 32 + look * 4 + faceIdx (faces N W S E)
PILLAR_TILESET, PILLAR_NUMBER, PILLAR_STRIDE = "MinidoracatKnoxPass_readerpillar", 13, 32
_spec = importlib.util.spec_from_file_location("kpbuild", SRC / "build.py")
COLORS = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(COLORS)               # the one colour table (build.py COLORS)


def reader_tex(c: int) -> str:
    return f"WorldItems/MinidoracatKnoxPassReader{COLORS.suffix(COLORS.COLORS[c][0])}"


@cache
def pillar_tiles() -> dict[int, tuple]:
    mount = _manifest("gate")["reader_mount"]
    gate = kinds()[2]
    return {c * PILLAR_STRIDE + li * 4 + fi: (f"MinidoracatKnoxPass_ReaderPillar{lk}",
                                              tuple(mount[lk]["faces"][f]["translate"]),
                                              tuple(mount[lk]["faces"][f]["rotate"]), reader_tex(c), None, None)
            for c in range(len(COLORS.COLORS)) for li, lk in enumerate(GATE_LOOKS) for fi, f in enumerate(gate.faces)}


def layout() -> dict[str, dict[int, tuple[tuple[str, ...], dict]]]:
    """tileset -> index -> (2D cell sources, props); only indices with a cell, props or (reader pillar) a pack entry."""
    out: dict = {}
    for kind in kinds():
        for b in kind.blocks:
            t = out.setdefault(b.tileset, {})
            v = variant_of(kind, b.tileset)
            for slot in range(STRIDE):
                p = slot_props(kind, v, b, slot)
                cell = b.cells.get(slot)
                if p or cell:
                    t[b.block * STRIDE + slot] = ((str(cell),) if cell else (), p)
    out[PILLAR_TILESET] = {i: ((), {}) for i in pillar_tiles()}
    return out


def tileset_specs() -> list[tuple[str, int, int]]:
    """(name, number, tile count = highest index used + 1, poses included)."""
    out = []
    for kind in kinds():
        for name, number, _ in kind.tilesets:
            last = max(b.block for b in kind.blocks if b.tileset == name)
            out.append((name, number, last * STRIDE + POSE_CLOSE + POSES + 1))
    return out + [(PILLAR_TILESET, PILLAR_NUMBER, max(pillar_tiles()) + 1)]


def faces_rows(kind: Kind, b: Block) -> list[tuple[int, ...]]:
    lanes = [PLACEHOLDER + i for i in range(b.width)]
    a, z = ([END_A], [END_B]) if kind.ends else ([], [])
    if b.face in ("N", "S"):
        return [tuple(a + lanes + z)]
    return [(s,) for s in z + lanes[::-1] + a]


# ---- spriteModels / model scripts / entities ----------------------------------------------------------------------
def _f3(v) -> str:
    return " ".join(f"{float(x):.4f}" for x in v)


def _sm_tile(i: int, model, tr, rot, tex, anim, t) -> str:
    lines = [f"            xy = {i % 8} {i // 8},", f"            modelScript = Base.{model},"]
    if tex:
        lines.append(f"            texture = {tex},")
    lines += [f"            translate = {_f3(tr)},", f"            rotate = {_f3(rot)},", "            scale = 1.0000,"]
    if anim:
        lines += [f"            animation = {anim},", f"            animationTime = {float(t or 0):.4f},"]
    return "        tile\n        {\n" + "\n".join(lines) + "\n        }\n"


def sprite_model_tilesets() -> list[str]:
    """One spriteModels 'tileset' block per tileset (same text layout as build_barrier_tiles.sm_tile), then the fast
    virtual tilesets (lane 1 closed / open only, model -> <model>Fast)."""
    blocks = []
    for kind in kinds():
        for name, _, _ in kind.tilesets:
            tiles = [_sm_tile(b.block * STRIDE + slot, *b.sm[slot])
                     for b in sorted((b for b in kind.blocks if b.tileset == name), key=lambda b: b.block)
                     for slot in sorted(b.sm)]
            blocks.append(f"    tileset\n    {{\n        name = {name},\n\n" + "".join(tiles) + "    }\n")
    tiles = [_sm_tile(i, *v) for i, v in sorted(pillar_tiles().items())]
    blocks.append(f"    tileset\n    {{\n        name = {PILLAR_TILESET},\n\n" + "".join(tiles) + "    }\n")
    for kind in kinds():
        for name, _, _ in kind.tilesets:
            tiles = [_sm_tile(b.block * STRIDE + slot, b.sm[slot][0] + "Fast", *b.sm[slot][1:])
                     for b in sorted((b for b in kind.blocks if b.tileset == name), key=lambda b: b.block)
                     for slot in FAST_SLOTS]
            blocks.append(f"    tileset\n    {{\n        name = {fast_tileset(name)},\n\n" + "".join(tiles) + "    }\n")
    return blocks


def model_script() -> str:
    out = []
    for kind in kinds():
        for name, mesh, tex, animated, _, _ in kind.models:
            if animated:
                out.append(f"    model {name}\n    {{\n        mesh = {mesh},\n        animationsMesh = {name},\n"
                           f"        texture = {tex},\n        shader = door,\n        static = false,\n"
                           "        scale = 1.0,\n        undoCoreScale = true,\n    }\n\n"
                           f"    animationsMesh {name}\n    {{\n        meshFile = {mesh},\n"
                           "        keepMeshAnimations = true,\n    }\n")
            else:
                out.append(f"    model {name}\n    {{\n        mesh = {mesh},\n        texture = {tex},\n"
                           "        static = true,\n        scale = 1.0,\n        undoCoreScale = true,\n    }\n")
    return "module Base\n{\n" + "\n".join(out) + "}\n"


def entity_path(kind: Kind) -> Path:
    return MEDIA / "scripts" / "entities" / f"entity_knoxpass_{kind.key}.txt"


def entity_script(kind: Kind) -> str:
    skins, ents = [], []
    for name, (variant, width, health) in kind.entities.items():
        blocks = sorted((b for b in kind.blocks if b.entity == name), key=lambda b: kind.faces.index(b.face))
        faces = []
        for b in blocks:
            rows = "".join(f"                    row = {' '.join(f'{b.tileset}_{b.block * STRIDE + s}' for s in r)},\n"
                           for r in faces_rows(kind, b))
            faces.append(f"            face {b.face}\n            {{\n                layer\n                {{\n{rows}"
                         "                }\n            }\n")
        head, inputs = recipe(kind, variant, width)
        hp = f"            health = {health},\n            skillBaseHealth = 0,\n" if kind.ends else ""
        skins.append(f"        entity ES_{name}\n        {{\n            LuaWindowClass = ISEntityWindow,\n"
                     f"            DisplayName = {display_key(kind, variant, width)},\n"
                     f"            Icon = media/{kind.icons[name][1]},\n        }}\n")
        ents.append(f"    entity {name}\n    {{\n        component UiConfig\n        {{\n            xuiSkin = default,\n"
                    f"            entityStyle = ES_{name},\n            uiEnabled = false,\n        }}\n\n"
                    f"        component SpriteConfig\n        {{\n{hp}            dontNeedFrame = true,\n"
                    f"            OnCreate = {ONCREATE},\n\n" + "\n".join(faces) + "        }\n\n"
                    "        component CraftRecipe\n        {\n"
                    + "".join(f"            {k} = {v},\n" for k, v in head.items())
                    + "            inputs\n            {\n" + "".join(f"                {i},\n" for i in inputs)
                    + "            }\n        }\n    }\n")
    return "module Base\n{\n    xuiSkin default\n    {\n" + "\n".join(skins) + "    }\n\n" + "\n".join(ents) + "}\n"


def assets() -> list[tuple[Path, Path]]:
    out = []
    for kind in kinds():
        out += [(src, MEDIA / ship) for *_, src, ship in kind.models]
        out += [(src, MEDIA / ship) for src, ship in kind.textures]
        out += [(src, MEDIA / ship) for src, ship in kind.icons.values()]
    return out


# Tiles that host a 3D model draw every frame instead of from the chunk FBO cache, like the vanilla animated fence
# gates (media/tileGeometry.txt fixtures_doors_fences_01 Translucent = true; TileGeometryFile.java:897-900 ->
# sprite.depthFlags 2 -> FBORenderCell.isObjectRenderLayer_Translucent). Reason (inference, not seen in game): a cached
# copy would be bound to its chunk's FBO area, and a 9-wide leaf or roll door hosted on lane 1 crosses into the next
# chunk. doorTrans would do it too but also lets sight through a closed solid door (IsoDoor.TestVision, :1106-1160).
TILE_GEOMETRY = OUT / "common" / "media" / "tileGeometry.txt"


def tile_geometry() -> str:
    sets = []
    for kind in kinds():
        for name, _, _ in kind.tilesets:
            tiles = []
            for b in sorted((b for b in kind.blocks if b.tileset == name), key=lambda b: b.block):
                for slot in (0, OPEN) + ((END_A, END_B) if kind.ends else ()):
                    i = b.block * STRIDE + slot
                    tiles.append(f"        tile\n        {{\n            xy = {i % 8}x{i // 8},\n\n"
                                 "            properties\n            {\n                Translucent = true,\n"
                                 "            }\n        }\n")
            sets.append(f"    tileset\n    {{\n        name = {name},\n\n" + "\n".join(tiles) + "    }\n")
    return "tileGeometry\n{\n    VERSION = 2,\n\n" + "\n".join(sets) + "}\n"


def write() -> None:
    MODELS_SCRIPT.write_text(model_script(), encoding="ascii", newline="\n")
    TILE_GEOMETRY.write_text(tile_geometry(), encoding="ascii", newline="\n")
    for kind in kinds():
        entity_path(kind).write_text(entity_script(kind), encoding="ascii", newline="\n")


# ---- check ------------------------------------------------------------------------------------------------------
def check(tsets: dict[str, dict], sm_text: str, pack_names: set[str]) -> str:
    """Assert the shipped r4 assets; tsets = tiledef name -> tileset, sm_text = spriteModels.txt."""
    # tiledef: one tileset per style / look, numbers 4..12, the reader pillars 13, <= 512 tiles (IsoWorld.java:639-640)
    specs = tileset_specs()
    assert [(n, no) for n, no, _ in specs] == [("MinidoracatKnoxPass_barrier2", 4)] + [
        (f"MinidoracatKnoxPass_roll2f_{s}", 5 + i) for i, s in enumerate(("industry", "green", "white"))] + [
        (f"MinidoracatKnoxPass_gate_{lk.lower()}", 8 + i) for i, lk in enumerate(GATE_LOOKS)] + [
        ("MinidoracatKnoxPass_readerpillar", 13)], specs
    pillar = pillar_tiles()
    assert len(pillar) == len(COLORS.COLORS) * 5 * 4 and not any(tsets[PILLAR_TILESET]["tiles"])
    assert all(f"{PILLAR_TILESET}_{i}" in pack_names for i in pillar)
    lay = layout()
    for name, number, count in specs:
        t = tsets[name]
        assert (t["number"], len(t["tiles"])) == (number, count) and count <= 512, (name, t["number"], len(t["tiles"]))
        assert {i: p for i, p in enumerate(t["tiles"]) if p} == {i: p for i, (_, p) in lay[name].items() if p}, name
    # every block: lanes 0-2 / 8-10 = GarageDoor 1-6 on the face's edge, ends solid, placeholders without GarageDoor
    n_blocks = 0
    for kind in kinds():
        assert {(b.width, b.face) for b in kind.blocks} == {(w, f) for w in kind.widths for f in kind.faces}
        for b in kind.blocks:
            n_blocks += 1
            t, base, e = tsets[b.tileset]["tiles"], b.block * STRIDE, edge_of(b.face)
            assert b.block == kind.widths.index(b.width) * len(kind.faces) + kind.faces.index(b.face), b
            for slot, k in ((0, 1), (1, 2), (2, 3), (8, 4), (9, 5), (10, 6)):
                assert t[base + slot].get(f"door{e}") == "" and t[base + slot]["GarageDoor"] == str(k), (b, slot)
                assert not {"WallN", "WallW", "DoorWallN", "DoorWallW", "solid", "cutN", "cutW"} & t[base + slot].keys()
            for k in range(1, b.width + 1):
                p = t[base + PLACEHOLDER + k - 1]
                assert p.get(f"door{e}") == "" and "GarageDoor" not in p and "doorTrans" not in p, (b, k)
                assert f"{b.tileset}_{base + PLACEHOLDER + k - 1}" in pack_names, (b, k)
            for s in (END_A, END_B):
                assert ("solid" in t[base + s]) == kind.ends and (f"{b.tileset}_{base + s}" in pack_names) == kind.ends
            # model on lane 1 only: closed = Open t0, open = Close t0, 9 + 9 poses; ends static
            sm = b.sm
            assert set(sm) == {0, OPEN, *range(POSE_OPEN, POSE_OPEN + 9), *range(POSE_CLOSE, POSE_CLOSE + 9)} | (
                {END_A, END_B} if kind.ends else set()), (b, sorted(sm))
            assert sm[0][4:] == ("Open", 0.0) and sm[OPEN][4:] == ("Close", 0.0), b
            for f in range(POSES + 1):
                assert sm[POSE_OPEN + f][4:] == sm[POSE_CLOSE + f][4:] == ("Open", f / POSES), (b, f)
                assert sm[POSE_OPEN + f][:3] == sm[0][:3], (b, f)
    # spriteModels: the generated blocks, in order, after the existing tilesets
    gen = sprite_model_tilesets()
    assert sm_text.endswith("\n" + "\n".join(gen) + "}\n"), "r4 spriteModels are stale: rerun the builder"
    # model scripts cover every spriteModel; animated ones have animationsMesh; files copied
    ms = MODELS_SCRIPT.read_text(encoding="ascii")
    assert ms == model_script(), "models_knoxpass_gates.txt is stale"
    assert TILE_GEOMETRY.read_text(encoding="ascii") == tile_geometry(), "tileGeometry.txt is stale"
    names = set(re.findall(r"^    model (\w+)", ms, re.M))
    used = {v[0] for kind in kinds() for b in kind.blocks for v in b.sm.values()}
    used |= {b.sm[s][0] + "Fast" for kind in kinds() for b in kind.blocks for s in FAST_SLOTS}
    assert used <= names | {"MinidoracatKnoxPass_BarrierCabinet"}, used - names
    # 加速：每個有動畫的模型都有 <名稱>Fast；clip 正常 6.0 s、加速 3.75 s（引擎 1.5 倍速：4 s／2.5 s）
    animated = [m for kind in kinds() for m in kind.models if m[3]]
    fast = {m[0] for m in animated if m[0].endswith("Fast")}
    assert fast == {m[0] + "Fast" for m in animated if m[0] not in fast}, sorted(fast)
    for name, _, _, _, src, _ in animated:
        assert clip_seconds(src) == {FAST_CLIP_S if name in fast else CLIP_S}, (name, clip_seconds(src))
    for src, dst in assets():
        assert dst.read_bytes() == src.read_bytes(), f"{dst} differs from {src}"
    # entities: faces per the contract, recipe header, icon 64 px
    from PIL import Image
    for kind in kinds():
        text = entity_path(kind).read_text(encoding="ascii")
        assert text == entity_script(kind), f"{entity_path(kind).name} is stale"
        assert "GarageDoor" not in text and text.count(f"OnCreate = {ONCREATE},") == len(kind.entities)
        for name in kind.entities:
            with Image.open(kind.icons[name][0]) as im:
                assert im.size == (64, 64) and im.getbbox(), name
    # Lua Core.lua: same tilesets, widths, faces, health, ends
    lua = CORE_LUA.read_text(encoding="utf-8")
    lua_sets = dict(re.findall(r"^    (MinidoracatKnoxPass_\w+) = (\w+),", lua, re.M))
    assert set(lua_sets) == {n for n, _, _ in specs} - {PILLAR_TILESET}, sorted(lua_sets)
    assert f'KP.READER_PILLAR_TILESET = "{PILLAR_TILESET}"' in lua and f"KP.READER_PILLAR_STRIDE = {PILLAR_STRIDE}" in lua
    assert ('string.match(spriteName, "^MinidoracatKnoxPass_(.+)$")' in lua
            and '"MinidoracatKnoxPassFast_" .. rest' in lua), "Lua KP.fastTwin no longer matches fast_tileset()"
    assert re.search(r'KP\.GATE_LOOKS = \{ ' + ", ".join(f'"{t}"' for t, _, _ in kinds()[2].tilesets) + r" \}", lua)
    for kind in kinds():
        for name, _, _ in kind.tilesets:
            d = re.search(rf"^local {lua_sets[name]} = \{{(.*?)\}}\n(?!\s)", lua, re.M | re.S).group(1)
            assert re.search(r"widths = \{ " + ", ".join(map(str, kind.widths)) + r" \}", d), (name, d)
            assert re.search(r"faces = \{ " + ", ".join(f'"{f}"' for f in kind.faces) + r" \}", d), (name, d)
            assert re.search(rf"ends = {str(kind.ends).lower()}", d), (name, d)
            for w in kind.widths:
                hp = {h for (v, wd, h) in kind.entities.values() if wd == w}
                assert len(hp) == 1 and f"[{w}] = {hp.pop()}" in d, (name, w)
    return f"r4 {len(specs)} tilesets / {n_blocks} blocks / {sum(len(k.entities) for k in kinds())} entities"
