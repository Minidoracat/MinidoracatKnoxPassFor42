# Minidoracat Knox Pass for B42

車輛裝上感應器、大門裝上讀頭，開車靠近就自動開門，不必下車也不必按鍵；單人與多人皆可用

Project Zomboid Build 42 MOD。

## 需要

- [Minidoracat UI Library for B42](https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701)（管理視窗）

## 功能

- **車用感應盒**：真正的車輛零件，原版與 MOD 車都能裝，從車輛維修面板「Knox Pass」分類拆裝；內建電池，車子發動時由電瓶充電。
- **大門讀頭**：對大門按右鍵安裝（需要螺絲起子）；支援地圖上的門、柵欄門、雙開門、車庫門與玩家建造的門。
- **各門各自登記**：讀頭擁有者在管理視窗登記附近裝了感應盒的車；登記跟著感應盒走，換車照樣通行。
- **自動開關門**：有人駕駛、裝著已登記感應盒的車靠近就開門，駛離後自動關；會依車速提前開門，自動駕駛不必停車；門口有車或有人時不關。
- **大門門鎖**：可設成只有 Knox Pass 開得了；步行時也能用右鍵「用 Knox Pass 開門」。
- **伺服器可調**：感應距離、行進預測、自動駕駛提早開門距離、關門延遲、供電需求、感應盒耗電、製作與搜刮開關。
- **給其他 MOD**：`KnoxPassAPI.registerGateAdapter` 可讓自訂的門接入 Knox Pass；`KnoxPassAPI.willOpenFor(vehicle, obj)` 讓自駕 MOD 在客戶端查「這扇門會不會替這台車開」（`KnoxPassAPI.VERSION >= 2`，預告不是保證，呼叫端仍要能在門前停住）。介面說明見 `42/media/lua/shared/MinidoracatKnoxPass/Gates.lua` 檔尾。

## 安裝

- Steam Workshop：（首次上傳後補上連結）
- 手動安裝：把 `MOD/MinidoracatKnoxPassFor42/Contents/mods/MinidoracatKnoxPassFor42` 複製到 `%USERPROFILE%\Zomboid\mods\` 並將資料夾改名為 `MinidoracatKnoxPassFor42`

## 開發

- `link_workshop.bat`：手動同步、唯讀狀態與歸檔卸載；MOD 以實體副本放入 `Zomboid\Workshop\` 與 `Zomboid\mods\`，不使用目錄連結
- `PZ_Test.bat`：暗色點選視窗，啟動前增量同步目前 MOD 與家族依賴；首次預設 no-Steam，之後記住各專案的選擇。需要換檔但遊戲仍在執行時拒絕同步與新啟動，不停止既有遊戲；完整驗證與資料邊界見 `../pz-family-docs/tools.md`
- `Publish_Workshop.bat`：發布到 Steam Workshop（需 Steam 用戶端已登入；可選擇只更新內容／封面／簡介；首發仍走遊戲內上傳器）

## 版本

版本號格式：`{PZ 版本}-{mod 版本}`（例 `42.21.0-0.1.0`），詳見 [CHANGELOG.md](CHANGELOG.md)。

## 作者

Minidoracat — [Discord](https://discord.gg/Gur2V67) | [Twitch](https://www.twitch.tv/minidoracat)
