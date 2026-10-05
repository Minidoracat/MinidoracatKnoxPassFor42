"""Knox Pass boom barrier: build the in-game models, save .blend files, export .glb.
用法：blender -b --factory-startup --python build_barrier.py
Idempotent: every variant starts from an empty factory scene and overwrites its outputs.

Full rebuild, run inside scripts/blender/barrier/ ("blender" = Blender 5.2 blender.exe):
    uv run --with pillow python atlas.py                          # textures/knoxpass_barrier.png (Barlow, OFL)
    blender -b --factory-startup --python build_barrier.py        # .blend + export/*.glb
    blender -b --factory-startup --python verify_export.py        # export/knoxpass_barrier_verify.txt
    uv run --with pillow python extract_vanilla_sprites.py        # vanilla_dump/sprites (calibration, gitignored)
    blender -b --factory-startup --python render_tiles.py         # cells/_canvas + previews (+ vanilla calibration)
    uv run --with pillow python assemble_previews.py              # cells/{N,W}/*.png + cells/cells.txt
    uv run scripts/build_barrier_tiles.py                         # (repo root) pack/tiles/scripts into MOD/

export/knoxpass_barrier_cabinet.glb  static: cabinet + cap + dome reader + KNOX PASS front + pivot hub
export/knoxpass_barrier_arm.glb      skinned: armature Dummy01, DoorBone = arm (+ tip cap),
                                     PostBone = static tip rest post with fork; clips Open 0->86 deg,
                                     Close 86->0 deg, 6.0 s each (barrier_arm.blend keeps the source)
export/knoxpass_barrier_empty.glb    static: one ~1 mm triangle 1 cm under the floor ("render nothing")

Rig conventions copied from vanilla fixtures_doors_fences_01_*.blend (vanilla_dump/dump.txt): armature
object "Dummy01", bones "DoorBone" (moving) + "PostBone" (static), bones point +Z, one skinned mesh, one
material/one image, actions "Open"/"Close" stashed on NLA, 24 fps from frame 1, Khronos glTF exporter +Y up.

Model space (Blender, metres = PZ tile units) shared by all three files: origin = centre of the CABINET
tile on the floor, +X = along the lane (arm direction), +Y = toward the gate edge (edge at y = +0.5),
-Y = cabinet front (nameplate). Footprint: cabinet tile x in [-0.5, 0.5], lane tiles 1..3 up to x = 3.5.
"""
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Quaternion, Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import atlas as A  # noqa: E402

LANE_Y = 0.30                         # arm / cabinet centre line, 0.2 m inside the gate edge
PIVOT = Vector((0.20, LANE_Y, 1.0))   # on the cabinet's lane-facing side; axis horizontal along Y; 1.0 m high
OPEN_DEG = 86.0
FPS = 24
F0, F1 = 1, 1 + 6 * FPS               # 6.0 s clip; engine plays at speedDelta 1.5 -> ~4.0 s (IsoObjectAnimations.java:281)
TEX = HERE / "textures" / "knoxpass_barrier.png"
POST, DOOR = 0, 1                     # vertex group indices (vertex_groups are created in this order)


def lift_quat(bone, deg):
    """Pose-space quaternion that lifts the arm tip (+X) by deg about the model Y axis through the pivot."""
    b = bone.matrix_local.to_3x3()
    world = Matrix.Rotation(math.radians(-deg), 3, "Y")   # -deg about +Y moves +X toward +Z
    return (b.inverted() @ world @ b).to_quaternion()


