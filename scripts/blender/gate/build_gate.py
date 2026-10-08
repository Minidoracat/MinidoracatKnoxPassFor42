"""Knox Pass two-story double-leaf gate: build the leaf models (per look x width) and post models (per look), export .glb.
用法：blender -b --factory-startup --python build_gate.py [-- A C ...]      (default: all looks)
Idempotent: every model starts from an empty factory scene and overwrites export/<name>.glb.

export/MinidoracatKnoxPass_gate_<look><L>.glb   skinned: armature Dummy01; PostBone (origin, no geometry),
    DoorBoneA (hinge of the leaf on the model's -X side, head (hinge_x, PLANE_Y, 0)), DoorBoneB (mirror, head
    (L + 1 - hinge_x, PLANE_Y, 0)); bones point +Z. Clips Open (0 -> 90 deg) and Close (90 -> 0 deg), 6.0 s at 24 fps
    from frame 1 (engine speedDelta 1.5 -> ~4 s), keyed on every frame along scripts/blender/ease.py (trapezoidal
    speed: eased start and stop, half-way pose at t = 0.5 unchanged). Opening turns DoorBoneA by -90 deg about +Z
    (leaf tip +X -> -Y) and DoorBoneB by +90 deg (tip -X -> -Y): both leaves swing to -Y, the post side of the line.
export/MinidoracatKnoxPass_gatepost_<look>.glb  static post on its own tile (see spec.py), symmetric about x = 0.
Both use textures/MinidoracatKnoxPass_gate_<look>.png (atlas.py). Model space and per-face transforms: spec.py.
export/knoxpass_reader_pillar_<look>.glb  static: the door-post reader (barrier build_barrier.py reader_post(), reader
    item texture / UVs) moved onto the end-A post's two faces normal to traffic, same model space as the post.
Rig / export conventions copied from scripts/blender/barrier/build_barrier.py (vanilla fixtures_doors_fences_01 rig:
armature Dummy01, one skinned mesh, one material / image, actions stashed on NLA, Khronos glTF exporter +Y up).
"""
import math
import sys
import types
from itertools import product
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Quaternion, Vector

sys.dont_write_bytecode = True       # the exec of ../barrier/build_barrier.py imports its atlas: no __pycache__ there

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.append(str(HERE.parent))       # after HERE: our atlas / spec win over any same-named module there
import atlas as A  # noqa: E402
import spec as S  # noqa: E402
from ease import ease  # noqa: E402  (scripts/blender/ease.py: shared door-clip speed curve)

POST, LEAF_A, LEAF_B = 0, 1, 2           # vertex group indices = BONES order
BONES = ("PostBone", "DoorBoneA", "DoorBoneB")
UA = {0: 1, 1: 0, 2: 0}                  # in-plane axes of a face normal to axis: X -> (Y, Z), Y -> (X, Z), Z -> (X, Y)
VA = {0: 2, 1: 2, 2: 1}
EPS = 1e-6


def splits(a0, a1, unit):
    """Pieces of [a0, a1] cut at multiples of unit, with each piece's texture coordinate inside its unit cell.
    unit None: one piece stretched 0..1."""
    if unit is None:
        return [(a0, a1, 0.0, 1.0)]
    out, k = [], math.floor(a0 / unit + EPS)
    while k * unit < a1 - EPS:
        lo, hi = max(a0, k * unit), min(a1, (k + 1) * unit)
        if hi - lo > EPS:
            out.append((lo, hi, lo / unit - k, hi / unit - k))
        k += 1
    return out


