# roll2f：兩層樓高捲門模型

Knox Pass r4 的兩層樓捲門（tileset `MinidoracatKnoxPass_roll2f`，編號 5；寬 3／4／6／9；款式 Industry／Green／White；N、W 兩向）。整合者要的東西全部在 `manifest.json`；本目錄只產生素材，不寫 `MOD/`。

## 重建（在本目錄執行；`blender` = `C:/Program Files/Blender Foundation/Blender 5.2/blender.exe`）

```bash
uv run --with pillow python atlas.py                              # textures/knoxpass_roll2f_{industry,green,white}.png
blender -b --factory-startup --python build_roll2f.py             # export/knoxpass_roll2f_{3,4,6,9}.glb
KNOXPASS_FAST=1 blender -b --factory-startup --python build_roll2f.py   # export/knoxpass_roll2f_{3,4,6,9}_fast.glb（「加速」，clip 3.75 s）
blender -b --factory-startup --python verify_roll2f.py            # export/knoxpass_roll2f_verify.txt（FAIL 時 exit 1）
blender -b --factory-startup --python render_roll2f.py            # cells/_canvas、previews/icon_*、previews/game_*
uv run assemble_roll2f.py                                         # cells/、icons/、previews/sheet_*、ghost_*、manifest.json
```

`atlas.py` 從原版 `Tiles2x.pack` 取色（import `scripts/build_barrier_tiles.py` 的 `vanilla_cells`，唯讀）。`render_roll2f.py` 的相機、引擎擺放公式、tile 遮罩 import 自 `../barrier/render_tiles.py`。

## 做法與出處

- 行程曲線：共用的 `scripts/blender/ease.py`（梯形速度，前後各 20% 加減速），烤進關鍵格；Open 用 `TRAVEL × ease(t)`，Close 用 `TRAVEL × ease(1 − t)`。每 2 格一個 key 就夠：加減速段的線性內插誤差最多 0.65 mm。
- 動畫：32 根 slat 骨頭，每根沿「導軌直上 → 繞捲軸」的路徑做位移＋旋轉 key。骨頭縮放不能用：匯入會讀 scale key（`ImportedSkeleton.java:206-235`），但 `AnimationPlayer.updateBoneAnimationTransform_Internal` 只混合位置與旋轉，scale 一律單位值（`AnimationPlayer.java:1209-1273`）。
- 骨頭上限：`door.vert` 是 `uniform mat4 MatrixPalette[60]`，骨架＝`Dummy01`＋其下所有節點（`ImportedSkeleton.java:57-112`），本模型用 34 個。
- 開到底時整片捲簾都在捲軸箱內（`verify_roll2f.py` 每一格都檢查）；淨空高 4.29 格（箱底），寬 L−0.2 格。
- 2D 格只畫下層（一層樓高、沿樓層線切），理由見 `assemble_roll2f.py` 檔頭。
