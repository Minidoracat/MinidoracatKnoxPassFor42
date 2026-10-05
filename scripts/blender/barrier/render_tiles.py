"""PZ 2x tile renders of the Knox Pass barrier + camera calibration against vanilla sprites.
用法：blender -b --factory-startup --python render_tiles.py [-- step ...]   (then: python assemble_previews.py)
steps: calibrate barrier game reader (default: all). `-- reader` re-renders only the door-post reader cells
(no Blender canvases needed by assemble_previews.py; previews of the reader on vanilla doors: reader_previews.py).

Camera = PZ 2x projection (IsoObjectModelDrawer.java:743-752, IsoUtils.java:72-76): orthographic,
elevation 30 deg, looking toward PZ north-west; 1 tile unit = 128/sqrt(2) = 90.51 px; 1 floor level
(2.44949 units) = 192 px. Scene axes: +X = PZ east, +Y = PZ north (= -PZ y), +Z = up.

Models are placed with the engine's spriteModels transform (see pz_matrix), so the renders double as a
check of the translate/rotate values we hand to spriteModels.txt:
  calib/*:  vanilla fixtures_doors_fences_01_{0,1}.glb with their vanilla spriteModels values
  barrier:  knoxpass_barrier_cabinet.glb on the cabinet tile, translate 0; knoxpass_barrier_arm.glb on
            lane tile 1 with translate = one tile back toward the cabinet (LAYOUTS); rotate N (0,180,0), W (0,-90,0).
  game:     previews/<N|W>_<closed|half|open>_game.png at the 2x scale (game default zoom) and *_zoom.png at 2.5x:
            asphalt ground with a tile grid, + knoxpass_barrier_lines.glb on lane tile 2 (translate two tiles back),
            lamp texture as the engine picks it (closed red; half = opening and open use knoxpass_barrier_green.png).
            Cells never include the road paint: 2D only shows in the build cursor.

Cells: 128x256, tile top corner at (64,192), centre at (64,224) — vanilla Tiles2x convention
(IsoObject.java:2174 offsetY = 96*tileScale; all 35k Tiles2x world tiles are 128x256).
Each cell is rendered on a 128x448 canvas (top corner at (64,384)) so geometry taller than one level can
go to an optional z+1 cell (rows 0..191 of the canvas); slicing by tile uses a world-position alpha mask.
Cell kinds: cabinet (cabinet model, state independent), lane1..3 (arm model inside that tile),
cabinet_arm (arm model inside the cabinet tile: the raised arm lives here), cabinet_ghost (cabinet + closed arm
inside the cabinet tile, depth-correct: the build-cursor cell for the cabinet tile, where the lamp sits).

reader:   cells/reader/reader_<i>.png, knoxpass_reader_post.glb on its host tile with the spriteModels values of
          build_barrier_tiles.py READER (READER_XFORM here, keep both in sync), plus a holdout plane on the host
          tile's north (i 0,1) or west (i 2,3) edge = the wall/door line: the far-face plate is hidden as the wall
          hides it in game. The 2D cell is only the build/no-model fallback; the 3D model is what the game draws.
"""
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

HERE = Path(__file__).resolve().parent
VANILLA = Path("D:/SteamLibrary/steamapps/common/ProjectZomboid/media/models_X/IsoObject")
PX = 128 / math.sqrt(2)             # pixels per tile unit (horizontal or vertical) at 2x
STATES = {"closed": 0.0, "a30": 30.0, "a60": 60.0, "open": 86.0}
LAYOUTS = {   # spriteModels rotate, translate per tile back toward the cabinet tile, tile k centre in scene coords
    "N": ((0.0, 180.0, 0.0), (-1.0, 0.0, 0.0), lambda k: (k, 0)),   # arm runs east (+x) along the north edge
    "W": ((0.0, -90.0, 0.0), (0.0, 0.0, 1.0), lambda k: (0, k)),    # arm runs north (-y) along the west edge
}
GAME = {"closed": (0.0, False), "half": (43.0, True), "open": (86.0, True)}   # deg, green lamp texture
EPS = 1e-4
# door-post reader variants: spriteModels rotate (translate is always the host tile's NW corner, READER_T):
# 0 N door, post at its west end (opening +x); 1 N, post at its east end (opening -x, host = tile east of the door);
# 2 W door, post at its north end (opening +y); 3 W, post at its south end (opening -y, host = tile south of it)
READER_XFORM = {0: (0.0, 180.0, 0.0), 1: (0.0, 0.0, 0.0), 2: (0.0, 90.0, 0.0), 3: (0.0, -90.0, 0.0)}
READER_T = (-0.5, 0.0, -0.5)


