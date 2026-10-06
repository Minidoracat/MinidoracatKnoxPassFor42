# Minidoracat Knox Pass for B42

車輛裝上感應盒、大門裝上讀頭，開車靠近就自動開門，不必下車也不必按鍵；單人與多人皆可用

Project Zomboid Build 42 MOD。

名稱取自遊戲舞台肯塔基州的 Knox 郡，加上美國電子收費卡的命名習慣（E-ZPass、TollTag）：遊戲開局 24 天後，紐約州啟用了 E-ZPass。典故與原始資料見 [docs/name-origin.md](docs/name-origin.md)。

## 需要

- [Minidoracat UI Library for B42](https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701)（管理視窗）

## 功能

- **車用感應盒**：真正的車輛零件，原版與 MOD 車都能裝，從車輛維修面板「Knox Pass」分類拆裝；內建電池，車子發動時由電瓶充電。原版車與[支援清單](#支援的-mod-車)上的常見 MOD 車，擋風玻璃上緣看得到裝上的感應盒。
- **大門讀頭**：對大門按右鍵安裝（需要螺絲起子）；支援地圖上的門、柵欄門、雙開門、車庫門與玩家建造的門。裝好後門柱上看得到讀頭。
- **各門各自登記**：讀頭擁有者在管理視窗登記附近裝了感應盒的車；登記跟著感應盒走，換車照樣通行。
- **自動開關門**：有人駕駛、裝著已登記感應盒的車靠近就開門，駛離後自動關；會依車速提前開門，自動駕駛不必停車；門口有車或有人時不關。
- **抬升閘門**：製作組件後從建造選單放在路上（機箱 1 格加 3 格車道），內建讀頭、建造者就是擁有者；關著亮紅燈、掛 STOP 牌，開啟時桿子抬起轉綠燈，車道兩側有停止線與 KNOX PASS 字樣。
- **外殼顏色**：感應盒與讀頭各有 7 色（米白、黑色、石墨灰、軍綠、深藍、安全橘、紅色）。製作與搜刮拿到米白；身上帶對應顏色的原版油漆（用掉一格）和漆刷，在物品欄右鍵「重新上色」就能換色，電量與登記都保留。已裝在門上的讀頭，擁有者從大門右鍵的 Knox Pass 選單直接重新上色；車上的感應盒要先從維修面板拆下來再換。
- **開車接近前提醒**：開向一扇不會為你打開的 Knox Pass 大門或閘門時，約 20 格前提示原因。
- **大門門鎖**：可設成只有 Knox Pass 開得了；步行時也能用右鍵「用 Knox Pass 開門」。
- **伺服器可調**：感應距離、行進預測、自動駕駛提早開門距離、關門延遲、供電需求、感應盒耗電、製作與搜刮開關。
- **給其他 MOD**：`KnoxPassAPI.registerGateAdapter` 可讓自訂的門接入 Knox Pass；`KnoxPassAPI.willOpenFor(vehicle, obj)` 讓自駕 MOD 在客戶端查「這扇門會不會替這台車開」（預告不是保證，呼叫端仍要能在門前停住），裝了讀頭的門不會開時第二個回傳值是原因代碼，`KnoxPassAPI.whyText(why)` 轉成玩家語言（`KnoxPassAPI.VERSION >= 3`）。介面說明見 `42/media/lua/shared/MinidoracatKnoxPass/Gates.lua` 檔尾。

## 效果圖

### 大門與閘門

| 開車靠近，大門提前打開 | 抬升閘門為登記的車抬起、轉綠燈 |
|---|---|
| ![開車靠近，大門提前打開](docs/screenshots/steam/zh/01-gate-opens-ahead-zh.jpg) | ![抬升閘門抬起](docs/screenshots/steam/zh/02-barrier-opens-zh.jpg) |
| **開向不會打開的閘門：約 20 格前提醒原因** | **搭配 Minidoracat AutoDrive 自駕穿過大門** |
| ![開車接近前提醒](docs/screenshots/steam/zh/03-barrier-warning-zh.jpg) | ![AutoDrive 穿過大門](docs/screenshots/steam/zh/04-autodrive-through-gate-zh.jpg) |

### 大門讀頭

| 雙開門：讀頭在外端門柱上 | 柵欄門 |
|---|---|
| ![雙開門的讀頭](docs/screenshots/readme/reader-double.jpg) | ![柵欄門的讀頭](docs/screenshots/readme/reader-fence.jpg) |
| **車庫門** | **右鍵選單：管理、上鎖、步行開門、重新上色** |
| ![車庫門的讀頭](docs/screenshots/readme/reader-garage.jpg) | ![右鍵選單](docs/screenshots/steam/zh/06-gate-menu-zh.jpg) |

### 車用感應盒

| 原版車：擋風玻璃上緣看得到感應盒 | 從車輛維修面板安裝 |
|---|---|
| ![原版車的感應盒](docs/screenshots/steam/zh/10-windshield-tag-zh.jpg) | ![車輛維修面板](docs/screenshots/steam/zh/07-mechanics-tag-zh.jpg) |
| **MOD 車：'93 Ford F-350（KI5）** | **MOD 車：'93 Ford F-150，盒子在行李架下方** |
| ![F-350 的感應盒](docs/screenshots/readme/modcar-f350.jpg) | ![F-150 的感應盒](docs/screenshots/readme/modcar-f150.jpg) |
| **MOD 車：W900 Semi-Truck，盒子在遮陽板下** | **管理視窗：登記附近裝了感應盒的車** |
| ![W900 的感應盒](docs/screenshots/readme/modcar-w900.jpg) | ![管理視窗](docs/screenshots/steam/zh/05-manage-window-zh.jpg) |

### 外殼顏色

感應盒與讀頭各有 7 種顏色：米白、黑色、石墨灰、軍綠、深藍、安全橘、紅色。製作與搜刮拿到的是米白；帶著對應顏色的原版油漆和漆刷，可以在物品欄或門上「重新上色」，電量與登記都保留。

| 7 色擺在地上 | 物品欄 |
|---|---|
| ![7 色的感應盒與讀頭](docs/screenshots/readme/colors-ground.jpg) | ![物品欄的 7 色圖示](docs/screenshots/readme/colors-inventory.jpg) |
| **門上的讀頭重新上色成黑色** | **車上看得到該色的盒子（多人連線實機）** |
| ![黑色讀頭](docs/screenshots/readme/colors-reader-black.jpg) | ![擋風玻璃上的 4 種顏色](docs/screenshots/readme/colors-windshields.jpg) |

### 製作與伺服器設定

| 製作抬升閘門組件 | 伺服器設定（沙盒「Knox Pass」頁） |
|---|---|
| ![製作視窗](docs/screenshots/steam/zh/08-craft-barrier-kit-zh.jpg) | ![沙盒設定](docs/screenshots/steam/zh/09-sandbox-options-zh.jpg) |

## 支援的 MOD 車

<!-- modcars:start（由 scripts/gen_modcar_list.py 從 scripts/blender/modcars.json 產生，不要手改） -->
原版車全部支援。下表的 MOD 車已經對好擋風玻璃位置，裝上感應盒就看得到；✔＝遊戲裡實際看過，其餘看過遊戲視角的預覽圖。其他 MOD 沿用這些車身的車也一樣支援。表上沒有的車照樣能裝感應盒、登記、開門、充電，只是盒子未必看得到；車上加裝的配件（例如自己裝的擋風玻璃裝甲）也可能擋住盒子。

<details>
<summary>已支援的 MOD 車（47 個 MOD，點開看車款）</summary>

| MOD | 車款 |
|---|---|
| ['97 ADI Bushmaster](https://steamcommunity.com/sharedfiles/filedetails/?id=2897390033) | '97 Bushmaster、'97 Bushmaster Ambulance |
| ['78 AM General M35 Series Trucks](https://steamcommunity.com/sharedfiles/filedetails/?id=2799152995) | '78 AM General M35A2、'78 AM General M49A2C Fuel Tanker、'78 AM General M50A3 Water Tanker、'78 AM General M62 Wrecker |
| ['92 AM General M998 + M101A3 Trailer](https://steamcommunity.com/sharedfiles/filedetails/?id=2642541073) | '92 AM General M998 HMMWV |
| ['90 BMW 3 Series (E30)](https://steamcommunity.com/sharedfiles/filedetails/?id=3110913021) | '90 BMW E30 2-Door、'90 BMW E30 4-Door、'90 BMW E30 Cabrio、'90 BMW E30 M3、'90 BMW E30 Touring |
| ['84 Buick Electra](https://steamcommunity.com/sharedfiles/filedetails/?id=3596903773) | '84 Buick Electra Coupe、'84 Buick Electra Sedan |
| ['85 Buick LeSabre](https://steamcommunity.com/sharedfiles/filedetails/?id=3418252689) | '85 Buick LeSabre Coupe、'85 Buick LeSabre Sedan、'85 Buick LeSabre Wagon |
| ['84 Cadillac DeVille](https://steamcommunity.com/sharedfiles/filedetails/?id=3592777775) | '84 Cadillac DeVille Coupe、'84 Cadillac DeVille Sedan |
| ['85 Chevrolet Caprice / Impala](https://steamcommunity.com/sharedfiles/filedetails/?id=3413704851) | '85 Chevrolet Caprice Coupe、'85 Chevrolet Caprice Sedan、'85 Chevrolet Caprice Wagon、'85 Chevrolet Impala Airport Security、'85 Chevrolet Impala Bulletin County Sheriff、'85 Chevrolet Impala City of Louisville PD、'85 Chevrolet Impala Fire Department、'85 Chevrolet Impala KY State Trooper、'85 Chevrolet Impala Louisville County PD、'85 Chevrolet Impala Meade County Sheriff、'85 Chevrolet Impala Muldraugh PD、'85 Chevrolet Impala Police、'85 Chevrolet Impala Prison Security、'85 Chevrolet Impala Ranger、'85 Chevrolet Impala Taxi、'85 Chevrolet Impala Undercover、'85 Chevrolet Impala West Point PD |
| ['86 Chevrolet CUCVs + M101A2 Trailer](https://steamcommunity.com/sharedfiles/filedetails/?id=3428008364) | '86 Chevrolet K5 Blazer、'86 Chevrolet K5 KSP、'86 Chevrolet K5 PD、'86 Chevrolet M1008、'86 Chevrolet M1009、'86 Chevrolet M1009 MP、'86 Chevrolet M1010、'86 Chevrolet M1028、'86 Chevrolet M1031 |
| ['76 Chevrolet K series](https://steamcommunity.com/sharedfiles/filedetails/?id=3161951724)（含同一個 Workshop 項目的 76chevyKseriesExpanded） | '76 Chevrolet K10、'76 Chevrolet K10 Fire Dept、'76 Chevrolet K10 Spirit of 76、'76 Chevrolet K20、'76 Chevrolet K20 Big Red、'76 Chevrolet K20 Single Cab Utility Truck、'76 Chevrolet K30 Crew Cab、'76 Chevrolet K30 Crew Cab Dually、'76 Chevrolet K30 Crew Cab Fire Dept、'76 Chevrolet K30 Crew Cab Utility Truck、'76 Chevrolet K30 Single Cab Dually、'76 Chevrolet K30 Single Cab Fire Dept、'76 Chevrolet K30 Special、'76 Chevrolet K5 Blazer、'76 Chevrolet Suburban |
| ['85 Chevrolet Step-Van](https://steamcommunity.com/sharedfiles/filedetails/?id=3614034284)（含同一個 Workshop 項目的 85chevyStepVanexpanded） | '85 Chevrolet Step-Van |
| ['87 Chevrolet Suburban](https://steamcommunity.com/sharedfiles/filedetails/?id=3196180339) | '87 Chevrolet Suburban、'87 Chevrolet Suburban CUCV、'87 Chevrolet Suburban Offroad Pack |
| ['93 Chevrolet Suburban / Silverado](https://steamcommunity.com/sharedfiles/filedetails/?id=3152529790)（含同一個 Workshop 項目的 93chevySuburbanExpanded） | '93 Chevrolet K3500 Flatbed、'93 Chevrolet Silverado Crew Cab、'93 Chevrolet Silverado Crew Cab Dually、'93 Chevrolet Silverado Crew Cab Long Bed、'93 Chevrolet Silverado Extended Cab、'93 Chevrolet Silverado Extended Cab Dually、'93 Chevrolet Silverado Extended Cab Long Bed、'93 Chevrolet Silverado Fire Dept、'93 Chevrolet Silverado Fossoil、'93 Chevrolet Silverado McCoy、'93 Chevrolet Silverado Ranger、'93 Chevrolet Silverado Single Cab、'93 Chevrolet Silverado Single Cab Dually、'93 Chevrolet Silverado Single Cab Long Bed、'93 Chevrolet Suburban、'93 Chevrolet Suburban Dually、'93 Chevrolet Suburban FBI、'93 Chevrolet Suburban Fire Chief、'93 Chevrolet Suburban KSP、'93 Chevrolet Suburban PD、'93 Chevrolet Suburban Undercover |
| ['89 Dodge Caravan](https://steamcommunity.com/sharedfiles/filedetails/?id=3034636011) | '89 Dodge Caravan、'89 Dodge Caravan LE、'89 Dodge Caravan Nomad |
| ['69 Dodge Charger](https://steamcommunity.com/sharedfiles/filedetails/?id=3631989559) | '69 Dodge Charger 440 Pro Touring、'69 Dodge Charger Daytona、'69 Dodge Charger Demon Love Child、'69 Dodge Charger RT、'69 Dodge HEMI Charger 500 |
| ['49 Dodge Power Wagon Crew Cab](https://steamcommunity.com/sharedfiles/filedetails/?id=2900580391) | '49 Dodge Power Wagon Apocalypse、'49 Dodge Power Wagon Crew Cab、'49 Dodge Power Wagon Military Police、'49 Dodge Power Wagon Police |
| ['87 Ford B700/F700 Trucks](https://steamcommunity.com/sharedfiles/filedetails/?id=3110911330) | '87 Ford B700 Military Bus、'87 Ford B700 Prison Bus、'87 Ford B700 School Bus、'87 Ford F700 Armored Truck、'87 Ford F700 Box Truck、'87 Ford F700 SWAT Van |
| ['93 Ford CF8000 Elgin Street Sweeper](https://steamcommunity.com/sharedfiles/filedetails/?id=2969343830) | '93 Ford CF8000 Elgin Special Street Sweeper、'93 Ford CF8000 Elgin Street Sweeper |
| ['92 Ford Crown Victoria Police Interceptor](https://steamcommunity.com/sharedfiles/filedetails/?id=2962175696) | '92 Ford Crown Victoria、'92 Ford Crown Victoria KC Fire Rescue、'92 Ford Crown Victoria KYSP Interceptor、'92 Ford Crown Victoria Patrol Supervisor、'92 Ford Crown Victoria Police Interceptor、'92 Ford Crown Victoria Taxi、'92 Ford Crown Victoria Undercover、'92 Ford Crown Victoria Unmarked、The Sheriff |
| ['86 Ford Econoline E150](https://steamcommunity.com/sharedfiles/filedetails/?id=2870394916)（含同一個 Workshop 項目的 86fordE150expanded） | '86 Ford E-150 KY State Police、'86 Ford E-150 Knox County Medical Examiner、'86 Ford E-150 Knox County Sheriff、'86 Ford Econoline E-150、'86 Ford Econoline E-150 Escape Van、'86 Ford Econoline E-150 McCoy、'86 Ford Econoline E-150 Spiffo、'86 Ford Econoline E-150 long variant、'86 Ford Econoline E-150 with sliding door、'86 Ford Econoline E-150 with windows、The Mystery Machine |
| ['93 Ford F-Series](https://steamcommunity.com/sharedfiles/filedetails/?id=3073430075) | '93 Ford F-150 Single Cab ✔、'93 Ford F-150 Special ✔、'93 Ford F-250 Single Cab ✔、'93 Ford F-350 Crew Cab ✔、'93 Ford F-350 Crew Cab Dually ✔、'93 Ford F-350 Crew Cab FD ✔、'93 Ford F-350 Crew Cab PD ✔、'93 Ford F-350 Crew Cab SO ✔、'93 Ford F-350 DPW Utility Truck ✔、'93 Ford F-350 FD Utility Truck ✔、'93 Ford F-350 Utility Truck ✔ |
| ['90 Ford F350 Ambulance Type 1](https://steamcommunity.com/sharedfiles/filedetails/?id=2952802178) | '90 Ford F350 Ambulance、'90 Ford F350 S.W.A.T. |
| ['93 Ford Taurus](https://steamcommunity.com/sharedfiles/filedetails/?id=3088951320) | '93 Ford Taurus、'93 Ford Taurus SHO、'93 Ford Taurus Wagon |
| ['91 Geo Metro](https://steamcommunity.com/sharedfiles/filedetails/?id=3008795514) | '91 Geo Metro |
| ['89 Isuzu Trooper](https://steamcommunity.com/sharedfiles/filedetails/?id=2932549988) | '89 Isuzu Trooper、'89 Isuzu Trooper Offroad Pack、'89 Isuzu Trooper RS |
| ['89 LAND ROVER Defender](https://steamcommunity.com/sharedfiles/filedetails/?id=3570973322) | '89 LAND ROVER Defender 110、'89 LAND ROVER Defender 110 Utility、'89 LAND ROVER Defender 130、'89 LAND ROVER Defender 90、'89 LAND ROVER Defender 90 Utility、'89 LAND ROVER Wolf |
| ['84 Mercedes Benz W460](https://steamcommunity.com/sharedfiles/filedetails/?id=2805630347) | '84 Mercedes-Benz Military W460、'84 Mercedes-Benz W460 2-Door LWB、'84 Mercedes-Benz W460 4-Door LWB、'84 Mercedes-Benz W460 SWB |
| ['69 Mini Mk2](https://steamcommunity.com/sharedfiles/filedetails/?id=2937786633) | '69 Mini、Italian Job Mini、MrBean's Mini、Pitbull Special Mini、Union Jack Mini |
| ['96 Mitsubishi Lancer EVO IV](https://steamcommunity.com/sharedfiles/filedetails/?id=3647736504) | '96 Mitsubishi Lancer EVO IV Converted、'96 Mitsubishi Lancer EVO IV Imported |
| ['92 NISSAN Skyline GT-R (R32)](https://steamcommunity.com/sharedfiles/filedetails/?id=2846036306) | '92 NISSAN Skyline GT-R (R32) Converted、'92 NISSAN Skyline GT-R (R32) Imported |
| ['98 Nissan Stagea 260RS Autech](https://steamcommunity.com/sharedfiles/filedetails/?id=3315443103) | '98 Nissan Stagea 260RS Autech Converted、'98 Nissan Stagea 260RS Autech Imported |
| ['85 Oldsmobile Delta 88](https://steamcommunity.com/sharedfiles/filedetails/?id=3418253716) | '85 Oldsmobile Delta 88 Coupe、'85 Oldsmobile Delta 88 Sedan、'85 Oldsmobile Delta 88 Wagon |
| ['82 Oshkosh M911](https://steamcommunity.com/sharedfiles/filedetails/?id=2618213077) | '82 Oshkosh M911、'82 Oshkosh M911 Black |
| ['86 Oshkosh P19A + Military Trailers](https://steamcommunity.com/sharedfiles/filedetails/?id=2566953935) | '86 Oshkosh P19A KYFD、'86 Oshkosh P19A USMC、P19A FRTR55 |
| ['90 Pierce Arrow Pumper and Ladder Trucks](https://steamcommunity.com/sharedfiles/filedetails/?id=2942793445) | '90 Pierce Arrow Pumper |
| ['70 Plymouth Road Runner](https://steamcommunity.com/sharedfiles/filedetails/?id=3642935062) | '70 Plymouth Road Runner |
| ['75 Pontiac Grand Prix](https://steamcommunity.com/sharedfiles/filedetails/?id=3213391371) | '75 Pontiac Grand Prix Hurst Special、'75 Pontiac Grand Prix LJ、'75 Pontiac Grand Prix SJ |
| ['85 Pontiac Parisienne](https://steamcommunity.com/sharedfiles/filedetails/?id=3413706334) | '85 Pontiac Parisienne Sedan、'85 Pontiac Parisienne Wagon |
| ['82 Porsche 911](https://steamcommunity.com/sharedfiles/filedetails/?id=3379334330) | '82 Porsche 911 RWB、'82 Porsche 911 Turbo、'82 Porsche 911SC、'82 Porsche 911SC Targa |
| ['91 RANGE ROVER Classic](https://steamcommunity.com/sharedfiles/filedetails/?id=2409333430) | '91 RANGE ROVER 2-door、'91 RANGE ROVER 4-door |
| ['67 Shelby GT500 + Eleanor](https://steamcommunity.com/sharedfiles/filedetails/?id=3026723485) | '67 Shelby GT500、'67 Shelby GT500 Eleanor |
| ['95 Subaru Impreza WRX STI](https://steamcommunity.com/sharedfiles/filedetails/?id=3647735736) | '95 Subaru Impreza WRX STI Converted、'95 Subaru Impreza WRX STI Imported |
| ['87 Toyota MR2](https://steamcommunity.com/sharedfiles/filedetails/?id=3052360250) | '87 Toyota MR2、'87 Toyota MR2 Convertible |
| ['63 Volkswagen 1300 Beetle](https://steamcommunity.com/sharedfiles/filedetails/?id=3005903549) | '63 Volkswagen 1300 Beetle、'63 Volkswagen Beetle Dune Buggy、'63 Volkswagen Beetle High Performance |
| ['63 Volkswagen Type 2 Van](https://steamcommunity.com/sharedfiles/filedetails/?id=3041122351) | '63 Volkswagen Type 2 Apocalypse Van、'63 Volkswagen Type 2 Hippie Van、'63 Volkswagen Type 2 Military Van、'63 Volkswagen Type 2 Van |
| ['89 Volvo 200 Series](https://steamcommunity.com/sharedfiles/filedetails/?id=3292659291) | '89 Volvo 242 Turbo、'89 Volvo 244 Sedan、'89 Volvo 245 Wagon |
| [W900 Semi-Truck](https://steamcommunity.com/sharedfiles/filedetails/?id=3409472393) | W900 Box Truck ✔、W900 Day Cab、W900 Flat Top ✔、W900 Military Box ✔、W900 Military Edition ✔ |

同車身但遊戲裡看不到盒子（功能照常）：'85 Chevrolet Step-Van SWAT（出廠就裝了擋風玻璃裝甲）、'90 Pierce Arrow Quint Ladder Truck（雲梯架在駕駛室上方，擋住擋風玻璃）。

</details>

想支援別的 MOD 車：用 GitHub 的 [「MOD 車位置申請」表單](https://github.com/Minidoracat/MinidoracatKnoxPassFor42/issues/new?template=modcar-request.yml)，或到 [Discord](https://discord.gg/Gur2V67) 提出；附上車輛 MOD 的 Workshop 連結和車名，有裝上感應盒後從車頭前方拍的截圖更好。
<!-- modcars:end -->

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
