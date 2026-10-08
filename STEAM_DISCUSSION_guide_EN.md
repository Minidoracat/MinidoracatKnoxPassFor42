<!-- Steam discussion post source (English); the description is a summary, this thread is the reference -->
<!-- Thread URL: https://steamcommunity.com/workshop/filedetails/discussion/3814684002/586187800874015404/ -->
<!-- Title: 📖 Knox Pass Guide: Tags, Readers & Hands-free Gates -->

[b]中文版：[/b] [url=https://steamcommunity.com/workshop/filedetails/discussion/3814684002/586187800874015409/]Knox Pass 完整說明：感應盒、讀頭與自動開門[/url]

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
[*] [b]You can see it[/b]: once installed, the tag shows at the top of the windshield on vanilla cars and on the listed modded vehicles (list and requests: [url=https://steamcommunity.com/workshop/filedetails/discussion/3814684002/586187800874015388/]🚗 Supported Modded Vehicles & Requests[/url]). On other modded vehicles it may not be visible, but it works the same.
[/list]

[h3]Gate Reader[/h3]
[list]
[*] [b]Where it fits[/b]: map doors, fence gates, double doors, garage doors, player-built doors and gates, and Knox Pass's own roll-up garage doors, two-story roll-up doors and two-story gates (see "Build your own gates" below).
[*] [b]Installing[/b]: right-click the gate with the reader and a screwdriver. Whoever installs it owns it. Once installed, the reader shows on the gate post (on the face of the pillar for two-story gates; boom barriers and double boom barriers have theirs on top of the cabinet); it doesn't block people or cars.
[*] [b]Management window[/b]: shows the gate type, owner, power, lock, this gate's read range, close delay and speed, registered cars (charge, last pass) and nearby cars with a tag. While it's open, an amber circle on the ground shows this gate's read range (the range for a car standing still; faster cars open it sooner).
[*] [b]Per-gate settings[/b]: the owner or an admin picks this gate's read range and close delay from two dropdowns in the window, limited to what the server allows (2–30 tiles and 0–30 seconds by default); "Server default" follows the sandbox setting. If the server later narrows the limits, gates that were set follow the new limits and keep their value.
[*] [b]Opening speed[/b]: boom barriers, double boom barriers, two-story roll-up doors and two-story gates can be set to [b]Normal (4 s)[/b] or [b]Fast (2.5 s)[/b] under "Speed" in the window, and every player sees the same speed. One-story roll-up doors and vanilla doors can't be changed; the dropdown says "Not adjustable".
[*] [b]Removing[/b]: the owner can take the reader back. If Knox Pass has the gate open, it closes it first and restores the original lock.
[/list]

[h3]Shell Colors and Repainting[/h3]
[list]
[*] [b]7 colors[/b]: tags and readers come in Cream, Black, Graphite, Olive, Navy, Safety Orange and Red. Looted ones come in a random color.
[*] [b]Which paint[/b]: a paintbrush plus one use of the matching vanilla paint: white paint for Cream, gray for Graphite, green for Olive, blue for Navy, and the same-named paint for Black, Safety Orange and Red.
[*] [b]Craft it in color[/b]: the crafting list has one entry per color (for example "Craft Knox Pass Vehicle Tag (Black)"). It takes the usual materials plus one use of that paint, and you need a paintbrush (it isn't used up). Without paint you craft a Cream one.
[*] [b]In your inventory[/b]: right-click a tag or reader you carry (bags count) → [b]Repaint[/b] → pick a color. Colors you lack paint or a paintbrush for are grayed out; hover to see what's missing. A tag keeps its charge and its registration at every gate, so it opens the same gates after repainting.
[*] [b]A reader on a gate[/b]: the owner or an admin right-clicks the gate → Knox Pass → [b]Repaint[/b]; your character walks to the gate and paints it, and registrations stay as they are.
[*] [b]A tag in a car[/b]: the windshield shows its color. To repaint it, remove it in the mechanics panel first, then install it again. The built-in reader of a boom barrier or double boom barrier can't be repainted.
[/list]

[h3]Boom Barrier[/h3]
[list]
[*] [b]Building[/b]: craft a "Knox Pass Boom Barrier Kit" and place it on the road from the build menu. It takes 4 tiles: 1 for the cabinet and 3 for the lane; rotate it while building to face any of four directions, with the cabinet at either end of the lane.
[*] [b]Built-in reader[/b]: whoever builds it owns it, and registration, the lock, power and the management window all work like a gate. The reader can't be removed on its own.
[*] [b]Easy to read[/b]: when closed, the pivot lamp is red and a STOP sign hangs from the arm; when it opens for a registered car, the arm lifts over about 4 seconds, easing in and out, and the lamp turns green. Stop lines and KNOX PASS lettering are painted on the lane on both sides.
[*] [b]Removing and damage[/b]: dismantling the cabinet removes the whole barrier and gives the kit back. If the cabinet or the lane gets broken, the whole barrier is destroyed with no refund. New barriers have 1000 durability on the cabinet and lane; barriers built before this update keep their old durability.
[/list]

[h3]Build your own gates[/h3]
[list]
[*] [b]Roll-up garage doors[/b]: search the build menu for "Roll-up Garage Door". Vanilla look in Industrial White, Green and White, each 3, 4, 6 or 9 tiles wide (6 fits two cars side by side, 9 fits three). Needs Welding 3 plus a welding torch, welding rods, steel sheets, iron pipes and door hinges; wider doors take more. No reader built in: install one like on any gate.
[*] [b]Two-story roll-up doors[/b]: the same three colors, 3, 4, 6 or 9 wide; the curtain rolls all the way up into the box on top, so vans fit through. Needs Welding 4 and twice the materials of the one-story door of the same width. No reader built in.
[*] [b]Double boom barrier[/b]: 6 or 9 tiles wide, with a cabinet at each end and two arms that meet in the middle. Build it with a screwdriver from 1 boom barrier kit plus iron pipes, steel sheets and wire (6 wide: 4, 2 and 2; 9 wide: 6, 3 and 2); no skill needed. It comes with a built-in reader, and the builder owns it.
[*] [b]Two-story gates[/b]: 6 or 9 tiles wide double gates in five looks: Chain-link, Steel Plate, Iron Bars (Welding 5), Ranch Wood (Carpentry 5) and Medieval Oak (Carpentry 5, plus Welding 2 for its iron bands). Rotating while building picks which side the leaves swing to. No reader built in; once installed, the reader hangs on the face of the post.
[*] [b]Durability[/b]: a one-car door (3 or 4 wide) has 1000, two cars (6 wide) 1500 and three cars (9 wide) 2000; two-story ones get 500 more.
[*] [b]Removing and damage[/b]: dismantling either end (cabinet or post) of a double boom barrier or two-story gate removes the whole thing and refunds only that end's materials. If any door piece gets broken, the whole thing is destroyed with no refund.
[*] [b]Animation[/b]: arms, roll-up curtains and gate leaves ease in and out as they move, taking about 4 seconds each way (about 2.5 with "Fast" in the window), and several gates moving at once each run on their own.
[/list]

[h3]Hands-free opening and closing[/h3]
[list]
[*] [b]Who opens it[/b]: the driver of a car carrying a registered, charged tag. Passengers, unregistered cars and empty tags open nothing.
[*] [b]Opens early[/b]: the server predicts where the car is heading from its actual movement, so the faster you drive the earlier it opens; driving past in another direction doesn't. When a car under Minidoracat AutoDrive heads for the gate, the gate opens while it is still out of the car's sight; newer AutoDrive versions also know in advance that the gate will open for them, so they never slow down or detour for it.
[*] [b]Closes by itself[/b]: it only closes gates Knox Pass opened. Once a registered car, including any trailer it tows, has fully passed through the gateway, the close countdown starts; it doesn't wait for the car to leave the read range, and a car parked inside doesn't hold it open. Turning back toward the gate opens it again.
[*] [b]Never closes on anything[/b]: it waits while a car or a person is in the doorway and tries again two seconds later. Zombies alone don't hold it open, so zombies following a car in can't keep the gate open.
[*] [b]Warning before you reach it[/b]: when you drive toward a Knox Pass gate or barrier that won't open for you, you get a message above your head and in the top-right corner about 20 tiles before it, saying why (no tag installed, the tag isn't registered at that gate, an empty tag, an unpowered reader), so you don't drive straight into it.
[/list]

[h3]Gate lock and opening on foot[/h3]
[list]
[*] [b]Lock[/b]: the owner can turn on "Lock (only Knox Pass opens it)" in the right-click menu or the window. A locked gate can't be opened bare-handed, and zombies that open doors can't open it either; Knox Pass unlocks it to open and locks it again once closed. A house door's original key keeps working, so whoever holds that key can still open it.
[*] [b]Your old locks stay intact[/b]: a map door that was locked goes back to exactly the same kind of lock after closing, so its original key still works.
[*] [b]On foot[/b]: right-click → Knox Pass → [b]Open with Knox Pass[/b]. The owner, admins, and anyone carrying a registered, charged tag can use it. A gate opened on foot stays open at least 5 seconds, so you can walk through even with a very short close delay.
[*] [b]Close with Knox Pass[/b]: while the gate stands open (for example after someone opened it with the original key), right-click → Knox Pass → [b]Close with Knox Pass[/b]; it closes and locks again. The same people who can open it on foot can use it.
[*] [b]Gates locked before this update[/b]: they get the new lock automatically; there's nothing to set again.
[/list]

[h3]Getting them[/h3]
[list]
[*] [b]Vehicle Tag[/b]: Electrical 2. Use a screwdriver to build it from a pager or TV remote, 2 electronics scrap and 1 battery; add one use of paint and a paintbrush to craft it in that color (see "Shell Colors" above). Also found in gas station storage, car supply stores, mechanic electrical shelves and electronics stores, in a random color.
[*] [b]Gate Reader[/b]: Electrical 4. Use a screwdriver to build it from a radio receiver, 3 electronics scrap and 2 electrical wires; it can be crafted in color the same way. Also found in electrician tool boxes, electronics crates, hardware stores and mechanics, in a random color.
[*] [b]Boom Barrier Kit[/b]: Electrical 4. Use a screwdriver to build it from 1 Gate Reader (any color), 2 iron pipes, 1 steel sheet and 2 electrical wires. Crafting only; it isn't found as loot.
[*] [b]Gates you build[/b]: roll-up garage doors, two-story roll-up doors, two-story gates and double boom barriers all come from the build menu; see "Build your own gates" above for materials and skills.
[/list]

[h2]⚙️ Server settings (sandbox page "Knox Pass")[/h2]
[list]
[*] [b]Read range[/b]: 8 tiles by default (2–50). The range around the gate while the car stands still; owners can set each gate to a value within the limits.
[*] [b]Read range minimum / maximum[/b]: 2 / 30 tiles by default (2–50). The window's dropdown only lists this range, and each gate's effective value is kept inside it.
[*] [b]Look-ahead seconds[/b]: 2 by default (0–5). How far ahead along the car's movement to look; 0 uses the plain range only.
[*] [b]Self-driving early open distance[/b]: 150 tiles by default (0–250). When a car under Minidoracat AutoDrive heads for the gate (the gate within about 12 degrees of its direction of travel), the gate opens once the car is this close; the server must have the gate's area loaded first, so in practice it opens about 70–130 tiles out. 0 treats it like any other car.
[*] [b]Auto-close delay[/b]: 2 seconds by default (0–120).
[*] [b]Auto-close delay minimum / maximum[/b]: 0 / 30 seconds by default (0–120); they work like the read range limits.
[*] [b]Reader needs power[/b]: on by default. Grid power or a generator both count, and outdoor gates do get grid power.
[*] [b]Tag battery drain[/b]: 100% by default (0–500%, 0 means it never runs out).
[*] [b]Allow crafting[/b] and [b]Spawn as loot[/b]: on by default.
[/list]

[h2]⚠️ Known limitations[/h2]
[list]
[*] Modded gates built some other way (for example ones that fake opening by swapping textures in code) aren't supported automatically. Mod authors can hook them in through the public interface, and players can ask for support in the feedback section.
[*] Garage doors built from the vanilla build menu aren't supported (the game itself doesn't open them as a group); for a garage door that opens by itself, build a Knox Pass roll-up garage door instead.
[*] The door pieces of the barriers, roll-up doors and two-story gates you build are garage doors, which the game doesn't let you barricade.
[*] A parked car with nobody in it and the engine off doesn't recharge its tag.
[*] When a self-driving car passes along another road heading almost straight at the gate (for example a parallel road a few dozen tiles away), the gate may open early and close again a few seconds later.
[*] The server can only open a gate once it has loaded that part of the map (roughly 60–130 tiles ahead of the car). With older AutoDrive versions a self-driving car may now and then see the gate closed a moment before it opens and slow down or drive around; newer versions are not affected. If the gate never opens, the self-driving car stops in front of it and waits or hands control back, just like at any closed gate; when the reason is something like an unpowered reader or a tag that isn't registered at that gate, newer AutoDrive versions tell you why in the top-right corner and with a voice line.
[*] Low fence gates can always be climbed over; the lock doesn't stop climbing.
[*] Barrier lamps are just a color and don't glow at night.
[/list]

[h2]📜 Where the name comes from[/h2]
"Knox Pass" combines the game's Knox County, Kentucky, with the way American toll tags were named (E-ZPass, TollTag).
[list]
[*] The game starts on July 9, 1993. 24 days later, on August 2, 1993, the New York State Thruway opened electronic tolling at Spring Valley, the start of E-ZPass ([url=https://rosap.ntl.bts.gov/view/dot/3157/dot_3157_DS1.pdf]E-ZPass evaluation report, 2000[/url]).
[*] Electronic tolling was already running in Norway in 1987, Dallas in 1989 and Oklahoma in 1991, and in the 1990s the same TollTag could open gated communities ([url=https://transcore.com/wp-content/uploads/2017/01/History-of-RFID-White-Paper.pdf]TransCore's RFID history white paper[/url]).
[*] The first TollTag in 1989 was a credit-card-sized plastic box about 6 mm thick that hung on the windshield and could move to another car ([url=https://www.dallasnews.com/news/transportation/2014/08/07/as-tolltags-turn-25-originals-hang-on-for-dallas-area-motorists/]Dallas News, 2014[/url]). The Knox Pass tag is modelled on it.
[*] The original quotes with screenshots of the source pages, page numbers and archived links are collected on [url=https://github.com/Minidoracat/MinidoracatKnoxPassFor42/blob/main/docs/name-origin.md]GitHub (in Chinese, quotes in the original English)[/url].
[/list]

[h2]❓ FAQ[/h2]
[list]
[*] [b]I drove up and nothing opened.[/b] Check that you're in the driver's seat, the tag has charge, this tag is registered at this gate, and the reader has power (the window shows it).
[*] [b]The gate won't close.[/b] It waits while a car or a person is in the doorway (zombies don't count). It also stays open until a registered car has fully passed through, then closes after the close delay.
[*] [b]Can other players open my gate?[/b] Only the tags you registered can. Once locked, neither bare hands nor zombies can open it, except someone holding that door's original key; an unlocked gate can still be opened by hand as usual.
[*] [b]Can zombies open my gate?[/b] Not one with the Knox Pass lock on. An unlocked gate can be opened by zombies when the server lets zombies open doors, as in vanilla.
[*] [b]Is it safe in multiplayer?[/b] Opening, closing, locking and registering are all checked by the server, and the registrations live only on the server.
[*] [b]Removing this mod?[/b] First turn off "Lock (only Knox Pass opens it)" on every locked gate, or take its reader back; otherwise the gate stays locked after removal and can only be broken down unless someone has its original key. Also dismantle Knox Pass barriers, roll-up doors and gates first, as they may not display or work after removal. Tags in cars and all other Knox Pass items disappear.
[/list]

[h2]💬 Feedback[/h2]
[list]
[*] GitHub Issues: https://github.com/Minidoracat/MinidoracatKnoxPassFor42/issues
[*] Discord: https://discord.gg/Gur2V67
[/list]
Please include your game version, mod list, and what happened (which kind of gate, single player or multiplayer).