class Builder:
    def __init__(self):
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.verify()
        self.dl = self.bm.verts.layers.deform.verify()

    def _face(self, verts, group, uvs, smooth=False):
        for v in verts:
            v[self.dl][group] = 1.0
        f = self.bm.faces.new(verts)
        f.smooth = smooth
        for loop, uv in zip(f.loops, uvs):
            loop[self.uv].uv = uv
        return f

    def box(self, mn, mx, group, paint):
        """Axis-aligned box. paint(axis, sign) -> colour name or atlas region (projected per face)."""
        mn, mx = Vector(mn), Vector(mx)
        size = mx - mn
        corners = {}
        for i in (0, 1):
            for j in (0, 1):
                for k in (0, 1):
                    corners[i, j, k] = self.bm.verts.new((mx.x if i else mn.x, mx.y if j else mn.y, mx.z if k else mn.z))
        faces = [                         # (axis, sign, ccw corner keys seen from outside)
            (0, -1, [(0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)]),
            (0, 1, [(1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1)]),
            (1, -1, [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)]),
            (1, 1, [(0, 1, 0), (0, 1, 1), (1, 1, 1), (1, 1, 0)]),
            (2, -1, [(0, 0, 0), (0, 1, 0), (1, 1, 0), (1, 0, 0)]),
            (2, 1, [(0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]),
        ]
        uaxis = {0: 1, 1: 0, 2: 0}        # in-plane axes: X faces use (Y, Z), Y faces (X, Z), Z faces (X, Y)
        vaxis = {0: 2, 1: 2, 2: 1}
        for axis, sign, keys in faces:
            p = paint(axis, sign)
            verts = [corners[k] for k in keys]
            if isinstance(p, str):
                uvs = [A.swatch_uv(p)] * 4
            else:
                ua, va = uaxis[axis], vaxis[axis]
                uvs = [A.region_uv(p, (v.co[ua] - mn[ua]) / size[ua], (v.co[va] - mn[va]) / size[va]) for v in verts]
            self._face(verts, group, uvs)

    def cylinder_y(self, centre, r, depth, n, group, colour):
        """Prism with its axis along Y (hub disc)."""
        uv = A.swatch_uv(colour)
        a, b = ([self.bm.verts.new((centre.x + r * math.cos(2 * math.pi * i / n), y,
                                    centre.z + r * math.sin(2 * math.pi * i / n))) for i in range(n)]
                for y in (centre.y - depth / 2, centre.y + depth / 2))
        for i in range(n):
            j = (i + 1) % n
            self._face([a[i], a[j], b[j], b[i]], group, [uv] * 4, smooth=True)
        self._face(list(reversed(a)), group, [uv] * n)
        self._face(b, group, [uv] * n)

    def dome(self, centre, r, zscale, n, rings, group, colour):
        """Closed hemisphere (flat bottom) sitting on centre.z."""
        uv = A.swatch_uv(colour)
        layers = []
        for k in range(rings):
            phi = (math.pi / 2) * k / rings
            layers.append([self.bm.verts.new((centre.x + r * math.cos(phi) * math.cos(2 * math.pi * i / n),
                                              centre.y + r * math.cos(phi) * math.sin(2 * math.pi * i / n),
                                              centre.z + r * zscale * math.sin(phi))) for i in range(n)])
        top = self.bm.verts.new((centre.x, centre.y, centre.z + r * zscale))
        for k in range(rings - 1):
            a, b = layers[k], layers[k + 1]
            for i in range(n):
                j = (i + 1) % n
                self._face([a[i], a[j], b[j], b[i]], group, [uv] * 4, smooth=True)
        last = layers[-1]
        for i in range(n):
            self._face([last[i], last[(i + 1) % n], top], group, [uv] * 3, smooth=True)
        self._face(list(reversed(layers[0])), group, [uv] * n)

    def to_mesh(self, name):
        me = bpy.data.meshes.new(name)
        self.bm.normal_update()
        self.bm.to_mesh(me)
        self.bm.free()
        me.uv_layers[0].name = "UVMap"
        return me


def cabinet(m):
    hw, hd = A.CAB_W / 2, A.CAB_D / 2
    y0 = LANE_Y - hd                                      # front face (-Y) at y = 0.12
    m.box((-hw, y0, 0), (hw, LANE_Y + hd, A.CAB_H), POST, lambda ax, s: A.FRONT if (ax, s) == (1, -1) else "orange")
    m.box((-hw - 0.015, y0 - 0.015, A.CAB_H), (hw + 0.015, LANE_Y + hd + 0.015, A.CAB_H + 0.05), POST,
          lambda ax, s: "cap")
    m.dome(Vector((0, LANE_Y - 0.04, A.CAB_H + 0.05)), 0.06, 0.7, 10, 3, POST, "dome")
    m.cylinder_y(Vector((PIVOT.x, LANE_Y, PIVOT.z)), 0.075, 0.08, 10, POST, "cap")


def arm(m):
    arm_h, arm_t = 0.085, 0.05
    x1 = PIVOT.x + A.ARM_LEN                              # 3.46: arm + cap end inside the 4th tile (x < 3.5)
    m.box((PIVOT.x, LANE_Y - arm_t / 2, PIVOT.z - arm_h / 2), (x1, LANE_Y + arm_t / 2, PIVOT.z + arm_h / 2), DOOR,
          lambda ax, s: "white" if ax == 0 else A.ARM)
    m.box((x1, LANE_Y - 0.0275, PIVOT.z - 0.045), (x1 + 0.03, LANE_Y + 0.0275, PIVOT.z + 0.045), DOOR,
          lambda ax, s: "dark")
    post_x = x1 - 0.16                                    # tip rest post (static), arm rests in the fork
    post_top = PIVOT.z - arm_h / 2 - 0.005
    m.box((post_x - 0.04, LANE_Y - 0.04, 0), (post_x + 0.04, LANE_Y + 0.04, post_top), POST, lambda ax, s: "orange")
    for sy in (-1, 1):
        yc = LANE_Y + sy * 0.04
        m.box((post_x - 0.015, yc - 0.006, post_top - 0.02), (post_x + 0.015, yc + 0.006, post_top + 0.10), POST,
              lambda ax, s: "dark")


