[h1]Minidoracat Knox Pass for B42 42.22.2-0.13.3[/h1]
[i]2026-11-28[/i]

[b]English summary[/b]
[list]
[*] Fix: on multiplayer servers, closing a locked roll-up door or barrier by hand while it was open could make nearby players lag. Restart the server once after updating.
[*] After a hand close, the key lock now comes back a few seconds later (about 5 s, up to about 35 s if someone keeps standing in the doorway). The Knox Pass lock still keeps players out meanwhile.
[*] Knox Pass now waits until nobody has been walking in the doorway for 2 s before it closes on its own. Driving through does not count.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]上鎖的捲門、閘門開著時被人用手關上，附近的人一起卡頓[/b]：現在不會了，伺服器更新後重啟一次即可。只發生在多人伺服器、門邊有兩位以上玩家時，之前的版本都有這個問題。
[list]
[*] 門被人用手關上後，鑰匙鎖晚幾秒才鎖回：門關著、門口沒人站滿 5 秒才鎖，一直有人站著最多等 35 秒左右；這段時間 Knox Pass 門鎖照樣擋住玩家。
[*] Knox Pass 自動關門前，門口要沒有人走動滿 2 秒（開車經過不算）；右鍵「用 Knox Pass 關門」照舊馬上關。
[/list]
[/list]