def pz_matrix(translate, rotate, scale=1.0):
    """Blender-space model (as exported to / imported from glb) -> scene, as the engine places it.
    glb is +Y up and assimp MAKE_LEFT_HANDED mirrors Z (FileTask_LoadMesh.java:113-120): L = (x, z, y).
    M = Rx(rx) Ry(-ry) Rz(rz) L (IsoObjectModelDrawer.java:190-203, JOML rotateXYZ).
    World offset from tile centre: dx = tx - M.x, dy = tz + M.z, up = ty + M.y
    (camera scale(-1.5,1.5,1.5)*rotY(pi) and translate(-difX, .., -difY), IsoObjectModelDrawer.java:747-751;
    undoCoreScale 0.6667 cancels the 1.5, ModelScript.java:106-108). Scene = (dx, -dy, up)."""
    S = Matrix(((1, 0, 0), (0, 0, 1), (0, 1, 0)))
    R = (Matrix.Rotation(math.radians(rotate[0]), 3, "X") @ Matrix.Rotation(math.radians(-rotate[1]), 3, "Y")
         @ Matrix.Rotation(math.radians(rotate[2]), 3, "Z"))
    P = Matrix(((-1, 0, 0), (0, 0, -1), (0, 1, 0)))
    m = (P @ R @ S * scale).to_4x4()
    m.translation = Vector((translate[0], -translate[2], translate[1]))
    return m


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE"
    sc.eevee.taa_render_samples = 32
    sc.render.film_transparent = True
    sc.render.filter_size = 1.0
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.view_settings.view_transform = "Standard"
    w = bpy.data.worlds.new("W")
    sc.world = w
    w.color = (1, 1, 1)
    if w.node_tree:
        w.node_tree.nodes["Background"].inputs["Color"].default_value = (1, 1, 1, 1)
        w.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.9
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 2.0
    sun.data.angle = math.radians(5)
    # light travels from PZ south-south-west, above: lights the visible south face most, east face less
    sun.rotation_euler = Vector((0.45, 0.75, -0.75)).to_track_quat("-Z", "Y").to_euler()
    sc.collection.objects.link(sun)
    cd = bpy.data.cameras.new("Cam")
    cd.type = "ORTHO"
    cd.clip_end = 100
    cam = bpy.data.objects.new("Cam", cd)
    sc.collection.objects.link(cam)
    sc.camera = cam
    d = Vector((-math.cos(math.radians(30)) / math.sqrt(2), math.cos(math.radians(30)) / math.sqrt(2),
                -math.sin(math.radians(30))))
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    cam["dir"] = d
    return sc


def aim(point, px, py, w, h, zoom=1.0):
    """Put scene point at canvas pixel (px, py) of a w x h render at the PZ 2x scale (x zoom)."""
    sc = bpy.context.scene
    cam = sc.camera
    sc.render.resolution_x, sc.render.resolution_y = w, h
    cam.data.sensor_fit = "AUTO"
    cam.data.ortho_scale = max(w, h) / (PX * zoom)
    rot = cam.rotation_euler.to_matrix()
    right, up, d = rot.col[0], rot.col[1], Vector(cam["dir"])
    centre = Vector(point) + right * ((w / 2 - px) / (PX * zoom)) + up * ((py - h / 2) / (PX * zoom))
    cam.location = centre - d * 30


def render(path):
    sc = bpy.context.scene
    path.parent.mkdir(parents=True, exist_ok=True)
    sc.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


