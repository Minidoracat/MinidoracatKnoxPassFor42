"""Game-camera renders of the double boom barrier: 2D cells, previews, icon source.
用法：blender -b --factory-startup --python render_barrier2.py   (then: uv run --with pillow python manifest.py)

Camera, PZ 2x scale, engine spriteModels transform and tile masks = scripts/blender/barrier/render_tiles.py
(imported). Every block is placed exactly as manifest.json tells the game: end-A cabinet on its tile (translate 0),
the boom model on lane 1 with the lane-1 -> end-A translate, end-B cabinet on its tile (translate 0, same rotate).
Scene axes: +X = PZ east, +Y = PZ north, +Z up; end-A tile centre at the origin.

cells/<L><F>/lane<k>.png  closed model inside lane k's tile, road paint masked out (build-cursor ghost of the
                          placeholder slot 16+k-1; like barrier/cells/<F>/lane<k>_closed.png)
cells/<L><F>/endA.png, endB.png   cabinet + closed model inside that end tile (pivot lamp, boom root), depth-correct
                          (like barrier/cells/<F>/cabinet_ghost_closed.png)
previews/<L><F>_<closed|half|open>_game.png   asphalt + 1-tile grid, both cabinets, model with paint; half = Open at
                          t 0.5 (43 deg) and open use the green lamp texture (opening poses / open tile); open adds a
                          2 x 4.5 x 1.2 tile car proxy (vanilla car footprint) in car lane 1 straddling the gate line
previews/<L>N_icon_src.png   transparent closed N composite without paint (manifest.py fits it to the 64 px icon)
"""
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

HERE = Path(__file__).resolve().parent
BARRIER = HERE.parent / "barrier"
sys.dont_write_bytecode = True           # no __pycache__ in the single barrier's folder
sys.path.insert(0, str(BARRIER))
import render_tiles as R  # noqa: E402

CABINET = BARRIER / "export" / "knoxpass_barrier_cabinet.glb"
GREEN = BARRIER / "textures" / "knoxpass_barrier_green.png"
# face -> (spriteModels rotate, lane-1 translate (lane 1 -> end A), scene xy of the tile d tiles along the row from end A)
FACES = {"N": ((0.0, 180.0, 0.0), (-1.0, 0.0, 0.0), lambda d: (d, 0.0)),
         "W": ((0.0, -90.0, 0.0), (0.0, 0.0, 1.0), lambda d: (0.0, d))}
STATES = {"closed": (0.0, False), "half": (43.0, True), "open": (86.0, True)}


def place(L, face):
    rot, t1, at = FACES[face]
    cabs = [R.import_glb(CABINET, Matrix.Translation((*at(d), 0)) @ R.pz_matrix((0, 0, 0), rot)) for d in (0, L + 1)]
    rig = R.import_glb(HERE / "export" / f"knoxpass_barrier2_boom{L}.glb",
                       Matrix.Translation((*at(1), 0)) @ R.pz_matrix(t1, rot))
    return cabs, rig, next(o for o in rig.children if o.type == "MESH")


def pose(rig, deg):
    for bone, sign in (("DoorBone", 1), ("DoorBoneB", -1)):
        pb = rig.pose.bones[bone]
        pb.rotation_mode = "QUATERNION"
        b = pb.bone.matrix_local.to_3x3()
        pb.rotation_quaternion = (b.inverted() @ Matrix.Rotation(math.radians(-sign * deg), 3, "Y") @ b).to_quaternion()
    if rig.animation_data:
        rig.animation_data.action = None
        for t in rig.animation_data.nla_tracks:
            t.mute = True
    bpy.context.view_layer.update()


