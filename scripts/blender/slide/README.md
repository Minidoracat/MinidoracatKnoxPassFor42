# 滑動大門（slide）資產

單扇側滑的大門：門扇沿門線滑進一端外側的「收納段」。數值都在 `spec.py`，其他腳本只讀它。
遊戲端的格位、tile、entity 由 `scripts/build_model_gates.py` 讀這裡的 `manifest.json` 產生。

## 重建

在這個資料夾執行（`B="C:/Program Files/Blender Foundation/Blender 5.2/blender.exe"`）：

```bash
python spec.py                                                   # 印 spec ok
"$B" -b --factory-startup --python build_slide.py                # export/*.glb
KNOXPASS_FAST=1 "$B" -b --factory-startup --python build_slide.py   # export/*_fast.glb（加速版 clip）
"$B" -b --factory-startup --python verify_slide.py               # export/verify.txt 結尾 ALL OK
"$B" -b --factory-startup --python render_slide.py -- cells game icons
uv run --with pillow python assemble.py                          # icons/*.png、manifest.json
```

之後在 repo 根目錄跑 `uv run scripts/build_barrier_tiles.py`，再跑 `--check`。

## 產物

| 檔案 | 內容 |
|---|---|
| `export/MinidoracatKnoxPass_slide<樓層>_<外觀><寬>.glb`、`_fast.glb` | 門柱＋門扇，clip 4.0／2.5 秒；左收、右收共用 |
| `export/MinidoracatKnoxPass_slidepost<樓層>_<外觀>.glb` | 兩端門柱的靜止模型 |
| `cells/<外觀><樓層>/<N\|W\|S\|E>/{lane,endA,endB,stow}.png` | 建造虛影的 2D 圖格；各寬度與左右收共用 |
| `icons/slide<樓層>_<外觀>_<寬><l\|r>.png` | 建造選單圖示；`r` 是 `l` 的鏡像 |
| `manifest.json` | kind、tileset、每個方向的 block、柱面讀頭位置、格位 14（收納段標記畫的開著門扇）的 translate |
| `previews/`（不進 git） | 四向 × 關／半開／全開的檢查圖 |

## 要記得的事

- 2D 圖格與圖示用 Cycles CPU 算（開發機沒有 GPU，EEVEE 起不來）。只影響建造虛影與圖示，遊戲裡畫的是 glb。
- 右收＝同一個 glb 轉 180°：原點放另一端，往門線移 `2 × LEAF_Y`。`build_model_gates.py --check` 會核對這個關係。
- 門扇中心離門線 0.09 格（`LEAF_Y = 0.41`），門柱中心 `POST_Y = 0.105`。門扇在門柱與門線之間滑。
- 收納段的格子只在建造時佔位：tile 在 `OnCreate` 當場移除。只有第 `stow_host(寬)`＝寬／2 格留一個沒有屬性的標記物件（透明 tile，格位 6）：
  門開著靜止時由它畫門扇（格位 14，`spec.py stow_translate`），鏡頭拉近、掛模型的中間片出畫面時門扇才不會整片不見。
- `gate/spec.py` 以路徑載入成 `S.G`（兩個資料夾的檔名都叫 `spec.py`）。
