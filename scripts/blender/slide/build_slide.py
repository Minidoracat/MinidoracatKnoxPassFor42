"""Knox Pass sliding gate: leaf (one sliding bone) + end post -> export/*.glb. Geometry rules in spec.py.

    blender -b --factory-startup --python build_slide.py                   # export/*.glb
    KNOXPASS_FAST=1 blender -b --factory-startup --python build_slide.py   # export/*_fast.glb (leaves only, 3.75 s)

Reuses ../gate/build_gate.py (Builder, the atlas layout) by running its definitions only, as that file does with
../barrier/build_barrier.py. Textures: textures/ (atlas.py: the gates' paint plus the cabinet swatches).
"""
import importlib.util
import sys
import types
from pathlib import Path

import bpy
from mathutils import Matrix, Quaternion, Vector

HERE = Path(__file__).resolve().parent
GATE = HERE.parent / "gate"
BG = types.ModuleType("build_gate")
BG.__file__ = str(GATE / "build_gate.py")
_src = (GATE / "build_gate.py").read_text(encoding="utf-8")
exec(compile(_src[:_src.index("\nlooks = sys.argv")], BG.__file__, "exec"), BG.__dict__)
A, ease = BG.A, BG.ease


def _load(name):
    sp = importlib.util.spec_from_file_location(f"knoxpass_slide_{name}", HERE / f"{name}.py")   # "spec" / "atlas" are the gate's
    mod = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(mod)
    return mod


S = _load("spec")
_load("atlas").extend(A)
G = S.G

BONES = ("PostBone", "LeafBone")
LEAF = 1


# ---------------------------------------------------------------- leaves (closed position, plane y = LEAF_Y)
def bays(xa, xb, t):
    """Truss bay starts along the leaf, about 2 tiles each."""
    n = max(1, round((xb - xa) / 2))
    w = (xb - xa - t) / n
    return [xa + i * w for i in range(n + 1)], w


def carriages(m, xa, xb, y):
    for x in (xa + 0.45, xb - 0.45):                            # wheel carriages under the bottom rail
        m.box((x - 0.11, y - 0.035, 0.03), (x + 0.11, y + 0.035, S.Z0), "hinge", skip=())


def frame(m, xa, xb, y, top, t, mid=False):
    y0, y1 = y - t / 2, y + t / 2
    for x0 in (xa, xb - t):
        m.box((x0, y0, S.Z0), (x0 + t, y1, top), "frame")
    for z0 in (S.Z0, top - t) + ((2.25 - t / 2,) if mid else ()):
        m.box((xa + t, y0, z0), (xb - t, y1, z0 + t), "frame")
    carriages(m, xa, xb, y)


def truss(m, xa, xb, y, top, t, vert="frame", diag="brace"):
    xs, w = bays(xa, xb, t)
    for x in xs[1:-1]:
        m.box((x, y - t / 2 + 0.01, S.Z0 + t), (x + t * 0.8, y + t / 2 - 0.01, top - t), vert)
    for i, x in enumerate(xs[:-1] if diag else ()):
        a, b = (x + t, S.Z0 + t), (x + w, top - t)
        if i % 2:
            a, b = (x + t, top - t), (x + w, S.Z0 + t)
        m.beam(a, b, 0.055, y - 0.022, y + 0.022, diag)


def mesh(m, xa, xb, y, top, t):
    m.slab(xa + t - 0.01, xb - t + 0.01, y - 0.002, y + 0.002, S.Z0 + t - 0.01, top - t + 0.01, (A.PANEL, 1.0, 1.0))


def leaf_a(m, xa, xb, y, top, t, story):                        # galvanised tube frame + chain-link
    frame(m, xa, xb, y, top, t, mid=story == 2)
    truss(m, xa, xb, y, top, t)
    mesh(m, xa, xb, y, top, t)


def leaf_b(m, xa, xb, y, top, t, story):                        # green steel plate with ribs
    m.slab(xa + 0.02, xb - 0.02, y - 0.02, y + 0.02, S.Z0 + 0.02, top - 0.02, (A.PANEL, 1.0, 1.0), "edge")
    frame(m, xa, xb, y, top, t)
    n = 3 * story
    for i in range(1, n + 1):
        z = S.Z0 + (top - S.Z0) * i / (n + 1)
        m.box((xa + t, y - 0.04, z - 0.035), (xb - t, y + 0.04, z + 0.035), "rib")
    truss(m, xa, xb, y, top, t, vert="rib", diag=None)


