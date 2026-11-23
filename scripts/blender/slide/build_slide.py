"""Knox Pass sliding gate: leaf (one sliding bone) + end post -> export/*.glb. Geometry rules in spec.py.

    blender -b --factory-startup --python build_slide.py                   # export/*.glb
    KNOXPASS_FAST=1 blender -b --factory-startup --python build_slide.py   # export/*_fast.glb (leaves only, 3.75 s)

Reuses ../gate/build_gate.py (Builder, the atlas, build_material: the leaves wear the two-story gates' textures) by
running its definitions only, as that file does with ../barrier/build_barrier.py.
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
_sp = importlib.util.spec_from_file_location("knoxpass_slide_spec", HERE / "spec.py")   # "spec" is the gate's
S = importlib.util.module_from_spec(_sp)
_sp.loader.exec_module(S)
G = S.G

BONES = ("PostBone", "LeafBone")
LEAF = 1


# ---------------------------------------------------------------- leaves (closed position, plane y = LEAF_Y)
def bays(xa, xb, t):
    """Truss bay starts along the leaf, about 2 tiles each."""
    n = max(1, round((xb - xa) / 2))
    w = (xb - xa - t) / n
    return [xa + i * w for i in range(n + 1)], w


def frame(m, xa, xb, y, top, t, mid=False):
    y0, y1 = y - t / 2, y + t / 2
    for x0 in (xa, xb - t):
        m.box((x0, y0, S.Z0), (x0 + t, y1, top), "frame")
    for z0 in (S.Z0, top - t) + ((2.25 - t / 2,) if mid else ()):
        m.box((xa + t, y0, z0), (xb - t, y1, z0 + t), "frame")
    for x in (xa + 0.45, xb - 0.45):                            # wheel carriages under the bottom rail
        m.box((x - 0.11, y - 0.035, 0.03), (x + 0.11, y + 0.035, S.Z0), "hinge", skip=())


def truss(m, xa, xb, y, top, t, vert="frame", diag="brace"):
    xs, w = bays(xa, xb, t)
    for x in xs[1:-1]:
        m.box((x, y - t / 2 + 0.01, S.Z0 + t), (x + t * 0.8, y + t / 2 - 0.01, top - t), vert)
    for i, x in enumerate(xs[:-1] if diag else ()):
        a, b = (x + t, S.Z0 + t), (x + w, top - t)
        if i % 2:
            a, b = (x + t, top - t), (x + w, S.Z0 + t)
        m.beam(a, b, 0.055, y - 0.022, y + 0.022, diag)


def leaf_a(m, xa, xb, y, top, t, story):                        # galvanised tube frame + chain-link
    frame(m, xa, xb, y, top, t, mid=story == 2)
    truss(m, xa, xb, y, top, t)
    m.slab(xa + t - 0.01, xb - t + 0.01, y - 0.002, y + 0.002, S.Z0 + t - 0.01, top - t + 0.01, (A.PANEL, 1.0, 1.0))


LEAVES = {"A": leaf_a}


def leaf(look, story, L):
    g = S.geometry(look)

    def build(m):
        m.group = LEAF
        LEAVES[g](m, S.LEAF_X0, L + S.LEAF_X1, S.LEAF_Y, S.TOP[story], S.LEAF_T[g], story)
    return build


# ---------------------------------------------------------------- end post (own tile, symmetric about x = 0)
def post(look, story):
    g = S.geometry(look)
    hw, top, y = S.post_hw(look), S.TOP[story], S.POST_Y
    hp, half = top + 0.25, S.LEAF_T[g] / 2

    def build(m):
        m.box((-hw - 0.07, y - hw - 0.07, 0), (hw + 0.07, y + hw + 0.07, 0.18), "footing")
        m.box((-hw, y - hw, 0.18), (hw, y + hw, hp), lambda ax, sg: "post" if ax == 2 else (A.PANEL2, 1.0, 1.0))
        m.box((-hw - 0.025, y - hw - 0.025, hp), (hw + 0.025, y + hw + 0.025, hp + 0.04), "cap", skip=())
        # guide bracket: an arm over the leaf's top rail, a roller plate on each side of it
        m.box((-0.07, y + hw, top + 0.03), (0.07, S.LEAF_Y + half + 0.045, top + 0.08), "hinge", skip=())
        for y0 in (S.LEAF_Y - half - 0.045, S.LEAF_Y + half + 0.015):
            m.box((-0.05, y0, top - 0.14), (0.05, y0 + 0.03, top + 0.03), "hinge", skip=())
    return build


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
    me.materials.append(BG.build_material(S.geometry(look)))
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
    for look, story, group in S.VARIANTS:
        for L in S.GROUPS[group]:
            build_variant(S.leaf_model(look, story, L) + suffix, leaf(look, story, L), look, L)
    for look, story in sorted({(S.geometry(v[0]), v[1]) for v in S.VARIANTS} if not G.FAST else ()):
        build_variant(S.post_model(look, story), post(look, story), look)
    print("[build] done")
