"""Knox Pass sliding gate: icons, faded stow cells, contact sheets, manifest.json (after render_slide.py, verify_slide.py).
用法：uv run --with pillow python assemble.py
Outputs: icons/slide<story>_<look>_<L><side>.png (64x64; R = L mirrored), cells/<look><story>/<face>/stow.png faded to
45 % alpha in place (once: the faded file is what ships), previews/sheet_*.png, manifest.json for build_model_gates.py.
"""
import json
from pathlib import Path

from PIL import Image, ImageOps

import spec as S

G = S.G
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
rel = lambda p: p.relative_to(REPO).as_posix()  # noqa: E731
SEE_THROUGH = {"A"}                            # closed lanes pass sight (doorTrans): chain-link
STOW_ALPHA = 115


def fit_icon(img, size=64):
    img = img.crop(img.getchannel("A").getbbox())
    k = (size - 2) / max(img.size)
    img = img.resize((max(1, round(img.width * k)), max(1, round(img.height * k))), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(img, ((size - img.width) // 2, (size - img.height) // 2))
    return out


def fade_stow():
    for p in sorted((HERE / "cells").glob("*/*/stow.png")):
        im = Image.open(p).convert("RGBA")
        a = im.getchannel("A")
        if a.getextrema()[1] > STOW_ALPHA:     # not faded yet
            im.putalpha(a.point(lambda v: min(v, STOW_ALPHA)))
            im.save(p, optimize=True)


def sheets():
    for look, story, group in S.VARIANTS:
        for L in S.GROUPS[group]:
            rows = [[Image.open(p).convert("RGBA") for s in ("closed", "half", "open")
                     for p in [HERE / "previews" / f"{look}{story}_{L}{side}_{face}_{s}.png"]]
                    for face, side in (("N", "L"), ("N", "R"), ("S", "L"), ("W", "L"), ("E", "R"))]
            w, h = max(i.width for r in rows for i in r), max(i.height for r in rows for i in r)
            sheet = Image.new("RGBA", (3 * w, len(rows) * h), (40, 40, 40, 255))
            for r, row in enumerate(rows):
                for c, im in enumerate(row):
                    sheet.alpha_composite(im, (c * w, r * h))
            sheet.thumbnail((3200, 3200))
            sheet.save(HERE / "previews" / f"sheet_{look}{story}_{L}.png")


def slot_table(look, story, L, face, side):
    cells = HERE / "cells" / f"{S.geometry(look)}{story}" / face
    leaf = {"model": S.leaf_model(look, story, L), "translate": list(S.leaf_translate(face, L, side)),
            "rotate": list(S.leaf_rotate(face, side))}
    post = {"model": S.post_model(look, story), "translate": [0.0, 0.0, 0.0], "rotate": list(G.ROTATE[face])}
    t = {0: {"spriteModel": dict(leaf, animation="Open", animationTime=0.0)},
         8: {"spriteModel": dict(leaf, animation="Close", animationTime=0.0)},
         3: {"cell": rel(cells / "endA.png"), "spriteModel": post}, 4: {"cell": rel(cells / "endB.png"), "spriteModel": post},
         S.STOW_HOST + 8: {"spriteModel": dict(leaf, translate=list(S.stow_translate(face, L, side)), animation="Close",
                                               animationTime=0.0)}}
    for k in range(L):
        t[16 + k] = {"cell": rel(cells / "lane.png")}
        t[S.STOW + k] = {"cell": rel(cells / "stow.png")}
    for k in range(G.POSE_FRAMES + 1):
        for base in (32, 48):
            t[base + k] = {"spriteModel": dict(leaf, animation="Open", animationTime=round(k / G.POSE_FRAMES, 4))}
    return {str(s): t[s] for s in sorted(t)}


def manifest():
    assert (HERE / "export" / "verify.txt").read_text(encoding="utf-8").rstrip().endswith("ALL OK"), "run verify_slide.py first"
    m = {"kind": "slide",
         "modelSpace": "spec.py docstring: leaf origin = stow end tile, closed x = LEAF_X0 .. L + LEAF_X1, plane y = LEAF_Y; "
                       "post symmetric about x = 0 at y = POST_Y; side R = the L glb turned 180 deg",
         "slots": {"0 / 8": "leaf at rest closed / open (build_model_gates.py re-hosts them on the middle lane)",
                   "3 / 4": "end A / end B post", "16..": "lane placeholders",
                   f"{S.STOW}..": "stow placeholders k = 1..L from the stow end: build footprint only, Lua removes them",
                   f"{S.STOW_HOST} / {S.STOW_HOST + 8}": "invisible marker object Lua leaves on stow tile k = L // 2 / the "
                                                           "open leaf re-hosted on it: build_model_gates.py only reads its "
                                                           "translate to place the marker's own rest and pose slots",
                   "32.. / 48..": "opening / closing poses"},
         "kinds": {}, "tilesets": {}, "models": {}, "posts": {}, "reader_mount": [], "entities": {}, "blocks": []}
    mounts = []
    for look, story, group in S.VARIANTS:
        key, geo, tex = S.kind(story, group), S.geometry(look), f"IsoObject/{S.texture(look)}"
        m["kinds"].setdefault(key, {"story": story, "widths": list(S.GROUPS[group])})
        pm = S.post_model(look, story)
        m["posts"].setdefault(pm, {"kind": key, "src": rel(HERE / "export" / f"{pm}.glb"), "ship": f"models_X/IsoObject/{pm}.glb",
                                   "modelScript": {"name": pm, "mesh": f"IsoObject/{pm}", "texture": tex}})
        mount = {"model": f"MinidoracatKnoxPass_ReaderPillar{geo}", "postHalfWidth": S.post_hw(look),
                 "faces": {f: {"translate": list(S.pillar_translate(f)), "rotate": list(G.ROTATE[f])} for f in S.FACES}}
        if mount not in mounts:
            mounts.append(mount)
        for L in S.GROUPS[group]:
            name = S.leaf_model(look, story, L)
            m["models"][name] = {"kind": key, "src": rel(HERE / "export" / f"{name}.glb"), "ship": f"models_X/IsoObject/{name}.glb",
                                 "modelScript": {"name": name, "mesh": f"IsoObject/{name}", "texture": tex}}
        for side in S.SIDES:
            ts = S.tileset(look, story, group, side)
            m["tilesets"][ts] = {"kind": key, "look": look, "side": side, "variant": look + side,
                                 "seeThrough": geo in SEE_THROUGH, "readerMount": mounts.index(mount)}
            for L in S.GROUPS[group]:
                e = S.entity(look, story, L, side)
                m["entities"][e] = {"kind": key, "variant": look + side, "width": L, "health": S.HEALTH[story][L],
                                    "icon": rel(HERE / "icons" / S.icon(look, story, L, side)),
                                    "ship": f"ui/MinidoracatKnoxPass/{S.icon(look, story, L, side)}"}
                for f in S.FACES:
                    m["blocks"].append({"kind": key, "tileset": ts, "blockInTileset": S.block(group, L, f), "width": L,
                                        "face": f, "side": side, "entity": e, "stowHead": S.stow_head(f, side),
                                        "stow": [S.STOW + k for k in range(L)], "slots": slot_table(look, story, L, f, side)})
    m["reader_mount"] = mounts
    (HERE / "manifest.json").write_text(json.dumps(m, indent=1) + "\n", encoding="utf-8")
    print(f"manifest: {len(m['kinds'])} kinds, {len(m['tilesets'])} tilesets, {len(m['blocks'])} blocks, {len(mounts)} reader mounts")


if __name__ == "__main__":
    for look, story, group in S.VARIANTS:
        for L in S.GROUPS[group]:
            icon = fit_icon(Image.open(HERE / "icons" / "_render" / f"{look}{story}_{L}.png").convert("RGBA"))
            icon.save(HERE / "icons" / S.icon(look, story, L, "L"), optimize=True)
            ImageOps.mirror(icon).save(HERE / "icons" / S.icon(look, story, L, "R"), optimize=True)
    fade_stow()
    sheets()
    manifest()
