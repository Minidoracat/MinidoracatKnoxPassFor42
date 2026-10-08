"""Knox Pass boom barrier: build the in-game models, save .blend files, export .glb.
用法：blender -b --factory-startup --python build_barrier.py
Idempotent: every variant starts from an empty factory scene and overwrites its outputs.

Full rebuild, run inside scripts/blender/barrier/ ("blender" = Blender 5.2 blender.exe):
    uv run --with pillow python atlas.py                          # textures/knoxpass_barrier{,_green}.png (Barlow, OFL)
    blender -b --factory-startup --python build_barrier.py        # .blend + export/*.glb
    blender -b --factory-startup --python verify_export.py        # export/knoxpass_barrier_verify.txt
    uv run --with pillow python extract_vanilla_sprites.py        # vanilla_dump/sprites (calibration, gitignored)
    blender -b --factory-startup --python render_tiles.py         # cells/_canvas + previews (+ vanilla calibration)
                                                                  # + cells/reader/ (`-- reader` renders only those)
    uv run --with pillow python assemble_previews.py              # cells/{N,W}/*.png + cells/cells.txt
    uv run --with pillow python reader_previews.py                # previews/reader_*.png (reader on vanilla doors)
    uv run scripts/build_barrier_tiles.py                         # (repo root) pack/tiles/scripts into MOD/
Door-post reader only (model or cells changed): build_barrier.py, render_tiles.py -- reader, build_barrier_tiles.py.

export/knoxpass_barrier_cabinet.glb  static: navy/amber cabinet + amber cap + dome reader, KNOX PASS plate on both
                                     traffic faces (+-Y), vertical KNOX PASS on +-X
export/knoxpass_barrier_arm.glb      skinned: armature Dummy01, DoorBone = 0.16 x 0.10 red/white arm (+ tip cap,
                                     reflectors, STOP octagon at the middle lane); PostBone = static lamp at the
                                     pivot (lens = "lamp" swatch: red in knoxpass_barrier.png, green in _green.png)
                                     + tip rest post with fork; clips Open 0->86 deg, Close 86->0 deg, 6.0 s each,
                                     keyed every frame on the shared ease (scripts/blender/ease.py; Close = reverse)
export/knoxpass_barrier_lines.glb    static: road paint, 2 cm above the floor: white stop line + amber KNOX PASS on
                                     both sides of the gate line, text facing oncoming traffic (Barlow, OFL)
export/knoxpass_barrier_empty.glb    static: one ~1 mm triangle 1 cm under the floor ("render nothing")
export/knoxpass_reader_post.glb      static: Knox Pass reader hung on a door post (gate reader install), both faces
                                     of the wall line: steel back plate + cream radome with the navy KNOX PASS band
                                     (item design B), junction box below, cable, conduit to the floor. Texture = the
                                     reader item texture (MOD textures/WorldItems/MinidoracatKnoxPassReader.png,
                                     painted by scripts/blender/build.py). Own model space, see reader_post().

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
sys.path.insert(0, str(HERE.parent))
import atlas as A  # noqa: E402
from ease import ease  # noqa: E402

LANE_Y = 0.30                         # arm / cabinet centre line, 0.2 m inside the gate edge
PIVOT = Vector((0.27, LANE_Y, 1.0))   # 0.11 m off the cabinet side: the raised 0.16 m arm clears the cap at 86 deg
GATE_Y = 0.5                          # gate line (tile edge of the door)
FONT = HERE / "fonts" / "Barlow-SemiBold.ttf"
OPEN_DEG = 86.0
FPS = 24
F0, F1 = 1, 1 + 6 * FPS               # 6.0 s clip; engine plays at speedDelta 1.5 -> ~4.0 s (IsoObjectAnimations.java:281)
TEX = HERE / "textures" / "knoxpass_barrier.png"
# reader item texture and its layout (pixels, top-left origin): same numbers as scripts/blender/build.py
# READER_FACE / READER_JLBL / READER_SW (that script needs PIL, which Blender's Python does not ship)
READER_TEX = HERE.parents[2] / "MOD/MinidoracatKnoxPassFor42/Contents/mods/MinidoracatKnoxPassFor42/42/media/textures/WorldItems/MinidoracatKnoxPassReader.png"
READER_FACE, READER_JLBL = (0, 0, 320, 320), (336, 0, 496, 100)
READER_SW = {name: (x + 4, 340, x + 36, 372) for name, x in
             {"radome": 0, "side": 48, "steel": 96, "jbox": 144, "cable": 192}.items()}
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
        """Axis-aligned box. paint(axis, sign) -> colour name, atlas region (projected per face, world-consistent u),
        or ("read", region): u runs to the viewer's right on every side face, so text is never mirrored."""
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
                flip = p[0] == "read" and (axis, sign) in ((0, -1), (1, 1))   # viewer's right = -u on these faces
                region = p[1] if p[0] == "read" else p
                ua, va = uaxis[axis], vaxis[axis]
                uvs = []
                for v in verts:
                    u = (v.co[ua] - mn[ua]) / size[ua]
                    uvs.append(A.region_uv(region, 1 - u if flip else u, (v.co[va] - mn[va]) / size[va]))
            self._face(verts, group, uvs)

    def cylinder_y(self, centre, r, depth, n, group, colour):
        """Prism with its axis along Y (lamp housing, lens), wound outward (the door shader culls back faces)."""
        uv = A.swatch_uv(colour)
        a, b = ([self.bm.verts.new((centre.x + r * math.cos(2 * math.pi * i / n), y,
                                    centre.z + r * math.sin(2 * math.pi * i / n))) for i in range(n)]
                for y in (centre.y - depth / 2, centre.y + depth / 2))
        for i in range(n):
            j = (i + 1) % n
            self._face([a[i], b[i], b[j], a[j]], group, [uv] * 4, smooth=True)
        self._face(a, group, [uv] * n)
        self._face(list(reversed(b)), group, [uv] * n)

    def octagon_y(self, centre, apothem, depth, group, region, rim):
        """Octagonal plate, flat top, normal +-Y; both faces map `region` so the text reads right from either side."""
        r = apothem / math.cos(math.radians(22.5))
        ring = [(math.cos(math.radians(22.5 + 45 * k)), math.sin(math.radians(22.5 + 45 * k))) for k in range(8)]
        f, b = ([self.bm.verts.new((centre.x + r * c, y, centre.z + r * s)) for c, s in ring]
                for y in (centre.y - depth / 2, centre.y + depth / 2))
        uv = lambda c, s, mirror: A.region_uv(region, (1 - c if mirror else 1 + c) / 2, (1 + s) / 2)  # noqa: E731
        self._face(f, group, [uv(c, s, False) for c, s in ring])
        self._face(list(reversed(b)), group, [uv(c, s, True) for c, s in reversed(ring)])
        rim_uv = A.swatch_uv(rim)
        for i in range(8):
            j = (i + 1) % 8
            self._face([f[i], b[i], b[j], f[j]], group, [rim_uv] * 4)

    def quad_up(self, x0, y0, x1, y1, z, group, colour):
        uv = A.swatch_uv(colour)
        v = [self.bm.verts.new(co) for co in ((x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z))]
        self._face(v, group, [uv] * 4)

    def text_up(self, text, x0, y0, x1, y1, z, turn, group, colour):
        """Flat text mesh (Barlow, curve fill) stretched into the rectangle, facing +Z. turn=True rotates it 180 deg
        so it reads from the +Y side."""
        cu = bpy.data.curves.new("t", "FONT")
        cu.body, cu.font, cu.resolution_u = text, bpy.data.fonts.load(str(FONT)), 3
        ob = bpy.data.objects.new("t", cu)
        bpy.context.scene.collection.objects.link(ob)
        me = bpy.data.meshes.new_from_object(ob.evaluated_get(bpy.context.evaluated_depsgraph_get()))
        xs, ys = [v.co.x for v in me.vertices], [v.co.y for v in me.vertices]
        mnx, mxx, mny, mxy = min(xs), max(xs), min(ys), max(ys)
        uv = A.swatch_uv(colour)
        new = {}
        for v in me.vertices:
            u, w = (v.co.x - mnx) / (mxx - mnx), (v.co.y - mny) / (mxy - mny)
            if turn:
                u, w = 1 - u, 1 - w
            new[v.index] = self.bm.verts.new((x0 + u * (x1 - x0), y0 + w * (y1 - y0), z))
        for p in me.polygons:
            vs = [new[i] for i in p.vertices]
            if p.normal.z < 0:                    # curve fill winding is not guaranteed; face up
                vs.reverse()
            self._face(vs, group, [uv] * len(vs))
        bpy.data.objects.remove(ob)
        bpy.data.curves.remove(cu)
        bpy.data.meshes.remove(me)

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
    m.box((-hw, y0, 0), (hw, LANE_Y + hd, A.CAB_H), POST,
          lambda ax, s: ("read", A.FRONT) if ax == 1 else ("read", A.SIDE) if ax == 0 else "navy")
    m.box((-hw - 0.015, y0 - 0.015, A.CAB_H), (hw + 0.015, LANE_Y + hd + 0.015, A.CAB_H + 0.05), POST,
          lambda ax, s: "amber")
    m.dome(Vector((0, LANE_Y - 0.04, A.CAB_H + 0.05)), 0.06, 0.7, 10, 3, POST, "dome")


