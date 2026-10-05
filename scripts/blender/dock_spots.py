"""原版車輛網格 → 擋風玻璃上感應盒的位置表（media/lua/shared/MinidoracatKnoxPass/DockSpots.lua）。

用法（repo 根目錄；PZ 更新換了車輛網格後重跑）：
    blender --background --factory-startup --python scripts/blender/dock_spots.py -- \
        "D:/SteamLibrary/steamapps/common/ProjectZomboid/media" [預覽輸出目錄]

為什麼要查網格：原版車窗是不透明貼圖，裝在玻璃內側的模型看不到；要畫在玻璃外表面上，誤差得在 1–2 cm 內，
車輛腳本（駕駛座、extents）推不出玻璃在哪（駕駛座到玻璃上緣 0.16–0.69 m 不等）。腳本沒有的車型（MOD 車）由 Parts.lua 用腳本幾何推算。
網格只知道斜面，玻璃從哪裡開始要看車輛的 textureMask（車窗色塊），StepVan 玻璃上方還有一段烤漆斜面。
預覽目錄裡每台車有 side／iso／wide 三張，改了參數要一張張看：固定座要平貼在擋風玻璃外表面上緣。

座標：PZ 讀 FBX 套節點變換、不套 UnitScaleFactor，assimp MAKE_LEFT_HANDED 讓 z 取負，
所以「車輛模型原點起算的公尺」＝車輛 scale × 模型腳本 scale × (x, y, -z_fbx)。找玻璃用公尺算，
表裡存除掉車輛 scale 的值＝零件模型 offset 的單位（BaseVehicle.java:4387-4471），Parts.lua 直接寫進 offset。
"""
import collections
import math
import os
import re
import struct
import sys

import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import barycentric_transform

ARGS = sys.argv[sys.argv.index("--") + 1:]
MEDIA = ARGS[0]
PREVIEW = ARGS[1] if len(ARGS) > 1 else None
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MOD_MEDIA = os.path.join(REPO, "MOD", "MinidoracatKnoxPassFor42", "Contents", "mods", "MinidoracatKnoxPassFor42", "42", "media")
OUT = os.path.join(MOD_MEDIA, "lua", "shared", "MinidoracatKnoxPass", "DockSpots.lua")

DROP = 0.015      # 固定座上緣（模型原點）在車窗上緣下方幾公尺；盒子往下垂 5.6 cm
LIFT = 0.018      # 模型原點（黏貼墊面）離玻璃外表面幾公尺：模型往車內方向厚 1.7 cm，整個要露在玻璃外
SCAN = 0.45       # 從車頂往下最多找幾公尺（救護車玻璃上緣在車廂頂下 0.30 m）
MIN_TILT = 15.0   # 後傾小於幾度就不當擋風玻璃
GLASS_MIN = 0.10  # 連續的玻璃面至少要幾公尺高
GLASS_SCAN = 0.35 # 斜面頂往下最多找幾公尺的車窗色
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


def ascii_mesh(path):
    """原版 vehicles 多是 ASCII FBX（Blender 不收）：自己讀 Vertices／PolygonVertexIndex／第 0 層 UV 與 Model 節點的 PreRotation、Lcl Scaling。"""
    t = open(path, encoding="latin1").read()
    model = t[t.find("Model::"):]
    pre = re.search(r'P: "PreRotation"[^\n]*"",([-\d.e]+),([-\d.e]+),([-\d.e]+)', model)
    sc = re.search(r'P: "Lcl Scaling"[^\n]*"A",([-\d.e]+),([-\d.e]+),([-\d.e]+)', model)
    s = float(sc.group(1)) if sc else 1.0
    rot = pre is not None and abs(float(pre.group(1)) + 90) < 1
    nums = lambda a: [float(x) for x in a.replace("\n", "").split(",")]
    verts, faces, uvs = [], [], []
    for geo in t.split("Geometry: ")[1:]:
        g = re.search(r"Vertices: \*\d+ \{\s*a: ([^}]*)\}\s*PolygonVertexIndex: \*\d+ \{\s*a: ([^}]*)\}", geo)
        if not g:
            continue
        vals = nums(g.group(1))
        base = len(verts)
        for i in range(0, len(vals), 3):
            x, y, z = vals[i] * s, vals[i + 1] * s, vals[i + 2] * s
            verts.append((x, z, -y) if rot else (x, y, z))   # Max 匯出的 PreRotation -90°：Z 上 → Y 上
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


def binary_mesh(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=path)
    u = unit_scale(path) / 100.0   # Blender 把 UnitScaleFactor/100 乘進 matrix_world，assimp 不乘
    verts, faces, uvs = [], [], []
    for o in bpy.data.objects:
        if o.type != "MESH":
            continue
        base = len(verts)
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            verts.append((w.x / u, w.z / u, -w.y / u))   # Blender Z 上 → FBX Y 上
        layer = o.data.uv_layers[0].data if o.data.uv_layers else None
        for p in o.data.polygons:
            faces.append([base + i for i in p.vertices])
            uvs.append([tuple(layer[li].uv) if layer else (0.0, 0.0) for li in p.loop_indices])
    return verts, faces, uvs


