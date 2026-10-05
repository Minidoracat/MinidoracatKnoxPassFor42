"""Re-import every export/knoxpass_barrier_*.glb into an empty scene; print glTF structure, bones, clips,
arm angle at clip start/middle/end and bounding boxes.
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
    ad.action = None
    for pb in rig.pose.bones:
        pb.rotation_quaternion = (1, 0, 0, 0)
    sc.frame_set(1)
    out(f"rest (closed) bbox {bbox(mesh)}")


for glb in sorted((HERE / "export").glob("knoxpass_barrier_*.glb")):
    verify(glb)
(HERE / "export" / "knoxpass_barrier_verify.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
sys.exit(0)