def import_glb(path, matrix):
    """Import a glb and place its root (armature, or the mesh of a static model) with matrix."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(path))
    new = [o for o in bpy.data.objects if o not in before]
    for o in new:
        if o.name.startswith("Icosphere"):          # importer's bone display shape, not part of the asset
            bpy.data.objects.remove(o)
    root = next(o for o in bpy.data.objects if o in new and o.parent is None and not o.name.startswith("Icosphere"))
    root.matrix_world = matrix
    return root


def add_mask(rig):
    """Alpha = 1 only inside one tile footprint (world X/Y). Returns (centre inputs, half-size limit inputs)."""
    mesh = next(o for o in rig.children if o.type == "MESH")
    mat = mesh.data.materials[0]
    nt = mat.node_tree
    outn = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
    bsdf = outn.inputs["Surface"].links[0].from_node
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(geo.outputs["Position"], sep.inputs[0])
    inside = []
    centres = []
    for axis in ("X", "Y"):
        sub = nt.nodes.new("ShaderNodeMath"); sub.operation = "SUBTRACT"
        ab = nt.nodes.new("ShaderNodeMath"); ab.operation = "ABSOLUTE"
        lt = nt.nodes.new("ShaderNodeMath"); lt.operation = "LESS_THAN"; lt.inputs[1].default_value = 0.5 + EPS
        nt.links.new(sep.outputs[axis], sub.inputs[0])
        nt.links.new(sub.outputs[0], ab.inputs[0])
        nt.links.new(ab.outputs[0], lt.inputs[0])
        inside.append(lt)
        centres.append(sub.inputs[1])
    mul = nt.nodes.new("ShaderNodeMath"); mul.operation = "MULTIPLY"
    nt.links.new(inside[0].outputs[0], mul.inputs[0])
    nt.links.new(inside[1].outputs[0], mul.inputs[1])
    tr = nt.nodes.new("ShaderNodeBsdfTransparent")
    mix = nt.nodes.new("ShaderNodeMixShader")
    nt.links.new(mul.outputs[0], mix.inputs["Fac"])
    nt.links.new(tr.outputs[0], mix.inputs[1])
    nt.links.new(bsdf.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], outn.inputs["Surface"])
    if hasattr(mat, "surface_render_method"):
        mat.surface_render_method = "DITHERED"
    return centres, [n.inputs[1] for n in inside]


def pose(rig, deg):
    pb = rig.pose.bones["DoorBone"]
    pb.rotation_mode = "QUATERNION"
    b = pb.bone.matrix_local.to_3x3()
    pb.rotation_quaternion = (b.inverted() @ Matrix.Rotation(math.radians(-deg), 3, "Y") @ b).to_quaternion()
    if rig.animation_data:
        rig.animation_data.action = None
        for t in rig.animation_data.nla_tracks:
            t.mute = True
    bpy.context.view_layer.update()


def play_first_frame(rig, clip):
    """spriteModels 'animation = clip, animationTime = 0' -> first frame of that imported action."""
    ad = rig.animation_data
    for t in ad.nla_tracks:
        t.mute = True
    act = bpy.data.actions[clip]
    ad.action = act
    if hasattr(ad, "action_slot") and act.slots:
        ad.action_slot = act.slots[0]
    bpy.context.scene.frame_set(int(act.frame_range[0]))


def calibrate():
    # (sprite, model, translate, rotate, clip) exactly as in vanilla spriteModels.txt:1142-1180
    for sprite, model, translate, rotate, clip in (
            ("fixtures_doors_fences_01_1", "fixtures_doors_fences_01_1", (-0.4688, 0, -0.4453), (0, 0, 0), "Open"),
            ("fixtures_doors_fences_01_0", "fixtures_doors_fences_01_0", (-0.4609, 0, -0.4453), (0, -90, 0), "Open"),
            ("fixtures_doors_fences_01_3", "fixtures_doors_fences_01_1", (-0.4687, 0, -0.4453), (0, 0, 0), "Close"),
            ("fixtures_doors_fences_01_2", "fixtures_doors_fences_01_0", (-0.4609, 0, -0.4453), (0, -90, 0), "Close")):
        reset()
        rig = import_glb(VANILLA / f"{model}.glb", pz_matrix(translate, rotate))
        play_first_frame(rig, clip)
        aim((0, 0, 0), 64, 224, 128, 256)
        render(HERE / "vanilla_dump" / "calib" / f"{sprite}_render.png")


def barrier():
    for layout, (rotate, lane1_translate, tile_xy) in LAYOUTS.items():
        reset()
        cab = import_glb(HERE / "export" / "knoxpass_barrier_cabinet.glb", pz_matrix((0, 0, 0), rotate))
        lane1 = Matrix.Translation((*tile_xy(1), 0))
        rig = import_glb(HERE / "export" / "knoxpass_barrier_arm.glb", lane1 @ pz_matrix(lane1_translate, rotate))
        arm_mesh = next(o for o in rig.children if o.type == "MESH")
        centres, limits = add_mask(rig)
        canvas = HERE / "cells" / "_canvas"

        def cell(name, cx, cy):
            centres[0].default_value, centres[1].default_value = cx, cy
            aim((cx, cy, 0), 64, 416, 128, 448)
            render(canvas / f"{layout}_{name}.png")

        arm_mesh.hide_render = True                  # cabinet cell: cabinet only, same for every state
        cell("cabinet", *tile_xy(0))
        arm_mesh.hide_render = False
        for state, deg in STATES.items():
            pose(rig, deg)
            for lim in limits:                       # full composite: mask off; tile 0 top corner (128, 480)
                lim.default_value = 1e6
            aim((0, 0, 0), 128, 512, 448, 704)
            render(HERE / "previews" / f"{layout}_{state}_full.png")
            for lim in limits:
                lim.default_value = 0.5 + EPS
            if state == "closed":
                cell("cabinet_ghost", *tile_xy(0))
            cab.hide_render = True                   # arm cells: arm only, sliced by tile footprint
            cell(f"cabinet_arm_{state}", *tile_xy(0))
            for k in (1, 2, 3):
                cell(f"lane{k}_{state}", *tile_xy(k))
            cab.hide_render = False


def ground():
    """Asphalt plane with a faint 1-tile grid (scene units = tiles)."""
    bpy.ops.mesh.primitive_plane_add(size=24, location=(1.5, 0, 0))
    mat = bpy.data.materials.new("asphalt")
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 1.0
    geo, sep = nt.nodes.new("ShaderNodeNewGeometry"), nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(geo.outputs["Position"], sep.inputs[0])
    edge = []
    for axis in ("X", "Y"):   # distance to the nearest tile edge (edges at k + 0.5) < 0.012 -> grid line
        add, fr, sub, ab, lt = (nt.nodes.new("ShaderNodeMath") for _ in range(5))
        add.operation, fr.operation, sub.operation, ab.operation, lt.operation = "ADD", "FRACT", "SUBTRACT", "ABSOLUTE", "LESS_THAN"
        add.inputs[1].default_value, sub.inputs[1].default_value, lt.inputs[1].default_value = 0.5, 0.5, 0.488
        nt.links.new(sep.outputs[axis], add.inputs[0])
        nt.links.new(add.outputs[0], fr.inputs[0])
        nt.links.new(fr.outputs[0], sub.inputs[0])
        nt.links.new(sub.outputs[0], ab.inputs[0])
        nt.links.new(ab.outputs[0], lt.inputs[0])
        edge.append(lt)
    both = nt.nodes.new("ShaderNodeMath")
    both.operation = "MULTIPLY"
    nt.links.new(edge[0].outputs[0], both.inputs[0])
    nt.links.new(edge[1].outputs[0], both.inputs[1])
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.inputs["A"].default_value = (0.045, 0.047, 0.05, 1)   # grid line
    mix.inputs["B"].default_value = (0.075, 0.077, 0.08, 1)   # asphalt
    nt.links.new(both.outputs[0], mix.inputs["Factor"])
    nt.links.new(mix.outputs["Result"], bsdf.inputs["Base Color"])
    bpy.context.object.data.materials.append(mat)


def game():
    for layout, (rotate, step, tile_xy) in LAYOUTS.items():
        for state, (deg, lit) in GAME.items():
            reset()
            bpy.data.objects["Sun"].data.use_shadow = False   # PZ draws no model shadows
            ground()
            import_glb(HERE / "export" / "knoxpass_barrier_cabinet.glb", pz_matrix((0, 0, 0), rotate))
            lane = lambda k: Matrix.Translation((*tile_xy(k), 0)) @ pz_matrix(tuple(k * s for s in step), rotate)  # noqa: E731
            rig = import_glb(HERE / "export" / "knoxpass_barrier_arm.glb", lane(1))
            import_glb(HERE / "export" / "knoxpass_barrier_lines.glb", lane(2))
            if lit:   # spriteModels texture = IsoObject/MinidoracatKnoxPass_barrier_green on open tiles / opening poses
                img = bpy.data.images.load(str(HERE / "textures" / "knoxpass_barrier_green.png"))
                mesh = next(o for o in rig.children if o.type == "MESH")
                for n in mesh.data.materials[0].node_tree.nodes:
                    if n.type == "TEX_IMAGE":
                        n.image = img
            pose(rig, deg)
            aim((0, 0, 0), 180, 450, 640, 640)
            render(HERE / "previews" / f"{layout}_{state}_game.png")
            if layout == "N" and state in ("closed", "open"):   # 2.5x: tile 0 centre at (300, y), all paint in frame
                aim((0, 0, 0), 300, 870 if state == "open" else 380, 1280, 1260 if state == "open" else 760, zoom=2.5)
                render(HERE / "previews" / f"{layout}_{state}_zoom.png")


def holdout_wall(north):
    """Vertical holdout plane, one floor high, on the host tile's north (scene y = +0.5) or west (x = -0.5) edge."""
    bpy.ops.mesh.primitive_plane_add(size=1)
    p = bpy.context.object
    p.scale = (6.0, 2.45, 1.0)
    if north:
        p.location, p.rotation_euler = (0.0, 0.5, 1.225), (math.radians(90), 0.0, 0.0)
    else:
        p.location, p.rotation_euler = (-0.5, 0.0, 1.225), (math.radians(90), 0.0, math.radians(90))
    mat = bpy.data.materials.new("holdout")
    nt = mat.node_tree
    out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
    nt.links.new(nt.nodes.new("ShaderNodeHoldout").outputs[0], out.inputs["Surface"])
    p.data.materials.append(mat)


def reader():
    for i, rotate in READER_XFORM.items():
        reset()
        import_glb(HERE / "export" / "knoxpass_reader_post.glb", pz_matrix(READER_T, rotate))
        holdout_wall(i < 2)
        aim((0, 0, 0), 64, 224, 128, 256)
        render(HERE / "cells" / "reader" / f"reader_{i}.png")


STEPS = {"calibrate": calibrate, "barrier": barrier, "game": game, "reader": reader}
for step in (sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else STEPS):
    STEPS[step]()
print("[render_tiles] done")