class Builder:
    """One bmesh; paint = swatch name, or (region, unit_u, unit_v): the region repeats every unit along the face's
    in-plane axes (None = stretched over the face)."""

    def __init__(self):
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.verify()
        self.dl = self.bm.verts.layers.deform.verify()
        self.group = POST
        self.mirror = None                # x -> mirror - x (the second leaf)

    def face(self, cos, uvs, out):
        """Polygon wound so its normal points along `out`: the door shader culls back faces."""
        if self.mirror is not None:
            cos = [(self.mirror - x, y, z) for x, y, z in cos]
            out = (-out[0], out[1], out[2])
        cos = [Vector(c) for c in cos]
        n = Vector()
        for i, a in enumerate(cos):                       # Newell normal
            b = cos[(i + 1) % len(cos)]
            n += Vector(((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y)))
        if n.dot(Vector(out)) < 0:
            cos, uvs = cos[::-1], uvs[::-1]
        vs = [self.bm.verts.new(c) for c in cos]
        for v in vs:
            v[self.dl][self.group] = 1.0
        f = self.bm.faces.new(vs)
        for loop, uv in zip(f.loops, uvs):
            loop[self.uv].uv = uv

    @staticmethod
    def _uv(paint, u, v):
        return A.swatch_uv(paint) if isinstance(paint, str) else A.region_uv(paint[0], u, v)

    def rect(self, axis, sign, c, a0, a1, b0, b1, paint):
        ua, va = UA[axis], VA[axis]
        units = (None, None) if isinstance(paint, str) else paint[1:]
        out = [0, 0, 0]
        out[axis] = sign
        for (pa0, pa1, u0, u1), (pb0, pb1, v0, v1) in product(splits(a0, a1, units[0]), splits(b0, b1, units[1])):
            cos, uvs = [], []
            for a, b, u, v in ((pa0, pb0, u0, v0), (pa1, pb0, u1, v0), (pa1, pb1, u1, v1), (pa0, pb1, u0, v1)):
                co = [0.0, 0.0, 0.0]
                co[axis], co[ua], co[va] = c, a, b
                cos.append(co)
                uvs.append(self._uv(paint, u, v))
            self.face(cos, uvs, out)

    def box(self, mn, mx, paint, skip=((2, -1),)):
        """Axis-aligned box; paint = spec or callable (axis, sign) -> spec; bottom face skipped by default."""
        for axis, sign in product((0, 1, 2), (-1, 1)):
            if (axis, sign) in skip:
                continue
            p = paint(axis, sign) if callable(paint) else paint
            ua, va = UA[axis], VA[axis]
            self.rect(axis, sign, (mx if sign > 0 else mn)[axis], mn[ua], mx[ua], mn[va], mx[va], p)

    def beam(self, p0, p1, w, y0, y1, paint):
        """Prism in the XZ plane from p0 to p1 (x, z), width w, depth y0..y1 (a diagonal brace)."""
        p0, p1 = Vector(p0), Vector(p1)
        d = (p1 - p0).normalized()
        n = Vector((-d.y, d.x)) * (w / 2)
        ring = [p0 + n, p1 + n, p1 - n, p0 - n]
        mid = (p0 + p1) / 2
        uv = A.swatch_uv(paint)
        for y, s in ((y0, -1), (y1, 1)):
            self.face([(q.x, y, q.y) for q in ring], [uv] * 4, (0, s, 0))
        for i in range(4):
            a, b = ring[i], ring[(i + 1) % 4]
            o = (a + b) / 2 - mid
            self.face([(a.x, y0, a.y), (b.x, y0, b.y), (b.x, y1, b.y), (a.x, y1, a.y)], [uv] * 4, (o.x, 0, o.y))

    def pyramid(self, cx, cy, hx, hy, z0, z1, paint):
        uv = A.swatch_uv(paint)
        base = [(cx - hx, cy - hy), (cx + hx, cy - hy), (cx + hx, cy + hy), (cx - hx, cy + hy)]
        for i in range(4):
            (ax, ay), (bx, by) = base[i], base[(i + 1) % 4]
            self.face([(ax, ay, z0), (bx, by, z0), (cx, cy, z1)], [uv] * 3,
                      ((ax + bx) / 2 - cx, (ay + by) / 2 - cy, 0.3 * max(hx, hy)))

    def slab(self, x0, x1, y0, y1, z0, top, paint, edge=None, xs=()):
        """Panel x0..x1 x y0..y1 from z0 up to top(x) (number or callable: the arched leaf). Both big faces get
        `paint`, cut into columns at unit multiples and at xs; edge = swatch of the top / end faces (None: no edges,
        a two-sided sheet)."""
        top_at = top if callable(top) else (lambda x: top)
        uu, uz = (None, None) if isinstance(paint, str) else paint[1:]
        cols = {x0, x1} | {x for x in xs if x0 + EPS < x < x1 - EPS}
        if uu:
            cols |= {k * uu for k in range(math.ceil(x0 / uu), math.floor(x1 / uu) + 1) if x0 + EPS < k * uu < x1 - EPS}
        cols = sorted(cols)
        for xa, xb in zip(cols, cols[1:]):
            ha, hb = top_at(xa), top_at(xb)
            if uu:
                kx = math.floor((xa + xb) / 2 / uu)
                u0, u1 = xa / uu - kx, xb / uu - kx
            else:
                u0, u1 = (xa - x0) / (x1 - x0), (xb - x0) / (x1 - x0)
            pieces = []                                       # (za, zb_a, zb_b, v0, v1_a, v1_b)
            if uz is None:
                pieces.append((z0, ha, hb, 0.0, 1.0, 1.0))
            else:
                zl = z0
                for lo, hi, v0, v1 in splits(z0, min(ha, hb), uz)[:-1]:
                    pieces.append((lo, hi, hi, v0, v1, v1))
                    zl = hi
                base = math.floor(zl / uz + EPS) * uz
                if max(ha, hb) - base > uz + EPS:              # steep top: restart the texture under it
                    mid = max(ha, hb) - uz
                    pieces.append((zl, mid, mid, zl / uz - base / uz, mid / uz - base / uz, mid / uz - base / uz))
                    zl, base = mid, mid
                pieces.append((zl, ha, hb, (zl - base) / uz, (ha - base) / uz, (hb - base) / uz))
            for za, zba, zbb, v0, va, vb in pieces:
                uvs = [self._uv(paint, u0, v0), self._uv(paint, u1, v0), self._uv(paint, u1, vb), self._uv(paint, u0, va)]
                for y, s in ((y0, -1), (y1, 1)):
                    self.face([(xa, y, za), (xb, y, za), (xb, y, zbb), (xa, y, zba)], uvs, (0, s, 0))
            if edge:
                uv = A.swatch_uv(edge)
                self.face([(xa, y0, ha), (xb, y0, hb), (xb, y1, hb), (xa, y1, ha)], [uv] * 4, (0, 0, 1))
        if edge:
            uv = A.swatch_uv(edge)
            for x, s in ((x0, -1), (x1, 1)):
                h = top_at(x)
                self.face([(x, y0, z0), (x, y1, z0), (x, y1, h), (x, y0, h)], [uv] * 4, (s, 0, 0))

    def to_mesh(self, name):
        me = bpy.data.meshes.new(name)
        self.bm.normal_update()
        self.bm.to_mesh(me)
        self.bm.free()
        me.uv_layers[0].name = "UVMap"
        return me