def leaf_c(m, xa, xb, y, top, t, story):                        # black palisade bars, spear heads up to `top`
    bar_top, y0, y1 = top - 0.22, y - t / 2, y + t / 2
    for x0 in (xa, xb - t):
        m.box((x0, y0, S.Z0), (x0 + t, y1, bar_top), "rail", skip=((2, -1), (2, 1)))
        m.pyramid(x0 + t / 2, y, t / 2, t / 2, bar_top, top, "top")
    for z0, z1 in [(S.Z0, S.Z0 + 0.12), (bar_top - 0.29, bar_top - 0.17)] + ([(2.0, 2.1)] if story == 2 else []):
        m.box((xa + t, y0, z0), (xb - t, y1, z1), "rail")
    span = xb - xa - 2 * t
    n = int(span / 0.14)
    for i in range(n):
        x = xa + t + (i + 0.5) * span / n
        m.box((x - 0.0175, y - 0.0175, S.Z0 + 0.06), (x + 0.0175, y + 0.0175, bar_top), "bar", skip=((2, -1), (2, 1)))
        m.pyramid(x, y, 0.035, 0.035, bar_top - 0.02, top - 0.04, "top")
    carriages(m, xa, xb, y)


def leaf_d(m, xa, xb, y, top, t, story):                        # ranch planks on a steel bottom channel
    d = 0.025
    m.slab(xa, xb, y - d, y + d, S.Z0 + 0.06, top, (A.PANEL, 1.0, 1.0), "top")
    m.box((xa, y - 0.045, S.Z0), (xb, y + 0.045, S.Z0 + 0.07), "hinge", skip=())
    rails = [(S.Z0 + 0.14, S.Z0 + 0.36)] + ([(2.14, 2.36)] if story == 2 else []) + [(top - 0.26, top - 0.04)]
    xs, w = bays(xa, xb, 0.0)
    for s in (-1, 1):
        ya, yb = sorted((y + s * d, y + s * t / 2))
        for z0, z1 in rails:
            m.box((xa, ya, z0), (xb, yb, z1), lambda ax, sg: (A.STRIP, 1.0, None) if ax == 1 else "rail")
        for (_, lo), (hi, _) in zip(rails, rails[1:]):
            for i, x in enumerate(xs[:-1]):
                a, b = (x + 0.12, lo - 0.02), (x + w - 0.12, hi + 0.02)
                if i % 2:
                    a, b = (a[0], b[1]), (b[0], a[1])
                m.beam(a, b, 0.16, ya, yb, "brace")
    carriages(m, xa, xb, y)


def leaf_f(m, xa, xb, y, top, t, story):                        # safety-yellow truss, chain-link, hazard kick strip
    ft, k = 0.10, t / 2
    frame(m, xa, xb, y, top, ft, mid=story == 2)
    truss(m, xa, xb, y, top, ft)
    mesh(m, xa, xb, y, top, ft)
    m.box((xa, y - k, S.Z0), (xb, y + k, S.Z0 + 0.30), lambda ax, sg: (A.STRIP, 1.0, None) if ax == 1 else "frame")


def leaf_g(m, xa, xb, y, top, t, story):                        # dark frame, chain-link, concertina wire up to `top`
    ft, rail = 0.09, top - 0.46
    frame(m, xa, xb, y, rail, ft, mid=story == 2)
    truss(m, xa, xb, y, rail, ft, diag=None)
    mesh(m, xa, xb, y, rail, ft)
    for x in bays(xa, xb, ft)[0]:                               # wire arms above the top rail
        m.box((x + 0.01, y - 0.02, rail), (x + ft - 0.01, y + 0.02, rail + 0.42), "frame")
    for dz in (0.14, 0.27, 0.40):
        m.box((xa, y - 0.008, rail + dz - 0.008), (xb, y + 0.008, rail + dz + 0.008), "bar", skip=())
    for dy in (-1, 1):
        yy = y + dy * (t / 2 - 0.002)
        m.slab(xa, xb, yy - 0.002, yy + 0.002, rail + 0.02, rail + 0.44, (A.STRIP, 1.0, None))


LEAVES = {"A": leaf_a, "B": leaf_b, "C": leaf_c, "D": leaf_d, "F": leaf_f, "G": leaf_g}


def leaf(look, story, L):
    g = S.geometry(look)

    def build(m):
        m.group = LEAF
        LEAVES[g](m, S.LEAF_X0, L + S.LEAF_X1, S.LEAF_Y, S.TOP[story], S.LEAF_T[g], story)
    return build