def arm(m):
    h, t = A.ARM_H, A.ARM_T
    x1 = PIVOT.x + A.ARM_LEN                              # 3.46: arm + cap end inside the 4th tile (x < 3.5)
    m.box((PIVOT.x, LANE_Y - t / 2, PIVOT.z - h / 2), (x1, LANE_Y + t / 2, PIVOT.z + h / 2), DOOR,
          lambda ax, s: "white" if ax == 0 else A.ARM if ax == 1 else A.ARM_TOP)
    m.box((x1, LANE_Y - t / 2 - 0.005, PIVOT.z - h / 2 - 0.005), (x1 + 0.03, LANE_Y + t / 2 + 0.005, PIVOT.z + h / 2 + 0.005),
          DOOR, lambda ax, s: "dark")
    # STOP sign: plate 6 mm proud of both arm faces, rides on DoorBone
    m.octagon_y(Vector((PIVOT.x + A.SIGN_U, LANE_Y, PIVOT.z)), A.SIGN_APOTHEM, t + 0.012, DOOR, A.SIGN, "white")
    # signal lamp on the pivot (PostBone, static): housing, lens on both traffic faces; the lens colour comes from
    # the texture (red default, green via spriteModels texture = on open tiles / opening poses)
    hd = t / 2 + 0.03
    m.cylinder_y(PIVOT, 0.12, 2 * hd, 16, POST, "cap")
    for sy in (-1, 1):
        m.cylinder_y(Vector((PIVOT.x, LANE_Y + sy * (hd + 0.004), PIVOT.z)), 0.095, 0.008, 16, POST, "lamp")
    post_x = x1 - 0.16                                    # tip rest post (static), arm rests in the fork
    post_top = PIVOT.z - h / 2 - 0.005
    pw = t / 2 + 0.015
    m.box((post_x - pw, LANE_Y - pw, 0), (post_x + pw, LANE_Y + pw, post_top), POST, lambda ax, s: "navy")
    m.box((post_x - pw - 0.01, LANE_Y - pw - 0.01, post_top - 0.06), (post_x + pw + 0.01, LANE_Y + pw + 0.01, post_top),
          POST, lambda ax, s: "amber")
    for sy in (-1, 1):
        yc = LANE_Y + sy * (t / 2 + 0.008)
        m.box((post_x - 0.015, yc - 0.006, post_top - 0.02), (post_x + 0.015, yc + 0.006, post_top + 0.12), POST,
              lambda ax, s: "dark")


