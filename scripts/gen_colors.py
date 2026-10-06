# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow"]
# ///
"""外殼顏色：由 scripts/blender/build.py 的 COLORS（同一份色表）產生物品、模型與配方腳本，以及配方名稱翻譯。

用法（repo 根目錄，先跑過 build.py 產生各色貼圖與圖示）：
    uv run scripts/gen_colors.py           # 重寫 items／models／recipes_knoxpass_colors.txt 與各語系 Recipes.json；重跑結果一致
    uv run scripts/gen_colors.py --check   # 只比對，過期或引用斷了就失敗

各色物品照 items_knoxpass.txt 的米白 VehicleTag／GateReader 原樣複製，只換 Icon、WorldStaticModel、StaticModel
的模型名；各色模型照 models_knoxpass.txt 的米白模型，只換 texture（網格共用）。
物品名稱的翻譯鍵就是完整 type（MinidoracatKnoxPass.VehicleTag_Black），不寫 DisplayName。
各色配方照 recipes_knoxpass.txt 的米白 CraftKnoxPassVehicleTag／CraftKnoxPassGateReader，輸入多一格該色油漆
（Core.lua KP.COLORS 的 paint，和換色用的同一罐）與不消耗的油漆刷，產物換成該色。配方名稱沒有翻譯會直接顯示 key
（Translator.java:691-701），所以各語系 Recipes.json 的該色配方名稱一併產生：米白配方名稱裡的米白物品名換成該色物品名。
門柱讀頭 tile 的各色格子由 scripts/build_barrier_tiles.py 產生（同一份色表）。
--check 也核對 7 色的每個引用都接得上：圖示、模型腳本、網格、貼圖檔都在；物品腳本沒有 VehiclePartModel
（零件沒有 parent 時 model 不寫 file 會讓客戶端 NPE，見 vehicle_knoxpass_parts.txt 檔頭）；
零件 template 的 Dock<後綴> model 7 色都在、file 指向存在的 KnoxPassTagDock<後綴>、setAllModelsVisible = false；
Core.lua 的 KP.COLORS 和 build.py COLORS 的顏色與順序一致。
"""
import importlib.util
import json
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
RECIPES, OUT_RECIPES = os.path.join(SCRIPTS, "recipes_knoxpass.txt"), os.path.join(SCRIPTS, "recipes_knoxpass_colors.txt")
CORE = os.path.join(MEDIA, "lua", "shared", "MinidoracatKnoxPass", "Core.lua")
TRANSLATE = os.path.join(MEDIA, "lua", "shared", "Translate")
CRAFTS = {"CraftKnoxPassVehicleTag": "VehicleTag", "CraftKnoxPassGateReader": "GateReader"}   # 米白配方 → 產物
HEAD = ("module {module}\n{{\n    /*\n        由 scripts/gen_colors.py 產生，不要手改：色表在 scripts/blender/build.py COLORS，\n"
        "        {what}改了就重跑產生器。\n    */\n")


def block(src, kind, name):
    m = re.search(rf"^    {kind} {name}\n    {{\n.*?^    }}\n", src, re.M | re.S)
    assert m, f"{kind} {name} not found"
    return m.group(0)


def recolor(text, sfx):
    """header 名稱加後綴；Icon／WorldStaticModel／StaticModel／texture 的值加後綴。"""
    text = re.sub(r"^(    (?:item|model) \w+)$", rf"\g<1>{sfx}", text, count=1, flags=re.M)
    return re.sub(r"^(        (?:Icon|WorldStaticModel|StaticModel|texture) = [\w./]+),$", rf"\g<1>{sfx},", text, flags=re.M)


def paints():
    """Core.lua 的 KP.COLORS：顏色 id → 原版油漆 type。顏色與順序必須和 build.py COLORS 一致（帳本存的是索引）。"""
    rows = re.findall(r'\{ id = "(\w+)", suffix = "(\w*)", paint = "([\w.]+)" \}', open(CORE, encoding="utf-8").read())
    want = [(c[0], B.suffix(c[0])) for c in B.COLORS]
    assert [r[:2] for r in rows] == want, f"Core.lua KP.COLORS {[r[:2] for r in rows]} != build.py COLORS {want}"
    return {cid: paint for cid, _, paint in rows}


def paint_recipe(text, sfx, paint):
    """米白配方 → 該色：名稱與產物加後綴，輸入多一格該色油漆（drainable 的數量是格數，原版 paint_sign.txt 同寫法）
    與油漆刷（不消耗）。"""
    text = re.sub(r"^(    craftRecipe \w+)$", rf"\g<1>{sfx}", text, count=1, flags=re.M)
    inputs, outputs = text.split("        outputs\n", 1)
    assert inputs.endswith("        }\n"), "inputs block not closed right before outputs"
    inputs = inputs[:-len("        }\n")] + f"            item 1 tags[base:paintbrush] mode:keep,\n            item 1 [{paint}],\n        }}\n"
    outputs = re.sub(r"^(            item 1 MinidoracatKnoxPass\.\w+),$", rf"\g<1>{sfx},", outputs, count=1, flags=re.M)
    return inputs + "        outputs\n" + outputs


