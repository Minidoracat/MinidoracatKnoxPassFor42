# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow"]
# ///
"""Knox Pass 自製模型：7 色貼圖 → Blender 建模匯出 FBX＋每色圖示原圖 → 32x32 物品圖示＋預覽總表。

用法（repo 根目錄）：
    uv run scripts/blender/build.py [--blender "C:/Program Files/Blender Foundation/Blender 5.2/blender.exe"]
    uv run scripts/gen_colors.py             # 之後再跑：色表 → 物品／模型腳本（build_barrier_tiles.py 管門柱 tile）

產物直接寫進 MOD 的 media/（<suffix> 見 COLORS：米白空字串，其他 _<id>）：
    models_X/WorldItems/MinidoracatKnoxPassTag.fbx、MinidoracatKnoxPassReader.fbx（網格共用，只建一次）
    models_X/vehicles/MinidoracatKnoxPassTagDock.fbx
    textures/WorldItems/MinidoracatKnoxPassTag<suffix>.png、MinidoracatKnoxPassReader<suffix>.png
    textures/Item_MinidoracatKnoxPassTag<suffix>.png、Item_MinidoracatKnoxPassReader<suffix>.png
預覽總表（不進 MOD、不進版控）：scripts/blender/previews/colors.png，每列一色，用剛寫進 MOD 的貼圖與圖示畫。
字型：Barlow（OFL 1.1，github.com/jpt/barlow）、IBM Plex Mono（OFL 1.1，github.com/IBM/plex），
授權全文在 fonts/。字只烘進貼圖，字型檔本身不進 MOD。
"""
import argparse
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MEDIA = os.path.join(REPO, "MOD", "MinidoracatKnoxPassFor42", "Contents", "mods", "MinidoracatKnoxPassFor42", "42", "media")
PREVIEWS = os.path.join(HERE, "previews")
FONT_BOLD = os.path.join(HERE, "fonts", "Barlow-SemiBold.ttf")
FONT_MED = os.path.join(HERE, "fonts", "Barlow-Medium.ttf")
FONT_MONO = os.path.join(HERE, "fonts", "IBMPlexMono-SemiBold.ttf")

# 外殼色表（使用者在 temp/color-preview 看過選定；索引＝Lua KP.COLORS、門柱 tile 的色號）。
# 欄位：id, 外殼, 外殼邊／側面, 字（KP 徽標底＋KNOX PASS）, 徽標字, 讀頭色條, 色條字（＝預覽稿 PALETTES）。
COLORS = [
    ("Cream", "#ebe5d6", "#cfc8b6", "#1d2b4a", "#f7f7f2", "#1d2b4a", "#f7f7f2"),
    ("Black", "#25262a", "#17181a", "#e8e4da", "#25262a", "#e8a33d", "#17181a"),
    ("Graphite", "#5b5f65", "#46494e", "#f2efe8", "#5b5f65", "#1d2b4a", "#f7f7f2"),
    ("Olive", "#59603a", "#454b2c", "#ece8d8", "#59603a", "#1d2b4a", "#f7f7f2"),
    ("Navy", "#22345a", "#182641", "#f2efe8", "#22345a", "#e8a33d", "#17181a"),
    ("Orange", "#e0692e", "#c45a26", "#1d2b4a", "#f7f7f2", "#1d2b4a", "#f7f7f2"),
    ("Red", "#a7332e", "#862823", "#f2efe8", "#a7332e", "#1d2b4a", "#f7f7f2"),
]
# 預覽稿把電池蓋換成邊色、天線罩換成外殼色；米白沿用已出貨的值，出貨的米白貼圖才逐位元不變
CREAM_SHIPPED = {"cover": "#d2ccbd", "radome": "#dedbd2", "radome_side": "#c9c5ba"}


def suffix(cid):
    return "" if cid == "Cream" else "_" + cid


def palette(color):
    cid, shell, edge, txt, logo, stripe, stripe_txt = color
    p = {"shell": shell, "edge": edge, "txt": txt, "logo": logo, "stripe": stripe, "stripe_txt": stripe_txt,
         "cover": edge, "radome": shell, "radome_side": edge}
    if cid == "Cream":
        p.update(CREAM_SHIPPED)
    return p