def lines(m):
    """Road paint over lanes 1..3 (x 0.5..3.5), mirrored about the gate line: stop line 0.55-0.75 from the line,
    KNOX PASS beyond it, letters upright for the driver approaching that side."""
    z, xa, xb = 0.02, 0.56, 3.44
    for side in (-1, 1):                                  # -1 = lane-tile side (Blender -Y), +1 = the far side
        near, far = GATE_Y + side * 0.55, GATE_Y + side * 0.75
        m.quad_up(xa, min(near, far), xb, max(near, far), z, POST, "paint_white")
        t0, t1 = GATE_Y + side * 0.95, GATE_Y + side * 1.55
        m.text_up("KNOX PASS", xa + 0.12, min(t0, t1), xb - 0.12, max(t0, t1), z, side > 0, POST, "amber")


def empty(m):
    uv = A.swatch_uv("dark")
    v = [m.bm.verts.new(co) for co in ((0, 0, -0.01), (0.001, 0, -0.01), (0, 0.001, -0.01))]
    m._face(v, POST, [uv] * 3)


def reader_post(m):
    """Reader hung on a door post. Model space: origin = the post (tile corner) on the floor, +X = along the wall line
    into the door opening, +-Y = the two faces of the wall line, Z up (metres = tile units; one floor = 2.449).
    Everything sits at x < -0.02 (beyond the post, away from the opening: the leaf swings about the hinge post and
    never reaches x < 0) and |y| >= 0.04 (on the faces, not inside the wall line). Same parts mirrored on both faces
    so a car reads it from either side; text reads unmirrored on both (Builder.box "read").
    Plate 0.34 x 0.34 (the item is 0.25: ~31 px wide at the default zoom), centre 0.92 up (car window height)."""
    for s in (1, -1):
        def box(x0, x1, y0, y1, z0, z1, paint, s=s):
            m.box((x0, min(s * y0, s * y1), z0), (x1, max(s * y0, s * y1), z1), POST, paint)
        box(-0.42, -0.06, 0.06, 0.075, 0.74, 1.10, lambda ax, sg: READER_SW["steel"])                 # back plate
        box(-0.41, -0.07, 0.075, 0.105, 0.75, 1.09,                                                # radome
            lambda ax, sg, s=s: ("read", READER_FACE) if (ax, sg) == (1, s) else READER_SW["side"])
        box(-0.075, -0.025, 0.04, 0.075, 0.86, 0.98, lambda ax, sg: READER_SW["steel"])             # post bracket
        box(-0.245, -0.225, 0.07, 0.085, 0.66, 0.75, lambda ax, sg: READER_SW["cable"])             # cable
        box(-0.30, -0.17, 0.06, 0.10, 0.56, 0.66,                                                  # junction box
            lambda ax, sg, s=s: ("read", READER_JLBL) if (ax, sg) == (1, s) else READER_SW["jbox"])
        box(-0.215, -0.195, 0.065, 0.08, 0.0, 0.56, lambda ax, sg: READER_SW["cable"])              # conduit


