"""Knox Pass double boom barrier (barrier2): one animated model per width, exported to export/*.glb.
用法：blender -b --factory-startup --python build_barrier2.py      (rebuild order: README.md)
    KNOXPASS_FAST=1 blender -b --factory-startup --python build_barrier2.py   # export/knoxpass_barrier2_boom{6,9}_fast.glb:
                                                                    # 每扇門可選的「加速」，clip 3.75 s（build_barrier.py FAST）

export/knoxpass_barrier2_boom{6,9}.glb  skinned, armature Dummy01:
    DoorBone  = boom A (pivot at the end-A cabinet, tip toward +X), same 0.16 x 0.10 red/white boom, end cap and
                STOP sign as the single barrier arm (scripts/blender/barrier/build_barrier.py arm())
    DoorBoneB = boom B = boom A turned 180 deg about the vertical axis through the lane-row middle (pivot at the
                end-B cabinet, tip toward -X); the two end caps meet 3 cm apart over the middle
    PostBone  = static: both pivot lamps (lens = "lamp" swatch: red in knoxpass_barrier.png, green in _green.png),
                rest posts at the 3-tile car-lane boundaries (x = 3.5 for L 6; 3.5 and 6.5 for L 9: never inside a
                car lane), each with a fork under the boom above it, road paint (stop line + KNOX PASS per 3-tile
                car lane, both sides of the gate line, letters upright for the approaching driver, 2 cm up)
    clips Open 0 -> 86 deg, Close 86 -> 0 deg, both booms together, 6.0 s at 24 fps (= the single barrier arm);
          angle = 86 * ease(t) keyed on every frame (scripts/blender/ease.py, shared by every Knox Pass door clip),
          Close = Open reversed
Texture = the single barrier atlas (scripts/blender/barrier/textures/knoxpass_barrier{,_green}.png), same UV layout.

Model space = the single barrier arm's (metres = tile units): origin = centre of the END-A cabinet tile on the floor,
+X along the lane row, +Y toward the gate edge (y = +0.5), lane k tile centre at x = k (k = 1..L), end-B cabinet
tile centre at x = L + 1, lane-row middle at x = (L + 1) / 2.
"""
import math
import sys
import types
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Quaternion, Vector

HERE = Path(__file__).resolve().parent
BARRIER = HERE.parent / "barrier"
sys.dont_write_bytecode = True           # no __pycache__ in the single barrier's folder
sys.path.insert(0, str(BARRIER))
sys.path.insert(0, str(HERE.parent))
import atlas as A  # noqa: E402
from ease import ease  # noqa: E402

# build_barrier.py has no __main__ guard (it builds on import): run only its definitions, i.e. everything above its
# first build_variant(...) call. Reused: Builder, build_material, lift_quat, PIVOT, LANE_Y, GATE_Y, FPS, F0, F1, OPEN_DEG.
_src = (BARRIER / "build_barrier.py").read_text(encoding="utf-8")
B = types.ModuleType("build_barrier")
B.__file__ = str(BARRIER / "build_barrier.py")
exec(compile(_src[:_src.index("\nbuild_variant(")], B.__file__, "exec"), B.__dict__)

WIDTHS = (6, 9)
POST, DOOR, DOOR_B = 0, 1, 2              # vertex group indices = BONES order
BONES = ("PostBone", "DoorBone", "DoorBoneB")
CAP = 0.03                                # tip end cap length
GAP = 0.015                               # cap end -> lane-row middle


def mid(L):
    return (L + 1) / 2


def pivot_b(L):
    return Vector((2 * mid(L) - B.PIVOT.x, B.PIVOT.y, B.PIVOT.z))