# 不隨顏色變的部分（沿用設計稿 concepts.py）
LABEL, INK = "#f7f6f1", "#121212"
DOCK, PAD, GOLD, WIRE = "#2b2d30", "#8a8f96", "#d4a73c", "#151515"
STEEL, JBOX = "#4b4f55", "#8f949b"

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


def tag_texture(path, p):
    W = TAG_TEX * SS
    im = Image.new("RGB", (W, W), p["shell"])
    d = ImageDraw.Draw(im)
    # 正面：86x54 mm
    x0, y0, x1, y1 = (v * SS for v in TAG_FRONT)
    mm = (x1 - x0) / 86.0
    def P(x, y):  # mm（左上原點）→ 像素
        return (x0 + x * mm, y0 + y * mm)
    d.rectangle([x0, y0, x1, y1], fill=p["shell"])
    d.rectangle([P(5, 6.5), P(19, 20.5)], fill=p["txt"])                   # KP 徽標
    text(d, P(12, 13.6), "KP", font(FONT_BOLD, 8.4 * mm), p["logo"], "mm")
    text(d, P(21.5, 11.4), "KNOX PASS", font(FONT_BOLD, 9.4 * mm), p["txt"])
    text(d, P(21.8, 18.2), "KNOX COUNTY \u00b7 KENTUCKY", font(FONT_MED, 3.1 * mm), p["txt"])
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
    d.rectangle([x0, y0, x1, y1], fill=p["shell"])
    d.rectangle([P(18, 18), P(68, 48)], fill=p["cover"], outline=p["edge"], width=int(mm * 0.5))
    d.ellipse([P(40.8, 9.3), P(45.2, 13.7)], fill="#b8bcc2")
    text(d, P(43, 26), "BATTERY  NiCd 3.6V", font(FONT_BOLD, 3.6 * mm), "#3a3a3a", "mm")
    text(d, P(43, 33), "RECHARGES FROM VEHICLE", font(FONT_MED, 2.7 * mm), "#3a3a3a", "mm")
    text(d, P(43, 42), "KNOX PASS AUTHORITY \u00b7 1993", font(FONT_MED, 2.7 * mm), "#3a3a3a", "mm")
    # 單色色塊
    for name, sx in TAG_SW.items():
        col = {"shell": p["shell"], "edge": p["edge"], "dock": DOCK, "pad": PAD, "gold": GOLD, "wire": WIRE}[name]
        d.rectangle([sx * SS, 330 * SS, (sx + 32) * SS - 1, 362 * SS - 1], fill=col)
    im.resize((TAG_TEX, TAG_TEX), Image.LANCZOS).save(path)


def reader_texture(path, p):
    W = READER_TEX * SS
    im = Image.new("RGB", (W, W), p["radome"])
    d = ImageDraw.Draw(im)
    x0, y0, x1, y1 = (v * SS for v in READER_FACE)
    mm = (x1 - x0) / 250.0
    def P(x, y):
        return (x0 + x * mm, y0 + y * mm)
    d.rectangle([x0, y0, x1, y1], fill=p["radome"])
    d.rectangle([P(4, 4), P(246, 246)], outline="#d0ccc2", width=int(3 * mm))  # 天線罩邊緣的淺溝
    d.rectangle([P(15, 194.5), P(235, 239.5)], fill=p["stripe"])
    text(d, P(125, 217.5), "KNOX PASS", font(FONT_BOLD, 34 * mm), p["stripe_txt"], "mm")
    x0, y0, x1, y1 = (v * SS for v in READER_JLBL)
    d.rectangle([x0, y0, x1, y1], fill=JBOX)
    d.rectangle([x0 + 18 * SS, y0 + 22 * SS, x1 - 18 * SS, y1 - 22 * SS], fill=LABEL)
    text(d, ((x0 + x1) / 2, y0 + 40 * SS), "KNOX PASS", font(FONT_BOLD, 17 * SS), p["stripe"], "mm")
    text(d, ((x0 + x1) / 2, y0 + 60 * SS), "READER  24V DC", font(FONT_MED, 11 * SS), INK, "mm")
    for name, sx in READER_SW.items():
        col = {"radome": p["radome"], "side": p["radome_side"], "steel": STEEL, "jbox": JBOX, "cable": "#2e3136"}[name]
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


