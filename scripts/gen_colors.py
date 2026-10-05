# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow"]
# ///
"""外殼顏色：由 scripts/blender/build.py 的 COLORS（同一份色表）產生物品與模型腳本。

用法（repo 根目錄，先跑過 build.py 產生各色貼圖與圖示）：
    uv run scripts/gen_colors.py           # 重寫 items_knoxpass_colors.txt、models_knoxpass_colors.txt；重跑結果一致
    uv run scripts/gen_colors.py --check   # 只比對，過期或引用斷了就失敗

各色物品照 items_knoxpass.txt 的米白 VehicleTag／GateReader 原樣複製，只換 Icon、WorldStaticModel、StaticModel
的模型名；各色模型照 models_knoxpass.txt 的米白模型，只換 texture（網格共用）。
物品名稱的翻譯鍵就是完整 type（MinidoracatKnoxPass.VehicleTag_Black），不寫 DisplayName。
門柱讀頭 tile 的各色格子由 scripts/build_barrier_tiles.py 產生（同一份色表）。
--check 也核對 7 色的每個引用都接得上：圖示、模型腳本、網格、貼圖檔都在；物品腳本沒有 VehiclePartModel
（零件沒有 parent 時 model 不寫 file 會讓客戶端 NPE，見 vehicle_knoxpass_parts.txt 檔頭）；
零件 template 的 Dock<後綴> model 7 色都在、file 指向存在的 KnoxPassTagDock<後綴>、setAllModelsVisible = false。
"""
import importlib.util
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("kpbuild", os.path.join(REPO, "scripts", "blender", "build.py"))
B = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(B)
MEDIA = B.MEDIA
SCRIPTS = os.path.join(MEDIA, "scripts")
ITEMS, MODELS = os.path.join(SCRIPTS, "items_knoxpass.txt"), os.path.join(SCRIPTS, "models_knoxpass.txt")
OUT_ITEMS = os.path.join(SCRIPTS, "items_knoxpass_colors.txt")
OUT_MODELS = os.path.join(SCRIPTS, "models_knoxpass_colors.txt")
PARTS = os.path.join(SCRIPTS, "vehicles", "vehicle_knoxpass_parts.txt")
HEAD = ("module MinidoracatKnoxPass\n{{\n    /*\n        由 scripts/gen_colors.py 產生，不要手改：色表在 scripts/blender/build.py COLORS，\n"
        "        {what}改了就重跑產生器。\n    */\n")


def block(src, kind, name):
    m = re.search(rf"^    {kind} {name}\n    {{\n.*?^    }}\n", src, re.M | re.S)
    assert m, f"{kind} {name} not found"
    return m.group(0)


def recolor(text, sfx):
    """header 名稱加後綴；Icon／WorldStaticModel／StaticModel／texture 的值加後綴。"""
    text = re.sub(r"^(    (?:item|model) \w+)$", rf"\g<1>{sfx}", text, count=1, flags=re.M)
    return re.sub(r"^(        (?:Icon|WorldStaticModel|StaticModel|texture) = [\w./]+),$", rf"\g<1>{sfx},", text, flags=re.M)


def generate():
    items, models = open(ITEMS, encoding="utf-8").read(), open(MODELS, encoding="utf-8").read()
    item_blocks = [block(items, "item", n) for n in ("VehicleTag", "GateReader")]
    model_blocks = [block(models, "model", n) for n in ("KnoxPassTag", "KnoxPassTagDock", "KnoxPassReader")]
    colors = [B.suffix(c[0]) for c in B.COLORS[1:]]   # 米白就是原檔裡的那幾個
    out_items = HEAD.format(what="屬性照 items_knoxpass.txt 的米白 VehicleTag／GateReader；那兩個物品")
    out_models = HEAD.format(what="照 models_knoxpass.txt 的米白模型，只換 texture；那幾個模型")
    out_items += "\n".join(recolor(b, s) for s in colors for b in item_blocks) + "}\n"
    out_models += "\n".join(recolor(b, s) for s in colors for b in model_blocks) + "}\n"
    return {OUT_ITEMS: out_items, OUT_MODELS: out_models}