def find_mesh(mesh):
    base = mesh.split("|")[0]
    for ext in (".fbx", ".FBX"):
        p = os.path.join(MEDIA, "models_X", base + ext)
        if os.path.exists(p):
            return p
    return None


def spot(verts, faces, uvs, k, mask):
    L = [Vector((x * k, y * k, -z * k)) for x, y, z in verts]   # 車輛模型原點起算的公尺，車頭 +z
    tris, tuv = [], []   # 拆三角形，命中點才能用重心座標內插 UV
    for f, fu in zip(faces, uvs):
        for i in range(1, len(f) - 1):
            tris.append((f[0], f[i], f[i + 1]))
            tuv.append((fu[0], fu[i], fu[i + 1]))
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
        """前表面這一高度在 textureMask 上是不是車窗色（vehicle.frag 的 colZone11／12，mask 用第 0 層 UV）。
        中線兩側也看：StepVan 的擋風玻璃左右兩片，中線是窗柱。"""
        w, h, pix = mask
        for x in (0.0, 0.15, -0.15):
            loc, _, idx, _ = bvh.ray_cast(Vector((x, y, zmax)), Vector((0, 0, -1)), 100)
            if loc is None:
                continue
            uv = barycentric_transform(loc, *(L[i] for i in tris[idx]), *(Vector((u, v, 0)) for u, v in tuv[idx]))
            p = ((int(uv.y % 1 * h)) * w + int(uv.x % 1 * w)) * 4   # Blender 影像第 0 列在下＝v 0
            if any(all(abs(pix[p + c] - win[c]) < 0.03 for c in range(3)) for win in WINDOW):
                return True
        return False

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
    yc = gtop - DROP
    zc, zl = front(yc), front(yc - 0.08)
    if zc is None or zl is None:
        return None
    tilt = math.atan2(max(zl - zc, 0.0), 0.08)   # 玻璃後傾角（離垂直）
    if math.degrees(tilt) < MIN_TILT:
        return None   # 近乎垂直的面不是擋風玻璃（拖車、燒毀車殼、救護車車廂前牆）
    return (yc + LIFT * math.sin(tilt), zc + LIFT * math.cos(tilt), math.degrees(tilt), roof, top, gtop)


def preview(name, verts, faces, k, s):
    """人看的檢查圖：車身＋固定座模型（側視、斜視），不進 MOD。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    me = bpy.data.meshes.new(name)
    me.from_pydata([(x * k, -z * k, y * k) for x, y, z in verts], [], faces)   # Blender：X、Y 前、Z 上
    car = bpy.data.objects.new(name, me)
    sc.collection.objects.link(car)
    bpy.ops.import_scene.fbx(filepath=os.path.join(MOD_MEDIA, "models_X", "vehicles", "MinidoracatKnoxPassTagDock.fbx"))
    dock = [o for o in bpy.data.objects if o.type == "MESH" and o is not car][0]
    # 匯入器把 FBX 的 Y 上轉回 Blender 的 Z 上（物件旋轉），要疊在它外面；+X 轉＝上緣往車尾倒，貼合後傾的玻璃
    dock.matrix_world = Matrix.Translation((0, s[1], s[0])) @ Matrix.Rotation(math.radians(s[2]), 4, "X") @ dock.matrix_world
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.display.shading.light = "STUDIO"
    sc.render.resolution_x, sc.render.resolution_y = 480, 360
    target = Vector((0, s[1], s[0]))
    for view, eye, ortho in (("side", Vector((3, 0, 0)), 0.5), ("iso", Vector((1.2, 2.2, 1.4)), 0.5), ("wide", Vector((3, 1.5, 1.2)), 4.0)):
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


def load_mask(name, cache={}):
    """textureMask（相對 media/textures）→ (寬, 高, RGBA float 列表)；找不到回 None。"""
    path = os.path.join(MEDIA, "textures", name + ".png")
    if path not in cache:
        cache[path] = None
        if os.path.exists(path):
            img = bpy.data.images.load(path)
            cache[path] = (img.size[0], img.size[1], list(img.pixels))
    return cache[path]


def main():
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
    lines = [
        "-- 由 scripts/blender/dock_spots.py 從原版車輛網格產生，不要手改；PZ 更新換了車輛網格後重跑。",
        "-- 鍵＝車輛腳本 model 區塊的 file；值＝{ 高, 前後, 玻璃後傾角(度) }：零件模型 offset 的 y、z",
        "-- （車輛模型的未縮放單位）與 rotate.x 的大小，固定座放在擋風玻璃外表面上緣中央。",
        "-- 原版車窗是不透明貼圖，裝在玻璃內側的模型看不到，所以畫在玻璃外表面上。",
        'require "MinidoracatKnoxPass/Core"',
        "local KP = MinidoracatKnoxPass",
        "KP.DOCK_SPOTS = {",
    ]
    for file, y, z, tilt in rows:
        lines.append('    ["%s"] = { %.4f, %.4f, %.1f },' % (file, y, z, tilt))
    lines.append("}")
    open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("SKIPPED", len(skipped), skipped)
    print("DONE", len(rows), "->", OUT)


main()
