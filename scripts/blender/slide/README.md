# 滑動大門（slide）資產

單扇側滑的大門：門扇沿門線滑進一端外側的「收納段」。數值都在 `spec.py`，其他腳本只讀它。
遊戲端的格位、tile、entity 與 16 語門名由 `scripts/build_model_gates.py` 讀這裡的 `manifest.json` 產生。

款式＝樓層（1、2）× 寬組（3／4 格、6 格）× 外觀 × 左右收。外觀 `LOOKS`：A 鐵網、B 鋼板、C 鐵欄杆、D 木板、F 工業黃、G 帶刺鐵絲網、
ABlack 黑色鐵網（A 的模型換貼圖，配方多一罐黑漆，`PAINT`）。出貨後要加外觀：加在 `LOOKS` 最後，`build_model_gates.py` 的
`NUMBERS` 另加編號（不進原本的 `product`，已出貨的編號不能動），Lua `Core.lua` 的 `SLIDE_LOOKS` 與產生器的門名表各補一項。

## 重建

在這個資料夾執行（`B="C:/Program Files/Blender Foundation/Blender 5.2/blender.exe"`）：

```bash
python spec.py                                                   # 印 spec ok
uv run --with pillow python atlas.py                             # textures/MinidoracatKnoxPass_slide_<外觀>.png
"$B" -b --factory-startup --python build_slide.py                # export/*.glb
KNOXPASS_FAST=1 "$B" -b --factory-startup --python build_slide.py   # export/*_fast.glb（加速版 clip）
"$B" -b --factory-startup --python verify_slide.py               # export/verify.txt 結尾 ALL OK
"$B" -b --factory-startup --python render_slide.py -- cells icons game   # 約 10 分鐘（Cycles CPU）
uv run --with pillow python assemble.py                          # icons/*.png、manifest.json、previews/sheet_*.png
```

之後在 repo 根目錄跑 `uv run scripts/build_barrier_tiles.py`，再跑 `--check`。

## 產物

| 檔案 | 內容 |
|---|---|
| `textures/MinidoracatKnoxPass_slide_<外觀>.png` | 大門的貼圖加機箱兩色（`atlas.py`）；F 多警示斜紋，G 多刺絲，ABlack 是 A 塗黑 |
| `export/MinidoracatKnoxPass_slide<樓層>_<外觀><寬>.glb`、`_fast.glb` | 只有門扇，clip 6.0／3.75 秒（遊戲內 4.0／2.5 秒）；左收、右收共用；ABlack 用 A 的 |
| `export/MinidoracatKnoxPass_slidepost<樓層>_<外觀>.glb` | 門扇關上去那一端的門柱（讀頭掛這根） |
| `export/MinidoracatKnoxPass_slidemotor<樓層>_<外觀>.glb` | 收的那一端的門柱：後面多一個機箱，在門柱自己那格內 |
| `cells/<外觀><樓層>/<N\|W\|S\|E>/{lane,endA,endB,motorA,motorB,stow}.png` | 建造虛影的 2D 圖格；各寬度與左右收共用，`motor*` 是帶機箱的那一端 |
| `icons/slide<樓層>_<外觀>_<寬><l\|r>.png` | 建造選單圖示；`r` 是 `l` 的鏡像 |
| `manifest.json` | kind、tileset、每個方向的 block、貼圖、柱面讀頭位置、格位 14（門扇改掛在收納段標記上的 translate，產生器只讀這個偏移） |
| `previews/`（不進 git） | 關／半開／全開的檢查圖；只有 `PREVIEW_ALL` 的兩款畫五個方向，其餘只畫 N 向左收 |

## 要記得的事

- 2D 圖格與圖示用 Cycles CPU 算（開發機沒有 GPU，EEVEE 起不來）。只影響建造虛影與圖示，遊戲裡畫的是 glb。
- 右收＝同一個 glb 轉 180°：原點放另一端，往門線移 `2 × LEAF_Y`。`build_model_gates.py --check` 會核對這個關係。
- 門扇中心離門線 0.09 格（`LEAF_Y = 0.41`），門柱中心 `POST_Y = 0.105`。門扇在門柱與門線之間滑。
- 七款外觀的門柱一樣粗（`POST_HW = 0.17`，木板款也是）：柱面讀頭只要一款（`reader_mount` 一項，Lua `def.pillar`）。
- 收在哪一端：`stow_at_a(face, side)`，Lua `KP.stowAtA`。機箱在收的那一端，讀頭掛另一端（收在 A 端時 A 端柱面被機箱擋住）。
- 鐵欄杆的矛頭與刺絲都收在 `TOP` 以內：門扇要從門柱的導輪臂底下滑過。
- 收納段的格子只在建造時佔位：tile 在 `OnCreate` 當場移除。只有第 `stow_host(寬)`＝寬／2 格留一個沒有屬性的標記物件（透明 tile，格位 6）。
  掛模型的中間片那格不在畫面上、標記那格在畫面上時，門扇改由標記畫：鏡頭拉近站在收納段旁，開著、關著、滑到一半都看得到。
  標記用的格位（靜止 7／15、打開 41–47、關上 57–63）由 `build_model_gates.py` 從格位 14 的偏移（`spec.py stow_translate`）算出，只進 `spriteModels.txt`。
- `gate/spec.py` 以路徑載入成 `S.G`（兩個資料夾的檔名都叫 `spec.py`）。
