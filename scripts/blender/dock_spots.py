"""車輛網格 → 擋風玻璃上感應盒的位置表（media/lua/shared/MinidoracatKnoxPass/DockSpots.lua）。

用法（repo 根目錄；PZ 更新換了車輛網格、MOD 車更新、改了 modcars.json 後重跑）：
    blender --background --factory-startup --python scripts/blender/dock_spots.py -- \
        "D:/SteamLibrary/steamapps/common/ProjectZomboid/media" [預覽輸出目錄]

為什麼要查網格：原版車窗是不透明貼圖，裝在玻璃內側的模型看不到；要畫在玻璃外表面上，誤差得在 1–2 cm 內，
車輛腳本（駕駛座、extents）推不出玻璃在哪（駕駛座到玻璃上緣 0.16–0.69 m 不等）。表裡沒有的車由 Parts.lua 用腳本幾何推算。
網格只知道斜面，玻璃從哪裡開始要看車輛的 textureMask（車窗色塊），StepVan 玻璃上方還有一段烤漆斜面。
原版車的預覽每台 side／iso／wide 三張（車身灰、固定座橘），改了參數要一張張看：固定座要平貼在擋風玻璃外表面上緣。

MOD 車：清單在 scripts/blender/modcars.json（支援清單 scripts/gen_modcar_list.py 也讀它），檔案從本機 Steam Workshop 讀
（MEDIA 往上找 steamapps/workshop/content/108600）。MOD 車的玻璃有兩種：
- 擋風玻璃是獨立零件模型（KI5 系列：part Windshield { model { file } } 指到車身 FBX 裡的玻璃節點）→ 玻璃＝從正面看得到玻璃的地方；
- 玻璃畫在車身貼圖上（rSemiTruck 等，同原版）→ 看 textureMask 的車窗色。
兩種都是不透明：原版 vehicle.frag 與 damnlib 的 damn_vehicle_shader.frag 輸出的 alpha 都是 TexturePainColor.a，
不看貼圖 alpha（vehicle.frag:203、damn_vehicle_shader.frag:177），所以一樣畫在玻璃外表面。
MOD 車另外要遊戲鏡頭看得到（ModelCamera.java:34-35：正交、仰角 30°）：車頂燈架、行李架、遮陽板常蓋在玻璃上緣前方。
配件取這個車身所有車輛的所有零件 model（最壞情況），沿玻璃中線從上緣往下找第一個「車頭左右 45° 內三個方向都露出 VIS_MIN」的點；
玩家自己裝的裝甲不算（mod_spot 的說明）。預覽是遊戲視角的 az-45／az+0／az+45／wide 四張（車身灰、玻璃藍、配件紅褐、固定座橘）。
MOD 車的鍵是模型腳本的 mesh（Parts.lua 用 getModelScript(file):getMeshName() 查），不同 MOD 撞同一個 model 名也不會誤用。

座標：PZ 讀 FBX 套節點變換、不套 UnitScaleFactor，assimp MAKE_LEFT_HANDED 讓 z 取負，
所以「車輛模型原點起算的公尺」＝車輛 scale × 模型腳本 scale × (x, y, -z_fbx)。找玻璃用公尺算，
表裡存除掉車輛 scale 的值＝零件模型 offset 的單位（BaseVehicle.java:4387-4471），Parts.lua 直接寫進 offset。
"""
import collections
import json
import math
import os
import re
import struct
import sys

import bpy
from mathutils import Euler, Matrix, Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import barycentric_transform

ARGS = sys.argv[sys.argv.index("--") + 1:]
MEDIA = ARGS[0]
PREVIEW = ARGS[1] if len(ARGS) > 1 else None
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MOD_MEDIA = os.path.join(REPO, "MOD", "MinidoracatKnoxPassFor42", "Contents", "mods", "MinidoracatKnoxPassFor42", "42", "media")
OUT = os.path.join(MOD_MEDIA, "lua", "shared", "MinidoracatKnoxPass", "DockSpots.lua")
MANIFEST = os.path.join(HERE, "modcars.json")
WORKSHOP = os.path.normpath(os.path.join(MEDIA, "..", "..", "..", "workshop", "content", "108600"))

DROP = 0.015      # 固定座上緣（模型原點）在車窗上緣下方幾公尺；盒子往下垂 5.6 cm
LIFT = 0.018      # 模型原點（黏貼墊面）離玻璃外表面幾公尺：模型往車內方向厚 1.7 cm，整個要露在玻璃外
SCAN = 0.45       # 從車頂往下最多找幾公尺（救護車玻璃上緣在車廂頂下 0.30 m）
MIN_TILT = 15.0   # 後傾小於幾度就不當擋風玻璃
GLASS_MIN = 0.10  # 連續的玻璃面至少要幾公尺高
GLASS_SCAN = 0.35 # 斜面頂往下最多找幾公尺的車窗色
SEEN = 0.003      # 獨立玻璃：正面射線先打到的面離玻璃不到幾公尺，才算看得到玻璃（窗框、車頂簷蓋在前面就不算）
# MOD 車另外要「遊戲鏡頭看得到」：鏡頭由上往下斜看（正交），玻璃上緣常被遮陽板、車頂燈架、護網擋住（models-mp 1005i 實踩：
# F350／F150／W900 的盒子在正面預覽看得到、遊戲裡看不到）。原版表不套這個判斷（原版車已實機確認看得到）。
VIEW_ELEV = 30.0              # 鏡頭仰角
VIEW_AZ = (-45.0, 0.0, 45.0)  # 鏡頭方位：車頭正前方左右 45° 內（車可以朝任何方向停，這段是看得到擋風玻璃的方向）
VIS_MIN = 0.6                 # 每個方向，盒子朝鏡頭那幾面的投影面積至少要露出幾成（細條護網擋一部分可以）
WINDOW = ((0.5, 0.0, 0.0), (0.0, 0.5, 0.0))   # textureMask 的車窗色：vehicle.frag colZone11（Window T）、colZone12（Window H）


