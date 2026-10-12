# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow", "resvg_py"]
# ///
"""地圖手錶「Knox Pass 感應模組」的物品圖示與小地圖大門標記的圖形。

用法（repo 根目錄）：
    uv run scripts/build_module_icon.py

- textures/Item_MinidoracatKnoxPassWatchModule.png（32×32）：照地圖手錶 scripts/build_watch_art.py 的 module_svg／to_icon
  晶片版型（一般級銀框 TIER），圖形是感應卡＋波紋，用米白 CREAM（琥珀和照明模組的黃色只差 6°，背包裡容易認錯）。
- ui/MinidoracatKnoxPass/map_gate.png（32×32）：小地圖標記的柵門圖形，白色，顏色由標記的 r、g、b 染（client/MapLayer.lua）。
"""
import io
import os

import resvg_py
from PIL import Image, ImageEnhance, ImageFilter

MEDIA = os.path.join(os.path.dirname(__file__), "..", "MOD", "MinidoracatKnoxPassFor42", "Contents", "mods",
                     "MinidoracatKnoxPassFor42", "42", "media")
TIER = "#A7B0BA"   # 一般級銀框（地圖手錶 build_watch_art.py TIER_COL["std"]）
CREAM = "#F2E6C8"  # 小地圖標記同色（MapLayer.lua 的 r、g、b）
CARD = ('<rect x="3" y="7" width="11" height="10" rx="2"/><path d="M6 11h5"/>'
        '<path d="M17.5 9a4.5 4.5 0 0 1 0 6"/><path d="M20.5 6.5a8 8 0 0 1 0 11"/>')
GATE = '<path d="M-6 6V-6M6 6V-6M-6 -3H6M-6 3H6M-6 3L6 -3"/>'


def render(view, inner, px):
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}" width="{px}" height="{px}">{inner}</svg>'
    return Image.open(io.BytesIO(bytes(resvg_py.svg_to_bytes(svg_string=svg)))).convert("RGBA")


def module_icon():
    pins = "".join(f'<rect x="{11 + i * 6}" y="6" width="3.2" height="7" rx="1" fill="#D9B45A"/>' for i in range(8))
    im = render("0 0 64 64", f'<g transform="rotate(-12 32 32)">{pins}'
                f'<rect x="8" y="11" width="48" height="44" rx="5" fill="#23282E" stroke="{TIER}" stroke-width="4"/>'
                f'<g transform="translate(16 18) scale(1.33)" fill="none" stroke="{CREAM}" stroke-width="2.3" '
                f'stroke-linecap="round" stroke-linejoin="round">{CARD}</g></g>', 256)
    # 縮到 28 px、硬邊 alpha、深色描邊一圈（同 build_watch_art.py to_icon）
    im = im.crop(im.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox())
    s = 28.0 / max(im.size)
    im = im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)
    a = im.getchannel("A").point(lambda v: 255 if v > 110 else 0)
    im = ImageEnhance.Sharpness(ImageEnhance.Contrast(im.convert("RGB")).enhance(1.15)).enhance(1.3)
    im.putalpha(a)
    canvas = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    canvas.paste(im, ((32 - im.width) // 2, (32 - im.height) // 2), im)
    out = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    out.paste(Image.new("RGBA", (32, 32), (28, 26, 24, 255)), (0, 0), canvas.getchannel("A").filter(ImageFilter.MaxFilter(3)))
    out.paste(canvas, (0, 0), canvas)
    return out


def map_gate():
    return render("-9 -9 18 18", f'<g fill="none" stroke="#FFFFFF" stroke-width="2.2" stroke-linecap="round">{GATE}</g>', 32)


if __name__ == "__main__":
    for rel, im in (("textures/Item_MinidoracatKnoxPassWatchModule.png", module_icon()),
                    ("ui/MinidoracatKnoxPass/map_gate.png", map_gate())):
        im.save(os.path.join(MEDIA, rel))
        print("wrote", rel, im.size)