def check_refs():
    """7 色的物品 → 圖示／模型腳本 → 網格／貼圖都接得上，零件 template 的 Dock model 也是；回傳問題清單。"""
    bad = []
    items = "".join(open(p, encoding="utf-8").read() for p in (ITEMS, OUT_ITEMS))
    models_src = "".join(open(p, encoding="utf-8").read() for p in (MODELS, OUT_MODELS))
    models = {m.group(1): m.group(2) for m in re.finditer(r"^    model (\w+)\n    \{\n(.*?)^    \}", models_src, re.M | re.S)}
    for src in (items, models_src):
        if src.count("{") != src.count("}"):
            bad.append("brace mismatch")
    for m in models.values():
        mesh, tex = re.search(r"mesh = ([\w/]+),", m).group(1), re.search(r"texture = ([\w/]+),", m).group(1)
        if not os.path.exists(os.path.join(MEDIA, "models_X", mesh + ".fbx")):
            bad.append(f"mesh {mesh}.fbx missing")
        if not os.path.exists(os.path.join(MEDIA, "textures", tex + ".png")):
            bad.append(f"texture {tex}.png missing")
    if re.search(r"^\s*VehiclePartModel\s*=", items, re.M):
        bad.append("item scripts must not use VehiclePartModel (part has no parent: model without file NPEs on clients)")
    part = re.sub(r"/\*.*?\*/", "", open(PARTS, encoding="utf-8").read(), flags=re.S)
    docks = dict(re.findall(r"^            model (\w+)\n            \{\n(.*?)^            \}", part, re.M | re.S))
    if "            setAllModelsVisible = false,\n" not in part:
        bad.append("template KnoxPassTag: setAllModelsVisible = false missing")
    if len(docks) != len(B.COLORS):
        bad.append(f"template KnoxPassTag: {len(docks)} models, want {len(B.COLORS)}")
    for cid, *_ in B.COLORS:
        s = B.suffix(cid)
        for item, kind, need in (("VehicleTag", "Tag", ("WorldStaticModel", "StaticModel")),
                                 ("GateReader", "Reader", ("WorldStaticModel",))):
            body = block(items, "item", item + s)
            want = {"Icon": f"MinidoracatKnoxPass{kind}{s}", **{k: f"MinidoracatKnoxPass.KnoxPass{kind}{s}" for k in need}}
            for k, v in want.items():
                if f"        {k} = {v},\n" not in body:
                    bad.append(f"{item}{s}: {k} != {v}")
            if not os.path.exists(os.path.join(MEDIA, "textures", f"Item_MinidoracatKnoxPass{kind}{s}.png")):
                bad.append(f"icon Item_MinidoracatKnoxPass{kind}{s}.png missing")
        for name in ("KnoxPassTag", "KnoxPassTagDock", "KnoxPassReader"):
            if name + s not in models:
                bad.append(f"model {name}{s} missing")
        dock = docks.get("Dock" + s)
        if dock is None or f"                file = MinidoracatKnoxPass.KnoxPassTagDock{s},\n" not in dock:
            bad.append(f"template model Dock{s}: file != MinidoracatKnoxPass.KnoxPassTagDock{s}")
    return bad


def main():
    check = "--check" in sys.argv
    stale = []
    for path, text in generate().items():
        old = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if old != text:
            stale.append(os.path.relpath(path, REPO))
            if not check:
                with open(path, "w", encoding="utf-8", newline="\n") as f:
                    f.write(text)
    if check and stale:
        sys.exit("stale (rerun scripts/gen_colors.py): " + ", ".join(stale))
    bad = check_refs()
    if bad:
        sys.exit("broken references:\n  " + "\n  ".join(bad))
    print(("OK: " if check else "wrote: ") + f"{len(B.COLORS)} colours, items/models scripts and references match"
          + ("" if check or not stale else " (" + ", ".join(stale) + ")"))


if __name__ == "__main__":
    main()
