"""Knox Pass two-story roll-up door: build the animated model per width, export .glb.
用法：blender -b --factory-startup --python build_roll2f.py      (after atlas.py; writes export/knoxpass_roll2f_<W>.glb)
    KNOXPASS_FAST=1 blender -b --factory-startup --python build_roll2f.py   # export/knoxpass_roll2f_<W>_fast.glb：
                                                                  # 每扇門可選的「加速」，同一個模型，clip 3.75 s
Idempotent: every width starts from an empty factory scene and overwrites its output.

export/knoxpass_roll2f_<W>.glb (W = 3, 4, 6, 9), one skinned mesh, one material (knoxpass_roll2f_industry.png; the
Green / White textures share the UV layout and are swapped by spriteModels `texture =`):
    PostBone   static: two guide rails (floor -> housing bottom) + drum housing across the full width at the top of
               the 2nd story (front on the camera side -Y, chamfered top edge, closed box)
    Slat00..31 one rigid curtain slat each (0.14 high, one corrugation rib); Slat00 also carries the bottom bar
    clips Open / Close, 6.0 s at 24 fps (engine speedDelta 1.5 -> ~4.0 s, IsoObjectAnimations.java:281), keyed every
    2nd frame (engine lerps position, slerps rotation between keys: Keyframe.lerp). Travel follows the shared
    trapezoidal ease (scripts/blender/ease.py: accelerate over the first 20 %, decelerate over the last 20 %); keys
    every 2nd frame are enough: the linear in-between of the quadratic ramp is off by at most
    a * h^2 / 8 = (TRAVEL * 1.25 / 0.2) * (2 / 144)^2 / 8 = 0.65 mm, so per-frame keys would only grow the file.

Technique: every slat bone follows the curtain path (straight up the rails at y = CURTAIN_Y, then around the drum
axis inside the housing) by TRANSLATION + ROTATION keys only. Bone SCALE keys are not usable: the importer reads them
(ImportedSkeleton.java:206-235, 306-311) but AnimationPlayer.updateBoneAnimationTransform_Internal blends only
position and rotation into the bone transform and leaves scale at identity (AnimationPlayer.java:1209-1273). Bone
budget: the door / basicEffect vertex shaders take `uniform mat4 MatrixPalette[60]` (media/shaders/door.vert:15) and
the skeleton = Dummy01 + every node under it (ImportedSkeleton.java:57-112), so 1 + 1 + 32 = 34 matrices.
Open: every slat moves TRAVEL * ease(t) along the path, slat 0 ends 3 cm above the housing bottom; slats past the drum
tangent wrap around it (overlapping turns, all inside the closed housing). Close = TRAVEL * ease(1 - t), the exact
reverse (ease is symmetric, so the half-way pose is unchanged).

Rig conventions = scripts/blender/barrier/build_barrier.py (vanilla fixtures_doors_fences_01_*): armature object
"Dummy01", bones point +Z, actions stashed on NLA, Khronos glTF exporter +Y up, export_force_sampling.
Model space: atlas.py docstring (origin = lane 1 tile centre on the floor, +X along the lanes, door line y = +0.5).
"""
import math
import os
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import atlas as A  # noqa: E402
from ease import ease  # noqa: E402

FPS = 24
# KNOXPASS_FAST=1：每扇門可選的「加速」版，clip 3.75 s（引擎以 speedDelta 1.5 播：正常 4.0 s、加速 2.5 s），檔名加 _fast
FAST = os.environ.get("KNOXPASS_FAST") == "1"
CLIP_S = 3.75 if FAST else 6.0
F0, F1 = 1, 1 + round(CLIP_S * FPS)
FRAME_STEP = 2
TEX = HERE / "textures" / "knoxpass_roll2f_industry.png"
POST = 0                                   # vertex group index; slat i = 1 + i


def path_point(s):
    """Curtain path (y, z) at arc length s: up the plane y = CURTAIN_Y, then around the drum (front side = -Y)."""
    if s <= A.DRUM_Z:
        return Vector((A.CURTAIN_Y, s))
    phi = (s - A.DRUM_Z) / A.DRUM_R
    return Vector((A.DRUM_Y + A.DRUM_R * math.cos(phi), A.DRUM_Z + A.DRUM_R * math.sin(phi)))


def slat_matrix(i, travel):
    """Model-space deformation of slat i after moving `travel` along the path: rest bottom-edge point
    (CURTAIN_Y, i*h) -> path(i*h + travel), rest +Z -> chord to path(i*h + travel + h)."""
    s = i * A.SLAT_H + travel
    b, t = path_point(s), path_point(s + A.SLAT_H)
    d = (t - b).normalized()
    a = math.atan2(-d.x, d.y)              # rotation about +X taking +Z to (0, d.y, d.z): (0, -sin a, cos a)
    return (Matrix.Translation((0, b.x, b.y)) @ Matrix.Rotation(a, 4, "X")
            @ Matrix.Translation((0, -A.CURTAIN_Y, -i * A.SLAT_H)))


