"""Re-import every export/knoxpass_roll2f_<W>.glb (and the KNOXPASS_FAST=1 *_fast.glb) into an empty scene and check
the animation.
用法：blender -b --factory-startup --python verify_roll2f.py      (writes export/knoxpass_roll2f_verify.txt, exit 1 on FAIL)

Per glb: glTF structure (skin joints, animations, channel paths, key count, duration), re-imported bones, bone
transforms of Slat00 / Slat16 / Slat31 at t = 0, 0.5, 1 of both clips, Slat00 travel (its head height; it never leaves
the straight part of the path) = TRAVEL * ease(t) for Open / TRAVEL * ease(1 - t) for Close at t = 0.1, 0.5, 0.9
(scripts/blender/ease.py, < 1 cm) and monotonic over every frame, and on EVERY frame of both clips: each slat
vertex is either on the curtain plane below the housing or inside the housing cross-section (atlas.HOUSE_PROFILE,
x within the width). End of Open / start of Close: every slat vertex inside the housing (curtain fully hidden, opening
clear up to HOUSE_B). Start of Open / end of Close: curtain closed from the floor to inside the housing.
"""
import json
import struct
import sys
from pathlib import Path

import bpy

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import atlas as A  # noqa: E402
from ease import ease  # noqa: E402

lines, fails = [], []
EPS = 1e-3


def out(s=""):
    print(s)
    lines.append(str(s))


def check(ok, msg):
    if not ok:
        fails.append(msg)
        out(f"FAIL {msg}")


def inside_profile(y, z):
    """More than EPS (1 mm, true distance) inside every edge of the convex housing cross-section (CCW in (y, z)).
    The on-plane test accepts z <= HOUSE_B + EPS, so the two regions meet where the curtain enters the housing."""
    p = A.HOUSE_PROFILE
    for k in range(len(p)):
        (ya, za), (yb, zb) = p[k], p[(k + 1) % len(p)]
        length = ((yb - ya) ** 2 + (zb - za) ** 2) ** 0.5
        if ((yb - ya) * (z - za) - (zb - za) * (y - ya)) / length <= EPS:
            return False
    return True