def scripts():
    """模型腳本名 → (mesh, 模型 scale)；車輛 model 區塊的 file → 車輛 scale、→ textureMask（照 template 往上找）。"""
    models, vscale, blocks = {}, {}, {}
    for root, _, files in os.walk(os.path.join(MEDIA, "scripts")):
        for f in files:
            if not f.endswith(".txt"):
                continue
            t = open(os.path.join(root, f), encoding="utf-8", errors="ignore").read()
            for m in re.finditer(r"\bmodel\s+(\w+)\s*\{([^}]*)\}", t):
                mesh = re.search(r"mesh\s*=\s*([^,\n]+)", m.group(2))
                sc = re.search(r"scale\s*=\s*([\d.]+)", m.group(2))
                if mesh:
                    models[m.group(1)] = (mesh.group(1).strip(), float(sc.group(1)) if sc else 1.0)
            for m in re.finditer(r"\n\s*model\s*\n\s*\{([^}]*)\}", t):
                fi = re.search(r"file\s*=\s*(\w+)", m.group(1))
                sc = re.search(r"scale\s*=\s*([\d.]+)", m.group(1))
                if fi:
                    sc = float(sc.group(1)) if sc else 1.0
                    if vscale.setdefault(fi.group(1), sc) != sc:
                        print("WARN", fi.group(1), "has vehicle scales", vscale[fi.group(1)], sc)
            heads = list(re.finditer(r"\n\s*(template\s+)?vehicle\s+(\w+)", t))
            for i, h in enumerate(heads):
                body = t[h.end():heads[i + 1].start() if i + 1 < len(heads) else len(t)]
                fi = re.search(r"\n\s*model\s*\n\s*\{[^}]*?file\s*=\s*(\w+)", body)
                mk = re.search(r"textureMask\s*=\s*([\w/]+)", body)
                blocks[(h.group(1) is not None, h.group(2))] = (fi and fi.group(1), mk and mk.group(1),
                                                                re.findall(r"template!?\s*=\s*(\w+)", body))

    def up(key, field, seen):   # 自己沒有就往引用的 template 找
        if key not in blocks or key in seen:
            return None
        seen.add(key)
        own = blocks[key][field]
        return own or next((v for ref in blocks[key][2] for v in [up((True, ref), field, seen)] if v), None)

    masks = {}
    for key in blocks:
        if not key[0]:
            fi, mk = up(key, 0, set()), up(key, 1, set())
            if fi and mk:
                masks.setdefault(fi, collections.Counter())[mk] += 1
    return models, vscale, {fi: c.most_common(1)[0][0] for fi, c in masks.items()}


def braces(t, head):
    """head（regex）後面接 { … }：括號配對取內文 → (match, 內文)。"""
    for m in re.finditer(head + r"\s*\{", t):
        d = 0
        for j in range(m.end() - 1, len(t)):
            d += {"{": 1, "}": -1}.get(t[j], 0)
            if d == 0:
                yield m, t[m.end():j]
                break


def top(body):
    """拿掉巢狀區塊，只留這一層的 key = value。"""
    prev = None
    while prev != body:
        prev, body = body, re.sub(r"\{[^{}]*\}", "", body)
    return body


def val(body, key):
    m = re.search(r"(?:^|[\s,])" + key + r"\s*=\s*([^,\n]+)", top(body))
    return m.group(1).strip() if m else None


def mod_media(workshop, mod_id):
    """Workshop 項目裡 mod.info id 相符的 MOD → [最高的 42.x 版本目錄/media, common/media]（同一相對路徑版本目錄優先）。"""
    base = os.path.join(WORKSHOP, workshop, "mods")
    for d in sorted(os.listdir(base)):
        md = os.path.join(base, d)
        vers = sorted((tuple(map(int, v.split("."))), v) for v in os.listdir(md)
                      if re.fullmatch(r"42(\.\d+)*", v) and os.path.exists(os.path.join(md, v, "mod.info")))
        if not vers:
            continue
        info = open(os.path.join(md, vers[-1][1], "mod.info"), encoding="utf-8", errors="ignore").read()
        if re.search(r"^id\s*=\s*" + re.escape(mod_id) + r"\s*$", info, re.M):
            return [os.path.join(md, vers[-1][1], "media"), os.path.join(md, "common", "media")]
    raise SystemExit("mod %s not found in workshop item %s" % (mod_id, workshop))


def mod_scripts(medias):
    """MOD 的腳本 → 模型腳本（全名；Base 模組也收短名）→ (mesh, scale)、車輛／template 名 → 內文。"""
    files = {}
    for media in reversed(medias):   # 同一相對路徑：版本目錄蓋過 common
        sd = os.path.join(media, "scripts")
        for dp, _, fs in os.walk(sd):
            for f in fs:
                if f.endswith(".txt"):
                    files[os.path.relpath(os.path.join(dp, f), sd).lower()] = os.path.join(dp, f)
    models, vehicles, templates = {}, {}, {}
    for path in files.values():
        t = re.sub(r"/\*.*?\*/", "", open(path, encoding="utf-8", errors="ignore").read(), flags=re.S)
        t = re.sub(r"//[^\n]*", "", t)
        for mm, mb in braces(t, r"\bmodule\s+(\w+)"):
            names = lambda n: [mm.group(1) + "." + n] + ([n] if mm.group(1) == "Base" else [])
            for m, b in braces(mb, r"\bmodel\s+(\w+)"):
                if val(b, "mesh"):
                    for n in names(m.group(1)):
                        models[n] = (val(b, "mesh"), float(val(b, "scale") or 1.0))
            for m, b in braces(mb, r"(?<!\w)(template\s+)?vehicle\s+(\w+)"):
                for n in names(m.group(2)):
                    (templates if m.group(1) else vehicles)[n] = b
    return models, vehicles, templates


def vehicle_info(body, templates, seen=()):
    """車輛（自己沒有就照 template 往上找）→ {file, scale, extents z, textureMask, 擋風玻璃零件的 model file}。"""
    info = dict.fromkeys(("file", "scale", "length", "mask", "glass"))
    for _, b in braces(body, r"(?<![\w])model"):
        info["file"], info["scale"] = val(b, "file"), val(b, "scale") and float(val(b, "scale"))
        break
    ext = val(body, "extents")
    info["length"] = ext and float(ext.split()[2])
    info["mask"] = val(body, "textureMask")
    for _, b in braces(body, r"\bpart\s+Windshield"):
        for _, mb in braces(b, r"\bmodel\s+\w+"):
            if val(mb, "offset") or val(mb, "rotate") or val(mb, "scale"):
                raise SystemExit("windshield part model has its own offset/rotate/scale: not handled")
            info["glass"] = val(mb, "file")
    for ref in re.findall(r"\btemplate!?\s*=\s*([\w.]+)(?![\w./])", top(body)):   # 跳過 X/part/Y（只拿單一零件）
        if ref in templates and ref not in seen:
            for k, v in vehicle_info(templates[ref], templates, seen + (ref,)).items():
                info[k] = info[k] if info[k] is not None else v
    return info