class Builder:
    def __init__(self):
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.verify()
        self.dl = self.bm.verts.layers.deform.verify()

    def face(self, cos, group, uvs):
        vs = [self.bm.verts.new(c) for c in cos]
        for v in vs:
            v[self.dl][group] = 1.0
        f = self.bm.faces.new(vs)
        for loop, uv in zip(f.loops, uvs):
            loop[self.uv].uv = uv
        return f

    def box(self, mn, mx, group, paint):
        """Axis-aligned box, faces wound outward (the door shader culls back faces). paint(axis, sign, u, v) -> uv."""
        (x0, y0, z0), (x1, y1, z1) = mn, mx
        c = lambda i, j, k: ((x0, x1)[i], (y0, y1)[j], (z0, z1)[k])  # noqa: E731
        for axis, sign, keys in ((0, -1, [(0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)]),
                                 (0, 1, [(1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1)]),
                                 (1, -1, [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)]),
                                 (1, 1, [(0, 1, 0), (0, 1, 1), (1, 1, 1), (1, 1, 0)]),
                                 (2, -1, [(0, 0, 0), (0, 1, 0), (1, 1, 0), (1, 0, 0)]),
                                 (2, 1, [(0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)])):
            cos = [c(*k) for k in keys]
            self.face(cos, group, [paint(axis, sign, Vector(p)) for p in cos])

    def to_mesh(self, name):
        me = bpy.data.meshes.new(name)
        self.bm.normal_update()
        self.bm.to_mesh(me)
        self.bm.free()
        me.uv_layers[0].name = "UVMap"
        return me


def door(m, width):
    xl, xr = -0.5, width - 0.5
    cx0, cx1 = xl + A.CURTAIN_INSET, xr - A.CURTAIN_INSET
    u = lambda x: (x - xl) / A.U_SPAN  # noqa: E731
    sw = A.swatch_uv
    # curtain: slat i = front (-Y) + back (+Y) quad, rib i of the CURTAIN region; ends hide in the rail channels
    y0, y1 = A.CURTAIN_Y - A.SLAT_T / 2, A.CURTAIN_Y + A.SLAT_T / 2
    for i in range(A.SLATS):
        za, zb = i * A.SLAT_H, (i + 1) * A.SLAT_H
        uv = lambda x, z: A.region_uv(A.CURTAIN, u(x), (z / A.SLAT_H) / A.SLATS)  # noqa: E731
        m.face([(cx0, y0, za), (cx1, y0, za), (cx1, y0, zb), (cx0, y0, zb)], 1 + i,
               [uv(cx0, za), uv(cx1, za), uv(cx1, zb), uv(cx0, zb)])
        m.face([(cx0, y1, za), (cx0, y1, zb), (cx1, y1, zb), (cx1, y1, za)], 1 + i,
               [uv(cx0, za), uv(cx0, zb), uv(cx1, zb), uv(cx1, za)])
    # bottom bar on slat 0 (1 cm off the floor so it never z-fights the ground)
    m.box((cx0, A.CURTAIN_Y - A.BAR_T / 2, 0.01), (cx1, A.CURTAIN_Y + A.BAR_T / 2, 0.01 + A.BAR_H), 1,
          lambda ax, sg, p: A.region_uv(A.BAR, u(p.x), (p.z - 0.01) / A.BAR_H) if ax == 1 else sw("rubber"))
    # guide rails (PostBone)
    for rx0, rx1 in ((xl, xl + A.RAIL_W), (xr - A.RAIL_W, xr)):
        m.box((rx0, A.RAIL_Y0, 0.0), (rx1, 0.5, A.HOUSE_B), POST,
              lambda ax, sg, p, rx0=rx0: A.region_uv(A.RAIL, (p.x - rx0) / A.RAIL_W, p.z / A.HOUSE_B)
              if (ax, sg) == (1, -1) else sw("rail_side"))
    # housing: atlas.HOUSE_PROFILE extruded over the full width; the camera-side faces of the profile map to HOUSING
    # bands by profile length, back face and end caps "end", bottom face "dark"
    prof = A.HOUSE_PROFILE
    lens = [(Vector(prof[(k + 1) % len(prof)]) - Vector(prof[k])).length for k in range(len(prof))]
    vis = list(range(1, len(prof) - 1))               # top .. front lip, the camera-side faces
    total = sum(lens[k] for k in vis)
    acc = 0.0
    for k in range(len(prof)):
        (ya, za), (yb, zb2) = prof[k], prof[(k + 1) % len(prof)]
        quad = [(xl, ya, za), (xl, yb, zb2), (xr, yb, zb2), (xr, ya, za)]   # outward: profile is CCW seen from +X
        if k in vis:                                  # profile runs top -> bottom here; v = 1 at the top
            va, vb = 1 - acc / total, 1 - (acc + lens[k]) / total
            acc += lens[k]
            m.face(quad, POST, [A.region_uv(A.HOUSING, u(xl), va), A.region_uv(A.HOUSING, u(xl), vb),
                                A.region_uv(A.HOUSING, u(xr), vb), A.region_uv(A.HOUSING, u(xr), va)])
        else:                                         # back face on the door line, bottom face
            m.face(quad, POST, [sw("end" if k == 0 else "dark")] * 4)
    m.face([(xl, y, z) for y, z in reversed(prof)], POST, [sw("end")] * len(prof))
    m.face([(xr, y, z) for y, z in prof], POST, [sw("end")] * len(prof))


