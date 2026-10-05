<!-- Steam discussion post source (English); the description is a summary, this thread is the reference -->
<!-- Thread URL: (to be created after the first upload; then add the guide link to STEAM_DESCRIPTION*.md) -->
<!-- Title: 📖 Knox Pass Guide: Tags, Readers & Hands-free Gates -->

[b]中文版：[/b] [url={KP_GUIDE_CH}]Knox Pass 完整說明：感應盒、讀頭與自動開門[/url]

Knox Pass lets you drive home without getting out: put a tag in the car and a reader on the gate, and registered cars open the gate as they drive up, then it closes behind them. This thread covers every feature, the server settings and common questions.

[h2]🚀 Quick Start[/h2]
[olist]
[*] Get a [b]Vehicle Tag[/b] and a [b]Gate Reader[/b] (craft or loot, see below)
[*] Open the vehicle mechanics panel and install the tag under "Knox Pass"; you need the car key or an unlocked door
[*] With the reader and a screwdriver, right-click the gate → Knox Pass → [b]Install Knox Pass reader[/b]
[*] Park next to the gate, right-click → Knox Pass → [b]Manage reader[/b], pick the car under "Nearby vehicles with a tag" and press [b]Register[/b]
[/olist]

[h2]🧰 Features[/h2]

[h3]Vehicle Tag[/h3]
[list]
[*] [b]A real vehicle part[/b]: every car with a battery has the slot, vanilla and modded alike; bicycles and trailers don't.
[*] [b]Installing[/b]: install or remove it from the "Knox Pass" category of the mechanics panel. No tools or skills needed, but you need the car key or an unlocked door, so nobody can steal it from a locked car.
[*] [b]Battery[/b]: the tag has a built-in battery. It recharges slowly while installed in a car whose engine is running and whose battery is above 10%; each gate opening uses a little charge. An empty tag opens nothing.
[*] [b]Moves with the tag[/b]: the gate registers this tag, not the car. Move the tag to another car and it still opens the same gate. When you remove or install it in the mechanics panel, the car name in the management window updates right away; a removed tag shows as "Not in a vehicle".
[*] [b]You can see it[/b]: once installed, the tag shows at the top of the windshield on vanilla cars and on the listed modded vehicles (list and requests: [url={KP_MODCARS_EN}]🚗 Supported Modded Vehicles & Requests[/url]). On other modded vehicles it may not be visible, but it works the same.
[/list]

[h3]Gate Reader[/h3]
[list]
[*] [b]Where it fits[/b]: map doors, fence gates, double doors, garage doors, and player-built doors and gates.
[*] [b]Installing[/b]: right-click the gate with the reader and a screwdriver. Whoever installs it owns it. Once installed, the reader shows on the gate post (a boom barrier has its reader on top of the cabinet); it doesn't block people or cars.
[*] [b]Management window[/b]: shows the gate type, owner, power, lock, registered cars (charge, last pass) and nearby cars with a tag.
[*] [b]Removing[/b]: the owner can take the reader back. If Knox Pass has the gate open, it closes it first and restores the original lock.
[/list]

[h3]Boom Barrier[/h3]
[list]
[*] [b]Building[/b]: craft a "Knox Pass Boom Barrier Kit" and place it on the road from the build menu. It takes 4 tiles: 1 for the cabinet and 3 for the lane; rotate it to run north–south or east–west.
[*] [b]Built-in reader[/b]: whoever builds it owns it, and registration, the lock, power and the management window all work like a gate. The reader can't be removed on its own.
[*] [b]Easy to read[/b]: when closed, the pivot lamp is red and a STOP sign hangs from the arm; when it opens for a registered car, the arm lifts over about 4 seconds and the lamp turns green. Stop lines and KNOX PASS lettering are painted on the lane on both sides.
[*] [b]Removing and damage[/b]: dismantling the cabinet removes the whole barrier and gives the kit back. If the cabinet or the lane gets broken, the whole barrier is destroyed with no refund.
[/list]

[h3]Hands-free opening and closing[/h3]
[list]
[*] [b]Who opens it[/b]: the driver of a car carrying a registered, charged tag. Passengers, unregistered cars and empty tags open nothing.
[*] [b]Opens early[/b]: the server predicts where the car is heading from its actual movement, so the faster you drive the earlier it opens; driving past in another direction doesn't. When a car under Minidoracat AutoDrive heads for the gate, the gate opens while it is still out of the car's sight; newer AutoDrive versions also know in advance that the gate will open for them, so they never slow down or detour for it.
[*] [b]Closes by itself[/b]: it only closes gates Knox Pass opened, after no registered, driven car has been in range for a while.
[*] [b]Never closes on anything[/b]: it waits while a car, a person or a zombie is in the doorway, and tries again two seconds later.
[*] [b]Warning before you reach it[/b]: when you drive toward a Knox Pass gate or barrier that won't open for you, you get a message above your head and in the top-right corner about 20 tiles before it, saying why (no tag installed, the tag isn't registered at that gate, an empty tag, an unpowered reader), so you don't drive straight into it.
[/list]

[h3]Gate lock and opening on foot[/h3]
[list]
[*] [b]Lock[/b]: the owner can turn on "Lock (only Knox Pass opens it)" in the right-click menu or the window. A locked gate can't be opened bare-handed; Knox Pass unlocks it to open and locks it again once closed. A house door's original key keeps working, so whoever holds that key can still open it.
[*] [b]Your old locks stay intact[/b]: a map door that was locked goes back to exactly the same kind of lock after closing, so its original key still works.
[*] [b]On foot[/b]: right-click → Knox Pass → [b]Open with Knox Pass[/b]. The owner, admins, and anyone carrying a registered, charged tag can use it.
[/list]

