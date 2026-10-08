"""Knox Pass gate: icons, end-cell sharing, contact sheets, manifest.json (after render_gate.py and verify_gate.py).
用法：uv run --with pillow python assemble.py
Outputs: icons/gate_<look>_<L>.png (64x64), previews/sheet_<look><L>.png (N/S x closed/half/open),
previews/cells_<look><L>.png (each face's cells re-assembled at their tile positions), manifest.json.
End cells: 9-wide blocks reuse the 6-wide endA / endB file when the two renders differ in < 2 % of the opaque pixels
(B / E: identical; A brace angle / C bar spacing / D brace angle inside the end tile change with the width by 1-2 px;
the cell is a build-ghost only), so all 40 end cells of the 9-wide blocks share the 6-wide files.
"""
import json
from pathlib import Path

from PIL import Image, ImageChops

import spec as S

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
rel = lambda p: p.relative_to(REPO).as_posix()  # noqa: E731
HEALTH = {6: 2000, 9: 2500}
FAMILY = "MinidoracatKnoxPass_gate_"           # integration: one tileset per look (512-tile tiledef limit)


def fit_icon(img, size=64):
    img = img.crop(img.getchannel("A").getbbox())
    k = (size - 2) / max(img.size)
    img = img.resize((max(1, round(img.width * k)), max(1, round(img.height * k))), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(img, ((size - img.width) // 2, (size - img.height) // 2))
    return out


def near_same(a, b):
    a, b = Image.open(a).convert("RGBA"), Image.open(b).convert("RGBA")
    diff = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 24 else 0)
    opaque = sum(a.getchannel("A").histogram()[9:]) or 1
    return diff.histogram()[255] / opaque


def end_cell(look, L, face, end):
    own = HERE / "cells" / f"{look}{L}" / face / f"{end}.png"
    if L == 6:
        return own, 0.0
    base = HERE / "cells" / f"{look}6" / face / f"{end}.png"
    d = near_same(own, base)
    return (base if d < 0.02 else own), d


def sheets():
    for look in S.LOOKS:
        for L in S.WIDTHS:
            ims = [[Image.open(HERE / "previews" / f"{look}{L}_{f}_{s}.png").convert("RGBA") for s in ("closed", "half", "open")]
                   for f in "NS"]
            w = max(i.width for r in ims for i in r)
            h = max(i.height for r in ims for i in r)
            sheet = Image.new("RGBA", (3 * w, 2 * h), (40, 40, 40, 255))
            for r, row in enumerate(ims):
                for c, im in enumerate(row):
                    sheet.alpha_composite(im, (c * w, r * h))
            sheet.thumbnail((2400, 2400))
            sheet.save(HERE / "previews" / f"sheet_{look}{L}.png")
            # cells re-assembled: tile (x, y) top corner at (64 (x - y), 32 (x + y)) + offset, painter's order x + y
            canvas = Image.new("RGBA", (4 * 1500, 1100), (96, 96, 96, 255))
            for fi, f in enumerate(S.FACES):
                tiles = [(S.placeholder(f, L, k), HERE / "cells" / f"{look}{L}" / f / f"lane{k}.png") for k in range(1, L + 1)]
                tiles += [(S.end_a(f, L), end_cell(look, L, f, "endA")[0]), (S.end_b(f, L), end_cell(look, L, f, "endB")[0])]
                for (x, y), p in sorted(tiles, key=lambda t: t[0][0] + t[0][1]):
                    canvas.alpha_composite(Image.open(p).convert("RGBA"), (fi * 1500 + 700 + 64 * (x - y) - 64, 200 + 32 * (x + y) - 192 + 400))
            canvas.thumbnail((3000, 3000))
            canvas.save(HERE / "previews" / f"cells_{look}{L}.png")


def slot_table(look, L, face):
    edge = "N" if face in "NS" else "W"
    rot = list(S.ROTATE[face])
    leaf = {"model": S.leaf_model(look, L), "translate": list(S.leaf_translate(face, L)), "rotate": rot}
    post = {"model": S.post_model(look), "translate": [0.0, 0.0, 0.0], "rotate": rot}
    cell = lambda p: rel(p)  # noqa: E731
    t = {}
    for k, gd in ((0, 1), (1, 2), (2, 3)):
        t[str(k)] = {"role": f"lane closed, GarageDoor {gd}" + (" (lane 1 = chain anchor)" if k == 0 else
                                                                  " (every middle lane)" if k == 1 else " (last lane)"),
                     "props": {f"door{edge}": "", "GarageDoor": str(gd)}, "cell": None,
                     "spriteModel": dict(leaf, animation="Open", animationTime=0.0) if k == 0 else None}
        t[str(k + 8)] = {"role": f"lane open, GarageDoor {gd + 3}", "props": {f"door{edge}": "", "GarageDoor": str(gd + 3)},
                         "cell": None, "spriteModel": dict(leaf, animation="Close", animationTime=0.0) if k == 0 else None}
    for slot, end in ((3, "endA"), (4, "endB")):
        p, d = end_cell(look, L, face, end)
        t[str(slot)] = {"role": f"{end} post (solid)", "cell": cell(p), "spriteModel": dict(post),
                        "shared_from_width6": L == 9 and "/" + f"{look}6/" in rel(p), "diff_vs_width6": round(d, 4)}
    for k in range(1, L + 1):
        t[str(15 + k)] = {"role": f"placeholder lane {k} (build only, no GarageDoor)", "props": {f"door{edge}": ""},
                          "cell": cell(HERE / "cells" / f"{look}{L}" / face / f"lane{k}.png"), "spriteModel": None}
    for k in range(S.POSE_FRAMES + 1):
        for base, what in ((32, "opening"), (48, "closing")):
            t[str(base + k)] = {"role": f"{what} pose {k}/8 (spriteModel only)", "cell": None,
                                "spriteModel": dict(leaf, animation="Open", animationTime=round(k / S.POSE_FRAMES, 4))}
    return dict(sorted(t.items(), key=lambda kv: int(kv[0])))


def manifest():
    verify = (HERE / "export" / "verify.txt").read_text(encoding="utf-8")
    assert verify.rstrip().endswith("ALL OK"), "run verify_gate.py first"
    m = {
        "kind": "gate",
        "contract": "r4-contract.md + 2026-10-08 split: one tileset per look",
        "tilesets": {look: {"name": f"{FAMILY}{look.lower()}", "blockInTileset": "widthIdx * 4 + faceIdx",
                            "index": "blockInTileset * 64 + slot"} for look in S.LOOKS},
        "globalBlock": "(look * 2 + widthIdx) * 4 + faceIdx (original contract numbering; blocks below carry both)",
        "units": {"tile": 1.0, "story": S.STORY, "cell": [128, 256], "cellAnchor": "tile top corner (64,192)",
                  "cellContent": "lower story only (frame cut), world-position mask per tile footprint"},
        "modelSpace": {
            "leaf": "origin = centre of the end tile on the model's -X side (N/W: end A, S/E: end B) on the floor; +X along "
                    "the line to the other end (other end tile centre x = L + 1, lane k at x = k); door line y = +0.5; leaf "
                    f"centre plane y = {S.PLANE_Y}; leaves swing to -Y (post side). Symmetric about x = (L + 1) / 2.",
            "post": f"origin = its own tile centre on the floor; post centred on x = 0, y = {S.PLANE_Y}; symmetric about "
                    "x = 0, so end A and end B share one transform per face.",
            "glb": "Khronos glTF exporter, +Y up, 1 unit = 1 tile (same settings as scripts/blender/barrier/build_barrier.py)",
        },
        "faces": {f: {"rotate": list(S.ROTATE[f]), "edge": "N" if f in "NS" else "W",
                      "swing": {"N": "south", "S": "north", "W": "east", "E": "west"}[f],
                      "leafHost": "real lane 1 (slot 0 / 8 / poses)",
                      "leafTranslate": {str(L): list(S.leaf_translate(f, L)) for L in S.WIDTHS},
                      "endA": {"tile": "entity endA", "translate": [0.0, 0.0, 0.0], "rotate": list(S.ROTATE[f])},
                      "endB": {"tile": "entity endB", "translate": [0.0, 0.0, 0.0], "rotate": list(S.ROTATE[f])}}
                  for f in S.FACES},
        "clips": {"Open": "both leaves 0 -> 90 deg", "Close": "90 -> 0 deg", "fps": S.FPS, "frames": [S.F0, S.F1],
                  "seconds": (S.F1 - S.F0) / S.FPS, "inGameSeconds": "~4 (speedDelta 1.5)",
                  "interpolation": "ease (scripts/blender/ease.py), keyed on every frame: angle = 90 x ease(t) for Open, "
                                   "90 x ease(1 - t) for Close; t = 0.5 is the same half-way pose as before",
                  "poses": "slots 32+k and 48+k: animation Open, animationTime k/8 (k = 0..8); pose angle = 90 x "
                           "ease(k/8) (the clip is eased, the sampling time stays linear)"},
        "bones": {"armature": "Dummy01", "PostBone": "origin, no geometry (vanilla rig convention)",
                  "DoorBoneA": "leaf on the model's -X side, head (hinge_x, PLANE_Y, 0), bone +Z; Open turns it -90 deg about +Z",
                  "DoorBoneB": "leaf on the model's +X side, head (L + 1 - hinge_x, PLANE_Y, 0); Open turns it +90 deg about +Z",
                  "hinge_x": {look: round(S.hinge_x(look), 4) for look in S.LOOKS}},
        "models": {}, "posts": {}, "textures": {}, "reader_mount": {}, "entities": {}, "blocks": [],
    }
    for look in S.LOOKS:
        tex = S.texture(look)
        m["textures"][look] = {"src": rel(HERE / "textures" / f"{tex}.png"), "ship": f"textures/IsoObject/{tex}.png",
                               "size": [512, 512], "alpha": "chain-link cut-out (binary alpha, door shader discards a < 0.01)"
                               if look == "A" else "opaque"}
        for L in S.WIDTHS:
            name = S.leaf_model(look, L)
            m["models"][name] = {
                "look": look, "width": L, "src": rel(HERE / "export" / f"{name}.glb"),
                "ship": f"models_X/IsoObject/{name}.glb",
                "modelScript": {"name": name, "mesh": f"IsoObject/{name}", "texture": f"IsoObject/{tex}", "shader": "door",
                                "static": False, "undoCoreScale": True,
                                "animationsMesh": {"name": name, "meshFile": f"IsoObject/{name}", "keepMeshAnimations": True}}}
        pm = S.post_model(look)
        m["posts"][look] = {"model": pm, "src": rel(HERE / "export" / f"{pm}.glb"), "ship": f"models_X/IsoObject/{pm}.glb",
                            "modelScript": {"name": pm, "mesh": f"IsoObject/{pm}", "texture": f"IsoObject/{tex}",
                                            "static": True, "undoCoreScale": True},
                            "postHalfWidth": S.LOOK[look]["post_hw"]}
        rp = f"knoxpass_reader_pillar_{look}"
        m["reader_mount"][look] = {
            "src": rel(HERE / "export" / f"{rp}.glb"), "ship": f"models_X/IsoObject/MinidoracatKnoxPass_reader_pillar_{look}.glb",
            "modelScript": {"mesh": f"IsoObject/MinidoracatKnoxPass_reader_pillar_{look}", "static": True, "undoCoreScale": True,
                            "texture": "same as reader_post: WorldItems/MinidoracatKnoxPassReader<colour suffix> (spriteModels texture = per colour)"},
            "useReaderPost": False,
            "why": f"post {2 * S.LOOK[look]['post_hw']:.2f} tiles thick (> 0.08): reader_post would sit inside the post",
            "geometry": "reader_post() parts (bracket dropped), back plate 0.005 off both post faces normal to traffic, "
                        "centred on the post along the line, 0.92 high; same reader item texture and UVs",
            "host": "end A tile", "faces": {f: {"translate": [0.0, 0.0, 0.0], "rotate": list(S.ROTATE[f])} for f in S.FACES}}
        for L in S.WIDTHS:
            e = S.entity(look, L)
            icon = HERE / "icons" / S.icon(look, L)
            m["entities"][e] = {"look": look, "width": L, "icon": rel(icon),
                                "ship": f"ui/MinidoracatKnoxPass/{S.icon(look, L)}", "health": HEALTH[L], "faces": list(S.FACES)}
            for f in S.FACES:
                g = S.block(look, L, f)
                tb = S.WIDTHS.index(L) * 4 + S.FACES.index(f)
                m["blocks"].append({
                    "look": look, "width": L, "face": f, "tileset": f"{FAMILY}{look.lower()}", "blockInTileset": tb,
                    "firstIndexInTileset": tb * 64, "globalBlock": g, "entity": e, "health": HEALTH[L],
                    "tilesFromEntityOrigin": {"placeholder": {str(k): list(S.placeholder(f, L, k)) for k in range(1, L + 1)},
                                              "realLane": {str(k): list(S.real_lane(f, L, k)) for k in range(1, L + 1)},
                                              "endA": list(S.end_a(f, L)), "endB": list(S.end_b(f, L))},
                    "slots": slot_table(look, L, f)})
    (HERE / "manifest.json").write_text(json.dumps(m, indent=1) + "\n", encoding="utf-8")
    shared = sum(1 for b in m["blocks"] for s in b["slots"].values() if s.get("shared_from_width6"))
    print(f"manifest: {len(m['blocks'])} blocks, {shared} end cells shared from width 6")


if __name__ == "__main__":
    for look in S.LOOKS:
        for L in S.WIDTHS:
            fit_icon(Image.open(HERE / "icons" / "_render" / f"{look}{L}.png").convert("RGBA")).save(
                HERE / "icons" / S.icon(look, L), optimize=True)
    sheets()
    manifest()