def boom_a(m, L):
    """Boom A + its pivot lamp. The atlas arm strip is ARM_LEN long: a longer boom continues on a second box whose
    strip window starts a whole number of red+white band pairs earlier, so bands and reflectors run on in phase."""
    h, t, P, y = A.ARM_H, A.ARM_T, B.PIVOT, B.LANE_Y
    x1 = mid(L) - GAP - CAP
    length = x1 - P.x
    assert length <= 2 * A.ARM_LEN, length
    for u0 in (0.0, A.ARM_LEN):
        if u0 >= length:
            break
        u1 = min(length, u0 + A.ARM_LEN)
        s = u0 // (2 * A.BAND) * 2 * A.BAND
        assert u1 - s <= A.ARM_LEN

        def sub(r, u0=u0, u1=u1, s=s):
            px = (r[2] - r[0]) / A.ARM_LEN
            return (r[0] + (u0 - s) * px, r[1], r[0] + (u1 - s) * px, r[3])
        m.box((P.x + u0, y - t / 2, P.z - h / 2), (P.x + u1, y + t / 2, P.z + h / 2), DOOR,
              lambda ax, sg: "white" if ax == 0 else sub(A.ARM) if ax == 1 else sub(A.ARM_TOP))
    m.box((x1, y - t / 2 - 0.005, P.z - h / 2 - 0.005), (x1 + CAP, y + t / 2 + 0.005, P.z + h / 2 + 0.005),
          DOOR, lambda ax, s: "dark")
    m.octagon_y(Vector((P.x + A.SIGN_U, y, P.z)), A.SIGN_APOTHEM, t + 0.012, DOOR, A.SIGN, "white")
    hd = t / 2 + 0.03                                     # lamp housing + lenses on both traffic faces (static)
    m.cylinder_y(P, 0.12, 2 * hd, 16, POST, "cap")
    for sy in (-1, 1):
        m.cylinder_y(Vector((P.x, y + sy * (hd + 0.004), P.z)), 0.095, 0.008, 16, POST, "lamp")


def booms(m, L):
    bm, dl = m.bm, m.dl
    old_v, old_e, old_f = set(bm.verts), set(bm.edges), set(bm.faces)
    boom_a(m, L)
    geom = ([v for v in bm.verts if v not in old_v] + [e for e in bm.edges if e not in old_e]
            + [f for f in bm.faces if f not in old_f])
    dup = [g for g in bmesh.ops.duplicate(bm, geom=geom)["geom"] if isinstance(g, bmesh.types.BMVert)]
    bmesh.ops.rotate(bm, cent=(mid(L), B.LANE_Y, 0.0), matrix=Matrix.Rotation(math.pi, 3, "Z"), verts=dup)
    for v in dup:                                         # boom verts -> DoorBoneB, lamp verts stay on PostBone
        if DOOR in v[dl].keys():
            v[dl].clear()
            v[dl][DOOR_B] = 1.0