def build_material(path=TEX):
    mat = bpy.data.materials.new(path.stem)
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.5
    bsdf.inputs["Metallic"].default_value = 0.0
    tex = nt.nodes.new("ShaderNodeTexImage")
    img = bpy.data.images.load(str(path), check_existing=True)
    img.name = path.stem
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
    for clip, angle in (("Open", lambda t: OPEN_DEG * ease(t)), ("Close", lambda t: OPEN_DEG * (1.0 - ease(t)))):
        act = bpy.data.actions.new(clip)
        act.use_fake_user = True
        ad.action = act
        for frame in range(F0, F1 + 1):   # every frame keyed (LINEAR between): the eased curve is baked in
            door.rotation_quaternion = lift_quat(door.bone, angle((frame - F0) / (F1 - F0)))
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


def build_variant(name, parts, rigged, blend=None, tex=TEX):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.fps, sc.render.fps_base = FPS, 1.0
    sc.frame_start, sc.frame_end = F0, F1
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    m = Builder()
    parts(m)
    me = m.to_mesh(name)
    me.materials.append(build_material(tex))
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
build_variant("knoxpass_barrier_lines", lines, False)
build_variant("knoxpass_barrier_empty", empty, False)
build_variant("knoxpass_reader_post", reader_post, False, tex=READER_TEX)