# ---------------------------------------------------------------- end post (own tile, symmetric about x = 0)
def post(look, story, motor=False):
    g = S.geometry(look)
    hw, top, y = S.POST_HW, S.TOP[story], S.POST_Y
    hp, half = top + 0.25, S.LEAF_T[g] / 2

    def build(m):
        m.box((-hw - 0.07, y - hw - 0.07, 0), (hw + 0.07, y + hw + 0.07, 0.18), "footing")
        if g == "D":                                            # timber post, as tall as the steel one with its cap
            m.box((-hw, y - hw, 0.18), (hw, y + hw, hp - 0.05), lambda ax, sg: "cap" if ax == 2 else (A.PANEL2, 1.0, 1.0))
            m.pyramid(0, y, hw, hw, hp - 0.05, hp + 0.04, "cap")
        else:                                                   # steel post
            m.box((-hw, y - hw, 0.18), (hw, y + hw, hp), lambda ax, sg: "post" if ax == 2 else (A.PANEL2, 1.0, 1.0))
            m.box((-hw - 0.025, y - hw - 0.025, hp), (hw + 0.025, y + hw + 0.025, hp + 0.04), "cap", skip=())
        # guide bracket: an arm over the leaf's top rail, a roller plate on each side of it (the outer one stays
        # inside the tile for the thickest leaf)
        out = S.LEAF_Y + half + 0.012
        m.box((-0.07, y + hw, top + 0.03), (0.07, out + 0.015, top + 0.08), "hinge", skip=())
        for y0 in (S.LEAF_Y - half - 0.027, out):
            m.box((-0.05, y0, top - 0.14), (0.05, y0 + 0.015, top + 0.03), "hinge", skip=())
        if motor:   # drive cabinet behind the post: Knox Pass navy, amber band and cap (user 2026-11-24: cabinet only)
            y0, y1 = S.MOTOR_Y
            m.box((-0.26, y0, 0), (0.26, y1, 0.95), "motor")
            m.box((-0.265, y0 - 0.005, 0.62), (0.265, y1 + 0.005, 0.70), "motor_trim", skip=())
            m.box((-0.28, y0 - 0.02, 0.95), (0.28, y1 + 0.02, 0.99), "motor_trim", skip=())
    return build


def material(look):
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
    if look in S.CUTOUT:      # chain-link cut-out: Round -> the glTF exporter writes alphaMode MASK (cutoff 0.5)
        rnd = nt.nodes.new("ShaderNodeMath")
        rnd.operation = "ROUND"
        nt.links.new(tex.outputs["Alpha"], rnd.inputs[0])
        nt.links.new(rnd.outputs[0], bsdf.inputs["Alpha"])
    return mat


# ---------------------------------------------------------------- rig, export
def add_rig(sc, obj, L):
    arm_data = bpy.data.armatures.new("Dummy01")
    rig = bpy.data.objects.new("Dummy01", arm_data)
    sc.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    for bone, head in zip(BONES, (Vector((0, 0, 0)), Vector((S.LEAF_X0, S.LEAF_Y, 0)))):
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
    ml = pbs[LEAF].bone.matrix_local
    ad = rig.animation_data_create()
    for clip, a0, a1 in (("Open", 0.0, 1.0), ("Close", 1.0, 0.0)):
        act = bpy.data.actions.new(clip)
        act.use_fake_user = True
        ad.action = act
        # every frame keyed: slide = travel x the shared ease (ease(1 - t) = 1 - ease(t): Close = reversed Open)
        for f in range(G.F0, G.F1 + 1):
            k = a0 + (a1 - a0) * ease((f - G.F0) / (G.F1 - G.F0))
            pbs[0].matrix_basis = Matrix.Identity(4)
            pbs[LEAF].matrix_basis = ml.inverted() @ Matrix.Translation((-S.travel(L) * k, 0, 0)) @ ml
            for pb in pbs:
                pb.rotation_quaternion = Quaternion()
                pb.keyframe_insert("rotation_quaternion", frame=f)
                pb.keyframe_insert("location", frame=f)
        slot = ad.action_slot
        ad.action = None
        track = ad.nla_tracks.new()
        track.name = clip
        strip = track.strips.new(clip, G.F0, act)
        if hasattr(strip, "action_slot") and slot is not None:
            strip.action_slot = slot
    for pb in pbs:
        pb.matrix_basis = Matrix.Identity(4)
    return rig


def build_variant(name, parts, look, L=None):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.fps, sc.render.fps_base = G.FPS, 1.0
    sc.frame_start, sc.frame_end = G.F0, G.F1
    bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
    m = BG.Builder()
    parts(m)
    me = m.to_mesh(name)
    me.materials.append(material(S.geometry(look)))
    obj = bpy.data.objects.new(name, me)
    sc.collection.objects.link(obj)
    rigged = L is not None
    keep = [obj, add_rig(sc, obj, L)] if rigged else [obj]
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


if __name__ == "__main__":
    suffix = "_fast" if G.FAST else ""
    built = set()
    for look, story, group in S.VARIANTS:
        for L in S.GROUPS[group]:
            name = S.leaf_model(look, story, L) + suffix
            if name not in built:                               # painted looks share their geometry look's models
                built.add(name)
                build_variant(name, leaf(look, story, L), look, L)
    for look, story in sorted({(S.geometry(v[0]), v[1]) for v in S.VARIANTS} if not G.FAST else ()):
        for motor in (False, True):
            build_variant(S.post_model(look, story, motor), post(look, story, motor), look)
    print("[build] done")
