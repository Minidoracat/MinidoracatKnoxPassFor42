# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow"]
# ///
"""Knox Pass 自製模型：貼圖 → Blender 建模匯出 FBX＋圖示原圖 → 32x32 物品圖示。

用法（repo 根目錄）：
    uv run scripts/blender/build.py [--blender "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe"]

產物直接寫進 MOD 的 media/：
    models_X/WorldItems/MinidoracatKnoxPassTag.fbx、MinidoracatKnoxPassReader.fbx
    models_X/vehicles/MinidoracatKnoxPassTagDock.fbx
    textures/WorldItems/MinidoracatKnoxPassTag.png、MinidoracatKnoxPassReader.png
    textures/Item_MinidoracatKnoxPassTag.png、Item_MinidoracatKnoxPassReader.png
字型：Barlow（OFL 1.1，github.com/jpt/barlow）、IBM Plex Mono（OFL 1.1，github.com/IBM/plex），
授權全文在 fonts/。字只烘進貼圖，字型檔本身不進 MOD。
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MEDIA = os.path.join(REPO, "MOD", "MinidoracatKnoxPassFor42", "Contents", "mods", "MinidoracatKnoxPassFor42", "42", "media")
FONT_BOLD = os.path.join(HERE, "fonts", "Barlow-SemiBold.ttf")
FONT_MED = os.path.join(HERE, "fonts", "Barlow-Medium.ttf")
FONT_MONO = os.path.join(HERE, "fonts", "IBMPlexMono-SemiBold.ttf")

# 顏色沿用設計稿 concepts.py
SHELL, SHELL_EDGE, NAVY, LABEL, INK, WTXT = "#ebe5d6", "#cfc8b6", "#1d2b4a", "#f7f6f1", "#121212", "#f7f7f2"
DOCK, PAD, GOLD, WIRE, COVER = "#2b2d30", "#8a8f96", "#d4a73c", "#151515", "#d2ccbd"
RADOME, RADOME_SIDE, STEEL, JBOX = "#dedbd2", "#c9c5ba", "#4b4f55", "#8f949b"

# 貼圖格局（像素，左上原點）；build_models.py 的 UV 用同一份數字
TAG_TEX = 512
TAG_FRONT = (0, 0, 512, 322)      # 86x54 mm 正面
TAG_BACK = (0, 330, 256, 491)     # 背面
TAG_SW = {"shell": 272, "edge": 312, "dock": 352, "pad": 392, "gold": 432, "wire": 472}  # x，y=330，32x32
READER_TEX = 512
READER_FACE = (0, 0, 320, 320)    # 250x250 mm 天線罩正面
READER_JLBL = (336, 0, 496, 100)  # 接線盒正面小標籤
READER_SW = {"radome": 0, "side": 48, "steel": 96, "jbox": 144, "cable": 192}  # x，y=336，40x40

SS = 4  # 超取樣倍率：畫大再縮，字邊緣平滑


def font(path, px):
    return ImageFont.truetype(path, max(1, int(round(px))))


def text(d, xy, s, f, fill, anchor="lm"):
    d.text(xy, s, font=f, fill=fill, anchor=anchor)


def tag_texture(path):
    W = TAG_TEX * SS
    im = Image.new("RGB", (W, W), SHELL)
    d = ImageDraw.Draw(im)
    # 正面：86x54 mm
    x0, y0, x1, y1 = (v * SS for v in TAG_FRONT)
    mm = (x1 - x0) / 86.0
    def P(x, y):  # mm（左上原點）→ 像素
        return (x0 + x * mm, y0 + y * mm)
    d.rectangle([x0, y0, x1, y1], fill=SHELL)
    d.rectangle([P(5, 6.5), P(19, 20.5)], fill=NAVY)                       # KP 徽標
    text(d, P(12, 13.6), "KP", font(FONT_BOLD, 8.4 * mm), WTXT, "mm")
    text(d, P(21.5, 11.4), "KNOX PASS", font(FONT_BOLD, 9.4 * mm), NAVY)
    text(d, P(21.8, 18.2), "KNOX COUNTY \u00b7 KENTUCKY", font(FONT_MED, 3.1 * mm), NAVY)
    d.rectangle([P(5, 31), P(81, 50)], fill=LABEL)                          # 條碼序號貼紙
    x, i = 8.0, 0
    while x < 39:
        w = (0.6, 1.1, 1.6)[(i * 7) % 3]
        d.rectangle([P(x, 35), P(x + w, 46)], fill=INK)
        x += w + (0.7, 1.2)[(i * 5) % 2]
        i += 1
    text(d, P(61, 37.6), "KP 4721-08", font(FONT_MONO, 4.6 * mm), INK, "mm")
    text(d, P(61, 44.6), "PROPERTY OF KNOX PASS", font(FONT_MED, 2.3 * mm), INK, "mm")
    # 背面：電池蓋與說明
    x0, y0, x1, y1 = (v * SS for v in TAG_BACK)
    mm = (x1 - x0) / 86.0
    d.rectangle([x0, y0, x1, y1], fill=SHELL)
    d.rectangle([P(18, 18), P(68, 48)], fill=COVER, outline=SHELL_EDGE, width=int(mm * 0.5))
    d.ellipse([P(40.8, 9.3), P(45.2, 13.7)], fill="#b8bcc2")
    text(d, P(43, 26), "BATTERY  NiCd 3.6V", font(FONT_BOLD, 3.6 * mm), "#3a3a3a", "mm")
    text(d, P(43, 33), "RECHARGES FROM VEHICLE", font(FONT_MED, 2.7 * mm), "#3a3a3a", "mm")
    text(d, P(43, 42), "KNOX PASS AUTHORITY \u00b7 1993", font(FONT_MED, 2.7 * mm), "#3a3a3a", "mm")
    # 單色色塊
    for name, sx in TAG_SW.items():
        col = {"shell": SHELL, "edge": SHELL_EDGE, "dock": DOCK, "pad": PAD, "gold": GOLD, "wire": WIRE}[name]
        d.rectangle([sx * SS, 330 * SS, (sx + 32) * SS - 1, 362 * SS - 1], fill=col)
    im.resize((TAG_TEX, TAG_TEX), Image.LANCZOS).save(path)


def reader_texture(path):
    W = READER_TEX * SS
    im = Image.new("RGB", (W, W), RADOME)
    d = ImageDraw.Draw(im)
    x0, y0, x1, y1 = (v * SS for v in READER_FACE)
    mm = (x1 - x0) / 250.0
    def P(x, y):
        return (x0 + x * mm, y0 + y * mm)
    d.rectangle([x0, y0, x1, y1], fill=RADOME)
    d.rectangle([P(4, 4), P(246, 246)], outline="#d0ccc2", width=int(3 * mm))  # 天線罩邊緣的淺溝
    d.rectangle([P(15, 194.5), P(235, 239.5)], fill=NAVY)
    text(d, P(125, 217.5), "KNOX PASS", font(FONT_BOLD, 34 * mm), WTXT, "mm")
    x0, y0, x1, y1 = (v * SS for v in READER_JLBL)
    d.rectangle([x0, y0, x1, y1], fill=JBOX)
    d.rectangle([x0 + 18 * SS, y0 + 22 * SS, x1 - 18 * SS, y1 - 22 * SS], fill=LABEL)
    text(d, ((x0 + x1) / 2, y0 + 40 * SS), "KNOX PASS", font(FONT_BOLD, 17 * SS), NAVY, "mm")
    text(d, ((x0 + x1) / 2, y0 + 60 * SS), "READER  24V DC", font(FONT_MED, 11 * SS), INK, "mm")
    for name, sx in READER_SW.items():
        col = {"radome": RADOME, "side": RADOME_SIDE, "steel": STEEL, "jbox": JBOX, "cable": "#2e3136"}[name]
        d.rectangle([sx * SS, 336 * SS, (sx + 40) * SS - 1, 376 * SS - 1], fill=col)
    im.resize((READER_TEX, READER_TEX), Image.LANCZOS).save(path)


def icon(src, dst):
    """原版物品圖示風格：32x32 透明底、物體約 28px、1px 深色外框（對照 UI2.pack 的 Item_Pager／Item_CreditCard）。"""
    im = Image.open(src).convert("RGBA")
    bbox = im.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox()
    im = im.crop(bbox)
    s = 28.0 / max(im.size)
    im = im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)
    a = im.getchannel("A").point(lambda v: 255 if v > 110 else 0)
    # 原版圖示對比與飽和度都比較重（工作台渲染偏灰），縮完再拉一次
    im = ImageEnhance.Sharpness(ImageEnhance.Color(ImageEnhance.Contrast(im.convert("RGB")).enhance(1.35)).enhance(1.3)).enhance(1.4)
    im.putalpha(a)
    canvas = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    canvas.paste(im, ((32 - im.width) // 2, (32 - im.height) // 2), im)
    mask = canvas.getchannel("A")
    ring = mask.filter(ImageFilter.MaxFilter(3))
    outline = Image.new("RGBA", (32, 32), (28, 26, 24, 255))
    out = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    out.paste(outline, (0, 0), ring)
    out.paste(canvas, (0, 0), mask)
    out.save(dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--blender", default=r"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe")
    ap.add_argument("--keep", help="把 Blender 渲染原圖（圖示原圖、車上預覽）複製到這個目錄")
    a = ap.parse_args()
    tex_dir = os.path.join(MEDIA, "textures", "WorldItems")
    os.makedirs(tex_dir, exist_ok=True)
    for sub in ("WorldItems", "vehicles"):
        os.makedirs(os.path.join(MEDIA, "models_X", sub), exist_ok=True)
    tag_png = os.path.join(tex_dir, "MinidoracatKnoxPassTag.png")
    reader_png = os.path.join(tex_dir, "MinidoracatKnoxPassReader.png")
    tag_texture(tag_png)
    reader_texture(reader_png)
    with tempfile.TemporaryDirectory() as tmp:
        cmd = [a.blender, "--background", "--factory-startup", "--python", os.path.join(HERE, "build_models.py"),
               "--", MEDIA, tmp]
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
        if r.returncode != 0 or "BUILD OK" not in r.stdout:
            sys.stdout.write(r.stdout[-4000:] + r.stderr[-4000:])
            sys.exit("blender build failed")
        icon(os.path.join(tmp, "icon_tag.png"), os.path.join(MEDIA, "textures", "Item_MinidoracatKnoxPassTag.png"))
        icon(os.path.join(tmp, "icon_reader.png"), os.path.join(MEDIA, "textures", "Item_MinidoracatKnoxPassReader.png"))
        if a.keep:
            os.makedirs(a.keep, exist_ok=True)
            for f in os.listdir(tmp):
                shutil.copy(os.path.join(tmp, f), a.keep)
    print("build ok ->", MEDIA)


if __name__ == "__main__":
    main()
