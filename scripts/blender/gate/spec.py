"""Knox Pass two-story double-leaf gate: shared numbers (pure Python; imported by the Blender scripts and assemble.py).

Model space (Blender, 1 unit = 1 tile, one story = STORY units), shared by leaf and post models:
  leaf model origin = centre of the END tile on the model's -X side (N/W: end A, S/E: end B), on the floor;
  +X = along the gate line toward the other end (other end tile centre at x = L + 1, lanes 1..L at x = 1..L);
  +Y = toward the door line (line at y = +0.5, the tile edge the IsoDoor lanes sit on); posts stand at -Y of it,
  leaves swing toward -Y (the post side). Leaf centre plane y = PLANE_Y.
  post model origin = its own tile centre on the floor, same axes (post centred on x = 0 and y = PLANE_Y),
  symmetric about x = 0, so end A and end B use the same transform.
"""

import os

LOOKS = "ABCDE"
WIDTHS = (6, 9)
FACES = "NWSE"
TILESET = "MinidoracatKnoxPass_gate"
TILESET_NUMBER = 6
STORY = 2.44949                      # one level (render_tiles.py / skill: 192 px at 2x)
PLANE_Y = 0.36                       # leaf centre plane, 0.14 inside the door line
GAP = 0.015                          # half the gap where the two leaves meet
Z0 = 0.05                            # leaf bottom clearance
FPS = 24
# KNOXPASS_FAST=1（build_gate.py 只匯出門扇，檔名加 _fast）：每扇門可選的「加速」，clip 3.75 s → 遊戲裡 2.5 s
FAST = os.environ.get("KNOXPASS_FAST") == "1"
CLIP_S = 3.75 if FAST else 6.0
F0, F1 = 1, 1 + round(CLIP_S * FPS)  # 6.0 s clips like the barrier arm; engine speedDelta 1.5 -> ~4.0 s
OPEN_DEG = 90.0
POSE_FRAMES = 8                      # BarrierAnim stepper poses: animationTime k/8, k = 0..8

NAMES = {"A": "steel tube frame + chain-link", "B": "solid steel plate with ribs", "C": "black palisade bars",
         "D": "wooden ranch gate", "E": "medieval oak gate"}
# per look: post half width (square post), total leaf thickness including rails / bands proud of the panel (hinge_x
# uses it so the swung leaf clears the post)
LOOK = {
    "A": {"post_hw": 0.17, "t": 0.08},
    "B": {"post_hw": 0.17, "t": 0.09},
    "C": {"post_hw": 0.17, "t": 0.08},
    "D": {"post_hw": 0.20, "t": 0.15},
    "E": {"post_hw": 0.30, "t": 0.13},
}


def hinge_x(look):
    """Hinge axis x of the origin-side leaf: the leaf's hinge stile clears the post by 0.02 and, swung 90 deg, lies
    beside the post face instead of through it."""
    p = LOOK[look]
    return p["post_hw"] + p["t"] / 2 + 0.02


def leaf_model(look, w):
    return f"MinidoracatKnoxPass_gate_{look}{w}"


def post_model(look):
    return f"MinidoracatKnoxPass_gatepost_{look}"


def texture(look):
    return f"MinidoracatKnoxPass_gate_{look}"


def entity(look, w):
    return f"MinidoracatKnoxPassGate{look}{w}"


def icon(look, w):
    return f"gate_{look.lower()}_{w}.png"


def block(look, w, face):
    return (LOOKS.index(look) * 2 + WIDTHS.index(w)) * 4 + FACES.index(face)


# Entity cells in PZ coordinates relative to the entity origin (x0, y0) (contract "Entity faces"):
#   lane k placeholder (build tile), real lane door k (IsoDoor; lane 1 hosts the leaf model), end A, end B.
def placeholder(face, L, k):
    return (k, 0) if face in "NS" else (0, L + 1 - k)


def real_lane(face, L, k):
    return {"N": (k, 0), "S": (k, 1), "W": (0, L + 1 - k), "E": (1, L + 1 - k)}[face]


def end_a(face, L):
    return (0, 0) if face in "NS" else (0, L + 1)


def end_b(face, L):
    return (L + 1, 0) if face in "NS" else (0, 0)


# spriteModels rotate per face (render_tiles.py / build_barrier_tiles.py XFORM convention):
#   N (0,180,0): model +X = east,  +Y = north     W (0,-90,0): +X = north, +Y = west
#   S (0,0,0):   +X = west,  +Y = south           E (0,90,0):  +X = south, +Y = east
ROTATE = {"N": (0.0, 180.0, 0.0), "W": (0.0, -90.0, 0.0), "S": (0.0, 0.0, 0.0), "E": (0.0, 90.0, 0.0)}


def model_origin(face, L):
    """Tile the leaf model's origin lands on: the end tile on the model's -X side."""
    return end_a(face, L) if face in "NW" else end_b(face, L)


def leaf_translate(face, L):
    """spriteModels translate of the leaf model on its host (real lane 1): (dx, 0, dy) host -> model origin tile."""
    (hx, hy), (ox, oy) = real_lane(face, L, 1), model_origin(face, L)
    return (float(ox - hx), 0.0, float(oy - hy))


if __name__ == "__main__":   # self-check against the contract and the barrier's XFORM pattern
    assert [block(l, w, f) for l in LOOKS for w in WIDTHS for f in FACES] == list(range(40))
    assert leaf_translate("N", 6) == (-1, 0, 0) and leaf_translate("W", 6) == (0, 0, 1)
    assert leaf_translate("S", 6) == (6, 0, -1) and leaf_translate("E", 9) == (-1, 0, -9)
    for L in WIDTHS:
        for f in FACES:
            # placeholder k sits in the entity row/column next to the real lane k (same tile for N/W)
            px, py = placeholder(f, L, 1)
            rx, ry = real_lane(f, L, 1)
            assert (rx - px, ry - py) == {"N": (0, 0), "W": (0, 0), "S": (0, 1), "E": (1, 0)}[f]
    print("spec ok")
