"""Knox Pass sliding gate: shared numbers (pure Python; loaded by path by the Blender scripts and assemble.py).

One leaf slides along the gate line, past one end post, into a stow section as long as the gate. Model space is the
two-story gates' (../gate/spec.py): 1 unit = 1 tile, +X along the line, +Y toward the door line (y = +0.5), floor z = 0.
  leaf model  origin = centre of the end tile the leaf slides past (the stow end). Closed leaf x = LEAF_X0 .. L + LEAF_X1
              (it overlaps both posts), centre plane y = LEAF_Y: between the posts and the door line, so the leaf is
              drawn 0.09 from where the lane doors block. Open moves it travel(L) toward -X.
  post model  origin = its own tile centre; post centred on x = 0, y = POST_Y, symmetric about x = 0 (both ends share
              one transform); the guide bracket reaches over the leaf plane.
Posts sit POST_Y - gate PLANE_Y nearer the tile centre than the two-story gates' so the leaf passes between the post
(and the reader on its face) and the door line; the reader pillar models are the gates', shifted by the same amount.

Sides (which end the leaf stows past):
  L  the glb as built: the face's rotation, origin on the end at the model's -X side (N / W end A, S / E end B).
  R  the same glb turned 180 deg about its origin: the opposite face's rotation, origin on the other end, shifted
     2 * LEAF_Y toward the door line so the leaf plane and the closed span stay put and the leaf slides the other way.
Seen from the post side of the line, L stows to the left and R to the right on every face.
"""
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load(name, path):
    sp = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(mod)
    return mod


G = _load("knoxpass_gate_spec", HERE.parent / "gate" / "spec.py")   # by path: both folders call the file spec.py

# (look, story, width group) built so far. Order = tileset / build-menu order: append only once shipped.
VARIANTS = (("A", 1, "6"),)
GROUPS = {"34": (3, 4), "6": (6,)}     # widths of one tileset: 2 widths x 4 faces = the 512-tile limit
SIDES = "LR"
FACES = G.FACES
TOP = {1: 2.15, 2: 4.45}               # leaf top by story
HEALTH = {1: {3: 1000, 4: 1000, 6: 1500}, 2: {3: 1500, 4: 1500, 6: 2000}}   # by size, two-story + 500 (2026-10-08)
POST_Y = 0.105
LEAF_Y = 0.41
LEAF_X0, LEAF_X1 = 0.10, 0.90
Z0 = 0.10                              # leaf bottom: the wheel carriages run under it
LEAF_T = {"A": 0.08}                   # total leaf thickness
STOW = 25                              # first stow slot (build_model_gates.py STOW, Lua KP.GATE_SLOT.STOW)
OPP = {"N": "S", "S": "N", "W": "E", "E": "W"}
# model +X and +Y in PZ tile coordinates (x east, y south) under the face's rotation (../gate/spec.py ROTATE)
AXES = {"N": ((1, 0), (0, -1)), "W": ((0, -1), (-1, 0)), "S": ((-1, 0), (0, 1)), "E": ((0, 1), (1, 0))}


def travel(L):
    """Open: the leaf's lane-side end stops at x = 0.45, inside the stow end's tile, and its far end at -L - 0.35."""
    return L + 0.45


def geometry(look):
    return look


def post_hw(look):
    return G.LOOK[geometry(look)]["post_hw"]


def leaf_model(look, story, L):
    return f"MinidoracatKnoxPass_slide{story}_{geometry(look)}{L}"


def post_model(look, story):
    return f"MinidoracatKnoxPass_slidepost{story}_{geometry(look)}"


def texture(look):
    return G.texture(look)             # the two-story gate's atlas (shipped by the gate kind)


def tileset(look, story, group, side):
    return f"MinidoracatKnoxPass_slide{story}_{look.lower()}{group}{side.lower()}"


def kind(story, group):
    return f"slide{story}w{group}"


def entity(look, story, L, side):
    return f"MinidoracatKnoxPassSlide{story}{look}{L}{side}"


def icon(look, story, L, side):
    return f"slide{story}_{look.lower()}_{L}{side.lower()}.png"


def block(group, L, face):
    return GROUPS[group].index(L) * 4 + FACES.index(face)


