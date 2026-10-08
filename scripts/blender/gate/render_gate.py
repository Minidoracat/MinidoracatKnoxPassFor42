"""Knox Pass gate: 2D cells, game-camera previews, icon renders, reader-on-post check.
用法：blender -b --factory-startup --python render_gate.py [-- step ...]   steps: cells game icons reader (default all)
then: uv run --with pillow python assemble.py

Camera, lighting, glb placement = scripts/blender/barrier/render_tiles.py (imported, not copied): orthographic, 30 deg
elevation, PZ 2x scale (1 tile = 90.51 px, 1 story = 192 px), models placed with the engine's spriteModels formula
(pz_matrix) at the tiles spec.py gives, so every render also checks the translate / rotate values in manifest.json.

cells/<look><L>/<face>/{lane1..laneL,endA,endB}.png  128x256 build-ghost cells (closed gate, Open clip frame 0):
    lane k = slice of the closed model inside placeholder tile k (slot 16 + k - 1), endA / endB = post + leaf slice
    inside the end tile (slots 3 / 4); world-position alpha mask per tile footprint (render_tiles.add_mask), lower
    story only (what is taller than the 128x256 frame is cut, like every one-level Tiles2x cell).
previews/<look><L>_<face>_<closed|half|open>.png  game camera, asphalt with a tile grid, a 2 x 4.5 x 1.45 car box in
    front of the gate (vanilla car footprint) and one-story wall stubs (STORY high) continuing the line past both ends.
    closed = Open clip t 0, half = Open clip t 0.5, open = Close clip t 0 (what the open tile, slot 8, shows).
icons/_render/<look><L>.png  N closed on transparent, for the 64x64 entity icons (assemble.py).
previews/reader_<look>_<face>.png  door reader model on the end-A post (cream reader texture), closed gate, 2.5x.
"""
import sys
from pathlib import Path
from types import SimpleNamespace

sys.dont_write_bytecode = True       # importing ../barrier/render_tiles.py must not leave __pycache__ there

import bpy
from mathutils import Matrix, Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "barrier"))
import render_tiles as R  # noqa: E402
import spec as S  # noqa: E402

EXPORT = HERE / "export"
STATES = {"closed": ("Open", 0.0), "half": ("Open", 0.5), "open": ("Close", 0.0)}


def at(p):
    """PZ tile (x east, y south) -> scene translation."""
    return Matrix.Translation((p[0], -p[1], 0))


def place(look, L, face, reader=False):
    rot = S.ROTATE[face]
    rig = R.import_glb(EXPORT / f"{S.leaf_model(look, L)}.glb",
                       at(S.real_lane(face, L, 1)) @ R.pz_matrix(S.leaf_translate(face, L), rot))
    statics = [R.import_glb(EXPORT / f"{S.post_model(look)}.glb", at(p) @ R.pz_matrix((0, 0, 0), rot))
               for p in (S.end_a(face, L), S.end_b(face, L))]
    if reader:
        statics.append(R.import_glb(EXPORT / f"knoxpass_reader_pillar_{look}.glb",
                                    at(S.end_a(face, L)) @ R.pz_matrix((0, 0, 0), rot)))
    return rig, [o for o in rig.children if o.type == "MESH"] + statics


def play(rig, clip, t):
    """spriteModels animation = clip, animationTime = t."""
    ad = rig.animation_data
    for tr in ad.nla_tracks:
        tr.mute = True
    act = bpy.data.actions[clip]
    ad.action = act
    if hasattr(ad, "action_slot") and act.slots:
        ad.action_slot = act.slots[0]
    f0, f1 = act.frame_range
    bpy.context.scene.frame_set(round(f0 + t * (f1 - f0)))


def masks(meshes):
    centres, limits = [], []
    for mat in {m.data.materials[0] for m in meshes}:
        c, lim = R.add_mask(SimpleNamespace(children=[next(o for o in meshes if o.data.materials[0] == mat)]))
        centres.append(c)
        limits += lim
    return centres, limits


