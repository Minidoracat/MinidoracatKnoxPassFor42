"""Re-import every export/*.glb into an empty scene and check it: glTF structure (clips, alphaMode), bones, both leaf
angles along Open and Close (= OPEN_DEG x ease(t), scripts/blender/ease.py, at t = 0 / 0.1 / 0.5 / 0.9 / 1; monotonic
over every frame; eased start and stop), bounding boxes, triangle counts, leaf / post / reader clearances.
用法：blender -b --factory-startup --python verify_gate.py      (writes export/verify.txt, exit 1 on any failure)
"""
import json
import math
import struct
import sys
import traceback
from pathlib import Path

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.append(str(HERE.parent))
import spec as S  # noqa: E402
from ease import ease  # noqa: E402

lines = []
failed = []


def out(s=""):
    print(s)
    lines.append(str(s))


def gltf(glb):
    raw = glb.read_bytes()
    n = struct.unpack("<I", raw[12:16])[0]
    return json.loads(raw[20:20 + n]), len(raw)


def load(glb):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(glb))
    sc = bpy.context.scene
    rig = next((o for o in sc.objects if o.type == "ARMATURE"), None)
    mesh = next(o for o in sc.objects if o.type == "MESH" and not o.name.startswith("Icosphere"))
    return sc, rig, mesh


def verts(mesh, group=None):
    """World positions of the evaluated (posed) mesh, optionally only one vertex group."""
    dg = bpy.context.evaluated_depsgraph_get()
    ev = mesh.evaluated_get(dg)
    me = ev.to_mesh()
    gi = mesh.vertex_groups[group].index if group else None
    ws = [ev.matrix_world @ v.co for v, src in zip(me.vertices, mesh.data.vertices)
          if gi is None or any(g.group == gi and g.weight > 0.5 for g in src.groups)]
    ev.to_mesh_clear()
    return ws


def box(ws):
    return ([round(min(w[k] for w in ws), 3) for k in range(3)], [round(max(w[k] for w in ws), 3) for k in range(3)])


def tris(mesh):
    return sum(len(p.vertices) - 2 for p in mesh.data.polygons)