def stow_end(face, L, side):
    """(tile of the end post the leaf slides past, tile of the other end), from the entity origin without stow."""
    a, b = G.end_a(face, L), G.end_b(face, L)
    return (a, b) if (face in "NW") == (side == "L") else (b, a)


def stow_tiles(face, L, side):
    """Stow tiles k = 1..L, k = 1 next to the stow end, in the placed row / column beyond it."""
    (sx, sy), (ox, oy) = stow_end(face, L, side)
    dx, dy = (sx - ox) // (L + 1), (sy - oy) // (L + 1)
    return [(sx + k * dx, sy + k * dy) for k in range(1, L + 1)]


def stow_head(face, side):
    """The stow tiles come before the gate in the entity row (west / north of it)."""
    return (face in "NE") == (side == "L")


def leaf_rotate(face, side):
    return G.ROTATE[face if side == "L" else OPP[face]]


def leaf_origin(face, L, side):
    """Model origin in tiles from the entity origin (fractional for R: shifted to keep the leaf plane)."""
    (sx, sy), _ = stow_end(face, L, side)
    if side == "L":
        return float(sx), float(sy)
    yx, yy = AXES[face][1]
    return sx + 2 * LEAF_Y * yx, sy + 2 * LEAF_Y * yy


def leaf_translate(face, L, side):
    """spriteModels translate on real lane 1: (dx, 0, dy) host -> model origin."""
    (hx, hy), (ox, oy) = G.real_lane(face, L, 1), leaf_origin(face, L, side)
    return (round(ox - hx, 4), 0.0, round(oy - hy, 4))


def pillar_translate(face):
    """The gates' reader pillar model (built for a post at PLANE_Y) on a slide post."""
    yx, yy = AXES[face][1]
    d = POST_Y - G.PLANE_Y
    return (round(d * yx, 4), 0.0, round(d * yy, 4))


if __name__ == "__main__":   # self-check
    for face in FACES:
        (xx, xy), (yx, yy) = AXES[face]
        assert xx * yx + xy * yy == 0 and AXES[OPP[face]] == ((-xx, -xy), (-yx, -yy))
        # +Y points from the placed row to the real lane row (the door line side), as ../gate/spec.py real_lane has it
        px, py = G.placeholder(face, 6, 1)
        rx, ry = G.real_lane(face, 6, 1)
        assert (rx - px, ry - py) in ((0, 0), (yx, yy)), face
        for L in (3, 4, 6):
            for side in SIDES:
                (sx, sy), (ox, oy) = stow_end(face, L, side)
                # the leaf's -X (stow) direction under its rotation points from the other end to the stow end
                lx, ly = AXES[face if side == "L" else OPP[face]][0]
                assert (-lx * (L + 1), -ly * (L + 1)) == (sx - ox, sy - oy), (face, L, side)
                # leaf plane: origin + LEAF_Y x its +Y = the stow end + LEAF_Y toward the door line, on both sides
                qx, qy = AXES[face if side == "L" else OPP[face]][1]
                gx, gy = leaf_origin(face, L, side)
                assert abs(gx + LEAF_Y * qx - (sx + LEAF_Y * yx)) < 1e-9 and abs(gy + LEAF_Y * qy - (sy + LEAF_Y * yy)) < 1e-9
                tiles = stow_tiles(face, L, side)
                assert len(set(tiles)) == L and not set(tiles) & {G.placeholder(face, L, k) for k in range(1, L + 1)}
                head = all(t < min(stow_end(face, L, side)) for t in tiles)
                assert head == stow_head(face, side), (face, side, tiles)
    assert leaf_translate("N", 6, "L") == (-1, 0, 0) and leaf_translate("N", 6, "R") == (6, 0, -0.82)
    assert leaf_translate("S", 6, "L") == (6, 0, -1) and leaf_translate("W", 6, "R") == (-0.82, 0, -6)
    assert stow_tiles("N", 3, "L") == [(-1, 0), (-2, 0), (-3, 0)] and stow_tiles("W", 3, "L") == [(0, 5), (0, 6), (0, 7)]
    assert all(travel(L) + LEAF_X1 - 0.5 <= L + 0.9 and L + LEAF_X1 - travel(L) <= 0.5 for L in (3, 4, 6))
    assert max(len(w) for w in GROUPS.values()) * 4 * 64 <= 512 and STOW + 6 <= 32
    print("spec ok")