# ---------------------------------------------------------------- leaves (built as the -X leaf; the +X leaf mirrors)
Y = S.PLANE_Y


def knuckles(m, xa, zs):
    for z in zs:                                              # hinge barrels on the hinge stile, toward the post
        m.box((xa - 0.015, Y - 0.035, z - 0.09), (xa + 0.03, Y + 0.035, z + 0.09), "hinge", skip=())


def leaf_a(m, xa, xb, t):
    top, zc = 4.45, 2.25
    y0, y1 = Y - t / 2, Y + t / 2
    m.box((xa, y0, S.Z0), (xa + t, y1, top), "frame")                       # hinge stile
    m.box((xb - t, y0, S.Z0), (xb, y1, top), "frame")                       # free stile
    m.box((xa + t, y0, S.Z0), (xb - t, y1, S.Z0 + t), "frame")              # bottom rail
    m.box((xa + t, y0, top - t), (xb - t, y1, top), "frame")                # top rail
    m.box((xa + t, y0 + 0.01, zc - 0.035), (xb - t, y1 - 0.01, zc + 0.035), "frame")
    m.beam((xa + t, S.Z0 + t), (xb - t, top - t), 0.06, Y - 0.025, Y + 0.025, "brace")   # hinge foot -> free top
    # chain-link: two-sided alpha-cut sheet in the frame opening (atlas PANEL, 1 x 1 unit repeat)
    m.slab(xa + t - 0.01, xb - t + 0.01, Y - 0.002, Y + 0.002, S.Z0 + t - 0.01, top - t + 0.01, (A.PANEL, 1.0, 1.0))
    knuckles(m, xa, (0.5, zc, 4.0))


