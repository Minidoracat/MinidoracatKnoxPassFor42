"""PZ 2x renders of the two-story roll door: 2D cell canvases, icon renders, game-camera previews.
用法：blender -b --factory-startup --python render_roll2f.py [-- cells icons game]   (default: all; then assemble_roll2f.py)

Camera, engine placement (pz_matrix), tile mask and ground are imported read-only from
scripts/blender/barrier/render_tiles.py (orthographic, 30 deg elevation, PZ 2x scale: 1 tile = 90.51 px, one story =
192 px). The model is placed exactly as spriteModels will place it (translate 0, rotate N (0,180,0) / W (0,-90,0) on
lane 1), so the renders double as a check of the manifest transforms. Pose = what the engine draws: closed tile =
Open clip t 0, open tile = Close clip t 0, half = Open t 0.5 (opening pose slot 36).

cells: cells/_canvas/<style>_<face>_lane<k>.png (k = 1..3 of the 3-wide door, closed, masked to lane tile k and to
       z < one story; 128x448 canvas, tile top corner at (64,384) like barrier/render_tiles.py)
icons: previews/icon_<style>_<w>.png (N face, closed, transparent, no ground)
game:  previews/game_<face>_<style>_<w>_<closed|half|open>.png: asphalt + tile grid, two-story wall stubs beyond the
       door ends (darker lower story = one vanilla wall height), a car proxy 2 x 4.5 x 1.2 tiles (closed / half) or a
       box-truck proxy 2.4 x 6.5 x 2.9 driving through (open). N face all widths, W face width 4 Industry.
"""
import importlib.util
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import atlas as A  # noqa: E402

_spec = importlib.util.spec_from_file_location("rt", HERE.parent / "barrier" / "render_tiles.py")
RT = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(RT)                      # helpers only (its steps run under __main__)

ROTATE = {"N": (0.0, 180.0, 0.0), "W": (0.0, -90.0, 0.0)}
TILE = {"N": lambda k: (k - 1, 0), "W": lambda k: (0, k - 1)}   # lane k tile centre, scene (x east, y north)
STATES = {"closed": ("Open", 0.0), "half": ("Open", 0.5), "open": ("Close", 0.0)}


def glb(width):
    return HERE / "export" / f"knoxpass_roll2f_{width}.glb"


def door(width, face, style):
    rig = RT.import_glb(glb(width), RT.pz_matrix((0, 0, 0), ROTATE[face]))
    mesh = next(o for o in rig.children if o.type == "MESH")
    img = bpy.data.images.load(str(HERE / "textures" / f"knoxpass_roll2f_{style.lower()}.png"))
    for n in mesh.data.materials[0].node_tree.nodes:
        if n.type == "TEX_IMAGE":
            n.image = img
    return rig


def pose(rig, clip, t):
    ad = rig.animation_data
    for tr in ad.nla_tracks:
        tr.mute = True
    act = bpy.data.actions[clip]
    ad.action = act
    if hasattr(ad, "action_slot") and act.slots:
        ad.action_slot = act.slots[0]
    f0, f1 = act.frame_range
    bpy.context.scene.frame_set(round(f0 + t * (f1 - f0)))


def box(name, mn, mx, colour, matrix):
    """Model-space box (x along the lanes, -y = camera side), placed like the door."""
    bpy.ops.mesh.primitive_cube_add(size=1)
    o = bpy.context.object
    o.name = name
    o.data.transform(Matrix.Translation(Vector(mn).lerp(Vector(mx), 0.5)) @ Matrix.Diagonal((*(Vector(mx) - Vector(mn)), 1)))
    o.matrix_world = matrix
    mat = bpy.data.materials.new(name)
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*colour, 1)
    mat.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.9
    o.data.materials.append(mat)
    return o


def frame_canvas(points, margin=24, zoom=1.0):
    """aim() so every scene point is on the canvas; returns nothing (sets resolution + camera)."""
    cam = bpy.context.scene.camera
    rot = cam.rotation_euler.to_matrix()
    right, up = rot.col[0], rot.col[1]
    sx = [RT.PX * zoom * p.dot(right) for p in points]
    sy = [-RT.PX * zoom * p.dot(up) for p in points]
    w, h = int(max(sx) - min(sx)) + 2 * margin, int(max(sy) - min(sy)) + 2 * margin
    RT.aim((0, 0, 0), margin - min(sx), margin - min(sy), w + w % 2, h + h % 2, zoom)


def corners(mn, mx, matrix):
    return [matrix @ Vector((x, y, z)) for x in (mn[0], mx[0]) for y in (mn[1], mx[1]) for z in (mn[2], mx[2])]


