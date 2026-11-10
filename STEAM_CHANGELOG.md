[h1]Minidoracat Knox Pass for B42 42.22.2-0.11.0[/h1]
[i]2026-11-10[/i]

[b]English summary[/b]
[list]
[*] New "Opens on" setting per gate in the reader window: "Approach" (default, as before) or "Headlight flash". With flash, toggle your headlights twice quickly (default F, or the dashboard button) and drive into range within 5 seconds. AutoDrive still opens it directly.
[*] You can now take down a boom barrier or a self-built gate and get materials back: right-click it → Knox Pass → "Dismantle the whole barrier" or "Dismantle the whole gate". It needs a screwdriver, a hammer, or a fuelled welding torch with a welder mask, depending on the gate. On a gate with a reader, only the owner or an admin can.
[*] Fixed: wide barriers and gates disappeared when zoomed in while standing at one end. Gates you already built need nothing redone.
[*] Fixed (multiplayer): a player-built door with the Knox Pass lock on could still be opened by hand by players nearby. Restart the server after updating.
[*] Game 42.22 crowbars can't force a door that has a reader, and the "Force" option is hidden on those doors.
[*] Stronger server-side checks when gates are dismantled.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]大門可以設成「閃一下大燈才開」[/b]：有玩家反映，開車路過自己的大門、其實不想進去時，門也會自動打開。現在讀頭管理視窗多了「開門方式」：「靠近就開」（預設，跟以前一樣）或「閃一下大燈才開」。設成閃燈的門，開車接近時連按兩下切大燈的鍵（預設 F），或點兩下儀表板的大燈鈕，之後 5 秒內開進感應距離，門才會打開。不用多記一個鍵，也不用按喇叭（喇叭會引來殭屍）。搭配 Minidoracat AutoDrive 自動駕駛時照舊直接開門。
[*] [b]閃燈的提醒與按鍵[/b]：自己開車接近這種門時，頭上會提醒一次要閃大燈。按鍵設定裡「車輛頭燈」和「裝備或開 / 關 光源」要是同一個鍵，鍵盤才切得了大燈（原版兩個預設都是 F）；只改了其中一個時，提醒會請你點儀表板的大燈鈕。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]蓋錯位置的抬升閘門與自建大門拆不掉[/b]：以前只能用大錘整座敲掉，材料一個都拿不回來（0.1.0 起就是這樣）。現在對機箱、門柱、車道或門片按右鍵，Knox Pass 子選單多了「拆除整座閘門」或「拆除整座大門」，整座移除並把材料放在地上：被拆那一端的建造材料每項退回 1 到原本的數量（抬升閘門一定退回組件），另外裝上去的讀頭也退回。
[*] [b]拆除要帶的工具[/b]：抬升閘門要螺絲起子；鐵網、鋼板、鐵欄杆大門與兩層樓車庫捲門要有燃料的瓦斯噴槍（用掉一格）和焊接面罩；牧場木門、中世紀厚木門要鎚子。一層樓車庫捲門照舊用原版「拆解」，大錘照舊能敲。
[*] [b]誰能拆[/b]：裝了讀頭的門只有擁有者與伺服器管理員能拆（共同管理者不行，跟拆讀頭一樣）；沒裝讀頭的誰都能拆。門只要有一部分在別人的安全屋裡就不能拆。
[*] [b]寬的閘門與大門，鏡頭拉近時整座不見[/b]：9 格這類寬的雙桿閘門、兩層樓大門與兩層樓車庫捲門，鏡頭拉近、人又站在門的一端時，整座門（連路面的 KNOX PASS 字）會突然不畫。現在同樣的位置會照常顯示；門只剩畫面邊緣幾格時仍可能看不到。已經蓋好的門不用重蓋，更新後就生效。
[*] [b]玩家建造的門開了門鎖，多人伺服器上別人照樣用手打得開[/b]：用建造選單蓋的門（含雙開門）裝讀頭、開 Knox Pass 門鎖之後，當時在附近的玩家沒鑰匙也能用手打開。從有門鎖起就是這樣；地圖原有的門、柵欄門、車庫門與本 MOD 的閘門、大門不受影響，單人也不受影響。現在沒鑰匙的人用手開不了。伺服器更新後重啟即可，已經上鎖的門不用重設。
[*] [b]門開著時拆讀頭，雙開門中間兩片沒鎖回[/b]：原本有鑰匙鎖的雙開門，在 Knox Pass 開著門的時候拆下讀頭，中間兩片沒鎖回原本的鑰匙鎖，沒鑰匙的人點中間就打得開。現在四片都會鎖回。
[*] [b]裝了讀頭的門可以用撬棍撬開[/b]：遊戲 42.22 加了用撬棍撬開上鎖的門，裝了讀頭的門也撬得開。現在裝了讀頭的門右鍵不會出現「撬開」，伺服器也不讓撬；能通行的人照舊用「用 Knox Pass 開門」。擁有者要撬自己的門，先拆下讀頭；抬升閘門的讀頭是內建的，一律用 Knox Pass 開。
[*] [b]強化伺服器端驗證[/b]：抬升閘門與有門柱的自建大門，要拆除並拿回材料，伺服器現在只接受右鍵 Knox Pass 的「拆除整座」，並檢查擁有者、工具與距離。一般遊玩不受影響，伺服器更新後重啟即可。
[/list]