def leaf_b(m, xa, xb, t):
    top = 4.45
    y0, y1 = Y - t / 2, Y + t / 2
    m.slab(xa + 0.02, xb - 0.02, Y - 0.02, Y + 0.02, S.Z0 + 0.02, top - 0.02, (A.PANEL, 1.0, 1.0), "edge")
    f = 0.09
    m.box((xa, y0, S.Z0), (xa + f, y1, top), "frame")
    m.box((xb - f, y0, S.Z0), (xb, y1, top), "frame")
    m.box((xa + f, y0, S.Z0), (xb - f, y1, S.Z0 + f), "frame")
    m.box((xa + f, y0, top - f), (xb - f, y1, top), "frame")
    for i in range(1, 7):                                                   # 6 horizontal ribs, 0.02 proud
        z = S.Z0 + (top - S.Z0) * i / 7
        m.box((xa + f, Y - 0.04, z - 0.035), (xb - f, Y + 0.04, z + 0.035), "rib")
    knuckles(m, xa, (0.5, 2.25, 4.0))


def leaf_c(m, xa, xb, t):
    bar_top, spear = 4.42, 0.20
    y0, y1 = Y - t / 2, Y + t / 2
    for x0 in (xa, xb - t):                                                 # stiles end in a spear like the bars
        m.box((x0, y0, S.Z0), (x0 + t, y1, bar_top), "rail", skip=((2, -1), (2, 1)))
        m.pyramid(x0 + t / 2, Y, t / 2, t / 2, bar_top, bar_top + spear + 0.04, "top")
    for z0, z1 in ((S.Z0, S.Z0 + 0.12), (2.0, 2.1), (4.13, 4.25)):         # heavy bottom / middle / top rails
        m.box((xa + t, y0, z0), (xb - t, y1, z1), "rail")
    span = xb - xa - 2 * t
    n = int(span / 0.14)
    for i in range(n):
        x = xa + t + (i + 0.5) * span / n
        m.box((x - 0.0175, Y - 0.0175, S.Z0 + 0.06), (x + 0.0175, Y + 0.0175, bar_top), "bar", skip=((2, -1), (2, 1)))
        m.pyramid(x, Y, 0.035, 0.035, bar_top - 0.02, bar_top + spear, "top")
    knuckles(m, xa, (0.5, 2.05, 4.0))


def leaf_d(m, xa, xb, t):
    top, d = 4.40, 0.025                                                    # plank sheet half thickness
    m.slab(xa, xb, Y - d, Y + d, S.Z0, top, (A.PANEL, 1.0, 1.0), "top")     # 5 planks per unit, dark gaps
    rails = ((S.Z0 + 0.08, S.Z0 + 0.30), (top - 0.26, top - 0.04))
    for s in (-1, 1):                                                       # rails + Z brace on both faces
        ya, yb = sorted((Y + s * d, Y + s * (d + 0.05)))
        for z0, z1 in rails:
            m.box((xa, ya, z0), (xb, yb, z1), lambda ax, sg: (A.STRIP, 1.0, None) if ax == 1 else "rail")
        m.beam((xa + 0.12, rails[0][1] - 0.02), (xb - 0.12, rails[1][0] + 0.02), 0.18, ya, yb, "brace")
        for z0, z1 in rails + ((2.13, 2.27),):                             # black iron strap hinges
            if z1 - z0 > 0.15:
                za, zb, base = (z0 + z1) / 2 - 0.045, (z0 + z1) / 2 + 0.045, d + 0.05
            else:
                za, zb, base = z0, z1, d
            yc0, yc1 = sorted((Y + s * base, Y + s * (base + 0.012)))
            m.box((xa - 0.015, yc0, za), (xa + 0.6, yc1, zb), "hinge")
    knuckles(m, xa, (0.24, 2.2, 4.25))


def leaf_e(m, xa, xb, t, mid):
    h_hinge, h_mid = 4.25, 4.85
    half, rise = mid - xa, h_mid - h_hinge
    r = (half * half + rise * rise) / (2 * rise)
    top = lambda x: h_mid - r + math.sqrt(max(r * r - (mid - x) ** 2, 0.0))   # noqa: E731  arch of the closed pair
    d = 0.05
    m.slab(xa, xb, Y - d, Y + d, S.Z0, top, (A.PANEL, 1.0, 1.0), "top", xs=[k * 0.25 for k in range(0, 40)])
    for s in (-1, 1):                                                       # three iron bands with studs, both faces
        ya, yb = sorted((Y + s * d, Y + s * (d + 0.015)))
        for z in (0.75, 2.35, 3.75):
            m.box((xa - 0.015, ya, z - 0.08), (xb - 0.06, yb, z + 0.08),
                  lambda ax, sg: (A.STRIP, 1.0, None) if ax == 1 else "band")
    knuckles(m, xa, (0.75, 2.35, 3.75))