def post_xs(L):
    """Rest posts on the car-lane boundaries: a car in any 3-tile car lane never drives through one."""
    return [3 * c + 0.5 for c in range(1, L // 3)]


def rest_posts(m, L):
    """Same post / collar / fork as the single barrier, static; the boom above rests in the fork."""
    h, t, y = A.ARM_H, A.ARM_T, B.LANE_Y
    top, pw = B.PIVOT.z - h / 2 - 0.005, t / 2 + 0.015
    for px in post_xs(L):
        m.box((px - pw, y - pw, 0), (px + pw, y + pw, top), POST, lambda ax, s: "navy")
        m.box((px - pw - 0.01, y - pw - 0.01, top - 0.06), (px + pw + 0.01, y + pw + 0.01, top), POST,
              lambda ax, s: "amber")
        for sy in (-1, 1):
            yc = y + sy * (t / 2 + 0.008)
            m.box((px - 0.015, yc - 0.006, top - 0.02), (px + 0.015, yc + 0.006, top + 0.12), POST, lambda ax, s: "dark")


def paint(m, L):
    """Road paint of the single barrier (build_barrier.py lines()) repeated per 3-tile car lane."""
    z = 0.02
    for c in range(L // 3):
        xa, xb = 0.56 + 3 * c, 3.44 + 3 * c
        for side in (-1, 1):                              # -1 = lane-tile side, +1 = far side of the gate line
            near, far = B.GATE_Y + side * 0.55, B.GATE_Y + side * 0.75
            m.quad_up(xa, min(near, far), xb, max(near, far), z, POST, "paint_white")
            t0, t1 = B.GATE_Y + side * 0.95, B.GATE_Y + side * 1.55
            m.text_up("KNOX PASS", xa + 0.12, min(t0, t1), xb - 0.12, max(t0, t1), z, side > 0, POST, "amber")


def add_rig(sc, obj, L):
    arm_data = bpy.data.armatures.new("Dummy01")
    rig = bpy.data.objects.new("Dummy01", arm_data)
    sc.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    for bone, head in zip(BONES, (Vector((0, 0, 0)), B.PIVOT, pivot_b(L))):
        eb = arm_data.edit_bones.new(bone)
        eb.head, eb.tail, eb.roll = head, head + Vector((0, 0, 1)), 0.0
    bpy.ops.object.mode_set(mode="OBJECT")
    for g in BONES:
        obj.vertex_groups.new(name=g)
    obj.parent = rig
    obj.modifiers.new("Armature", "ARMATURE").object = rig

    pbs = [rig.pose.bones[b] for b in BONES]
    for pb in pbs:
        pb.rotation_mode = "QUATERNION"
    post, door, door_b = pbs
    ad = rig.animation_data_create()
    n = B.F1 - B.F0
    for clip, rev in (("Open", False), ("Close", True)):
        act = bpy.data.actions.new(clip)
        act.use_fake_user = True
        ad.action = act
        for i in range(n + 1):                            # every frame: the eased curve is baked, not interpolated
            frame, t = B.F0 + i, i / n
            deg = B.OPEN_DEG * ease(1 - t if rev else t)
            post.rotation_quaternion = Quaternion()
            door.rotation_quaternion = B.lift_quat(door.bone, deg)
            door_b.rotation_quaternion = B.lift_quat(door_b.bone, -deg)   # tip at -X: lift = +deg about Y
            for pb in pbs:
                pb.location = (0, 0, 0)
                pb.keyframe_insert("rotation_quaternion", frame=frame)
                pb.keyframe_insert("location", frame=frame)
        slot = ad.action_slot
        ad.action = None
        track = ad.nla_tracks.new()
        track.name = clip
        strip = track.strips.new(clip, B.F0, act)
        if hasattr(strip, "action_slot") and slot is not None:
            strip.action_slot = slot
    for pb in pbs:
        pb.rotation_quaternion = Quaternion()
    return rig


def build(L):
    name = f"knoxpass_barrier2_boom{L}" + ("_fast" if B.FAST else "")   # KNOXPASS_FAST=1：同一個模型，clip 用 B.F1 的加速版
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.fps, sc.render.fps_base = B.FPS, 1.0
    sc.frame_start, sc.frame_end = B.F0, B.F1
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    m = B.Builder()
    booms(m, L)
    rest_posts(m, L)
    paint(m, L)
    me = m.to_mesh(name)
    me.materials.append(B.build_material())
    obj = bpy.data.objects.new(name, me)
    sc.collection.objects.link(obj)
    keep = [obj, add_rig(sc, obj, L)]
    for o in sc.objects:
        o.select_set(o in keep)
    path = HERE / "export" / f"{name}.glb"
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(   # = build_barrier.py build_variant(rigged=True)
        filepath=str(path), export_format="GLB", use_selection=True, export_yup=True, export_apply=False,
        export_texcoords=True, export_normals=True, export_materials="EXPORT", export_image_format="AUTO",
        export_skins=True, export_animations=True, export_animation_mode="ACTIONS", export_force_sampling=True,
        export_anim_slide_to_zero=False, export_def_bones=False, export_cameras=False, export_lights=False,
    )
    print(f"[build] {name}: verts={len(me.vertices)} tris={sum(len(p.vertices) - 2 for p in me.polygons)} -> {path}")


for L in WIDTHS:
    build(L)
