"""Dump vanilla PZ door .blend / .glb structure (objects, bones, actions, units, materials, UV, images).
用法：blender -b --factory-startup --python dump_vanilla.py -- <file.blend|file.glb> [...]
"""
import sys

import bpy

files = sys.argv[sys.argv.index("--") + 1:]


def dump(label):
    sc = bpy.context.scene
    us = sc.unit_settings
    print(f"=== {label}")
    print(f"scene fps={sc.render.fps}/{sc.render.fps_base} frames={sc.frame_start}-{sc.frame_end} "
          f"unit system={us.system} scale_length={us.scale_length} length_unit={us.length_unit}")
    for o in bpy.data.objects:
        print(f"OBJ {o.name!r} type={o.type} parent={o.parent.name if o.parent else None} "
              f"parent_type={o.parent_type} parent_bone={o.parent_bone!r}")
        print(f"    loc={tuple(round(v, 4) for v in o.location)} rot({o.rotation_mode})="
              f"{tuple(round(v, 4) for v in (o.rotation_quaternion if o.rotation_mode == 'QUATERNION' else o.rotation_euler))} "
              f"scale={tuple(round(v, 4) for v in o.scale)}")
        if o.animation_data:
            ad = o.animation_data
            print(f"    anim action={ad.action.name if ad.action else None} "
                  f"nla={[ (t.name, [s.action.name for s in t.strips]) for t in ad.nla_tracks]}")
        if o.type == "ARMATURE":
            for b in o.data.bones:
                print(f"    BONE {b.name!r} parent={b.parent.name if b.parent else None} "
                      f"head={tuple(round(v, 4) for v in b.head_local)} tail={tuple(round(v, 4) for v in b.tail_local)} "
                      f"roll-matrix={[tuple(round(x, 3) for x in r) for r in b.matrix_local.to_3x3()]}")
        if o.type == "MESH":
            me = o.data
            ws = [o.matrix_world @ v.co for v in me.vertices]
            mn = [round(min(w[i] for w in ws), 4) for i in range(3)]
            mx = [round(max(w[i] for w in ws), 4) for i in range(3)]
            print(f"    mesh verts={len(me.vertices)} faces={len(me.polygons)} uv={[u.name for u in me.uv_layers]} "
                  f"vgroups={[g.name for g in o.vertex_groups]} mods={[(m.type, getattr(m, 'object', None) and m.object.name) for m in o.modifiers]}")
            print(f"    world bbox min={mn} max={mx}")
            print(f"    mats={[m.name if m else None for m in me.materials]}")
    for a in bpy.data.actions:
        rng = tuple(a.frame_range)
        paths = set()
        try:
            for fc in a.fcurves:
                paths.add(fc.data_path)
        except AttributeError:  # Blender 4.4+/5 layered actions
            for layer in a.layers:
                for strip in layer.strips:
                    for cb in strip.channelbags:
                        for fc in cb.fcurves:
                            paths.add(fc.data_path)
                            if 'rotation' in fc.data_path:
                                kps = [(round(k.co[0], 2), round(k.co[1], 4)) for k in fc.keyframe_points]
                                print(f"      KEY {a.name} {fc.data_path}[{fc.array_index}] {kps[:6]}{'...' if len(kps) > 6 else ''} interp={fc.keyframe_points[0].interpolation if kps else None}")
        print(f"ACTION {a.name!r} range={rng} users={a.users} fake={a.use_fake_user} paths={sorted(paths)}")
    for m in bpy.data.materials:
        imgs = []
        if m.use_nodes and m.node_tree:
            imgs = [n.image.name for n in m.node_tree.nodes if n.type == "TEX_IMAGE" and n.image]
        print(f"MAT {m.name!r} images={imgs}")
    for i in bpy.data.images:
        print(f"IMG {i.name!r} size={tuple(i.size)} file={i.filepath!r}")


for f in files:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if f.lower().endswith(".blend"):
        bpy.ops.wm.open_mainfile(filepath=f)
    else:
        bpy.ops.import_scene.gltf(filepath=f)
    dump(f)
