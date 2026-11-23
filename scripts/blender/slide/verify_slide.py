"""Re-import every export/*.glb and check it: clips, bones, the leaf's slide along Open and Close (= travel x ease(t),
monotonic, eased start and stop), closed / open spans, and that the leaf stays in its plane clear of the posts, the
guide brackets and the reader on the end-A post.
用法：blender -b --factory-startup --python verify_slide.py      (writes export/verify.txt, exit 1 on any failure)
"""
import importlib.util
import sys
import traceback
import types
from pathlib import Path

import bpy

HERE = Path(__file__).resolve().parent
GATE = HERE.parent / "gate"
V = types.ModuleType("verify_gate")          # its helpers only: out, gltf, load, verts, box, tris
V.__file__ = str(GATE / "verify_gate.py")
_src = (GATE / "verify_gate.py").read_text(encoding="utf-8")
exec(compile(_src[:_src.index("\ndef leaf(")], V.__file__, "exec"), V.__dict__)
out, ease = V.out, V.ease
_sp = importlib.util.spec_from_file_location("knoxpass_slide_spec", HERE / "spec.py")
S = importlib.util.module_from_spec(_sp)
_sp.loader.exec_module(S)
G = S.G
READER_OUT = 0.05                            # the reader pillar's plate + reader stand this far off the post face


def leaf(look, story, L, suffix=""):
    glb = HERE / "export" / f"{S.leaf_model(look, story, L)}{suffix}.glb"
    j, size = V.gltf(glb)
    out(f"\n== {glb.name} ({size} bytes)")
    anims = {a["name"]: (min(j["accessors"][s["input"]]["min"][0] for s in a["samplers"]),
                         max(j["accessors"][s["input"]]["max"][0] for s in a["samplers"])) for a in j["animations"]}
    out(f"glTF animations {anims}  alphaMode {[m.get('alphaMode', 'OPAQUE') for m in j['materials']]}"
        f"  images {[i.get('name') for i in j['images']]}")
    clip_s = 3.75 if suffix == "_fast" else 6.0
    assert set(anims) == {"Open", "Close"}, anims
    assert all(abs(t0 - 1 / G.FPS) < 1e-4 and abs(t1 - t0 - clip_s) < 1e-3 for t0, t1 in anims.values()), anims
    assert [i.get("name") for i in j["images"]] == [S.texture(look)], j["images"]
    if S.geometry(look) == "A":
        assert j["materials"][0].get("alphaMode") == "MASK", j["materials"]
    sc, rig, mesh = V.load(glb)
    out(f"bones {[(b.name, tuple(round(v, 3) for v in b.head_local)) for b in rig.data.bones]}  "
        f"verts={len(mesh.data.vertices)} tris={V.tris(mesh)}")
    assert sorted(b.name for b in rig.data.bones) == ["LeafBone", "PostBone"]
    assert len(V.verts(mesh, "LeafBone")) == len(mesh.data.vertices), "every vertex rides the leaf bone"
    hw, half, top = S.post_hw(look), S.LEAF_T[S.geometry(look)] / 2, S.TOP[story]
    ad = rig.animation_data
    for tr in ad.nla_tracks:
        tr.mute = True
    ad.action = None
    for pb in rig.pose.bones:
        pb.location, pb.rotation_quaternion = (0, 0, 0), (1, 0, 0, 0)
    sc.frame_set(1)
    rest = V.box(V.verts(mesh))
    out(f"rest (closed) bbox {rest}  height {rest[1][2] / G.STORY:.2f} stories")
    assert abs(rest[0][0] - S.LEAF_X0) < 1e-3 and abs(rest[1][0] - (L + S.LEAF_X1)) < 1e-3, rest
    assert rest[0][0] < hw and rest[1][0] > L + 1 - hw, "closed leaf overlaps both posts"
    assert 0 <= rest[0][2] and rest[1][2] <= top + 1e-3 < story * G.STORY, rest
    # its plane: off the post face by more than the reader, short of the door line, inside the guide rollers
    assert rest[0][1] >= S.POST_Y + hw + READER_OUT + 0.01 and rest[1][1] <= 0.5 - 0.02, rest
    assert rest[0][1] >= S.LEAF_Y - half - 1e-3 and rest[1][1] <= S.LEAF_Y + half + 1e-3, rest
    for clip in ("Open", "Close"):
        act = bpy.data.actions[clip]
        ad.action = act
        if hasattr(ad, "action_slot") and act.slots:
            ad.action_slot = act.slots[0]
        f0, f1 = act.frame_range
        n = f1 - f0
        want = (lambda t: S.travel(L) * ease(t)) if clip == "Open" else (lambda t: S.travel(L) * ease(1 - t))

        def slid():
            b = V.box(V.verts(mesh))
            assert b[0][1:] == rest[0][1:] and b[1][1:] == rest[1][1:], (clip, "left its plane", b)
            return rest[0][0] - b[0][0]
        samples = []
        for t in (0.0, 0.1, 0.5, 0.9, 1.0):
            f = f0 + t * n
            sc.frame_set(int(f), subframe=f - int(f))
            samples.append((t, round(slid(), 3), round(want(t), 3)))
            assert abs(samples[-1][1] - samples[-1][2]) < 0.01, (clip, samples[-1])
        per = []
        for f in range(int(f0), int(f1) + 1):
            sc.frame_set(f)
            per.append(slid())
        sgn = 1 if clip == "Open" else -1
        steps = [sgn * (q - p) for p, q in zip(per, per[1:])]
        out(f"clip {clip}: frames {f0:.0f}-{f1:.0f} = {n / sc.render.fps:.2f} s, (t, slid, want) {samples}; "
            f"per-frame step min {min(steps):.4f} max {max(steps):.4f}, first {steps[0]:.4f} last {steps[-1]:.4f}")
        assert min(steps) >= -1e-4 and steps[0] < 0.01 and steps[-1] < 0.01, (clip, min(steps), steps[0], steps[-1])
        if clip == "Open":
            b = V.box(V.verts(mesh))
            out(f"open bbox {b}")
            assert b[1][0] <= 0.5 and b[0][0] >= -L - 0.5, "open leaf inside the stow end's tile and the L stow tiles"