def clip_z(rig, zmax):
    """After RT.add_mask: also drop everything at world z >= zmax (the cell keeps the lower story only, cut along the
    story line like a one-story vanilla wall instead of along the cell's top row)."""
    nt = next(o for o in rig.children if o.type == "MESH").data.materials[0].node_tree
    mix = next(n for n in nt.nodes if n.type == "MIX_SHADER")
    fac = mix.inputs["Fac"].links[0].from_socket
    geo, sep = nt.nodes.new("ShaderNodeNewGeometry"), nt.nodes.new("ShaderNodeSeparateXYZ")
    lt, mul = nt.nodes.new("ShaderNodeMath"), nt.nodes.new("ShaderNodeMath")
    lt.operation, mul.operation = "LESS_THAN", "MULTIPLY"
    lt.inputs[1].default_value = zmax
    nt.links.new(geo.outputs["Position"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], lt.inputs[0])
    nt.links.new(fac, mul.inputs[0])
    nt.links.new(lt.outputs[0], mul.inputs[1])
    nt.links.new(mul.outputs[0], mix.inputs["Fac"])


def cells():
    for style in A.STYLES:
        for face in ROTATE:
            RT.reset()
            rig = door(3, face, style)
            pose(rig, *STATES["closed"])
            centres, _ = RT.add_mask(rig)
            clip_z(rig, A.STORY)
            for k in (1, 2, 3):
                cx, cy = TILE[face](k)
                centres[0].default_value, centres[1].default_value = cx, cy
                RT.aim((cx, cy, 0), 64, 416, 128, 448)
                RT.render(HERE / "cells" / "_canvas" / f"{style.lower()}_{face}_lane{k}.png")


def icons():
    for style in A.STYLES:
        for w in A.WIDTHS:
            RT.reset()
            rig = door(w, "N", style)
            pose(rig, *STATES["closed"])
            frame_canvas(corners((-0.5, A.HOUSE_Y0, 0), (w - 0.5, 0.5, A.Z_TOP), RT.pz_matrix((0, 0, 0), ROTATE["N"])))
            RT.render(HERE / "previews" / f"icon_{style.lower()}_{w}.png")


def game_one(face, style, w, state):
    RT.reset()
    bpy.data.objects["Sun"].data.use_shadow = False      # PZ draws no model shadows
    m = RT.pz_matrix((0, 0, 0), ROTATE[face])
    rig = door(w, face, style)
    pose(rig, *STATES[state])
    RT.ground()
    g = bpy.context.object
    g.scale = (2.0, 2.0, 1.0)
    g.location = (m @ Vector(((w - 1) / 2, -2.0, 0))).to_tuple()
    pts = corners((-0.5, A.HOUSE_Y0, 0), (w - 0.5, 0.5, A.Z_TOP), m)
    wall, upper = (0.28, 0.24, 0.18), (0.38, 0.34, 0.27)     # linear RGB; lower story darker
    for x0, x1 in ((-2.5, -0.5), (w - 0.5, w + 1.5)):      # wall stubs on the door line (tile edge y = 0.5)
        box("wall_lo", (x0, 0.45, 0), (x1, 0.55, A.STORY), wall, m)
        box("wall_hi", (x0, 0.45, A.STORY), (x1, 0.55, 2 * A.STORY), upper, m)
        box("floor_line", (x0, 0.43, A.STORY - 0.04), (x1, 0.45, A.STORY), (0.06, 0.05, 0.04), m)
        pts += corners((x0, 0.45, 0), (x1, 0.55, 2 * A.STORY), m)
    if state == "open":      # box truck 2.4 x 6.5 x 2.9 most of the way through the door (the cab end still outside)
        mn, mx = (0.0, -1.2, 0.0), (2.4, 5.3, 2.9)
    else:                    # car 2 x 4.5 x 1.2 in front of lanes 1-2
        mn, mx = (0.0, -5.4, 0.0), (2.0, -0.9, 1.2)
    box("vehicle", mn, mx, (0.10, 0.11, 0.13), m)
    pts += corners(mn, mx, m)
    frame_canvas(pts)
    RT.render(HERE / "previews" / f"game_{face}_{style.lower()}_{w}_{state}.png")


def game():
    for style in A.STYLES:
        for w in A.WIDTHS:
            for state in STATES:
                game_one("N", style, w, state)
    for state in STATES:
        game_one("W", "Industry", 4, state)


STEPS = {"cells": cells, "icons": icons, "game": game}
for step in (sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else STEPS):
    STEPS[step]()
print("[render_roll2f] done")
