"""Re-import every export/knoxpass_barrier_*.glb into an empty scene; print glTF structure, bones, clips,
arm angle at clip start/middle/end, bounding boxes, and per-part boxes (parts = atlas region / swatch the UVs hit:
SIGN = STOP plate, lamp = lens, ARM = arm sides, FRONT/SIDE = cabinet faces, paint_white/amber = road paint).
用法：blender -b --factory-startup --python verify_export.py   (writes export/knoxpass_barrier_verify.txt)
"""
import json
import math
import struct
import sys
from pathlib import Path

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import atlas as A  # noqa: E402

lines = []


def out(s=""):
    print(s)
    lines.append(str(s))


def bbox(o):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = o.evaluated_get(dg)
    ws = [ev.matrix_world @ v.co for v in ev.to_mesh().vertices]
    r = ([round(min(w[k] for w in ws), 4) for k in range(3)], [round(max(w[k] for w in ws), 4) for k in range(3)])
    ev.to_mesh_clear()
    return r


def parts(o):
    """Bounding box per atlas part, on the evaluated (posed) mesh."""
    dg = bpy.context.evaluated_depsgraph_get()
    ev = o.evaluated_get(dg)
    me = ev.to_mesh()
    uv = me.uv_layers[0].data
    pts = {}
    for loop in me.loops:
        pts.setdefault(A.classify(*uv[loop.index].uv), set()).add(loop.vertex_index)
    r = {}
    for name, idx in sorted(pts.items()):
        ws = [ev.matrix_world @ me.vertices[i].co for i in idx]
        r[name] = ([round(min(w[k] for w in ws), 3) for k in range(3)], [round(max(w[k] for w in ws), 3) for k in range(3)])
    ev.to_mesh_clear()
    return r


def out_parts(label, o):
    for name, (mn, mx) in parts(o).items():
        out(f"  {label} part {name:12s} min {mn} max {mx} size {[round(b - a, 3) for a, b in zip(mn, mx)]}")


def verify(glb):
    raw = glb.read_bytes()
    n = struct.unpack("<I", raw[12:16])[0]
    j = json.loads(raw[20:20 + n])
    out(f"\n==================== {glb.name} ({len(raw)} bytes)")
    out(f"asset {j['asset']}")
    for i, nd in enumerate(j["nodes"]):
        out(f"node {i} {nd}")
    out(f"skins {j.get('skins')}")
    for a in j.get("animations", []):
        tmin = {j['accessors'][s['input']]['min'][0] for s in a["samplers"]}
        tmax = {j['accessors'][s['input']]['max'][0] for s in a["samplers"]}
        out(f"animation {a['name']}: channels={len(a['channels'])} time {sorted(tmin)}..{sorted(tmax)} s")
    out(f"materials {j['materials']}")
    out(f"images {j['images']}")
    prim = j["meshes"][0]["primitives"][0]
    pos = j["accessors"][prim["attributes"]["POSITION"]]
    out(f"mesh {j['meshes'][0]['name']} attrs={sorted(prim['attributes'])} "
        f"POSITION(glTF Y-up) min={[round(v, 4) for v in pos['min']]} max={[round(v, 4) for v in pos['max']]}")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(glb))
    sc = bpy.context.scene
    rig = next((o for o in sc.objects if o.type == "ARMATURE"), None)
    mesh = next(o for o in sc.objects if o.type == "MESH" and not o.name.startswith("Icosphere"))
    out(f"-- re-import: objects {[(o.name, o.type) for o in sc.objects]} (Icosphere = importer bone shape)")
    out(f"vertex groups {[g.name for g in mesh.vertex_groups]} verts={len(mesh.data.vertices)} "
        f"tris={sum(len(p.vertices) - 2 for p in mesh.data.polygons)} uv={[u.name for u in mesh.data.uv_layers]} "
        f"images={[(i.name, tuple(i.size)) for i in bpy.data.images if i.size[0]]}")
    if rig is None:
        out(f"static bbox {bbox(mesh)}")
        out_parts("static", mesh)
        p = parts(mesh)
        if "lines" in glb.name:   # paint on both sides of the gate line (y = 0.5), flat 2 cm above the floor
            for k in ("paint_white", "amber"):
                assert p[k][0][1] < 0 and p[k][1][1] > 1 and p[k][0][2] == p[k][1][2] == 0.02, (k, p[k])
        if "cabinet" in glb.name:
            assert {"FRONT", "SIDE", "amber"} <= p.keys(), p.keys()
        return
    for b in rig.data.bones:
        out(f"bone {b.name} head={tuple(round(v, 4) for v in b.head_local)}")
    def tip_angle():
        m = (rig.matrix_world @ rig.pose.bones["DoorBone"].matrix).to_3x3()
        d = m @ (rig.data.bones["DoorBone"].matrix_local.to_3x3().inverted() @ Vector((1, 0, 0)))
        return math.degrees(math.atan2(d.z, d.x))

    ad = rig.animation_data
    for track in ad.nla_tracks:
        track.mute = True
    for track in ad.nla_tracks:
        act = track.strips[0].action
        ad.action = act
        if hasattr(ad, "action_slot") and act.slots:
            ad.action_slot = act.slots[0]
        f0, f1 = act.frame_range
        samples = []
        for f in (f0, (f0 + f1) / 2, f1):
            sc.frame_set(int(f))
            samples.append((int(f), round(tip_angle(), 2)))
        out(f"action {act.name}: frames {f0:.0f}-{f1:.0f} @ {sc.render.fps} fps = {(f1 - f0) / sc.render.fps:.3f} s, "
            f"arm angle (frame, deg) {samples}, bbox at last frame {bbox(mesh)}")
        out_parts(f"{act.name} last frame", mesh)
    ad.action = None
    for pb in rig.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
    sc.frame_set(1)
    out(f"rest (closed) bbox {bbox(mesh)}")
    out_parts("rest", mesh)
    p = parts(mesh)
    sx, sy, sz = (b - a for a, b in zip(*p["SIGN"]))   # STOP plate 0.55 across the flats, 0.112 thick, on the arm line
    assert abs(sx - 2 * A.SIGN_APOTHEM) < 0.01 and abs(sz - 2 * A.SIGN_APOTHEM) < 0.01 and abs(sy - (A.ARM_T + 0.012)) < 0.002, p["SIGN"]
    assert p["lamp"][0][1] < 0.3 < p["lamp"][1][1] and abs((p["lamp"][0][2] + p["lamp"][1][2]) / 2 - 1.0) < 0.01, p["lamp"]


for glb in sorted((HERE / "export").glob("knoxpass_barrier_*.glb")):
    verify(glb)
(HERE / "export" / "knoxpass_barrier_verify.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
sys.exit(0)