def leaves(look, L):
    def build(m):
        t = S.LOOK[look]["t"]
        xa = S.hinge_x(look) - t / 2
        mid = (L + 1) / 2
        xb = mid - S.GAP
        for group, mirror in ((LEAF_A, None), (LEAF_B, L + 1.0)):
            m.group, m.mirror = group, mirror
            if look == "E":
                leaf_e(m, xa, xb, t, mid)
            else:
                {"A": leaf_a, "B": leaf_b, "C": leaf_c, "D": leaf_d}[look](m, xa, xb, t)
        m.group, m.mirror = POST, None
    return build


# ---------------------------------------------------------------- posts (own tile, centred on x = 0, y = PLANE_Y)
def post(look):
    hw = S.LOOK[look]["post_hw"]

    def build(m):
        if look in "ABC":                                                   # steel post on a concrete footing
            m.box((-0.24, Y - 0.24, 0), (0.24, Y + 0.24, 0.18), "footing")
            m.box((-hw, Y - hw, 0.18), (hw, Y + hw, 4.70), lambda ax, sg: "post" if ax == 2 else (A.PANEL2, 1.0, 1.0))
            m.box((-hw - 0.025, Y - hw - 0.025, 4.70), (hw + 0.025, Y + hw + 0.025, 4.74), "cap", skip=())
        elif look == "D":                                                   # timber post on a concrete footing
            m.box((-0.28, Y - 0.28, 0), (0.28, Y + 0.28, 0.25), "footing")
            m.box((-hw, Y - hw, 0.25), (hw, Y + hw, 4.55), lambda ax, sg: "cap" if ax == 2 else (A.PANEL2, 1.0, 1.0))
            m.pyramid(0, Y, hw, hw, 4.55, 4.66, "cap")
        else:                                                               # stone pillar, cap stone + pyramid
            m.box((-hw, Y - hw, 0), (hw, Y + hw, 4.45), lambda ax, sg: "post" if ax == 2 else (A.PANEL2, 1.0, 1.0))
            m.box((-0.36, Y - 0.36, 4.45), (0.36, Y + 0.36, 4.57), "stone_cap", skip=())
            m.pyramid(0, Y, 0.30, 0.30, 4.57, 4.77, "stone_cap")
    return build


# ---------------------------------------------------------------- scene, rig, export
def build_material(look):
    path = HERE / "textures" / f"{S.texture(look)}.png"
    mat = bpy.data.materials.new(path.stem)
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.6
    tex = nt.nodes.new("ShaderNodeTexImage")
    img = bpy.data.images.load(str(path), check_existing=True)
    img.name = path.stem
    tex.image = img
    tex.interpolation = "Closest"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    if look == "A":           # chain-link cut-out: Round -> the glTF exporter writes alphaMode MASK (cutoff 0.5)
        rnd = nt.nodes.new("ShaderNodeMath")
        rnd.operation = "ROUND"
        nt.links.new(tex.outputs["Alpha"], rnd.inputs[0])
        nt.links.new(rnd.outputs[0], bsdf.inputs["Alpha"])
    return mat


def swing_quat(bone, deg):
    """Pose quaternion turning the bone by deg about world +Z through its head."""
    b = bone.matrix_local.to_3x3()
    return (b.inverted() @ Matrix.Rotation(math.radians(deg), 3, "Z") @ b).to_quaternion()