[h3]Getting them[/h3]
[list]
[*] [b]Vehicle Tag[/b]: Electrical 2. Use a screwdriver to build it from a pager or TV remote, 2 electronics scrap and 1 battery. Also found in gas station storage, car supply stores, mechanic electrical shelves and electronics stores.
[*] [b]Gate Reader[/b]: Electrical 4. Use a screwdriver to build it from a radio receiver, 3 electronics scrap and 2 electric wires. Also found in electrician tool boxes, electronics crates, hardware stores and mechanics.
[*] [b]Boom Barrier Kit[/b]: Electrical 4. Use a screwdriver to build it from 1 Gate Reader, 2 metal pipes, 1 sheet of metal and 2 electric wires. Crafting only; it isn't found as loot.
[/list]

[h2]⚙️ Server settings (sandbox page "Knox Pass")[/h2]
[list]
[*] [b]Read range[/b]: 8 tiles by default (2–30). The range around the gate while the car stands still.
[*] [b]Look-ahead seconds[/b]: 2 by default (0–5). How far ahead along the car's movement to look; 0 uses the plain range only.
[*] [b]Self-driving early open distance[/b]: 150 tiles by default (0–250). When a car under Minidoracat AutoDrive heads for the gate (the gate within about 12 degrees of its direction of travel), the gate opens once the car is this close; the server must have the gate's area loaded first, so in practice it opens about 70–130 tiles out. 0 treats it like any other car.
[*] [b]Auto-close delay[/b]: 5 seconds by default (0–120).
[*] [b]Reader needs power[/b]: on by default. Grid power or a generator both count, and outdoor gates do get grid power.
[*] [b]Tag battery drain[/b]: 100% by default (0–500%, 0 means it never runs out).
[*] [b]Allow crafting[/b] and [b]Spawn as loot[/b]: on by default.
[/list]

[h2]⚠️ Known limitations[/h2]
[list]
[*] Modded gates built some other way (for example ones that fake opening by swapping textures in code) aren't supported automatically. Mod authors can hook them in through the public interface, and players can ask for support in the feedback section.
[*] Player-built garage doors aren't supported (the game itself doesn't open them as a group).
[*] A parked car with nobody in it and the engine off doesn't recharge its tag.
[*] When a self-driving car passes along another road heading almost straight at the gate (for example a parallel road a few dozen tiles away), the gate may open early and close again a few seconds later.
[*] The server can only open a gate once it has loaded that part of the map (roughly 60–130 tiles ahead of the car). With older AutoDrive versions a self-driving car may now and then see the gate closed a moment before it opens and slow down or drive around; newer versions are not affected. If the gate never opens, the self-driving car stops in front of it and waits or hands control back, just like at any closed gate; when the reason is something like an unpowered reader or a tag that isn't registered at that gate, newer AutoDrive versions tell you why in the top-right corner and with a voice line.
[*] Low fence gates can always be climbed over; the lock doesn't stop climbing.
[*] The boom barrier's cabinet always sits at one end (west for north–south, south for east–west); it can't be mirrored yet. Its lamp is just a color and doesn't glow at night.
[/list]

[h2]📜 Where the name comes from[/h2]
"Knox Pass" combines the game's Knox County, Kentucky, with the way American toll tags were named (E-ZPass, TollTag).
[list]
[*] The game starts on July 9, 1993. 24 days later, on August 2, 1993, the New York State Thruway opened electronic tolling at Spring Valley, the start of E-ZPass ([url=https://rosap.ntl.bts.gov/view/dot/3157/dot_3157_DS1.pdf]E-ZPass evaluation report, 2000[/url]).
[*] Electronic tolling was already running in Norway in 1987, Dallas in 1989 and Oklahoma in 1991, and in the 1990s the same TollTag could open gated communities ([url=https://transcore.com/wp-content/uploads/2017/01/History-of-RFID-White-Paper.pdf]TransCore's RFID history white paper[/url]).
[*] The first TollTag in 1989 was a credit-card-sized plastic box about 6 mm thick that hung on the windshield and could move to another car ([url=https://www.dallasnews.com/news/transportation/2014/08/07/as-tolltags-turn-25-originals-hang-on-for-dallas-area-motorists/]Dallas News, 2014[/url]). The Knox Pass tag is modelled on it.
[/list]

[h2]❓ FAQ[/h2]
[list]
[*] [b]I drove up and nothing opened.[/b] Check that you're in the driver's seat, the tag has charge, this tag is registered at this gate, and the reader has power (the window shows it).
[*] [b]The gate won't close.[/b] It waits while a car, a person or a zombie is in the doorway, and while a registered car with a driver is still in range.
[*] [b]Can other players open my gate?[/b] Only the tags you registered can. Once locked it can't be opened bare-handed either, except by someone holding that door's original key; an unlocked gate can still be opened by hand as usual.
[*] [b]Is it safe in multiplayer?[/b] Opening, closing, locking and registering are all checked by the server, and the registrations live only on the server.
[/list]

[h2]💬 Feedback[/h2]
[list]
[*] GitHub Issues: https://github.com/Minidoracat/MinidoracatKnoxPassFor42/issues
[*] Discord: https://discord.gg/Gur2V67
[/list]
Please include your game version, mod list, and what happened (which kind of gate, single player or multiplayer).