def part_models(body, templates, seen=()):
    """車輛（含 template）每個 part 底下的 model → [(part id, model file, offset, rotate, scale, lua create 的設定名)]。
    `template = X/part/Y` 只取 X 的零件 Y；不在這個 MOD 腳本裡的 template（原版座椅等）略過。
    KI5 的配件（車頂燈架、行李架、護網）一個零件列好幾個 model，由 damnlib 的 Lua 挑一個顯示，這裡全收＝最壞情況。
    設定名＝part 的 lua { create = NS.Create.<名> }，對到 damnlib 零件設定的項目名（同一個零件 id 不同車可以用不同項目）。"""
    out = []
    for m, b in braces(body, r"\bpart\s+([\w*]+)"):
        create = re.search(r"\bcreate\s*=\s*[\w.]*\.(\w+)", b)
        out.append((m.group(1), None, None, None, None, create and create.group(1)))
        for _, mb in braces(b, r"\bmodel\s+\w+"):
            out.append((m.group(1), val(mb, "file"), val(mb, "offset"), val(mb, "rotate"), val(mb, "scale"), create and create.group(1)))
    for ref in re.findall(r"\btemplate!?\s*=\s*([\w./]+)", top(body)):
        name, _, part = ref.partition("/part/")
        if name not in templates or name in seen:
            continue
        if part:
            for _, b in braces(templates[name], r"\bpart\s+%s(?![\w*])" % re.escape(part)):
                out += part_models("part %s {%s}" % (part, b), templates, seen)
        else:
            out += part_models(templates[name], templates, seen + (name,))
    return out


def ascii_mesh(path, node=None, cache={}):
    """原版 vehicles 多是 ASCII FBX（Blender 不收）：自己讀 Vertices／PolygonVertexIndex／第 0 層 UV 與 Model 節點的 PreRotation、Lcl Scaling。
    node：只取 Model::node（不分大小寫）連到的 Geometry，套那個節點的 Lcl Translation／PreRotation／Lcl Rotation／Lcl Scaling
    （MOD 車一個 FBX 裝整台車的零件；只處理直接掛在 RootNode 下的節點，pivot 不管）。"""
    if path not in cache:
        cache[path] = open(path, encoding="latin1").read()
    t = cache[path]
    geos = t.split("Geometry: ")[1:]
    if node:
        m = re.search(r'Model: (\d+), "Model::%s", "Mesh" \{(.*?)\n\t\}' % re.escape(node), t, re.S | re.I)
        if not m or not re.search(r'C: "OO",%s,0\s' % m.group(1), t):
            return [], [], []
        gids = set(re.findall(r'C: "OO",(\d+),%s\s' % m.group(1), t))
        geos = [g for g in geos if g.split(",")[0] in gids]

        def prop(name, default):
            p = re.search(r'P: "%s"[^\n]*?,([-\d.e]+),([-\d.e]+),([-\d.e]+)\s*\n' % name, m.group(2))
            return [float(x) for x in p.groups()] if p else default

        rot = lambda deg: Euler([math.radians(a) for a in deg], "XYZ").to_matrix().to_4x4()
        M = (Matrix.Translation(prop("Lcl Translation", (0, 0, 0))) @ rot(prop("PreRotation", (0, 0, 0)))
             @ rot(prop("Lcl Rotation", (0, 0, 0))) @ Matrix.Diagonal(list(prop("Lcl Scaling", (1, 1, 1))) + [1]))
        xf = lambda x, y, z: tuple(M @ Vector((x, y, z)))
    else:
        model = t[t.find("Model::"):]
        pre = re.search(r'P: "PreRotation"[^\n]*"",([-\d.e]+),([-\d.e]+),([-\d.e]+)', model)
        sc = re.search(r'P: "Lcl Scaling"[^\n]*"A",([-\d.e]+),([-\d.e]+),([-\d.e]+)', model)
        s = float(sc.group(1)) if sc else 1.0
        rot = pre is not None and abs(float(pre.group(1)) + 90) < 1
        xf = lambda x, y, z: (x * s, z * s, -y * s) if rot else (x * s, y * s, z * s)   # Max 匯出的 PreRotation -90°：Z 上 → Y 上
    nums = lambda a: [float(x) for x in a.replace("\n", "").split(",")]
    verts, faces, uvs = [], [], []
    for geo in geos:
        g = re.search(r"Vertices: \*\d+ \{\s*a: ([^}]*)\}\s*PolygonVertexIndex: \*\d+ \{\s*a: ([^}]*)\}", geo)
        if not g:
            continue
        vals = nums(g.group(1))
        base = len(verts)
        for i in range(0, len(vals), 3):
            verts.append(xf(vals[i], vals[i + 1], vals[i + 2]))
        layer = geo[geo.find("LayerElementUV: 0"):]
        uv = re.search(r"UV: \*\d+ \{\s*a: ([^}]*)\}", layer)
        ui = re.search(r"UVIndex: \*\d+ \{\s*a: ([^}]*)\}", layer)
        uv = nums(uv.group(1)) if uv else []
        ui = [int(x) for x in nums(ui.group(1))] if ui else None
        corner, poly = 0, []
        for i in (int(x) for x in g.group(2).replace("\n", "").split(",")):
            poly.append(~i if i < 0 else i)
            corner += 1
            if i < 0:
                faces.append([base + k for k in poly])
                c0 = corner - len(poly)
                idx = ui[c0:corner] if ui else range(c0, corner)
                uvs.append([(uv[2 * j], uv[2 * j + 1]) if uv else (0.0, 0.0) for j in idx])
                poly = []
    return verts, faces, uvs