def recipe_names():
    """各語系 Recipes.json：手寫的配方照原順序，每個米白配方後面接 6 色（名稱裡的米白物品名換成該色物品名）。"""
    gen = {r + B.suffix(c[0]) for r in CRAFTS for c in B.COLORS[1:]}
    out = {}
    for lang in sorted(os.listdir(TRANSLATE)):
        path = os.path.join(TRANSLATE, lang, "Recipes.json")
        names = json.load(open(os.path.join(TRANSLATE, lang, "ItemName.json"), encoding="utf-8"))
        merged = {}
        for key, value in json.load(open(path, encoding="utf-8")).items():
            if key in gen:
                continue
            merged[key] = value
            if key in CRAFTS:
                base = names[f"MinidoracatKnoxPass.{CRAFTS[key]}"]
                assert base in value, f"{lang}/Recipes.json {key}: '{value}' does not contain the item name '{base}'"
                for cid, *_ in B.COLORS[1:]:
                    s = B.suffix(cid)
                    merged[key + s] = value.replace(base, names[f"MinidoracatKnoxPass.{CRAFTS[key]}{s}"])
        out[path] = json.dumps(merged, ensure_ascii=False, indent=4) + "\n"
    return out


def generate():
    items, models = open(ITEMS, encoding="utf-8").read(), open(MODELS, encoding="utf-8").read()
    recipes, paint = open(RECIPES, encoding="utf-8").read(), paints()
    item_blocks = [block(items, "item", n) for n in ("VehicleTag", "GateReader")]
    model_blocks = [block(models, "model", n) for n in ("KnoxPassTag", "KnoxPassTagDock", "KnoxPassReader")]
    recipe_blocks = [block(recipes, "craftRecipe", n) for n in CRAFTS]
    colors = [B.suffix(c[0]) for c in B.COLORS[1:]]   # 米白就是原檔裡的那幾個
    out_items = HEAD.format(module="MinidoracatKnoxPass", what="屬性照 items_knoxpass.txt 的米白 VehicleTag／GateReader；那兩個物品")
    out_models = HEAD.format(module="MinidoracatKnoxPass", what="照 models_knoxpass.txt 的米白模型，只換 texture；那幾個模型")
    out_recipes = HEAD.format(module="Base", what="照 recipes_knoxpass.txt 的米白配方，多一格該色油漆與油漆刷；那兩個配方")
    out_items += "\n".join(recolor(b, s) for s in colors for b in item_blocks) + "}\n"
    out_models += "\n".join(recolor(b, s) for s in colors for b in model_blocks) + "}\n"
    out_recipes += "\n".join(paint_recipe(b, B.suffix(c[0]), paint[c[0]]) for b in recipe_blocks for c in B.COLORS[1:]) + "}\n"
    return {OUT_ITEMS: out_items, OUT_MODELS: out_models, OUT_RECIPES: out_recipes, **recipe_names()}


def check_refs():
    """7 色的物品 → 圖示／模型腳本 → 網格／貼圖都接得上，零件 template 的 Dock model 也是；配方產物都是有定義的物品、
    每個配方各語系都有名稱。回傳問題清單。"""
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
    recipes = "".join(open(p, encoding="utf-8").read() for p in (RECIPES, OUT_RECIPES))
    names = re.findall(r"^    craftRecipe (\w+)$", recipes, re.M)
    defined = set(re.findall(r"^    item (\w+)$", items, re.M))
    for out in re.findall(r"^            item 1 MinidoracatKnoxPass\.(\w+),$", recipes, re.M):
        if out not in defined:
            bad.append(f"recipe output MinidoracatKnoxPass.{out} is not a defined item")
    for lang in sorted(os.listdir(TRANSLATE)):
        tr = json.load(open(os.path.join(TRANSLATE, lang, "Recipes.json"), encoding="utf-8"))
        missing = [n for n in names if not tr.get(n)]
        if missing:
            bad.append(f"{lang}/Recipes.json has no name for {', '.join(missing)} (the crafting list would show the key)")
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
    print(("OK: " if check else "wrote: ") + f"{len(B.COLORS)} colours, items/models/recipes scripts, recipe names and references match"
          + ("" if check or not stale else " (" + ", ".join(stale) + ")"))


if __name__ == "__main__":
    main()
