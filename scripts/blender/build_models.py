"""Blender 5.2 headless：建 Knox Pass 三個低面數模型、匯出 FBX（一次），再逐色換貼圖渲染圖示原圖與預覽。
由 build.py 呼叫：blender --background --factory-startup --python build_models.py -- <media> <out> <suffix>...
（suffix 依 build.py COLORS 的順序，米白是空字串；貼圖讀 MOD 裡剛寫好的 textures/WorldItems/*<suffix>.png）

座標慣例（Blender，Z 上）：
- 物品（WorldItems）：平躺在地，原點在底面中心，單位公尺；腳本 scale = 1.0。
- 車上（vehicles）：車頭朝 +Y、車頂朝 +Z（原版車輛 FBX 匯入 Blender 也是這個方向）；
  原點＝固定座貼擋風玻璃那一面的上緣中心，Lua 用車輛腳本幾何算出這一點的位置。
匯出：FBX_SCALE_UNITS＋bake_space_transform，軸 -Z 前／Y 上 → 頂點直接是公尺、節點變換全是單位矩陣
（PZ 用 assimp 讀，套節點變換但不套 UnitScaleFactor）。
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
ARGS = sys.argv[sys.argv.index("--") + 1:]
MEDIA, OUT, SUFFIXES = ARGS[0], ARGS[1], ARGS[2:]
BARRIER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "barrier")

# 與 build.py 相同的貼圖格局（像素，左上原點）
TAG_TEX, READER_TEX = 512, 512
TAG_FRONT, TAG_BACK = (0, 0, 512, 322), (0, 330, 256, 491)
TAG_SW = {"shell": 272, "edge": 312, "dock": 352, "pad": 392, "gold": 432, "wire": 472}
READER_FACE, READER_JLBL = (0, 0, 320, 320), (336, 0, 496, 100)
READER_SW = {"radome": 0, "side": 48, "steel": 96, "jbox": 144, "cable": 192}

TAG_W, TAG_H, TAG_T, TAG_R = 0.086, 0.054, 0.010, 0.0045


def rect_uv(rect, tex, u, v):
    x0, y0, x1, y1 = rect
    return ((x0 + u * (x1 - x0)) / tex, 1.0 - (y1 - v * (y1 - y0)) / tex)


def swatch(x, y, size, tex):
    return (x + 4, y + 4, x + size - 4, y + size - 4), tex


class MB:
    """逐面獨立頂點（平滑群組＝每面一組），每個 loop 自帶 UV。"""

    def __init__(self):
        self.verts, self.faces, self.uvs = [], [], []

    def face(self, pts, uvs):
        base = len(self.verts)
        self.verts += [tuple(p) for p in pts]
        self.faces.append(list(range(base, base + len(pts))))
        self.uvs.append(list(uvs))

    def box(self, lo, hi, uvf):
        """uvf(name) -> (rect, tex)；name in +x -x +y -y +z -z。整面對到 rect。"""
        (x0, y0, z0), (x1, y1, z1) = lo, hi
        quads = {
            "+z": [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
            "-z": [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)],
            "-y": [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
            "+y": [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
            "+x": [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
            "-x": [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
        }
        for name, q in quads.items():
            rect, tex = uvf(name)
            self.face(q, [rect_uv(rect, tex, u, v) for u, v in ((0, 0), (1, 0), (1, 1), (0, 1))])

    def transform(self, m, start=0):
        for i in range(start, len(self.verts)):
            self.verts[i] = tuple(m @ Vector(self.verts[i]))

    def build(self, name, image):
        me = bpy.data.meshes.new(name)
        me.from_pydata(self.verts, [], self.faces)
        me.update()
        uv = me.uv_layers.new(name="UVMap")
        li = 0
        for poly, fuv in zip(me.polygons, self.uvs):
            for k, loop in enumerate(poly.loop_indices):
                uv.data[loop].uv = fuv[k]
            li += 1
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes["Principled BSDF"]
        img = mat.node_tree.nodes.new("ShaderNodeTexImage")
        img.image = image
        img.interpolation = "Closest"
        mat.node_tree.links.new(img.outputs["Color"], bsdf.inputs["Base Color"])
        bsdf.inputs["Roughness"].default_value = 0.6
        me.materials.append(mat)
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        return ob


def rounded_rect(w, h, r, seg=3):
    pts = []
    for cx, cy, a0 in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180), (w / 2 - r, -h / 2 + r, 270)):
        for k in range(seg + 1):
            a = math.radians(a0 + 90 * k / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts  # 逆時針


def tag_shell(mb):
    """平躺的感應盒本體：z 0..T，正面（+Z）是標籤，文字沿 +X、標籤上緣朝 +Y。"""
    out = rounded_rect(TAG_W, TAG_H, TAG_R)
    top = [(x, y, TAG_T) for x, y in out]
    mb.face(top, [rect_uv(TAG_FRONT, TAG_TEX, (x + TAG_W / 2) / TAG_W, (y + TAG_H / 2) / TAG_H) for x, y in out])
    bot = [(x, y, 0.0) for x, y in reversed(out)]   # 翻面看：左右對調
    mb.face(bot, [rect_uv(TAG_BACK, TAG_TEX, 1 - (x + TAG_W / 2) / TAG_W, (y + TAG_H / 2) / TAG_H) for x, y in reversed(out)])
    er, et = swatch(TAG_SW["edge"], 330, 32, TAG_TEX)
    for i in range(len(out)):
        (ax, ay), (bx, by) = out[i], out[(i + 1) % len(out)]
        mb.face([(ax, ay, 0), (bx, by, 0), (bx, by, TAG_T), (ax, ay, TAG_T)],
                [rect_uv(er, et, u, v) for u, v in ((0, 0), (1, 0), (1, 1), (0, 1))])


def sw_tag(name):
    return lambda _face: swatch(TAG_SW[name], 330, 32, TAG_TEX)


def sw_reader(name):
    return lambda _face: swatch(READER_SW[name], 336, 40, READER_TEX)


def load_image(path):
    img = bpy.data.images.load(path, check_existing=True)
    return img


def export(ob, path):
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.export_scene.fbx(filepath=path, use_selection=True, object_types={"MESH"},
                             apply_scale_options="FBX_SCALE_UNITS", bake_space_transform=True,
                             axis_forward="-Z", axis_up="Y", mesh_smooth_type="FACE",
                             add_leaf_bones=False, bake_anim=False, path_mode="STRIP")
    print("exported", path)


def render_icon(ob, out, az, el, ortho):
    """工作台引擎、正交相機、透明底；build.py 再縮成 32x32 加外框。"""
    sc = bpy.context.scene
    for o in sc.collection.objects:
        o.hide_render = o is not ob and o.type == "MESH"
    sc.render.engine = "BLENDER_WORKBENCH"
    sh = sc.display.shading
    sh.light = "STUDIO"
    sh.color_type = "TEXTURE"
    sh.show_cavity = False
    sc.render.film_transparent = True
    sc.render.resolution_x = sc.render.resolution_y = 256
    sc.view_settings.view_transform = "Standard"
    lo = Vector((min(v.co.x for v in ob.data.vertices), min(v.co.y for v in ob.data.vertices), min(v.co.z for v in ob.data.vertices)))
    hi = Vector((max(v.co.x for v in ob.data.vertices), max(v.co.y for v in ob.data.vertices), max(v.co.z for v in ob.data.vertices)))
    target = (lo + hi) / 2
    cd = bpy.data.cameras.new("IconCam")
    cd.type = "ORTHO"
    cd.ortho_scale = ortho
    cam = bpy.data.objects.new("IconCam", cd)
    sc.collection.objects.link(cam)
    a, e = math.radians(az), math.radians(el)
    cam.location = target + Vector((math.cos(e) * math.sin(a), -math.cos(e) * math.cos(a), math.sin(e))) * 2
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    sc.camera = cam
    sc.render.filepath = out
    bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(cam)


def tex(kind, sfx):
    return os.path.join(MEDIA, "textures", "WorldItems", f"MinidoracatKnoxPass{kind}{sfx}.png")


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    tag_img = load_image(tex("Tag", ""))
    reader_img = load_image(tex("Reader", ""))

    # 1. 感應盒物品（地上／手上）
    mb = MB()
    tag_shell(mb)
    tag = mb.build("MinidoracatKnoxPassTag", tag_img)
    export(tag, os.path.join(MEDIA, "models_X", "WorldItems", "MinidoracatKnoxPassTag.fbx"))

    # 2. 車上：擋風玻璃固定座＋感應盒
    mb = MB()
    tag_shell(mb)
    mb.transform(Matrix.Rotation(math.radians(90), 4, "X"))  # 標籤朝 -Y（車內）、上緣朝 +Z；本體 y∈[-T,0]
    top = TAG_H / 2
    mb.box((-0.036, 0.0, top - 0.012), (0.036, 0.006, top + 0.004), sw_tag("dock"))            # 固定座
    mb.box((-0.033, 0.006, top - 0.010), (0.033, 0.0075, top + 0.002), sw_tag("pad"))           # 黏貼墊
    for sx in (-1, 1):                                                                           # 兩側卡榫
        mb.box((sx * 0.0395 - 0.003, -TAG_T - 0.002, top - 0.012), (sx * 0.0395 + 0.003, 0.006, top + 0.002), sw_tag("dock"))
    mb.box((0.031, 0.002, top + 0.004), (0.035, 0.005, top + 0.030), sw_tag("wire"))             # 電源線往車頂內襯
    mb.transform(Matrix.Translation((0, -0.0075, -(top + 0.002))))                                # 原點＝黏貼墊上緣中心
    # 不在模型裡烘傾角：各車型擋風玻璃後傾 22–66°，由 Parts.lua 寫零件 model 的 rotate（DockSpots.lua 的第 3 欄）
    dock = mb.build("MinidoracatKnoxPassTagDock", tag_img)
    export(dock, os.path.join(MEDIA, "models_X", "vehicles", "MinidoracatKnoxPassTagDock.fbx"))

    # 3. 讀頭物品：平板天線罩面朝上，接線盒與線放在下緣旁
    mb = MB()
    mb.box((-0.135, -0.135, 0.0), (0.135, 0.135, 0.02), sw_reader("steel"))                      # 背框
    face = lambda n: (READER_FACE, READER_TEX) if n == "+z" else swatch(READER_SW["side" if n != "-z" else "steel"], 336, 40, READER_TEX)
    mb.box((-0.125, -0.125, 0.012), (0.125, 0.125, 0.052), face)                                 # 天線罩（標帶在 -Y 側）
    mb.box((-0.025, 0.135, 0.004), (0.025, 0.19, 0.04), sw_reader("steel"))                      # 抱箍支架
    jb = lambda n: (READER_JLBL, READER_TEX) if n == "+z" else swatch(READER_SW["jbox"], 336, 40, READER_TEX)
    mb.box((0.0, -0.275, 0.0), (0.12, -0.165, 0.07), jb)                                         # 接線盒
    for (x0, y0), (x1, y1) in (((0.02, -0.13), (0.03, -0.15)), ((0.026, -0.152), (0.036, -0.168))):
        mb.box((min(x0, x1), min(y0, y1), 0.02), (max(x0, x1) + 0.008, max(y0, y1), 0.032), sw_reader("cable"))
    reader = mb.build("MinidoracatKnoxPassReader", reader_img)
    export(reader, os.path.join(MEDIA, "models_X", "WorldItems", "MinidoracatKnoxPassReader.fbx"))

    # 網格與 FBX 只建一次（米白貼圖）；各色只在模型腳本換 texture，這裡換同一張 image 的來源檔重渲
    for sfx in SUFFIXES:
        tag_img.filepath, reader_img.filepath = tex("Tag", sfx), tex("Reader", sfx)
        tag_img.reload()
        reader_img.reload()
        render_icon(tag, os.path.join(OUT, f"icon_tag{sfx}.png"), az=-25, el=58, ortho=0.11)
        render_icon(reader, os.path.join(OUT, f"icon_reader{sfx}.png"), az=-25, el=52, ortho=0.5)
        # 預覽（人看的，不進 MOD）：車上、地上（PZ 鏡頭方位 az 45 / 仰角 30，render_tiles.py 的相機方向）
        render_icon(dock, os.path.join(OUT, f"preview_dock{sfx}.png"), az=180 - 30, el=20, ortho=0.12)
        render_icon(tag, os.path.join(OUT, f"ground_tag{sfx}.png"), az=45, el=30, ortho=0.11)
        render_icon(reader, os.path.join(OUT, f"ground_reader{sfx}.png"), az=45, el=30, ortho=0.5)
    # 門柱讀頭：與 2D 格同一支渲染（PZ 2x 投影），貼圖換成該色；render_tiles 會重設場景，所以放最後
    sys.path.insert(0, BARRIER)
    import render_tiles
    for sfx in SUFFIXES:
        render_tiles.reader(tex=tex("Reader", sfx), out=os.path.join(OUT, f"post{sfx}"), variants=(0,))
    print("BUILD OK")


main()