def mask(rig):
    """render_tiles.add_mask (one tile footprint) x 'not the road paint' (paint is flat at model z = 0.02)."""
    centres, limits = R.add_mask(rig)
    nt = next(o for o in rig.children if o.type == "MESH").data.materials[0].node_tree
    mix = next(n for n in nt.nodes if n.type == "MIX_SHADER")
    tile = mix.inputs["Fac"].links[0].from_socket
    geo, sep = nt.nodes.new("ShaderNodeNewGeometry"), nt.nodes.new("ShaderNodeSeparateXYZ")
    sub, ab, gt, mul = (nt.nodes.new("ShaderNodeMath") for _ in range(4))
    sub.operation, ab.operation, gt.operation, mul.operation = "SUBTRACT", "ABSOLUTE", "GREATER_THAN", "MULTIPLY"
    sub.inputs[1].default_value, gt.inputs[1].default_value = 0.02, 0.002
    nt.links.new(geo.outputs["Position"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], sub.inputs[0])
    nt.links.new(sub.outputs[0], ab.inputs[0])
    nt.links.new(ab.outputs[0], gt.inputs[0])
    nt.links.new(tile, mul.inputs[0])
    nt.links.new(gt.outputs[0], mul.inputs[1])
    nt.links.new(mul.outputs[0], mix.inputs["Fac"])
    return centres, limits


def frame(objs, zoom=1.0, margin=24):
    """Size the canvas to the objects' projected extent and aim (origin pixel follows)."""
    rot = bpy.context.scene.camera.rotation_euler.to_matrix()
    dg = bpy.context.evaluated_depsgraph_get()
    xs, ys = [], []
    for o in objs:
        ev = o.evaluated_get(dg)
        me = ev.to_mesh()
        for v in me.vertices:
            w = ev.matrix_world @ v.co
            xs.append(w.dot(rot.col[0]) * R.PX * zoom)
            ys.append(-w.dot(rot.col[1]) * R.PX * zoom)
        ev.to_mesh_clear()
    w, h = math.ceil(max(xs) - min(xs)) + 2 * margin, math.ceil(max(ys) - min(ys)) + 2 * margin
    R.aim((0, 0, 0), margin - min(xs), margin - min(ys), w + w % 2, h + h % 2, zoom)


def car_proxy(face):
    """2 x 4.5 tiles, 1.2 high (vanilla car footprint), car lane 1 (lanes 1..3), centred on the gate line."""
    bpy.ops.mesh.primitive_cube_add(size=1)
    car = bpy.context.object
    if face == "N":
        car.location, car.scale = (2.0, 0.5, 0.6), (2.0, 4.5, 1.2)
    else:
        car.location, car.scale = (-0.5, 2.0, 0.6), (4.5, 2.0, 1.2)
    mat = bpy.data.materials.new("car")
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.25, 0.32, 0.45, 1)
    car.data.materials.append(mat)
    return car


def cells_and_icon(L, face):
    R.reset()
    cabs, rig, mesh = place(L, face)
    pose(rig, 0.0)
    centres, limits = mask(rig)
    at = FACES[face][2]
    out = HERE / "cells" / f"{L}{face}"
    for d in range(L + 2):
        name = "endA" if d == 0 else "endB" if d == L + 1 else f"lane{d}"
        for c in cabs:
            c.hide_render = name.startswith("lane")
        centres[0].default_value, centres[1].default_value = at(d)
        R.aim((*at(d), 0), 64, 224, 128, 256)
        R.render(out / f"{name}.png")
    if face == "N":
        for c in cabs:
            c.hide_render = False
        for lim in limits:
            lim.default_value = 1e6
        frame(cabs + [mesh])
        R.render(HERE / "previews" / f"{L}N_icon_src.png")


def previews(L, face):
    for state, (deg, lit) in STATES.items():
        R.reset()
        bpy.data.objects["Sun"].data.use_shadow = False   # PZ draws no model shadows
        cabs, rig, mesh = place(L, face)
        if lit:
            img = bpy.data.images.load(str(GREEN))
            for n in mesh.data.materials[0].node_tree.nodes:
                if n.type == "TEX_IMAGE":
                    n.image = img
        pose(rig, deg)
        objs = cabs + [mesh] + ([car_proxy(face)] if state == "open" else [])
        frame(objs, margin=64)
        R.ground()
        bpy.context.object.location = (*FACES[face][2]((L + 1) / 2), 0)
        bpy.context.object.scale = (2, 2, 1)
        R.render(HERE / "previews" / f"{L}{face}_{state}_game.png")


for L in (6, 9):
    for face in FACES:
        cells_and_icon(L, face)
        previews(L, face)
print("[render_barrier2] done")