def leaf(look, L):
    glb = HERE / "export" / f"{S.leaf_model(look, L)}.glb"
    j, size = gltf(glb)
    out(f"\n== {glb.name} ({size} bytes)")
    anims = {a["name"]: (min(j["accessors"][s["input"]]["min"][0] for s in a["samplers"]),
                         max(j["accessors"][s["input"]]["max"][0] for s in a["samplers"])) for a in j["animations"]}
    out(f"glTF animations {anims}  alphaMode {[m.get('alphaMode', 'OPAQUE') for m in j['materials']]}"
        f"  images {[i.get('name') for i in j['images']]}")
    assert set(anims) == {"Open", "Close"}, anims
    # barrier convention: keys from frame 1 (t = 1/24 s, export_anim_slide_to_zero=False), 6.0 s long
    assert all(abs(t0 - 1 / S.FPS) < 1e-4 and abs(t1 - t0 - 6.0) < 1e-3 for t0, t1 in anims.values()), anims
    if look == "A":
        assert j["materials"][0].get("alphaMode") == "MASK", j["materials"]
    sc, rig, mesh = load(glb)
    out(f"bones {[(b.name, tuple(round(v, 3) for v in b.head_local)) for b in rig.data.bones]}  "
        f"groups {[g.name for g in mesh.vertex_groups]}  verts={len(mesh.data.vertices)} tris={tris(mesh)}")
    hx, hw, t = S.hinge_x(look), S.LOOK[look]["post_hw"], S.LOOK[look]["t"]
    assert sorted(b.name for b in rig.data.bones) == ["DoorBoneA", "DoorBoneB", "PostBone"]
    assert (rig.data.bones["DoorBoneA"].head_local - Vector((hx, S.PLANE_Y, 0))).length < 1e-4
    assert (rig.data.bones["DoorBoneB"].head_local - Vector((L + 1 - hx, S.PLANE_Y, 0))).length < 1e-4

    def tip(bone, sign):
        """Yaw (deg, atan2(y, x)) of the leaf's tip direction: A starts at +X (0), B at -X (180)."""
        pb = rig.pose.bones[bone]
        d = (rig.matrix_world @ pb.matrix).to_3x3() @ (pb.bone.matrix_local.to_3x3().inverted() @ Vector((sign, 0, 0)))
        return round(math.degrees(math.atan2(d.y, d.x)), 2)

    ad = rig.animation_data
    for tr in ad.nla_tracks:
        tr.mute = True
    def swing():
        """Opening angles (deg, 0 closed .. 90 open) of leaf A (tip yaw 0 -> -90) and leaf B (tip yaw 180 -> -90)."""
        return -tip("DoorBoneA", 1), 180.0 - abs(tip("DoorBoneB", -1))

    reach = {}
    for clip in ("Open", "Close"):
        act = bpy.data.actions[clip]
        ad.action = act
        if hasattr(ad, "action_slot") and act.slots:
            ad.action_slot = act.slots[0]
        f0, f1 = act.frame_range
        n = f1 - f0
        want = (lambda t: S.OPEN_DEG * ease(t)) if clip == "Open" else (lambda t: S.OPEN_DEG * ease(1 - t))
        samples = []
        for t in (0.0, 0.1, 0.5, 0.9, 1.0):
            f = f0 + t * n
            sc.frame_set(int(f), subframe=f - int(f))
            a, b = swing()
            samples.append((t, round(a, 2), round(b, 2), round(want(t), 2)))
            assert abs(a - want(t)) < 0.5 and abs(b - want(t)) < 0.5, (clip, t, a, b, want(t))
        per_frame = []
        for f in range(int(f0), int(f1) + 1):
            sc.frame_set(f)
            per_frame.append(swing())
            if clip == "Open" and f == int(f1):
                reach["A"], reach["B"] = verts(mesh, "DoorBoneA"), verts(mesh, "DoorBoneB")
                reach["all"] = box(verts(mesh))
        sgn = 1 if clip == "Open" else -1
        steps = [sgn * (q[k] - p[k]) for p, q in zip(per_frame, per_frame[1:]) for k in (0, 1)]
        first = max(abs(per_frame[1][k] - per_frame[0][k]) for k in (0, 1))
        last = max(abs(per_frame[-1][k] - per_frame[-2][k]) for k in (0, 1))
        out(f"clip {clip}: frames {f0:.0f}-{f1:.0f} @ {sc.render.fps} fps = {n / sc.render.fps:.2f} s, "
            f"(t, leaf A deg, leaf B deg, want) {samples}; per-frame step min {min(steps):.3f} max {max(steps):.3f}, "
            f"first {first:.3f} last {last:.3f}")
        assert min(steps) >= -0.01, (clip, "not monotonic", min(steps))
        assert first < 0.1 and last < 0.1, (clip, first, last)
    out(f"open bbox {reach['all']}")
    # swung leaves stay clear of the posts and of the reader plate on the end-A post (x up to 0.18)
    clear = max(hw, 0.18) + 0.005
    amin, bmax = min(w.x for w in reach["A"]), max(w.x for w in reach["B"])
    out(f"open: leaf A min x {amin:.3f} (post / reader edge {clear - 0.005:.3f}), leaf B max x {bmax:.3f} "
        f"(post edge {L + 1 - hw:.3f})")
    assert amin >= clear and bmax <= L + 1 - hw - 0.005, (amin, bmax)
    ad.action = None
    for pb in rig.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
    sc.frame_set(1)
    closed = verts(mesh)
    b = box(closed)
    out(f"rest (closed) bbox {b}  height {b[1][2]:.3f} = {b[1][2] / S.STORY:.2f} stories")
    assert b[0][0] >= hw and b[1][0] <= L + 1 - hw, b                      # closed leaves between the posts
    assert b[1][1] <= 0.5 and b[0][1] >= S.PLANE_Y - t / 2 - 0.02, b     # never past the door line
    assert b[1][2] < 2 * S.STORY, b


def static(glb, look, reader):
    j, size = gltf(glb)
    sc, _, mesh = load(glb)
    ws = verts(mesh)
    b = box(ws)
    out(f"\n== {glb.name} ({size} bytes) static, verts={len(mesh.data.vertices)} tris={tris(mesh)} bbox {b} "
        f"images {[i.get('name') for i in j['images']]}")
    hw = S.LOOK[look]["post_hw"]
    if reader:   # back plate 0.005 off both post faces, nothing inside the post, centred along the line
        gap = min(abs(w.y - S.PLANE_Y) for w in ws)
        out(f"reader: min |y - PLANE_Y| {gap:.4f} (post face {hw:.3f} + 0.005), x {b[0][0]}..{b[1][0]}, "
            f"faces y {round(S.PLANE_Y - hw - 0.005, 3)} / {round(S.PLANE_Y + hw + 0.005, 3)}")
        assert abs(gap - (hw + 0.005)) < 1e-3 and abs(b[0][0] + b[1][0]) < 0.05, (gap, b)
        assert any(w.y > S.PLANE_Y for w in ws) and any(w.y < S.PLANE_Y for w in ws)
    else:
        assert abs(b[0][0] + b[1][0]) < 1e-3 and b[1][2] < 2 * S.STORY, b   # symmetric: end A == end B transform


def check(fn, *a):
    try:
        fn(*a)
    except Exception:
        failed.append(a)
        out("FAIL " + traceback.format_exc())


for look in S.LOOKS:
    check(static, HERE / "export" / f"{S.post_model(look)}.glb", look, False)
    check(static, HERE / "export" / f"knoxpass_reader_pillar_{look}.glb", look, True)
    for L in S.WIDTHS:
        check(leaf, look, L)
out(f"\n{'FAILED ' + str(failed) if failed else 'ALL OK'}")
(HERE / "export" / "verify.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
sys.exit(1 if failed else 0)