def unit_scale(path):
    d = open(path, "rb").read()
    i = d.find(b"UnitScaleFactor")
    for k in range(i, i + 80):  # P 記錄：名稱、型別字串… 之後是 'D' + double
        if d[k:k + 1] == b"D":
            v = struct.unpack_from("<d", d, k + 1)[0]
            if 1e-4 < v < 1e4:
                return v
    return 100.0


_NODES = {}


def fbx_nodes(path):
    """二進位 FBX 匯入一次 → {小寫節點名: (verts, faces, uvs)}（FBX 座標）。MOD 車一個 FBX 裝整台車的零件，
    配件要逐一取，所以整檔快取；節點名比對不分大小寫（腳本寫 f350_SideSteps0、FBX 是 f350_sidesteps0）。"""
    if path not in _NODES:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.import_scene.fbx(filepath=path)
        u = unit_scale(path) / 100.0   # Blender 把 UnitScaleFactor/100 乘進 matrix_world，assimp 不乘
        out = {}
        for o in bpy.data.objects:
            if o.type != "MESH":
                continue
            verts = [(w.x / u, w.z / u, -w.y / u) for w in (o.matrix_world @ v.co for v in o.data.vertices)]   # Blender Z 上 → FBX Y 上
            layer = o.data.uv_layers[0].data if o.data.uv_layers else None
            faces = [list(p.vertices) for p in o.data.polygons]
            uvs = [[tuple(layer[li].uv) if layer else (0.0, 0.0) for li in p.loop_indices] for p in o.data.polygons]
            out[o.name.lower()] = (verts, faces, uvs)
        _NODES[path] = out
    return _NODES[path]


def merge(parts):
    verts, faces, uvs = [], [], []
    for v, f, u in parts:
        faces += [[len(verts) + i for i in face] for face in f]
        verts += v
        uvs += u
    return verts, faces, uvs


def binary_mesh(path, node=None):
    """node＝模型腳本 mesh 的「|節點名」：只取那個節點；沒給就整個 FBX 合在一起。"""
    nodes = fbx_nodes(path)
    if node:
        return nodes.get(node.lower(), ([], [], []))
    return merge(nodes.values())


def find_mesh(mesh, medias=(MEDIA,)):
    base = mesh.split("|")[0]
    for media in medias:
        for ext in (".fbx", ".FBX"):
            p = os.path.join(media, "models_X", base + ext)
            if os.path.exists(p):
                return p
    return None


def load_mesh(mesh, medias):
    """MOD 車的模型腳本 mesh（路徑|節點）→ FBX 座標的 verts、faces、第 0 層 UV；找不到回 None。"""
    path = find_mesh(mesh, medias)
    if not path:
        return None
    node = mesh.split("|")[1] if "|" in mesh else None
    binary = open(path, "rb").read(20).startswith(b"Kaydara")
    verts, faces, uvs = binary_mesh(path, node) if binary else ascii_mesh(path, node)
    return (verts, faces, uvs) if verts else None


def triangles(verts, faces, uvs, k):
    """FBX 座標 → 車輛模型原點起算的公尺（車頭 +z），拆三角形（命中點才能用重心座標內插 UV）。"""
    L = [Vector((x * k, y * k, -z * k)) for x, y, z in verts]
    tris, tuv = [], []
    for f, fu in zip(faces, uvs):
        for i in range(1, len(f) - 1):
            tris.append((f[0], f[i], f[i + 1]))
            tuv.append((fu[0], fu[i], fu[i + 1]))
    return L, tris, tuv


def placement(front, gtop, min_tilt=MIN_TILT):
    """車窗上緣 gtop 往下 DROP 放固定座，用下方 8 cm 量後傾角，沿法線往外推 LIFT。"""
    yc = gtop - DROP
    zc, zl = front(yc), front(yc - 0.08)
    if zc is None or zl is None:
        return None
    tilt = math.atan2(max(zl - zc, 0.0), 0.08)   # 玻璃後傾角（離垂直）
    if math.degrees(tilt) < min_tilt:
        return None   # 近乎垂直的面不是擋風玻璃（拖車、燒毀車殼、救護車車廂前牆）
    return yc + LIFT * math.sin(tilt), zc + LIFT * math.cos(tilt), math.degrees(tilt)


def window_at(bvh, L, tris, tuv, mask, x, y, zmax):
    """(x, y) 從正面打的第一個命中點在 textureMask 上是不是車窗色（vehicle.frag 的 colZone11／12，mask 用第 0 層 UV）。"""
    w, h, pix = mask
    loc, _, idx, _ = bvh.ray_cast(Vector((x, y, zmax)), Vector((0, 0, -1)), 100)
    if loc is None:
        return False
    uv = barycentric_transform(loc, *(L[i] for i in tris[idx]), *(Vector((u, v, 0)) for u, v in tuv[idx]))
    p = ((int(uv.y % 1 * h)) * w + int(uv.x % 1 * w)) * 4   # Blender 影像第 0 列在下＝v 0
    return any(all(abs(pix[p + c] - win[c]) < 0.03 for c in range(3)) for win in WINDOW)


