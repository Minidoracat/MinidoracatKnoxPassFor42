# Knox Pass 兩層樓雙開大門（gate）資產

五種外觀（A 鐵管框＋鐵網、B 實心鋼板＋橫肋、C 黑色直條矛頭欄杆、D 牧場木門、E 中世紀橡木拱門）× 6／9 格寬 × N／W／S／E。整合用的完整資料在 `manifest.json`；共用數字與格位座標在 `spec.py`。

## 重建（在本目錄執行；`blender` = Blender 5.2 `blender.exe`）

```text
python spec.py                                                  # 自我檢查：block 編號、translate、格位
uv run --with pillow python atlas.py                            # textures/MinidoracatKnoxPass_gate_{A..E}.png
blender -b --factory-startup --python build_gate.py             # export/*.glb（門扇、門柱、讀頭掛柱）
blender -b --factory-startup --python verify_gate.py            # export/verify.txt，失敗 exit 1
blender -b --factory-startup --python render_gate.py            # cells/、previews/、icons/_render/（-- cells game icons reader 可單跑）
uv run --with pillow python assemble.py                         # icons/*.png（64×64）、預覽拼圖、manifest.json
```

前置：`../barrier/render_tiles.py`（相機、燈光、引擎擺放公式，直接 import）與 `../barrier/build_barrier.py`（`reader_post()`，只執行到第一個 `build_variant` 之前）。只讀不寫。

## 產物

| 檔案 | 內容 |
|---|---|
| `export/MinidoracatKnoxPass_gate_<外觀><寬>.glb` | 門扇模型，骨架 `Dummy01`：`PostBone`、`DoorBoneA`、`DoorBoneB`；clip `Open`／`Close` 各 6 秒（遊戲內約 4 秒） |
| `export/MinidoracatKnoxPass_gatepost_<外觀>.glb` | 門柱（兩端共用，對 x 對稱） |
| `export/knoxpass_reader_pillar_<外觀>.glb` | 讀頭掛在 end A 門柱的兩個車道向柱面上（讀頭物品貼圖） |
| `textures/MinidoracatKnoxPass_gate_<外觀>.png` | 512×512 atlas；只有 A 的鐵網有透明（二值 alpha） |
| `cells/<外觀><寬>/<面>/lane<k>.png`、`endA.png`、`endB.png` | 128×256 建造虛影格（只畫下層）；9 格寬的兩端格共用 6 格寬的檔（manifest 已指向共用檔） |
| `icons/gate_<外觀>_<寬>.png` | 64×64 entity 圖示 |
| `previews/` | 遊戲相機預覽（gitignored）：`<外觀><寬>_<N|S>_<closed|half|open>.png`、`sheet_*.png`、`cells_*.png`、`reader_<A|E>_<N|S>.png` |

## 鐵網透明的依據

`door` shader 對貼圖 alpha 做 `discard`（`media/shaders/door.frag`：`texSample.w < 0.01`），原版鐵網柵門的模型貼圖 `MODELS_fixtures_doors_fences_01.png` 有 64% 像素 alpha 0、model 腳本 `shader = door`，同一條路徑。所以 A 用 alpha 鏤空的雙面薄片（兩片相距 4 mm、法線相反，因為 door shader 開背面剔除，`IsoObjectModelDrawer.java:538-543`）。
