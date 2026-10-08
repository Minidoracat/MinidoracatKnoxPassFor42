"""Re-import export/knoxpass_barrier2_boom*.glb into an empty scene and check what the engine will get: glTF nodes,
skin joints, clips, both boom angles at clip start / middle / end, closed / open boxes, per-part boxes (atlas
classify, as scripts/blender/barrier/verify_export.py). Fails on any mismatch.
用法：blender -b --factory-startup --python verify_barrier2.py   (writes export/verify.txt)
"""
import json
import math
import struct
import sys
from pathlib import Path

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True           # no __pycache__ in the single barrier's folder
sys.path.insert(0, str(HERE.parent / "barrier"))
sys.path.insert(0, str(HERE.parent))
import atlas as A  # noqa: E402
from ease import ease  # noqa: E402

OPEN_DEG = 86.0

log = []


def out(s=""):
    print(s)
    log.append(str(s))


def world_verts(o):
    ev = o.evaluated_get(bpy.context.evaluated_depsgraph_get())
    me = ev.to_mesh()
    uv = me.uv_layers[0].data
    cls = {}
    for loop in me.loops:
        cls.setdefault(A.classify(*uv[loop.index].uv), set()).add(loop.vertex_index)
    ws = [ev.matrix_world @ v.co for v in me.vertices]
    ev.to_mesh_clear()
    return ws, cls


def box(ws):
    return ([round(min(w[k] for w in ws), 3) for k in range(3)], [round(max(w[k] for w in ws), 3) for k in range(3)])