def build_material():
    mat = bpy.data.materials.new(TEX.stem)
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.5
    bsdf.inputs["Metallic"].default_value = 0.0
    tex = nt.nodes.new("ShaderNodeTexImage")
    img = bpy.data.images.load(str(TEX), check_existing=True)
    img.name = TEX.stem
    tex.image = img
    tex.interpolation = "Closest"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def add_rig(sc, obj, width):
    arm = bpy.data.armatures.new("Dummy01")
    rig = bpy.data.objects.new("Dummy01", arm)
    sc.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    names = ["PostBone"] + [f"Slat{i:02d}" for i in range(A.SLATS)]
    heads = [Vector((0, 0, 0))] + [Vector(((width - 1) / 2, A.CURTAIN_Y, i * A.SLAT_H)) for i in range(A.SLATS)]
    for name, head in zip(names, heads):
        eb = arm.edit_bones.new(name)
        eb.head, eb.tail, eb.roll = head, head + Vector((0, 0, A.SLAT_H)), 0.0
    bpy.ops.object.mode_set(mode="OBJECT")
    for name in names:                                 # group index = bone order (POST = 0, slat i = 1 + i)
        obj.vertex_groups.new(name=name)
    obj.parent = rig
    obj.modifiers.new("Armature", "ARMATURE").object = rig

    pbs = [rig.pose.bones[n] for n in names]
    for pb in pbs:
        pb.rotation_mode = "QUATERNION"
    ad = rig.animation_data_create()
    for clip, sign in (("Open", 1), ("Close", -1)):
        act = bpy.data.actions.new(clip)
        act.use_fake_user = True
        ad.action = act
        for frame in range(F0, F1 + 1):
            t = (frame - F0) / (F1 - F0)
            travel = A.TRAVEL * ease(t if sign > 0 else 1 - t)
            for i, pb in enumerate(pbs):
                ml = pb.bone.matrix_local
                pb.matrix_basis = Matrix() if i == 0 else ml.inverted() @ slat_matrix(i - 1, travel) @ ml
                pb.keyframe_insert("location", frame=frame)
                pb.keyframe_insert("rotation_quaternion", frame=frame)
        slot = ad.action_slot
        ad.action = None
        track = ad.nla_tracks.new()
        track.name = clip
        strip = track.strips.new(clip, F0, act)
        if hasattr(strip, "action_slot") and slot is not None:
            strip.action_slot = slot
    for pb in pbs:
        pb.matrix_basis = Matrix()
    return rig


def build(width):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.fps, sc.render.fps_base = FPS, 1.0
    sc.frame_start, sc.frame_end = F0, F1
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    name = f"knoxpass_roll2f_{width}" + ("_fast" if FAST else "")
    m = Builder()
    door(m, width)
    me = m.to_mesh(name)
    me.materials.append(build_material())
    obj = bpy.data.objects.new(name, me)
    sc.collection.objects.link(obj)
    rig = add_rig(sc, obj, width)
    for o in sc.objects:
        o.select_set(o in (obj, rig))
    path = HERE / "export" / f"{name}.glb"
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=str(path), export_format="GLB", use_selection=True, export_yup=True, export_apply=False,
        export_texcoords=True, export_normals=True, export_materials="EXPORT", export_image_format="AUTO",
        export_skins=True, export_animations=True, export_animation_mode="ACTIONS", export_force_sampling=True,
        export_frame_step=FRAME_STEP, export_anim_slide_to_zero=False, export_def_bones=False,
        export_cameras=False, export_lights=False,
    )
    print(f"[build] {name}: verts={len(me.vertices)} tris={sum(len(p.vertices) - 2 for p in me.polygons)} "
          f"bones={len(rig.data.bones)} -> {path} ({path.stat().st_size} bytes)")


for w in A.WIDTHS:
    build(w)