def empty(m):
    uv = A.swatch_uv("dark")
    v = [m.bm.verts.new(co) for co in ((0, 0, -0.01), (0.001, 0, -0.01), (0, 0.001, -0.01))]
    m._face(v, POST, [uv] * 3)


def build_material():
    mat = bpy.data.materials.new("knoxpass_barrier")
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.5
    bsdf.inputs["Metallic"].default_value = 0.0
    tex = nt.nodes.new("ShaderNodeTexImage")
    img = bpy.data.images.load(str(TEX), check_existing=True)
    img.name = "knoxpass_barrier"
    tex.image = img
    tex.interpolation = "Closest"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def add_rig(sc, obj):
    arm_data = bpy.data.armatures.new("Dummy01")
    rig = bpy.data.objects.new("Dummy01", arm_data)
    sc.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    for bone, head in (("PostBone", Vector((0, 0, 0))), ("DoorBone", PIVOT)):
        eb = arm_data.edit_bones.new(bone)
        eb.head, eb.tail, eb.roll = head, head + Vector((0, 0, 1)), 0.0
    bpy.ops.object.mode_set(mode="OBJECT")
    for g in ("PostBone", "DoorBone"):
        obj.vertex_groups.new(name=g)
    obj.parent = rig
    obj.modifiers.new("Armature", "ARMATURE").object = rig

    door, post = rig.pose.bones["DoorBone"], rig.pose.bones["PostBone"]
    for pb in (door, post):
        pb.rotation_mode = "QUATERNION"
    ad = rig.animation_data_create()
    for clip, a0, a1 in (("Open", 0.0, OPEN_DEG), ("Close", OPEN_DEG, 0.0)):
        act = bpy.data.actions.new(clip)
        act.use_fake_user = True
        ad.action = act
        for frame, deg in ((F0, a0), (F1, a1)):
            door.rotation_quaternion = lift_quat(door.bone, deg)
            post.rotation_quaternion = Quaternion()
            for pb in (door, post):
                pb.location = (0, 0, 0)
                pb.keyframe_insert("rotation_quaternion", frame=frame)
                pb.keyframe_insert("location", frame=frame)
        slot = ad.action_slot
        ad.action = None
        track = ad.nla_tracks.new()
        track.name = clip
        strip = track.strips.new(clip, F0, act)
        if hasattr(strip, "action_slot") and slot is not None:
            strip.action_slot = slot
    for pb in (door, post):
        pb.rotation_quaternion = Quaternion()
    return rig


def build_variant(name, parts, rigged, blend=None):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.fps, sc.render.fps_base = FPS, 1.0
    sc.frame_start, sc.frame_end = F0, F1
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    m = Builder()
    parts(m)
    me = m.to_mesh(name)
    me.materials.append(build_material())
    obj = bpy.data.objects.new(name, me)
    sc.collection.objects.link(obj)
    keep = [obj, add_rig(sc, obj)] if rigged else [obj]
    if blend:
        bpy.ops.wm.save_as_mainfile(filepath=str(HERE / blend), relative_remap=True)
    for o in sc.objects:
        o.select_set(o in keep)
    path = HERE / "export" / f"{name}.glb"
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=str(path), export_format="GLB", use_selection=True, export_yup=True, export_apply=False,
        export_texcoords=True, export_normals=True, export_materials="EXPORT", export_image_format="AUTO",
        export_skins=rigged, export_animations=rigged, export_animation_mode="ACTIONS", export_force_sampling=True,
        export_anim_slide_to_zero=False, export_def_bones=False, export_cameras=False, export_lights=False,
    )
    print(f"[build] {name}: verts={len(me.vertices)} tris={sum(len(p.vertices) - 2 for p in me.polygons)} -> {path}")


build_variant("knoxpass_barrier_cabinet", cabinet, False, blend="barrier_cabinet.blend")
build_variant("knoxpass_barrier_arm", arm, True, blend="barrier_arm.blend")
build_variant("knoxpass_barrier_empty", empty, False)