def verify(glb, L):
    raw = glb.read_bytes()
    j = json.loads(raw[20:20 + struct.unpack("<I", raw[12:16])[0]])
    out(f"\n==================== {glb.name} ({len(raw)} bytes)")
    for i, nd in enumerate(j["nodes"]):
        out(f"node {i} {nd}")
    joints = [j["nodes"][n]["name"] for n in j["skins"][0]["joints"]]
    out(f"skin joints {joints}")
    clips = {}
    for a in j["animations"]:
        t = sorted({j["accessors"][s["input"]]["max"][0] - j["accessors"][s["input"]]["min"][0] for s in a["samplers"]})
        clips[a["name"]] = t
        out(f"animation {a['name']}: channels={len(a['channels'])} duration {t} s")
    out(f"images {[(i['name'], i['mimeType']) for i in j['images']]}")
    assert sorted(joints) == ["DoorBone", "DoorBoneB", "PostBone"], joints
    assert any(n.get("name") == "Dummy01" and "children" in n for n in j["nodes"]), "no Dummy01 root"
    assert set(clips) == {"Open", "Close"} and all(abs(t[0] - 6.0) < 1e-3 and len(t) == 1 for t in clips.values()), clips

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(glb))
    sc = bpy.context.scene
    rig = next(o for o in sc.objects if o.type == "ARMATURE")
    mesh = next(o for o in sc.objects if o.type == "MESH" and not o.name.startswith("Icosphere"))
    out(f"vertex groups {[g.name for g in mesh.vertex_groups]} verts={len(mesh.data.vertices)} "
        f"tris={sum(len(p.vertices) - 2 for p in mesh.data.polygons)} "
        f"images={[(i.name, tuple(i.size)) for i in bpy.data.images if i.size[0]]}")
    heads = {b.name: tuple(round(v, 4) for v in b.head_local) for b in rig.data.bones}
    out(f"bones {heads}")
    m = (L + 1) / 2
    assert heads["DoorBone"] == (0.27, 0.3, 1.0) and heads["DoorBoneB"] == (round(2 * m - 0.27, 4), 0.3, 1.0), heads

    def tip(bone, sign):   # elevation of the boom direction (+X for A, -X for B), degrees
        mm = (rig.matrix_world @ rig.pose.bones[bone].matrix).to_3x3()
        d = mm @ (rig.data.bones[bone].matrix_local.to_3x3().inverted() @ Vector((sign, 0, 0)))
        return round(math.degrees(math.atan2(d.z, sign * d.x)), 2)

    ad = rig.animation_data
    for track in ad.nla_tracks:
        track.mute = True
    for track in ad.nla_tracks:
        act = track.strips[0].action
        ad.action = act
        if hasattr(ad, "action_slot") and act.slots:
            ad.action_slot = act.slots[0]
        f0, f1 = (int(f) for f in act.frame_range)
        curve = (lambda t: OPEN_DEG * ease(t)) if act.name == "Open" else (lambda t: OPEN_DEG * ease(1 - t))

        def sample(f, sub=0.0):
            sc.frame_set(f, subframe=sub)
            return tip("DoorBone", 1), tip("DoorBoneB", -1), round(tip("PostBone", 1), 2)
        got = []
        for t in (0.0, 0.1, 0.5, 0.9, 1.0):                       # eased angle at clip time t, both booms
            fr = f0 + t * (f1 - f0)
            a, b, p = sample(int(fr), fr - int(fr))
            got.append((t, a, b, p))
            assert abs(a - curve(t)) < 0.5 and abs(b - curve(t)) < 0.5 and p == 0, (act.name, t, a, b, p, curve(t))
        every = [sample(f)[:2] for f in range(f0, f1 + 1)]          # every frame: monotonic, A == B, soft start / stop
        sgn = 1 if act.name == "Open" else -1
        assert all(abs(a - b) < 0.01 for a, b in every), "booms out of step"
        assert all(sgn * (n[0] - o[0]) >= -0.01 for o, n in zip(every, every[1:])), "not monotonic"
        first, last = abs(every[1][0] - every[0][0]), abs(every[-1][0] - every[-2][0])
        assert first < 0.1 and last < 0.1, (first, last)
        assert abs(every[0][0] - curve(0)) < 0.01 and abs(every[-1][0] - curve(1)) < 0.01, (every[0], every[-1])
        sc.frame_set(f1)
        ws, _ = world_verts(mesh)
        out(f"action {act.name}: frames {f0}-{f1} @ {sc.render.fps} fps = {(f1 - f0) / sc.render.fps:.3f} s; "
            f"(t, boom A deg, boom B deg, PostBone deg) {got}; want {[round(curve(g[0]), 2) for g in got]}; "
            f"first/last frame step {first:.3f}/{last:.3f} deg; bbox at last frame {box(ws)}")
    ad.action = None
    for pb in rig.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
    sc.frame_set(1)
    ws, cls = world_verts(mesh)
    out(f"rest (closed) bbox {box(ws)}")
    for name, idx in sorted(cls.items()):
        for side, sel in (("A", lambda w: w.x < m), ("B", lambda w: w.x >= m)):
            pts = [ws[i] for i in idx if sel(ws[i])]
            if pts:
                mn, mx = box(pts)
                out(f"  rest part {name:12s} side {side} min {mn} max {mx} size {[round(b - a, 3) for a, b in zip(mn, mx)]}")
    sign = {s: box([ws[i] for i in cls["SIGN"] if (ws[i].x < m) == (s == "A")]) for s in "AB"}
    centres = {s: round((sign[s][0][0] + sign[s][1][0]) / 2, 3) for s in "AB"}
    assert centres == {"A": 2.0, "B": round(2 * m - 2.0, 3)}, centres              # middle of car lane 1 / last
    arm = box([ws[i] for i in cls["ARM"]])
    assert abs(arm[0][0] - 0.27) < 1e-3 and abs(arm[1][0] - (2 * m - 0.27)) < 1e-3, arm   # pivots
    caps = box([ws[i] for i in cls["dark"] if abs(ws[i].x - m) < 0.1 and 0.9 < ws[i].z < 1.09])
    out(f"  tip caps at the middle (dark, |x - {m}| < 0.1): {caps}")
    assert abs(caps[0][0] - (m - 0.045)) < 1e-3 and abs(caps[1][0] - (m + 0.045)) < 1e-3, caps   # 3 cm cap, 1.5 cm gap
    xs = sorted({round(ws[i].x, 3) for i in cls["navy"]})                  # navy = rest posts only (pw 0.065)
    posts = [round((a + b) / 2, 3) for a, b in zip(xs[::2], xs[1::2])]
    out(f"  rest posts x {posts}")
    assert posts == [3 * c + 0.5 for c in range(1, L // 3)], posts           # car-lane boundaries only
    paint = box([ws[i] for i in cls["paint_white"]])
    assert paint[0][2] == paint[1][2] == 0.02 and paint[0][1] < 0 < 1 < paint[1][1], paint


for L in (6, 9):
    verify(HERE / "export" / f"knoxpass_barrier2_boom{L}.glb", L)
(HERE / "export" / "verify.txt").write_text("\n".join(log) + "\n", encoding="utf-8")
print("[verify] OK")
sys.exit(0)
