"""Vanilla paint cans behind the painted Knox Pass door colours (two-story chain-link gate skins, two-story roll doors).

PAINT = paint name -> swatch colour (sRGB 0..1) of the vanilla paint menu, media/lua/shared/BuildingObjects/
ISPaintMenu.lua:3-19 (the same values tint painted chairs / crates / doors, server/BuildingObjects/PaintingReference.lua
OtherPainting). The can is the item Base.Paint<name> (media/scripts/generated/items/drainable.txt, UseDelta 0.1 = 10
uses); a painted door's recipe takes one full can (scripts/build_model_gates.py PAINT_USES).

    import sys; sys.path.insert(0, str(<repo>/scripts/blender)); from paint import PAINT, rgb
"""
PAINT = {
    "Black": (0.20, 0.20, 0.20), "Grey": (0.50, 0.50, 0.50), "White": (0.92, 0.92, 0.92),
    "Red": (0.63, 0.10, 0.10), "Orange": (0.79, 0.44, 0.19), "Yellow": (0.84, 0.78, 0.30),
    "Brown": (0.45, 0.23, 0.11), "LightBrown": (0.59, 0.44, 0.21), "Pink": (0.81, 0.60, 0.60),
    "Purple": (0.61, 0.40, 0.63), "Blue": (0.35, 0.35, 0.80), "LightBlue": (0.55, 0.55, 0.87),
    "Cyan": (0.50, 0.80, 0.80), "Turquoise": (0.49, 0.70, 0.80), "Green": (0.41, 0.80, 0.41),
}


def rgb(name: str, k: float = 1.0) -> tuple[int, int, int]:
    """Swatch colour as sRGB 0..255 times k (part shading), clamped."""
    return tuple(max(0, min(255, round(c * 255 * k))) for c in PAINT[name])