def verify(glb, width):
    raw = glb.read_bytes()
    j = json.loads(raw[20:20 + struct.unpack("<I", raw[12:16])[0]])
    out(f"\n==================== {glb.name} ({len(raw)} bytes)")
    joints = [j["nodes"][i]["name"] for i in j["skins"][0]["joints"]]
    out(f"skin joints {len(joints)}: {joints[0]}, {joints[1]} .. {joints[-1]}")
    check(len(joints) + 1 <= 60, "door.vert MatrixPalette[60] (Dummy01 + joints)")
    anims = {a["name"]: a for a in j["animations"]}
    check(set(anims) == {"Open", "Close"}, f"clips {sorted(anims)}")
    for a in anims.values():
        paths = sorted({c["target"]["path"] for c in a["channels"]})
        tmin = min(j["accessors"][s["input"]]["min"][0] for s in a["samplers"])
        tmax = max(j["accessors"][s["input"]]["max"][0] for s in a["samplers"])
        keys = max(j["accessors"][s["input"]]["count"] for s in a["samplers"])
        # keys run frame 1 -> 145 = 0.042 .. 6.042 s, same as the shipped barrier arm (knoxpass_barrier_verify.txt);
        # the *_fast model frame 1 -> 91 = 3.75 s (build_roll2f.py CLIP_S)
        out(f"animation {a['name']}: channels={len(a['channels'])} paths={paths} keys<={keys} "
            f"time {tmin:.3f}..{tmax:.3f} s")
        clip_s = 3.75 if glb.stem.endswith("_fast") else 6.0
        check(abs(tmax - tmin - clip_s) < 1e-3, f"{a['name']} length {tmax - tmin}")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(glb))
    sc = bpy.context.scene
    rig = next(o for o in sc.objects if o.type == "ARMATURE")
    mesh = next(o for o in sc.objects if o.type == "MESH" and not o.name.startswith("Icosphere"))
    out(f"re-import: armature {rig.name}, bones {len(rig.data.bones)}, mesh verts {len(mesh.data.vertices)} "
        f"tris {sum(len(p.vertices) - 2 for p in mesh.data.polygons)}, fps {sc.render.fps}")
    check(rig.name == "Dummy01", f"armature {rig.name}")
    groups = {g.index: g.name for g in mesh.vertex_groups}
    slat_verts = [v.index for v in mesh.data.vertices
                  if any(groups[g.group].startswith("Slat") and g.weight > 0.5 for g in v.groups)]
    xl, xr = -0.5, width - 0.5
    ad = rig.animation_data
    for t in ad.nla_tracks:
        t.mute = True

    def slat_points():
        ev = mesh.evaluated_get(bpy.context.evaluated_depsgraph_get())
        me = ev.to_mesh()
        # glTF import is +Y up -> Blender Z up again; matrix_world is identity on both objects
        pts = [(mesh.matrix_world @ me.vertices[i].co).copy() for i in slat_verts]
        ev.to_mesh_clear()
        return pts

    for clip in ("Open", "Close"):
        act = bpy.data.actions[clip]
        ad.action = act
        if hasattr(ad, "action_slot") and act.slots:
            ad.action_slot = act.slots[0]
        f0, f1 = (int(round(f)) for f in act.frame_range)
        bad = 0
        heads = []
        for f in range(f0, f1 + 1):
            sc.frame_set(f)
            heads.append((rig.matrix_world @ rig.pose.bones["Slat00"].matrix).translation.z)
            for p in slat_points():
                on_plane = abs(p.y - A.CURTAIN_Y) <= A.BAR_T / 2 + EPS and p.z <= A.HOUSE_B + EPS
                hidden = xl < p.x < xr and inside_profile(p.y, p.z)
                if not (on_plane or hidden) or not (xl <= p.x <= xr):
                    bad += 1
        check(bad == 0, f"{clip}: {bad} slat vertex-frames outside the curtain plane and the housing")
        out(f"{clip}: frames {f0}-{f1}, every frame checked ({bad} violations)")
        sgn = 1 if clip == "Open" else -1
        mono = all(sgn * (b - a) >= -1e-5 for a, b in zip(heads, heads[1:]))
        check(mono, f"{clip}: Slat00 travel not monotonic")
        eased = []
        for t in (0.1, 0.5, 0.9):
            fr = f0 + t * (f1 - f0)                    # exact clip time: frame + subframe
            sc.frame_set(int(fr), subframe=fr - int(fr))
            got = (rig.matrix_world @ rig.pose.bones["Slat00"].matrix).translation.z
            want = A.TRAVEL * ease(t if clip == "Open" else 1 - t)
            eased.append(f"t={t} {got:.4f} (ease {want:.4f}, linear {A.TRAVEL * (t if sgn > 0 else 1 - t):.4f})")
            check(abs(got - want) < 0.01, f"{clip} t={t}: Slat00 travel {got:.4f} != TRAVEL*ease {want:.4f}")
        out(f"{clip}: Slat00 travel monotonic={mono}; " + "; ".join(eased))
        for t in (0.0, 0.5, 1.0):
            f = round(f0 + t * (f1 - f0))
            sc.frame_set(f)
            pts = slat_points()
            zmin = min(p.z for p in pts)
            n_in = sum(1 for p in pts if xl < p.x < xr and inside_profile(p.y, p.z))
            bones = []
            for name in ("Slat00", "Slat16", "Slat31"):
                m = rig.matrix_world @ rig.pose.bones[name].matrix
                d = m.to_3x3().col[1]                  # bone axis (rest: +Z, along the slat)
                bones.append(f"{name} head=(y {m.translation.y:.3f}, z {m.translation.z:.3f}) "
                             f"axis=(y {d.y:.2f}, z {d.z:.2f})")
            out(f"  {clip} t={t:.1f} frame {f}: slat zmin={zmin:.3f} inside housing {n_in}/{len(pts)} | "
                + "; ".join(bones))
            hidden_end = (clip == "Open" and t == 1.0) or (clip == "Close" and t == 0.0)
            closed_end = (clip == "Open" and t == 0.0) or (clip == "Close" and t == 1.0)
            if hidden_end:
                check(n_in == len(pts), f"{clip} t={t}: curtain not fully inside the housing ({n_in}/{len(pts)})")
                check(zmin > A.HOUSE_B, f"{clip} t={t}: zmin {zmin} under the housing bottom")
            if closed_end:
                check(zmin < 0.02 and max(p.z for p in pts) > A.HOUSE_B, f"{clip} t={t}: curtain not closed")
    ad.action = None


for w in A.WIDTHS:
    for suffix in ("", "_fast"):
        verify(HERE / "export" / f"knoxpass_roll2f_{w}{suffix}.glb", w)
out(f"\n{'ALL OK' if not fails else f'{len(fails)} FAIL'}")
(HERE / "export" / "knoxpass_roll2f_verify.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
sys.exit(1 if fails else 0)