def spot(verts, faces, uvs, k, mask):
    L, tris, tuv = triangles(verts, faces, uvs, k)
    bvh = BVHTree.FromPolygons(L, tris)
    zmax = max(v.z for v in L) + 1.0
    zmin = min(v.z for v in L) - 1.0
    # 車頂：往下打的射線，取「至少 0.5 m 長都在這個高度以上」的最高高度（排除車頂天線、計程車燈箱）
    tops = []
    z = zmin
    while z < zmax:
        hit = bvh.ray_cast(Vector((0, 50, z)), Vector((0, -1, 0)), 100)[0]
        if hit:
            tops.append(hit.y)
        z += 0.02
    tops.sort(reverse=True)
    if len(tops) < 25:
        return None
    roof = tops[24]

    def front(y):
        hit = bvh.ray_cast(Vector((0, y, zmax)), Vector((0, 0, -1)), 100)[0]
        return hit.z if hit else None

    def glass(y):
        """前表面這一高度是不是車窗色。中線兩側也看：StepVan 的擋風玻璃左右兩片，中線是窗柱。"""
        return any(window_at(bvh, L, tris, tuv, mask, x, y, zmax) for x in (0.0, 0.15, -0.15))

    # 擋風玻璃上緣：從車頂往下逐公分找第一段「連續、後傾 ≥ MIN_TILT、至少 GLASS_MIN 長」的面。
    # 往下找才跳得過車頂上的東西與近乎垂直的面（救護車、廣播車在駕駛室上方的車廂前牆）
    step, slope = 0.01, math.tan(math.radians(MIN_TILT)) * 0.01
    y, z, run, top = roof, front(roof), 0, None
    while y > roof - SCAN:
        z2 = front(y - step)
        if z is not None and z2 is not None and slope <= z2 - z < 0.04:
            run += 1
            if run * step >= GLASS_MIN:
                top = y + (run - 1) * step
                break
        else:
            run = 0
        y, z = y - step, z2
    if top is None:
        return None
    # 車窗上緣：斜面頂往下找 mask 標成車窗的第一點（StepVan 等玻璃上方還有一段烤漆斜面）
    gtop = next((top - i * 0.01 for i in range(int(GLASS_SCAN / 0.01))
                 if glass(top - i * 0.01) and glass(top - i * 0.01 - 0.01)), None) if mask else None
    if gtop is None:
        print("WARN no window mask under the slope top, using the slope top")
        gtop = top
    p = placement(front, gtop)
    return p and p + (roof, top, gtop)


def tri_list(faces):
    return [(f[0], f[i], f[i + 1]) for f in faces for i in range(1, len(f) - 1)]


def bvh_of(*meshes):
    """[(頂點, 三角形)] 合成一棵 BVH。"""
    V, T = [], []
    for v, t in meshes:
        T += [tuple(i + len(V) for i in tri) for tri in t]
        V += v
    return BVHTree.FromPolygons(V, T)


def place_part(data, k, vs, off, rot):
    """零件模型 → 車輛模型原點起算的公尺：vs×T(-ox, oy, oz) ＋ R×(k×v)，R＝rotationXYZ(rx, -ry, -rz)
    （BaseVehicle.java:4387-4471、:4418-4423；k＝車輛 scale×模型腳本 scale×零件 model scale）。"""
    ox, oy, oz = (float(x) for x in off.split()) if off else (0.0, 0.0, 0.0)
    rx, ry, rz = (math.radians(float(x)) for x in rot.split()) if rot else (0.0, 0.0, 0.0)
    R = Matrix.Rotation(rx, 3, "X") @ Matrix.Rotation(-ry, 3, "Y") @ Matrix.Rotation(-rz, 3, "Z")
    t = Vector((-ox * vs, oy * vs, oz * vs))
    return [t + R @ Vector((x * k, y * k, -z * k)) for x, y, z in data[0]], tri_list(data[1])


def dock_mesh(cache=[]):
    """固定座＋感應盒（MinidoracatKnoxPassTagDock.fbx，頂點公尺、節點單位）→ 模型座標 (x, y, -z) 的三角形、朝外單位法線、面積。
    z 取負是鏡射，三角形繞向跟著反過來，朝外法線＝-(b-a)×(c-a)；整體朝外與否用「法線對形心」的面積加權投票再確認一次。"""
    if not cache:
        v, f, _ = binary_mesh(os.path.join(MOD_MEDIA, "models_X", "vehicles", "MinidoracatKnoxPassTagDock.fbx"))
        P = [Vector((x, y, -z)) for x, y, z in v]
        tris = [tuple(P[i] for i in t) for t in tri_list(f)]
        c = sum(P, Vector()) / len(P)
        out = []
        for a, b, d in tris:
            n = -(b - a).cross(d - a)
            if n.length > 1e-12:
                out.append(((a, b, d), n.normalized(), n.length / 2))
        vote = sum(ar * n.dot((a + b + d) / 3 - c) for (a, b, d), n, ar in out)
        if vote < 0:
            out = [(t, -n, ar) for t, n, ar in out]
        cache.append(out)
    return cache[0]


def view_dirs():
    """鏡頭方向（從盒子指向鏡頭，模型座標：y 上、z 車頭）。"""
    e = math.radians(VIEW_ELEV)
    return [Vector((math.sin(math.radians(a)) * math.cos(e), math.sin(e), math.cos(math.radians(a)) * math.cos(e))) for a in VIEW_AZ]


def dock_at(s):
    """位置 s＝(高, 前後, 傾角) → 擺好的固定座三角形與法線：T(0, y, z)×Rx(-傾角)（零件 rotate.x＝-傾角）。"""
    R = Matrix.Rotation(math.radians(-s[2]), 3, "X")
    t = Vector((0.0, s[0], s[1]))
    return [(tuple(t + R @ p for p in tri), R @ n, ar) for tri, n, ar in dock_mesh()]


def visibility(occ, s):
    """每個鏡頭方向，盒子朝鏡頭那幾面（投影面積加權）有幾成沒被車身、玻璃、配件擋住（每個三角形取 4 點往鏡頭打射線）。"""
    placed = dock_at(s)
    out = []
    for d in view_dirs():
        tot = vis = 0.0
        for (a, b, c), n, ar in placed:
            w = ar * n.dot(d)
            if w <= 0:
                continue
            for p in ((a + b + c) / 3, a * .6 + b * .2 + c * .2, a * .2 + b * .6 + c * .2, a * .2 + b * .2 + c * .6):
                tot += w
                if occ.ray_cast(p + n * 5e-4 + d * 5e-4, d, 20)[0] is None:
                    vis += w
        out.append(vis / tot)
    return out


