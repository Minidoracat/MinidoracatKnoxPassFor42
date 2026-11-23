"""Knox Pass sliding gate: shared numbers (pure Python; loaded by path by the Blender scripts and assemble.py).

One leaf slides along the gate line, past one end post, into a stow section as long as the gate. Model space is the
two-story gates' (../gate/spec.py): 1 unit = 1 tile, +X along the line, +Y toward the door line (y = +0.5), floor z = 0.
  leaf model  origin = centre of the end tile the leaf slides past (the stow end). Closed leaf x = LEAF_X0 .. L + LEAF_X1
              (it overlaps both posts), centre plane y = LEAF_Y: between the posts and the door line, so the leaf is
              drawn 0.09 from where the lane doors block. Open moves it travel(L) toward -X.
  post model  origin = its own tile centre; post centred on x = 0, y = POST_Y, symmetric about x = 0 (both ends share
              one transform); the guide bracket reaches over the leaf plane. The stow end's post is the motor model:
              the same post with the drive cabinet behind it (-Y, MOTOR_Y), inside its own solid tile.
Posts sit POST_Y - gate PLANE_Y nearer the tile centre than the two-story gates' so the leaf passes between the post
(and the reader on its face) and the door line; the reader pillar model is the gates' look A one (every slide post is
POST_HW wide, the wooden look's too), shifted by the same amount. The reader hangs on the post the leaf closes
against, the one without the cabinet (Lua ReaderPost.lua).

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

# Looks in tileset / build-menu order (append only once shipped; tileset numbers: scripts/build_model_gates.py NUMBERS).
# A-D wear the two-story gates' paint, F = safety-yellow truss with a hazard kick strip, G = dark chain-link under
# concertina wire, ABlack = look A's models with the gates' black skin atlas and one can of black paint in the recipe.
LOOKS = ("A", "B", "C", "D", "F", "G", "ABlack")
PAINT = {"ABlack": ("A", "Black")}     # painted look -> (geometry look, vanilla paint)
CUTOUT = "AFG"                         # geometry looks with chain-link: binary alpha (glTF alphaMode MASK)
SEE_THROUGH = "ACFG"                   # geometry looks whose closed lanes pass sight (doorTrans)
STORIES = (1, 2)
GROUPS = {"34": (3, 4), "6": (6,)}     # widths of one tileset: 2 widths x 4 faces = the 512-tile limit
VARIANTS = tuple((look, story, group) for story in STORIES for group in GROUPS for look in LOOKS)
SIDES = "LR"
FACES = G.FACES
TOP = {1: 2.15, 2: 4.45}               # leaf top by story
HEALTH = {1: {3: 1000, 4: 1000, 6: 1500}, 2: {3: 1500, 4: 1500, 6: 2000}}   # by size, two-story + 500 (2026-10-08)
POST_Y = 0.105
POST_HW = 0.17                         # every look: one reader mount (the two-story wooden gate's posts are 0.20)
MOTOR_Y = (-0.47, -0.10)               # drive cabinet body behind the post; its cap overhangs 0.02
LEAF_Y = 0.41
LEAF_X0, LEAF_X1 = 0.10, 0.90
Z0 = 0.10                              # leaf bottom: the wheel carriages run under it
# total leaf thickness (everything proud of the centre plane included): it has to pass between the reader on the post
# face and the outer guide roller, which stays inside the tile (verify_slide.py)
LEAF_T = {"A": 0.08, "B": 0.10, "C": 0.08, "D": 0.12, "F": 0.112, "G": 0.10}
STOW = 25                              # first stow slot (build_model_gates.py STOW, Lua KP.GATE_SLOT.STOW)
# The open leaf lies in the stow section, L + 1 tiles from the lane that hosts the model, and the engine draws a model
# only while its host's square is on screen: one stow tile keeps an invisible object (slot STOW_HOST) that draws the
# open leaf at rest (spriteModels-only slot STOW_HOST + 8, client BarrierAnim.lua)
STOW_HOST = 6
OPP = {"N": "S", "S": "N", "W": "E", "E": "W"}
# model +X and +Y in PZ tile coordinates (x east, y south) under the face's rotation (../gate/spec.py ROTATE)
AXES = {"N": ((1, 0), (0, -1)), "W": ((0, -1), (-1, 0)), "S": ((-1, 0), (0, 1)), "E": ((0, 1), (1, 0))}


def travel(L):
    """Open: the leaf's lane-side end stops at x = 0.45, inside the stow end's tile, and its far end at -L - 0.35."""
    return L + 0.45


def geometry(look):
    return PAINT[look][0] if look in PAINT else look


def stow_at_a(face, side):
    """The leaf stows past end A (Lua KP.stowAtA): the motor post is end A, the reader hangs on end B."""
    return (face in "NW") == (side == "L")


def leaf_model(look, story, L):
    return f"MinidoracatKnoxPass_slide{story}_{geometry(look)}{L}"


def post_model(look, story, motor=False):
    return f"MinidoracatKnoxPass_slide{'motor' if motor else 'post'}{story}_{geometry(look)}"


def texture(look):
    return f"MinidoracatKnoxPass_slide_{look}"


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
    return (a, b) if stow_at_a(face, side) else (b, a)


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


def stow_host(L):
    """Stow tile k (1 = next to the stow end) under the open leaf's centre (Lua KP.stowHost)."""
    return L // 2


def stow_translate(face, L, side):
    """spriteModels translate of the open leaf on the stow host tile."""
    (hx, hy), (ox, oy) = stow_tiles(face, L, side)[stow_host(L) - 1], leaf_origin(face, L, side)
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
    assert [stow_host(L) for L in (3, 4, 6)] == [1, 2, 3] and stow_translate("N", 6, "L") == (3, 0, 0)
    # open leaf centre (model x) within half a tile of the stow host tile's centre
    assert all(abs((LEAF_X0 + L + LEAF_X1) / 2 - travel(L) + stow_host(L)) <= 0.5 for L in (3, 4, 6))
    assert max(len(w) for w in GROUPS.values()) * 4 * 64 <= 512 and STOW + 6 <= 32
    assert set(LEAF_T) == {geometry(lk) for lk in LOOKS} and len(VARIANTS) == len(LOOKS) * 4
    assert all(LEAF_Y + t / 2 <= 0.48 and LEAF_Y - t / 2 >= POST_Y + POST_HW + 0.06 for t in LEAF_T.values())
    print("spec ok")
