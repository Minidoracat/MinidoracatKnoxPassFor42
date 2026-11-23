"""Knox Pass sliding gate: 2D build-ghost cells, game-camera previews, icon renders.
用法：blender -b --factory-startup --python render_slide.py [-- step ...]   steps: cells game icons (default all)
then: uv run --with pillow python assemble.py

Camera, lighting and glb placement = ../barrier/render_tiles.py through ../gate/render_gate.py's helpers; models are
placed with the engine's spriteModels formula at the transforms spec.py gives, so every render also checks them.
Renders with Cycles on the CPU (render_tiles.reset picks EEVEE, which needs a GPU the build VM does not have).

cells/<look><story>/<face>/{lane,endA,endB,motorA,motorB,stow}.png  128x256 build-ghost cells, shared by every width
    (使用者 2026-11-23：虛影共用圖格): lane = one leaf tile of the closed gate, endA / endB = post + leaf end,
    motorA / motorB = the same end when the leaf stows past it (post + cabinet), stow = one leaf tile of the open
    gate (assemble.py fades it: where the leaf goes when open). Geometry looks only: a painted look uses its base's.
previews/<look><story>_<L><side>_<face>_<closed|half|open>.png  game camera, tile grid, car box, the reader on the
    post the leaf closes against, one-story wall stubs on the line past both ends. N / L for every model; the other
    faces and side R (the same glb turned) only for PREVIEW_ALL.
icons/_render/<look><story>_<L>.png  N closed on transparent, for the 64x64 entity icons (assemble.py).
"""
import importlib.util
import sys
from pathlib import Path

sys.dont_write_bytecode = True       # loading ../gate and ../barrier scripts must not leave __pycache__ there

import bpy

HERE = Path(__file__).resolve().parent
GATE = HERE.parent / "gate"


def _load(name, path):
    sp = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(mod)
    return mod


RG = _load("knoxpass_render_gate", GATE / "render_gate.py")    # at, play, masks, solid, fit
R = RG.R
S = _load("knoxpass_slide_spec", HERE / "spec.py")
G = S.G
EXPORT = HERE / "export"
STATES = {"closed": ("Open", 0.0), "half": ("Open", 0.5), "open": ("Close", 0.0)}
PREVIEW_ALL = {("A", 1, 6), ("D", 2, 3)}


def reset():
    sc = R.reset()
    sc.render.engine = "CYCLES"
    sc.cycles.device, sc.cycles.samples, sc.cycles.use_denoising = "CPU", 24, False
    sc.cycles.max_bounces, sc.cycles.transparent_max_bounces = 1, 12
    return sc


def place(look, story, L, face, side, reader=False):
    rot = G.ROTATE[face]
    rig = R.import_glb(EXPORT / f"{S.leaf_model(look, story, L)}.glb", RG.at(G.real_lane(face, L, 1))
                       @ R.pz_matrix(S.leaf_translate(face, L, side), S.leaf_rotate(face, side)))
    stow, other = S.stow_end(face, L, side)
    statics = [R.import_glb(EXPORT / f"{S.post_model(look, story, motor)}.glb", RG.at(p) @ R.pz_matrix((0, 0, 0), rot))
               for p, motor in ((stow, True), (other, False))]
    meshes = [o for o in rig.children if o.type == "MESH"] + statics
    if look in S.PAINT:                 # the base look's models with the painted atlas (spriteModels texture in game)
        img = bpy.data.images.load(str(HERE / "textures" / f"{S.texture(look)}.png"))
        for n in (n for o in meshes for mat in o.data.materials for n in mat.node_tree.nodes if n.type == "TEX_IMAGE"):
            n.image = img
    if reader:
        meshes.append(R.import_glb(GATE / "export" / "knoxpass_reader_pillar_A.glb",
                                   RG.at(other) @ R.pz_matrix(S.pillar_translate(face), rot)))
    return rig, meshes