def add_rig(sc, obj, look, L):
    arm_data = bpy.data.armatures.new("Dummy01")
    rig = bpy.data.objects.new("Dummy01", arm_data)
    sc.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    hx = S.hinge_x(look)
    for bone, head in zip(BONES, (Vector((0, 0, 0)), Vector((hx, Y, 0)), Vector((L + 1 - hx, Y, 0)))):
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
    ad = rig.animation_data_create()
    for clip, a0, a1 in (("Open", 0.0, S.OPEN_DEG), ("Close", S.OPEN_DEG, 0.0)):
        act = bpy.data.actions.new(clip)
        act.use_fake_user = True
        ad.action = act
        # every frame keyed: angle = deg(t) along the shared ease (ease(1 - t) = 1 - ease(t): Close = reversed Open)
        for frame in range(S.F0, S.F1 + 1):
            deg = a0 + (a1 - a0) * ease((frame - S.F0) / (S.F1 - S.F0))
            pbs[0].rotation_quaternion = Quaternion()
            pbs[1].rotation_quaternion = swing_quat(pbs[1].bone, -deg)
            pbs[2].rotation_quaternion = swing_quat(pbs[2].bone, deg)
            for pb in pbs:
                pb.location = (0, 0, 0)
                pb.keyframe_insert("rotation_quaternion", frame=frame)
                pb.keyframe_insert("location", frame=frame)
        slot = ad.action_slot
        ad.action = None
        track = ad.nla_tracks.new()
        track.name = clip
        strip = track.strips.new(clip, S.F0, act)
        if hasattr(strip, "action_slot") and slot is not None:
            strip.action_slot = slot
    for pb in pbs:
        pb.rotation_quaternion = Quaternion()
    return rig


def build_variant(name, parts, look, L=None, builder=Builder, material=None):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.fps, sc.render.fps_base = S.FPS, 1.0
    sc.frame_start, sc.frame_end = S.F0, S.F1
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    m = builder()
    parts(m)
    me = m.to_mesh(name)
    me.materials.append(material() if material else build_material(look))
    obj = bpy.data.objects.new(name, me)
    sc.collection.objects.link(obj)
    rigged = L is not None
    keep = [obj, add_rig(sc, obj, look, L)] if rigged else [obj]
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


# ---------------------------------------------------------------- door reader on the end-A post
# build_barrier.py builds on import: run only its definitions (everything above its first build_variant call), with
# its own atlas module (ours is also called "atlas"). Reused: Builder, reader_post, build_material, READER_TEX.
BARRIER = HERE.parent / "barrier"
_ours = sys.modules.pop("atlas")
_src = (BARRIER / "build_barrier.py").read_text(encoding="utf-8")
B = types.ModuleType("build_barrier")
B.__file__ = str(BARRIER / "build_barrier.py")
exec(compile(_src[:_src.index("\nbuild_variant(")], B.__file__, "exec"), B.__dict__)
sys.modules["atlas"] = _ours
READER_PLATE_X = -0.24          # reader_post back plate centre (x -0.42 .. -0.06)
READER_PLATE_Y = 0.06           # reader_post back plate inner face |y|


def reader_pillar(look):
    """reader_post() parts moved onto the two post faces normal to traffic (+-Y): back plate 0.005 off the face,
    centred on the post along the line. Same reader item texture and UVs. The post bracket (x -0.075 .. -0.025, it
    reaches for a thin door post at x = 0) is dropped: here the plate sits on the post face itself."""
    off = S.LOOK[look]["post_hw"] + 0.005 - READER_PLATE_Y

    def build(m):
        B.reader_post(m)
        bracket = [f for f in m.bm.faces if all(v.co.x > -0.0751 for v in f.verts)
                   and (any(v.co.x > -0.05 for v in f.verts) or all(abs(v.co.x + 0.075) < 1e-4 for v in f.verts))]
        bmesh.ops.delete(m.bm, geom=bracket, context="FACES")
        bmesh.ops.delete(m.bm, geom=[v for v in m.bm.verts if not v.link_faces], context="VERTS")
        for v in m.bm.verts:
            v.co.x -= READER_PLATE_X
            v.co.y = Y + v.co.y + math.copysign(off, v.co.y)
    return build


def reader_name(look):
    return f"knoxpass_reader_pillar_{look}"


looks = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else list(S.LOOKS)
for look in looks:
    build_variant(S.post_model(look), post(look), look)
    build_variant(reader_name(look), reader_pillar(look), look, builder=B.Builder,
                  material=lambda: B.build_material(B.READER_TEX))
    for L in S.WIDTHS:
        build_variant(S.leaf_model(look, L), leaves(look, L), look, L)