def preview_sheet(renders):
    """7 色 × 物品欄圖示（出貨的 32px，放大 3 倍）／地上／車上 Dock／門柱讀頭（2x 遊戲投影）。"""
    big, small = ImageFont.truetype(r"C:\Windows\Fonts\msjhbd.ttc", 24), ImageFont.truetype(r"C:\Windows\Fonts\msjh.ttc", 17)
    cols = ["物品欄圖示（32px ×3）", "地上（遊戲角度，放大）", "車上 Dock", "門柱讀頭（遊戲 2x，×2）"]
    cw, rh, lw = 240, 230, 130
    sheet = Image.new("RGB", (lw + cw * len(cols), 44 + rh * len(COLORS)), (38, 40, 44))
    d = ImageDraw.Draw(sheet)
    for i, t in enumerate(cols):
        d.text((lw + cw * i + cw // 2, 22), t, font=small, fill=(220, 220, 220), anchor="mm")

    def fit(path, box, scale=None):
        im = Image.open(path).convert("RGBA")
        im = im.crop(im.getbbox())
        if scale:
            return im.resize((im.width * scale, im.height * scale), Image.NEAREST)
        im.thumbnail(box, Image.LANCZOS)
        return im

    for row, c in enumerate(COLORS):
        s, y = suffix(c[0]), 44 + rh * row
        d.text((14, y + rh // 2 - 12), c[0], font=big, fill=(240, 240, 240), anchor="lm")
        d.text((14, y + rh // 2 + 16), c[1], font=small, fill=(170, 170, 170), anchor="lm")
        cells = [[fit(os.path.join(MEDIA, "textures", f"Item_MinidoracatKnoxPass{n}{s}.png"), None, 3) for n in ("Tag", "Reader")],
                 [fit(os.path.join(renders, f"ground_{k}{s}.png"), (105, 200)) for k in ("tag", "reader")],
                 [fit(os.path.join(renders, f"preview_dock{s}.png"), (220, 210))],
                 [fit(os.path.join(renders, f"post{s}", "reader_0.png"), None, 2)]]
        for i, ims in enumerate(cells):
            tile = Image.new("RGB", (cw - 10, rh - 10), (96, 100, 96))   # 柏油灰，深色外殼也看得清
            gap = (tile.width - sum(im.width for im in ims)) // (len(ims) + 1)
            x = gap
            for im in ims:
                tile.paste(im, (x, (tile.height - im.height) // 2), im)
                x += im.width + gap
            sheet.paste(tile, (lw + cw * i + 5, y + 5))
    path = os.path.join(PREVIEWS, "colors.png")
    sheet.save(path)
    print("preview ->", path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--blender", default=r"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe")
    a = ap.parse_args()
    tex_dir = os.path.join(MEDIA, "textures", "WorldItems")
    os.makedirs(tex_dir, exist_ok=True)
    for sub in ("WorldItems", "vehicles"):
        os.makedirs(os.path.join(MEDIA, "models_X", sub), exist_ok=True)
    sfx = [suffix(c[0]) for c in COLORS]
    for c, s in zip(COLORS, sfx):
        tag_texture(os.path.join(tex_dir, f"MinidoracatKnoxPassTag{s}.png"), palette(c))
        reader_texture(os.path.join(tex_dir, f"MinidoracatKnoxPassReader{s}.png"), palette(c))
    renders = os.path.join(PREVIEWS, "renders")   # Blender 渲染原圖留著備查（gitignored）
    os.makedirs(renders, exist_ok=True)
    cmd = [a.blender, "--background", "--factory-startup", "--python", os.path.join(HERE, "build_models.py"),
           "--", MEDIA, renders, *sfx]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0 or "BUILD OK" not in r.stdout:
        sys.stdout.write(r.stdout[-4000:] + r.stderr[-4000:])
        sys.exit("blender build failed")
    for s in sfx:
        for kind, name in (("tag", "Tag"), ("reader", "Reader")):
            icon(os.path.join(renders, f"icon_{kind}{s}.png"), os.path.join(MEDIA, "textures", f"Item_MinidoracatKnoxPass{name}{s}.png"))
    preview_sheet(renders)
    print("build ok ->", MEDIA)


if __name__ == "__main__":
    main()