def mod_glass_spot(L, tris, tuv, mask, G, gtris, accs):
    """MOD 車擋風玻璃上看得到盒子的位置。
    玻璃：G＝獨立擋風玻璃零件（KI5：part Windshield 的 model 指到車身 FBX 的玻璃節點），「在玻璃上」＝車身＋玻璃一起從正面打，
    第一個命中點就是玻璃；沒有 G 就看車身貼圖 textureMask 的車窗色（rSemiTruck，同原版；W900 玻璃只後傾約 13°，不擋傾角）。
    中線是窗柱（兩片玻璃）就看 ±0.15 m，盒子仍放中線、貼在窗柱上。
    遮擋：accs＝[(名稱, (頂點, 三角形))]，這個車身生車時可能出現的零件 model（遮陽板、燈架、行李架…，一個零件的幾個樣式全收）＝最壞情況。
    從玻璃上緣往下逐公分找第一個「每個鏡頭方向都露出 VIS_MIN」的點。
    回傳 (s, 資訊) 或 (None, 資訊)，s＝(高, 前後, 傾角)；失敗的資訊帶最接近的位置，給預覽看是誰擋住。"""
    both = bvh_of((L, tris), (G, gtris)) if G else bvh_of((L, tris))
    only = G and bvh_of((G, gtris))
    zmax = max(v.z for v in L + (G or [])) + 1.0

    def hit(bvh, x, y):
        h = bvh.ray_cast(Vector((x, y, zmax)), Vector((0, 0, -1)), 100)[0]
        return h.z if h else None

    front = lambda y: hit(both, 0.0, y)
    if G:
        def on(x, y):
            g, c = hit(only, x, y), hit(both, x, y)
            return g is not None and c is not None and c - g < SEEN
    else:
        on = lambda x, y: window_at(both, L, tris, tuv, mask, x, y, zmax)
    hi, lo = (max(v.y for v in G), min(v.y for v in G)) if G else (max(v.y for v in L), min(v.y for v in L))
    xs = next((xs for xs in ((0.0,), (0.15, -0.15)) if any(on(x, y / 100) for x in xs
                                                            for y in range(int(lo * 100), int(hi * 100) + 1))), None)
    if xs is None:
        return None, dict(msg="no windshield found", s=None)
    glass = lambda y: any(on(x, y) for x in xs)
    top = next((hi - i * 0.01 for i in range(int((hi - lo) / 0.01)) if glass(hi - i * 0.01) and glass(hi - i * 0.01 - 0.01)), None)
    if top is None:
        return None, dict(msg="no windshield found", s=None)
    worst = [mesh for _, mesh in accs]
    occ = bvh_of((L, tris), *(((G, gtris),) if G else ()), *worst)
    y, best = top, (0.0, None, None)
    while y - DROP - 0.07 > lo:
        if glass(y) and glass(y - DROP - 0.06):
            s = placement(front, y, 0.0)
            fr = s and visibility(occ, s)
            if fr and min(fr) >= VIS_MIN:
                return s, dict(top=top, at=y, vis=fr, worst=worst)
            if fr and min(fr) > best[0]:
                best = (min(fr), y, fr)
        y -= 0.01
    return None, dict(msg="no spot visible from the game camera (top=%.3f, best=%s)" % (top, best),
                      s=placement(front, best[1] or top, 0.0), worst=worst)


def preview(name, verts, faces, k, s, glass=None):
    """人看的檢查圖：車身（灰）＋獨立玻璃（藍）＋固定座模型（橘），側視、斜視、遠景，不進 MOD。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene

    def add(label, vs, fs, kk, color):
        me = bpy.data.meshes.new(label)
        me.from_pydata([(x * kk, -z * kk, y * kk) for x, y, z in vs], [], fs)   # Blender：X、Y 前、Z 上
        o = bpy.data.objects.new(label, me)
        o.color = color
        sc.collection.objects.link(o)
        return o

    car = add(name, verts, faces, k, (0.75, 0.75, 0.75, 1))
    if glass:
        add(name + "_glass", glass[0], glass[1], glass[2], (0.35, 0.6, 1.0, 1))
    bpy.ops.import_scene.fbx(filepath=os.path.join(MOD_MEDIA, "models_X", "vehicles", "MinidoracatKnoxPassTagDock.fbx"))
    dock = [o for o in bpy.data.objects if o.type == "MESH" and o.name not in (car.name, name + "_glass")][0]
    dock.color = (1.0, 0.45, 0.0, 1)
    # 匯入器把 FBX 的 Y 上轉回 Blender 的 Z 上（物件旋轉），要疊在它外面；+X 轉＝上緣往車尾倒，貼合後傾的玻璃
    dock.matrix_world = Matrix.Translation((0, s[1], s[0])) @ Matrix.Rotation(math.radians(s[2]), 4, "X") @ dock.matrix_world
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.display.shading.light = "STUDIO"
    sc.display.shading.color_type = "OBJECT"
    sc.render.resolution_x, sc.render.resolution_y = 480, 360
    target = Vector((0, s[1], s[0]))
    for view, eye, ortho in (("side", Vector((3, 0, 0)), 0.5), ("iso", Vector((1.2, 2.2, 1.4)), 0.5), ("wide", Vector((3, 1.5, 1.2)), 6.0)):
        cd = bpy.data.cameras.new("C")
        cd.type = "ORTHO"
        cd.ortho_scale = ortho
        cam = bpy.data.objects.new("C", cd)
        sc.collection.objects.link(cam)
        cam.location = target + eye
        cam.rotation_euler = (-eye).to_track_quat("-Z", "Y").to_euler()   # 相機 Y＝畫面上方對齊世界 Z
        sc.camera = cam
        sc.render.filepath = os.path.join(PREVIEW, f"{name}_{view}.png")
        bpy.ops.render.render(write_still=True)


def game_preview(name, body, glass, accs, s):
    """MOD 車的檢查圖＝遊戲視角：正交、仰角 VIEW_ELEV、車頭左右 45° 與正前方三張近景＋一張遠景。
    車身灰、擋風玻璃藍、配件（最壞情況，全部疊上）紅褐、固定座橘；畫的就是 visibility() 判斷用的同一份幾何。
    模型座標 (x, y 上, z 車頭) → Blender (-x, z, y)（轉動、不鏡射，左右跟遊戲一致）。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    B = lambda p: (-p[0], p[2], p[1])

    def add(label, verts, faces, color):
        me = bpy.data.meshes.new(label)
        me.from_pydata([B(p) for p in verts], [], faces)
        o = bpy.data.objects.new(label, me)
        o.color = color
        sc.collection.objects.link(o)

    add("body", *body, (0.75, 0.75, 0.75, 1))
    if glass:
        add("glass", *glass, (0.35, 0.6, 1.0, 1))
    for i, a in enumerate(accs):
        add("acc%d" % i, *a, (0.55, 0.3, 0.25, 1))
    dock = dock_at(s)
    add("dock", [p for tri, _, _ in dock for p in tri], [(3 * i, 3 * i + 1, 3 * i + 2) for i in range(len(dock))], (1.0, 0.45, 0.0, 1))
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.display.shading.light = "STUDIO"
    sc.display.shading.color_type = "OBJECT"
    sc.render.resolution_x, sc.render.resolution_y = 480, 360
    target = Vector(B((0.0, s[0], s[1])))
    views = [("az%+d" % a, d, 1.2) for a, d in zip(VIEW_AZ, view_dirs())] + [("wide", view_dirs()[-1], 6.0)]
    for view, d, ortho in views:
        eye = Vector(B(d))
        cd = bpy.data.cameras.new("C")
        cd.type = "ORTHO"
        cd.ortho_scale = ortho
        cam = bpy.data.objects.new("C", cd)
        sc.collection.objects.link(cam)
        cam.location = target + eye * 10
        cam.rotation_euler = (-eye).to_track_quat("-Z", "Y").to_euler()   # 相機 Y＝畫面上方對齊世界 Z
        sc.camera = cam
        sc.render.filepath = os.path.join(PREVIEW, f"{name}_{view}.png")
        bpy.ops.render.render(write_still=True)