def cells():
    L = 6
    for look, story in sorted({(S.geometry(v[0]), v[1]) for v in S.VARIANTS}):
        for face in S.FACES:
            ends = {G.end_a(face, L): "A", G.end_b(face, L): "B"}
            for side in S.SIDES:
                stow, other = S.stow_end(face, L, side)
                shots = [("closed", [(f"motor{ends[stow]}", stow), (f"end{ends[other]}", other)])]
                if side == "L":
                    shots[0][1].append(("lane", G.placeholder(face, L, 3)))
                    shots.append(("open", [("stow", S.stow_tiles(face, L, "L")[2])]))
                for state, tiles in shots:
                    reset()
                    rig, meshes = place(look, story, L, face, side)
                    RG.play(rig, *STATES[state])
                    centres, _ = RG.masks(meshes)
                    for name, (x, y) in tiles:
                        for c in centres:
                            c[0].default_value, c[1].default_value = x, -y
                        R.aim((x, -y, 0), 64, 224, 128, 256)
                        R.render(HERE / "cells" / f"{look}{story}" / face / f"{name}.png")


def scale_refs(face, L):
    """Car box (2 x 4.5 x 1.45) in front of lanes 2-3 and one-story wall stubs on the door line past both ends."""
    (xx, xy), (yx, yy) = S.AXES[face]
    (ax, ay), (bx, by) = G.end_a(face, L), G.end_b(face, L)
    ux, uy = (bx - ax) // (L + 1), (by - ay) // (L + 1)     # along the line, A -> B

    def box(name, a0, a1, d0, d1, h, rgba):
        """a = tiles along the line from end A, d = tiles from the placed row's centre toward the door line."""
        ps = [(ax + a * ux + d * yx, ay + a * uy + d * yy) for a in (a0, a1) for d in (d0, d1)]
        xs, ys = [p[0] for p in ps], [-p[1] for p in ps]
        RG.solid(name, (min(xs), min(ys), 0), (max(xs), max(ys), h), rgba)
    box("car", 1.5, 3.5, -1.7 - 4.5, -1.7, 1.45, (0.55, 0.57, 0.6, 0.55))
    for a0, a1 in ((-L - 1.5, -0.5), (L + 1.5, 2 * L + 2.5)):
        box("wall", a0, a1, 0.5, 0.6, G.STORY, (0.2, 0.11, 0.08, 1.0))


def models():
    """(look, story, L) of every build-menu model, painted looks included."""
    return [(look, story, L) for look, story, group in S.VARIANTS for L in S.GROUPS[group]]


def game():
    for look, story, L in models():
        every = (S.geometry(look), story, L) in PREVIEW_ALL and look not in S.PAINT
        for face, side in (("N", "L"), ("N", "R"), ("S", "L"), ("W", "L"), ("E", "R")) if every else (("N", "L"),):
            for state in STATES:
                reset()
                bpy.data.objects["Sun"].data.use_shadow = False   # PZ draws no model shadows
                R.ground()
                ground = bpy.context.object
                ground.scale = (3.0, 3.0, 1.0)
                rig, meshes = place(look, story, L, face, side, reader=True)
                RG.play(rig, *STATES[state])
                scale_refs(face, L)
                RG.fit([o for o in bpy.data.objects if o.type == "MESH" and o != ground])
                R.render(HERE / "previews" / f"{look}{story}_{L}{side}_{face}_{state}.png")


def icons():
    for look, story, L in models():
        reset()
        rig, meshes = place(look, story, L, "N", "L")
        RG.play(rig, "Open", 0.0)
        RG.fit(meshes, margin=4)
        R.render(HERE / "icons" / "_render" / f"{look}{story}_{L}.png")


if __name__ == "__main__":
    STEPS = {"cells": cells, "game": game, "icons": icons}
    for step in (sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else STEPS):
        STEPS[step]()
    print("[render_slide] done")
