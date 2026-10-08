# barrier2：雙臂抬升閘門（寬 6／9，N／W）

一個寬度一個動畫模型（`export/knoxpass_barrier2_boom{6,9}.glb`）：兩支臂各從自己那端的機箱伸到車道列中央相接、臂端支柱放在 3 格車道組的交界（6 寬一根 x=3.5，9 寬兩根 x=3.5／6.5，車在任何車道組都不會穿過支柱）、兩面 STOP 牌、兩顆轉軸燈，加上路面標線（每 3 格車道一組停止線＋KNOX PASS，閘線兩側，字腳朝來車）。機箱沿用單臂閘門的 `MinidoracatKnoxPass_BarrierCabinet`，貼圖沿用 `MinidoracatKnoxPass_barrier{,_green}`（同一張 atlas、同一套 UV，不另出貼圖）。接線用的所有數值在 `manifest.json`。

## 重建（在本目錄執行，`blender` = Blender 5.2 的 blender.exe）

```bash
blender -b --factory-startup --python build_barrier2.py    # export/*.glb
KNOXPASS_FAST=1 blender -b --factory-startup --python build_barrier2.py   # export/*_fast.glb（每扇門可選的「加速」，clip 3.75 s）
blender -b --factory-startup --python verify_barrier2.py   # export/verify.txt（重新匯入：骨架、clip、兩臂角度、尺寸，失敗即中止）
blender -b --factory-startup --python render_barrier2.py   # cells/<寬><向>/*.png、previews/*.png
uv run --with pillow python manifest.py                    # icons/boom_barrier_{6,9}.png、manifest.json
```

前置：`../barrier/` 的 `textures/`（atlas.py）與 `export/knoxpass_barrier_cabinet.glb`（build_barrier.py）已存在。本目錄的腳本只讀那邊的檔案，不寫入。

## 產物

| 路徑 | 內容 |
|---|---|
| `export/knoxpass_barrier2_boom{6,9}.glb` | 模型；出貨名 `models_X/IsoObject/MinidoracatKnoxPass_barrier2_boom{6,9}.glb` |
| `export/verify.txt` | 重新匯入的檢查紀錄 |
| `cells/{6N,6W,9N,9W}/lane<k>.png`、`endA.png`、`endB.png` | 128×256 建造虛影格（替代 tile 16+k-1、端點 3／4） |
| `icons/boom_barrier_{6,9}.png` | 64×64 建造選單圖示 |
| `previews/<寬><向>_{closed,half,open}_game.png` | 遊戲鏡頭預覽（open 附 2×4.5 格車輛方塊比例） |
| `previews/<寬>N_icon_src.png` | 圖示原圖 |