def load_mask(name, medias=(MEDIA,), cache={}):
    """textureMask（相對 media/textures）→ (寬, 高, RGBA float 列表)；找不到回 None。"""
    path = next((p for p in (os.path.join(m, "textures", name + ".png") for m in medias) if os.path.exists(p)), None)
    if path not in cache:
        cache[path] = None
        if path:
            img = bpy.data.images.load(path)
            cache[path] = (img.size[0], img.size[1], list(img.pixels))
    return cache[path]


def vanilla_rows():
    models, vscale, masks = scripts()
    rows, skipped = [], []
    for file in sorted(vscale):
        if file not in models:
            continue
        mesh, mss = models[file]
        path = find_mesh(mesh)
        if not path:
            skipped.append(file + " (no fbx)")
            continue
        head = open(path, "rb").read(20)
        verts, faces, uvs = binary_mesh(path) if head.startswith(b"Kaydara") else ascii_mesh(path)
        k = vscale[file] * mss
        mask = load_mask(masks[file]) if file in masks else None
        print("MESH", file, "mask=" + str(masks.get(file)), "loaded=" + str(mask is not None))
        s = spot(verts, faces, uvs, k, mask)
        if not s:
            skipped.append(file)
            continue
        rows.append((file, s[0] / vscale[file], s[1] / vscale[file], s[2]))
        print("SPOT %-40s y=%.3f z=%.3f tilt=%.1f roof=%.3f top=%.3f glass=%.3f" % ((file,) + s))
        if PREVIEW and not re.search("Smashed|Burnt", file):   # 殘骸沒有駕駛座、不掛模型
            preview(file, verts, faces, k, s)
    print("SKIPPED", len(skipped), skipped)
    return rows


def spawned_parts(medias):
    """damnlib 零件設定（DAMN.Parts:processConfigV2 的每一項 ["名稱"] = { partId = ..., default = ... }）裡有 default 的項目名：
    生車時會裝上東西（DAMN_Parts.lua processDefaults 只處理有 default 的項目）。項目以下一個 ["名稱"] = { 切開
    （itemToModel 的鍵含點，不會被當成項目）；零件用哪個項目看 part 的 lua { create = NS.Create.<名稱> }。"""
    out = set()
    for media in medias:
        for dp, _, fs in os.walk(os.path.join(media, "lua")):
            for f in fs:
                if f.endswith(".lua"):
                    t = open(os.path.join(dp, f), encoding="utf-8", errors="ignore").read()
                    parts = re.split(r"\[\s*\"(\w+)\"\s*\]\s*=\s*\{", t)
                    for name, body in zip(parts[1::2], parts[2::2]):
                        if re.search(r"\bdefault\s*=", body):
                            out.add(name)
    return out