def post(look, story):
    glb = HERE / "export" / f"{S.post_model(look, story)}.glb"
    j, size = V.gltf(glb)
    sc, _, mesh = V.load(glb)
    ws = V.verts(mesh)
    b = V.box(ws)
    out(f"\n== {glb.name} ({size} bytes) static, verts={len(mesh.data.vertices)} tris={V.tris(mesh)} bbox {b} "
        f"images {[i.get('name') for i in j['images']]}")
    hw, half, top = S.post_hw(look), S.LEAF_T[S.geometry(look)] / 2, S.TOP[story]
    assert abs(b[0][0] + b[1][0]) < 1e-3 and b[1][2] < story * G.STORY, b   # symmetric: both ends share a transform
    assert -0.5 < b[0][1] and b[1][1] < 0.5, b
    # the guide bracket (everything off the post's line-side face) clears the leaf's swept box by 0.01
    for w in ws:
        if w.y > S.POST_Y + hw + 1e-4 and w.z > 0.2:
            assert w.z >= top + 0.02 or abs(w.y - S.LEAF_Y) >= half + 0.01, tuple(w)


def check(fn, *a):
    try:
        fn(*a)
    except Exception:
        V.failed.append(a)
        out("FAIL " + traceback.format_exc())


for look, story, group in S.VARIANTS:
    check(post, look, story)
    for L in S.GROUPS[group]:
        check(leaf, look, story, L)
        check(leaf, look, story, L, "_fast")
out(f"\n{'FAILED ' + str(V.failed) if V.failed else 'ALL OK'}")
(HERE / "export" / "verify.txt").write_text("\n".join(V.lines) + "\n", encoding="utf-8")
sys.exit(1 if V.failed else 0)