def cells():
    for look in S.LOOKS:
        for L in S.WIDTHS:
            for face in S.FACES:
                R.reset()
                rig, meshes = place(look, L, face)
                play(rig, "Open", 0.0)
                centres, _ = masks(meshes)
                tiles = [(f"lane{k}", S.placeholder(face, L, k)) for k in range(1, L + 1)]
                tiles += [("endA", S.end_a(face, L)), ("endB", S.end_b(face, L))]
                for name, (x, y) in tiles:
                    for c in centres:
                        c[0].default_value, c[1].default_value = x, -y
                    R.aim((x, -y, 0), 64, 224, 128, 256)
                    R.render(HERE / "cells" / f"{look}{L}" / face / f"{name}.png")


def solid(name, mn, mx, rgba):
    bpy.ops.mesh.primitive_cube_add(size=1)
    o = bpy.context.object
    o.name = name
    o.scale = [b - a for a, b in zip(mn, mx)]
    o.location = [(a + b) / 2 for a, b in zip(mn, mx)]
    mat = bpy.data.materials.new(name)
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = rgba
    mat.node_tree.nodes["Principled BSDF"].inputs["Alpha"].default_value = rgba[3]
    o.data.materials.append(mat)
    return o


def scale_refs(face, L):
    """Car box (vanilla footprint 2 x 4.5 tiles, 1.45 high) in lanes 2-3 in front of the line (south), one-story wall
    stubs on the line beyond both ends."""
    line = -0.5 if face == "N" else 0.5                     # PZ y of the door line
    y0 = line + 1.7
    solid("car", (1.5, -(y0 + 4.5), 0), (3.5, -y0, 1.45), (0.55, 0.57, 0.6, 0.55))
    for xa, xb in ((-2.5, -0.5), (L + 1.5, L + 3.5)):
        solid("wall", (xa, -line - 0.05, 0), (xb, -line + 0.05, S.STORY), (0.2, 0.11, 0.08, 1.0))   # brick, 1 story


def fit(objs, margin=24, zoom=1.0):
    """Aim so every vertex of objs (evaluated, posed) is inside the canvas."""
    cam = bpy.context.scene.camera
    rot = cam.rotation_euler.to_matrix()
    right, up = rot.col[0], rot.col[1]
    dg = bpy.context.evaluated_depsgraph_get()
    rs, us = [], []
    for o in objs:
        ev = o.evaluated_get(dg)
        me = ev.to_mesh()
        for v in me.vertices:
            w = ev.matrix_world @ v.co
            rs.append(w.dot(right))
            us.append(w.dot(up))
        ev.to_mesh_clear()
    s = R.PX * zoom
    w, h = int((max(rs) - min(rs)) * s) + 2 * margin, int((max(us) - min(us)) * s) + 2 * margin
    R.aim((0, 0, 0), -min(rs) * s + margin, max(us) * s + margin, w, h, zoom)


def game():
    for look in S.LOOKS:
        for L in S.WIDTHS:
            for face in "NS":
                for state, (clip, t) in STATES.items():
                    R.reset()
                    bpy.data.objects["Sun"].data.use_shadow = False   # PZ draws no model shadows
                    R.ground()
                    ground = bpy.context.object
                    ground.scale = (2.0, 2.0, 1.0)
                    rig, meshes = place(look, L, face)
                    play(rig, clip, t)
                    scale_refs(face, L)
                    fit([o for o in bpy.data.objects if o.type == "MESH" and o != ground])
                    R.render(HERE / "previews" / f"{look}{L}_{face}_{state}.png")


def icons():
    for look in S.LOOKS:
        for L in S.WIDTHS:
            R.reset()
            rig, meshes = place(look, L, "N")
            play(rig, "Open", 0.0)
            fit(meshes, margin=4)
            R.render(HERE / "icons" / "_render" / f"{look}{L}.png")


def reader():
    for look in "AE":
        for face in "NS":
            R.reset()
            bpy.data.objects["Sun"].data.use_shadow = False
            R.ground()
            rig, meshes = place(look, 6, face, reader=True)
            play(rig, "Open", 0.0)
            x, y = S.end_a(face, 6)
            R.aim((x, -y, 0), 300, 560, 600, 640, zoom=2.5)
            R.render(HERE / "previews" / f"reader_{look}_{face}.png")


if __name__ == "__main__":
    STEPS = {"cells": cells, "game": game, "icons": icons, "reader": reader}
    for step in (sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else STEPS):
        STEPS[step]()
    print("[render_gate] done")