def mod_spot(mod, car, medias, models, vehicles, templates, extra=()):
    """一個 MOD 車身 → (mesh 鍵, (y, z, 傾角))；算不出來丟 ValueError（附上每台車單獨算行不行，清單可以只把擋住的那幾台移到 unsupported）。
    extra＝同車身、但不列在清單上的車（附加 MOD 的車），配件一樣算進最壞情況。"""
    infos = [vehicle_info(vehicles[v], templates) for v in car["vehicles"]]
    glass_mesh = lambda i: i["glass"] and models[i["glass"]]   # 左右駕版本的玻璃 model 名不同、mesh 相同（92nissanGTR）
    if any((i["file"], glass_mesh(i)) != (car["file"], glass_mesh(infos[0])) for i in infos):
        raise ValueError("vehicles disagree on model file / windshield mesh: %s" % infos)
    info = infos[0]
    mesh, mss = models[car["file"]]
    vs = info["scale"] or 1.0
    body = load_mesh(mesh, medias)
    if not body:
        raise ValueError("mesh %s not found" % mesh)
    k = vs * mss
    L, tris, tuv = triangles(*body, k)
    G = gtris = mask = None
    if info["glass"]:
        gmesh, gms = models[info["glass"]]
        g = load_mesh(gmesh, medias)
        if not g:
            raise ValueError("windshield mesh %s not found" % gmesh)
        G, gtris = place_part(g, vs * gms, vs, None, None)
        how = "glass part " + gmesh
    else:
        mask = info["mask"] and load_mask(info["mask"], medias)
        if not mask:
            raise ValueError("no windshield part and no textureMask %s" % info["mask"])
        how = "mask " + info["mask"]
    # 配件：這個車身所有車輛的所有零件 model（輪胎、擋風玻璃本身除外），同一個 mesh＋擺法只收一次。
    # 裝甲（零件 id 含 Armor）是玩家自己裝的：damnlib 生車時只替設定裡有 default 的零件裝東西（DAMN_Parts.lua processDefaults），
    # KI5 的擋風玻璃裝甲都沒有 default；有 default 的（例：B700 側窗、StepVan SWAT）照樣算進最壞情況。
    spawned = spawned_parts(medias)
    accs, per, missing = {}, {}, []
    for v in list(car["vehicles"]) + list(extra):
        entries = part_models(vehicles[v], templates)
        create = {}
        for e in entries:   # 車輛自己的 part 先於 template（同 id 取第一個寫了 create 的）
            if e[5]:
                create.setdefault(e[0], e[5])
        per[v] = set()
        for pid, file, off, rot, sc, _ in entries:
            if pid.startswith("Tire") or pid == "Windshield" or file not in models or ("Armor" in pid and create.get(pid) not in spawned):
                continue
            pmesh, pms = models[file]
            key = (pmesh, off, rot, sc)
            if key not in accs:
                data = load_mesh(pmesh, medias)
                if not data:
                    missing.append(pmesh)
                    continue
                accs[key] = (pid + " " + pmesh.split("|")[-1], place_part(data, vs * pms * float(sc or 1), vs, off, rot))
            per[v].add(key)
    zs = [v.z for v in L]
    # 比例檢查：網格長度對車輛腳本 extents z（兩者都乘車輛 scale）
    print("MODCAR %s %s len=%.2f extents=%.2f %s parts=%d addon-vehicles=%d missing=%s" % (
        mod["modId"], car["file"], max(zs) - min(zs), (info["length"] or 0) * vs, how, len(accs), len(extra), sorted(set(missing))))
    s, r = mod_glass_spot(L, tris, tuv, mask, G, gtris, list(accs.values()))
    if not s:
        if PREVIEW and r["s"]:   # 失敗也畫最好的那個位置，方便看是誰擋住
            game_preview("FAIL_" + mod["modId"] + "_" + car["file"].replace(".", "_"), (L, tris), G and (G, gtris), r["worst"], r["s"])
        # 逐台看是哪台車的配件擋住（清單可以只拿掉那幾台）
        alone = {v: mod_glass_spot(L, tris, tuv, mask, G, gtris, [accs[k] for k in keys])[0] is not None for v, keys in per.items()}
        raise ValueError("%s; vehicles that work alone: %s; blocked alone: %s" % (
            r["msg"], sorted(v for v, ok in alone.items() if ok), sorted(v for v, ok in alone.items() if not ok)))
    print("SPOT %-40s y=%.3f z=%.3f tilt=%.1f glass=%.3f at=%.3f (-%.0f cm) vis=%s" % (
        car["file"], s[0], s[1], s[2], r["top"], r["at"], (r["top"] - r["at"]) * 100, ["%.2f" % f for f in r["vis"]]))
    if PREVIEW:
        game_preview(mod["modId"] + "_" + car["file"].replace(".", "_"), (L, tris), G and (G, gtris), r["worst"], s)
    return mesh, (round(s[0] / vs, 4), round(s[1] / vs, 4), round(s[2], 1))


def mod_rows():
    """modcars.json 每個 model → {mesh 鍵: ((y, z, 傾角), ["modId file", …])}；有一台算不出來就整個失敗（清單與表要一致）。
    清單上 unsupported 的車（遊戲鏡頭看不到盒子）不算進最壞情況；附加 MOD（addons）裡用同一個車身的車要算。"""
    rows, fail = {}, []
    for mod in json.load(open(MANIFEST, encoding="utf-8"))["mods"]:
        medias = mod_media(mod["workshop"], mod["modId"])
        base = set(mod_scripts(medias)[1])
        for addon in mod.get("addons", []):   # 附加 MOD 的腳本蓋在本體上面（同相對路徑附加優先），模型也從兩邊找
            medias = mod_media(mod["workshop"], addon) + medias
        models, vehicles, templates = mod_scripts(medias)
        for car in mod["models"]:
            skip = set(car["vehicles"]) | set(car.get("unsupported", {}))
            extra = [v for v in sorted(vehicles) if v not in base and v not in skip and "." not in v
                     and vehicle_info(vehicles[v], templates)["file"] == car["file"]]
            try:
                mesh, row = mod_spot(mod, car, medias, models, vehicles, templates, extra)
            except ValueError as e:
                fail.append("%s %s: %s" % (mod["modId"], car["file"], e))
                continue
            if rows.setdefault(mesh, (row, []))[0] != row:
                fail.append("mesh %s used with different spots" % mesh)
            rows[mesh][1].append("%s %s" % (mod["modId"], car["file"]))
    if fail:
        raise SystemExit("MOD cars failed:\n  " + "\n  ".join(fail))
    return rows


def main():
    rows, mods = vanilla_rows(), mod_rows()
    lines = [
        "-- 由 scripts/blender/dock_spots.py 從車輛網格產生，不要手改；PZ 更新換了車輛網格、MOD 車更新或改了 modcars.json 後重跑。",
        "-- 值＝{ 高, 前後, 玻璃後傾角(度) }：零件模型 offset 的 y、z（車輛模型的未縮放單位）與 rotate.x 的大小，",
        "-- 固定座放在擋風玻璃外表面上緣中央。原版與 MOD 車的車窗都是不透明的，裝在玻璃內側的模型看不到，所以畫在玻璃外表面上。",
        'require "MinidoracatKnoxPass/Core"',
        "local KP = MinidoracatKnoxPass",
        "-- 原版：鍵＝車輛腳本 model 區塊的 file",
        "KP.DOCK_SPOTS = {",
    ]
    for file, y, z, tilt in rows:
        lines.append('    ["%s"] = { %.4f, %.4f, %.1f },' % (file, y, z, tilt))
    lines += [
        "}",
        "-- MOD 車（scripts/blender/modcars.json）：鍵＝模型腳本的 mesh（getModelScript(file):getMeshName()），",
        "-- 不同 MOD 撞同一個 model 名時 mesh 不同，不會誤用",
        "KP.DOCK_SPOTS_MOD = {",
    ]
    for mesh in sorted(mods):   # 註解列出用這個 mesh 的所有 model（gen_modcar_list.py 核對清單用）
        (y, z, tilt), users = mods[mesh]
        lines.append('    ["%s"] = { %.4f, %.4f, %.1f },   -- %s' % (mesh, y, z, tilt, "; ".join(users)))
    lines.append("}")
    open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("DONE", len(rows), "+", len(mods), "MOD ->", OUT)


if __name__ == "__main__":
    main()
