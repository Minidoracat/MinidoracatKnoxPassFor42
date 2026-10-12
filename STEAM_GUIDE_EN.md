<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3817842691 -->
<!-- Steam guide source (English): the full reference for this mod; the Workshop description only summarizes. Format and sync: pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 Knox Pass Mod Guide: Tags, Readers & Hands-free Gates -->
<!-- 摘要：Illustrated guide to the Minidoracat Knox Pass mod: the Vehicle Tag, the Gate Reader, co-managers, the Map Watch sensor module, shell colors, boom barriers and gates you build, hands-free opening and closing, the gate lock and opening on foot, how to get them, plus server settings and FAQ. -->
=== 🚀 Quick start
[b]繁體中文版：[/b][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817842603]感應大門 MOD 完整說明[/url]

The mod on Steam Workshop:
https://steamcommunity.com/sharedfiles/filedetails/?id=3814684002

Knox Pass lets you drive home without getting out: put a tag in the car and a reader on the gate, and registered cars open the gate as they drive up, then it closes behind them.
[olist]
[*] [b]Get them[/b]: a Vehicle Tag and a Gate Reader, crafted or looted (see "Getting them").
[*] [b]Install the tag[/b]: open the vehicle mechanics panel and install the tag under "Knox Pass"; you need the car key or an unlocked door.
[*] [b]Install the reader[/b]: with the reader and a screwdriver, right-click the gate → Knox Pass → "Install Knox Pass reader".
[*] [b]Register the car[/b]: park next to the gate, right-click → Knox Pass → "Manage reader", check the car on the "Nearby" tab and press "Register".
[/olist]
=== 🧰 Vehicle Tag
{{img:07-mechanics-tag-en.jpg}}
[list]
[*] [b]A real vehicle part[/b]: every car with a battery has the slot, vanilla and modded alike; bicycles and trailers don't.
[*] [b]Installing[/b]: install or remove it from the "Knox Pass" category of the mechanics panel. No tools or skills needed.
[*] [b]Theft-proof[/b]: you need the car key or an unlocked door, so nobody can steal it from a locked car.
[/list]
[h3]Battery[/h3]
[list]
[*] [b]Built-in battery[/b]: recharges slowly while installed in a car whose engine is running and whose battery is above 10%.
[*] [b]Drain[/b]: each gate opening uses a little charge.
[*] [b]Empty[/b]: an empty tag opens nothing.
[/list]
[h3]Moves with the tag[/h3]
[list]
[*] The gate registers this tag, not the car. Move the tag to another car and it still opens the same gate.
[*] When you remove or install it in the mechanics panel, the car name in the management window updates right away; a removed tag shows as "Not in a vehicle".
[/list]
[h3]You can see it[/h3]
{{img:10-windshield-tag-en.jpg}}
[list]
[*] Once installed, the tag shows at the top of the windshield on vanilla cars and on the listed modded vehicles.
[*] List and requests: [url=https://steamcommunity.com/workshop/filedetails/discussion/3814684002/586187800874015388/]🚗 Supported Modded Vehicles & Requests[/url].
[*] On other modded vehicles it may not be visible, but it works the same.
[/list]
=== 🧰 Gate Reader
[list]
[*] [b]Where it fits[/b]: map doors, fence gates, double doors, garage doors, player-built doors and gates, and Knox Pass's own roll-up garage doors, two-story roll-up doors and two-story gates (see "Build your own gates").
[*] [b]Installing[/b]: right-click the gate with the reader and a screwdriver. Whoever installs it owns it. The server can limit readers to your own safehouse (see "Server settings").
[*] [b]Where it shows[/b]: on the gate post; on the face of the pillar for two-story gates, and on top of the cabinet for boom barriers and double boom barriers. It doesn't block people or cars.
[*] [b]Removing[/b]: the owner or a server admin can take the reader back with a screwdriver. If Knox Pass has the gate open, it closes it first and restores the original lock. Co-managers can't remove it.
[/list]
[h3]Management window[/h3]
{{img:05-manage-window-en.jpg}}
[list]
[*] [b]Who can open it[/b]: the owner, co-managers and server admins. For anyone else the window closes right away and says why.
[*] [b]It shows[/b]:
[list]
[*] gate type, owner, power, lock
[*] this gate's read range, close delay, speed, sharing and co-managers
[*] "Registered" tab: registered cars and watch modules (charge, last pass), most recent pass first; 64 entries at most, cars and modules together
[*] "Nearby" tab: unregistered cars with a tag and people wearing a sensor module within 15 tiles, nearest first
[/list]
[*] [b]Read range[/b]: while the window is open, an amber circle on the ground shows this gate's read range (the range for a car standing still; faster cars open it sooner).
[*] [b]Several at once[/b]: each car has a checkbox; click a car to check it, or "Select all" for the whole tab. "Register (N)" or "Unregister (N)" handles them in one go; unregistering asks first.
[/list]
{{img:15-range-circle-en.jpg}}
[h3]Per-gate settings[/h3]
[list]
[*] [b]Read range and close delay[/b]: the owner, a co-manager or an admin picks them from two dropdowns in the window, limited to what the server allows (2–30 tiles and 0–30 seconds by default).
[*] [b]Server default[/b]: follows the sandbox setting.
[*] [b]If the server narrows the limits[/b]: gates that were set follow the new limits and keep their value.
[*] [b]Speed[/b]: boom barriers, double boom barriers, two-story roll-up doors and two-story gates can be set to [b]Normal (4 s)[/b] or [b]Fast (2.5 s)[/b] under "Speed", and every player sees the same speed.
[*] [b]Fixed speed[/b]: one-story roll-up doors and vanilla doors; the dropdown says "Not adjustable".
[*] [b]Share with[/b]: pick [b]Faction[/b], [b]Safehouse[/b] or [b]Faction + safehouse[/b] to let teammates open and close this gate on foot without a tag (see "Opening and closing on foot"). Not shared by default.
[/list]
[h3]Co-managers[/h3]
[list]
[*] [b]Open the list[/b]: press the button on the "Co-managers" row of the management window.
[*] [b]Adding someone[/b]: type a player account in the search box, pick them from the dropdown and press "Add"; up to 8 people.
[*] [b]Who you can find[/b]: online players show up after typing part of the account; offline players need the full account (same upper/lower case); an account that has never been online on this server can't be added, so wait until they log in once.
[*] [b]Your faction[/b]: turn on "Members of faction "…"" and everyone in the owner's faction counts as a co-manager; people who join later count too, and leaving the faction ends it.
[*] [b]What they can do[/b]: open the management window, change settings, register and unregister, lock, open and close on foot, and repaint the reader.
[*] [b]What they can't[/b]: remove the reader or change the co-manager list; only the owner and server admins can.
[*] Works in multiplayer only.
[/list]
=== 🧰 Shell colors and repainting
{{img:11-shell-colors-en.jpg}}
[list]
[*] [b]7 colors[/b]: tags and readers come in Cream, Black, Graphite, Olive, Navy, Safety Orange and Red.
[*] [b]Looted ones[/b]: random color.
[*] [b]Painting needs[/b]: a paintbrush plus one use of the matching vanilla paint.
[/list]
[table]
[tr][th]Shell color[/th][th]Paint[/th][/tr]
[tr][td]Cream[/td][td]White paint[/td][/tr]
[tr][td]Graphite[/td][td]Gray paint[/td][/tr]
[tr][td]Olive[/td][td]Green paint[/td][/tr]
[tr][td]Navy[/td][td]Blue paint[/td][/tr]
[tr][td]Black, Safety Orange, Red[/td][td]The same-named paint[/td][/tr]
[/table]
[h3]Craft it in color[/h3]
[list]
[*] The crafting list has one entry per color (for example "Craft Knox Pass Vehicle Tag (Black)").
[*] It takes the usual materials plus one use of that paint, and you need a paintbrush (it isn't used up).
[*] Without paint you craft a Cream one.
[/list]
[h3]Repainting[/h3]
[list]
[*] [b]In your inventory[/b]: right-click a tag or reader you carry (bags count) → "Repaint" → pick a color. Colors you lack paint or a paintbrush for are grayed out; hover to see what's missing.
[*] [b]A repainted tag[/b]: keeps its charge and its registration at every gate, so it opens the same gates.
[*] [b]A reader on a gate[/b]: the owner, a co-manager or an admin right-clicks the gate → Knox Pass → "Repaint"; your character walks to the gate and paints it, and registrations stay as they are.
[*] [b]A tag in a car[/b]: the windshield shows its color. To repaint it, remove it in the mechanics panel first, then install it again.
[*] [b]Can't be repainted[/b]: the built-in reader of a boom barrier or double boom barrier.
[/list]
=== 🧰 Boom barrier
{{img:02-barrier-opens-en.jpg}}
[list]
[*] [b]Building[/b]: craft a "Knox Pass Boom Barrier Kit" and place it on the road from the build menu.
[*] [b]Size[/b]: 4 tiles, 1 for the cabinet and 3 for the lane.
[*] [b]Direction[/b]: rotate it while building to face any of four directions, with the cabinet at either end of the lane.
[*] [b]Built-in reader[/b]: whoever builds it owns it, and registration, the lock, power and the management window all work like a gate. The reader can't be removed on its own.
[/list]
{{img:13-barrier-directions-en.jpg}}
[h3]Easy to read[/h3]
[list]
[*] [b]Closed[/b]: the pivot lamp is red and a STOP sign hangs from the arm.
[*] [b]Opening for a registered car[/b]: the arm lifts over about 4 seconds, easing in and out, and the lamp turns green.
[*] [b]Lane[/b]: stop lines and KNOX PASS lettering are painted on both sides.
[/list]
[h3]Removing and damage[/h3]
[list]
[*] [b]Dismantling[/b]: dismantling the cabinet removes the whole barrier and gives the kit back.
[*] [b]Damage[/b]: if the cabinet or the lane gets broken, the whole barrier is destroyed with no refund.
[*] [b]Durability[/b]: new barriers have 1000 on the cabinet and lane; barriers built before this update keep their old durability.
[/list]
=== 🧰 Build your own gates
{{img:12-roll-doors-en.jpg}}
[h3]Roll-up garage doors[/h3]
[list]
[*] [b]Find it[/b]: search the build menu for "Roll-up Garage Door".
[*] [b]Styles[/b]: vanilla look in Industrial White, Green and White, each 3, 4, 6 or 9 tiles wide (6 fits two cars side by side, 9 fits three).
[*] [b]Needs[/b]: Welding 3 plus a welding torch, welding rods, steel sheets, iron pipes and door hinges; wider doors take more.
[*] [b]Reader[/b]: none built in; install one like on any gate.
[/list]
[h3]Two-story roll-up doors[/h3]
[list]
[*] [b]Styles[/b]: the same three colors, 3, 4, 6 or 9 wide.
[*] [b]What's different[/b]: the curtain rolls all the way up into the box on top, so vans fit through.
[*] [b]Needs[/b]: Welding 4 and twice the materials of the one-story door of the same width.
[*] [b]Reader[/b]: none built in.
[/list]
{{img:17-wide-doors-en.jpg}}
[h3]Double boom barrier[/h3]
[list]
[*] [b]Size[/b]: 6 or 9 tiles wide, with a cabinet at each end and two arms that meet in the middle.
[*] [b]Materials[/b]: 1 boom barrier kit plus iron pipes, steel sheets and wire (6 wide: 4, 2 and 2; 9 wide: 6, 3 and 2).
[*] [b]Needs[/b]: a screwdriver; no skill needed.
[*] [b]Reader[/b]: built in, and the builder owns it.
[/list]
[h3]Two-story gates[/h3]
{{img:16-two-story-gates-en.jpg}}
6 or 9 tiles wide double gates in five looks:
[table]
[tr][th]Look[/th][th]Needs[/th][/tr]
[tr][td]Chain-link, Steel Plate, Iron Bars[/td][td]Welding 5[/td][/tr]
[tr][td]Ranch Wood[/td][td]Carpentry 5[/td][/tr]
[tr][td]Medieval Oak[/td][td]Carpentry 5, plus Welding 2 for its iron bands[/td][/tr]
[/table]
[list]
[*] [b]Swing side[/b]: rotating while building picks which side the leaves swing to.
[*] [b]Reader[/b]: none built in; once installed, the reader hangs on the face of the post.
[/list]
[h3]Durability, removing and animation[/h3]
[table]
[tr][th]Width[/th][th]Durability[/th][/tr]
[tr][td]One car (3 or 4 wide)[/td][td]1000[/td][/tr]
[tr][td]Two cars (6 wide)[/td][td]1500[/td][/tr]
[tr][td]Three cars (9 wide)[/td][td]2000[/td][/tr]
[/table]
[list]
[*] [b]Two-story ones[/b]: 500 more.
[*] [b]Dismantling[/b]: dismantling either end (cabinet or post) of a double boom barrier or two-story gate removes the whole thing and refunds only that end's materials.
[*] [b]Damage[/b]: if any door piece gets broken, the whole thing is destroyed with no refund.
[*] [b]Animation[/b]: arms, roll-up curtains and gate leaves ease in and out as they move, taking about 4 seconds each way (about 2.5 with "Fast" in the window).
[*] [b]Several at once[/b]: several gates moving at once each run on their own.
[/list]
=== 🧰 Hands-free opening and closing
{{img:01-gate-opens-ahead-en.jpg}}
[list]
[*] [b]Who opens it[/b]: the driver of a car carrying a registered, charged tag.
[*] [b]Opens nothing[/b]: passengers, unregistered cars and empty tags.
[*] [b]Opens early[/b]: the server predicts where the car is heading from its actual movement, so the faster you drive the earlier it opens; driving past in another direction doesn't.
[/list]
[h3]Closes by itself[/h3]
{{img:14-trailer-pass-en.jpg}}
[list]
[*] [b]Only its own[/b]: it only closes gates Knox Pass opened.
[*] [b]Countdown after passing[/b]: once a registered car, including any trailer it tows, has fully passed through the gateway, the close countdown starts; it doesn't wait for the car to leave the read range.
[*] [b]Parked inside[/b]: a car parked inside doesn't hold it open.
[*] [b]Turning back[/b]: turning back toward the gate opens it again.
[*] [b]Never closes on anything[/b]: it waits while a car or a person is in the doorway and tries again two seconds later.
[*] [b]Zombies don't hold it[/b]: zombies alone don't hold it open, so zombies following a car in can't keep the gate open.
[/list]
[h3]Warning before you reach it[/h3]
{{img:03-barrier-warning-en.jpg}}
[list]
[*] When you drive toward a Knox Pass gate or barrier that won't open for you, you get a message above your head and in the top-right corner about 20 tiles before it, so you don't drive straight into it.
[*] [b]Reasons it gives[/b]: no tag installed, the tag isn't registered at that gate, an empty tag, an unpowered reader.
[/list]
[h3]With Minidoracat AutoDrive[/h3]
{{img:04-autodrive-through-gate-en.jpg}}
[list]
[*] [b]Opens out of sight[/b]: when a self-driving car heads for the gate, the gate opens while it is still out of the car's sight.
[*] [b]Newer AutoDrive versions[/b]: know in advance that the gate will open for them, so they never slow down or detour for it.
[*] For the distance, see "Self-driving early open distance" under "Server settings".
[/list]
=== 🧰 Gate lock and opening on foot
{{img:06-gate-menu-en.jpg}}
[h3]Gate lock[/h3]
[list]
[*] [b]Turning it on[/b]: the owner, a co-manager or an admin can turn on "Lock (only Knox Pass opens it)" in the right-click menu or the window. When the server doesn't allow locking outside safehouses, the option is grayed out for gates outside one and says why; a gate that is already locked can still have its lock turned off.
[*] [b]Once locked[/b]: it can't be opened bare-handed, and zombies that open doors can't open it either.
[*] [b]Opening and closing[/b]: boom barriers, garage roll-up doors, two-story gates and garage doors stay locked while open, so without the key use "Close with Knox Pass" to shut them; other gates are unlocked to open and locked again once closed.
[*] [b]Original keys[/b]: a house door's original key keeps working, so whoever holds that key can still open it.
[*] [b]Your old locks stay intact[/b]: a map door that was locked goes back to exactly the same kind of lock after closing, so its original key still works.
[*] [b]Gates locked before this update[/b]: they get the new lock automatically; there's nothing to set again.
[/list]
[h3]Opening and closing on foot[/h3]
[list]
[*] [b]Open with Knox Pass[/b]: right-click → Knox Pass → "Open with Knox Pass".
[*] [b]Who can use it[/b]: the owner, co-managers, admins, teammates the owner shares the gate with, anyone carrying a registered, charged tag, and anyone wearing a registered watch sensor module.
[*] [b]Sharing with teammates[/b]: once the owner picks a faction or safehouse under "Share with" in the management window, the leader and members of the owner's faction, or anyone in a safehouse with the owner, can use it; it stops when the owner leaves that faction or safehouse. Teammates can only open and close the gate; they can't register cars or change settings. Multiplayer only.
[*] [b]At least 5 seconds[/b]: a gate opened on foot stays open at least 5 seconds, so you can walk through even with a very short close delay.
[*] [b]Close with Knox Pass[/b]: while the gate stands open (for example after someone opened it with the original key), right-click → Knox Pass → "Close with Knox Pass"; it closes and locks again. The same people who can open it on foot can use it.
[/list]
=== 🧰 Map Watch sensor module
Needs [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3816406671]Minidoracat MiniMap - Map Watch[/url] (42.21.0-0.3.0 or later); without the Map Watch nothing changes.
[list]
[*] [b]Crafting[/b]: "Craft Knox Pass Sensor Module (for the Map Watch)"; see "Getting them".
[*] [b]Into the watch[/b]: it goes in a standard slot of the Map Watch and adds 10% power use.
[*] [b]Registering[/b]: with the wearer within 15 tiles of the gate, check "Watch module (name)" on the "Nearby" tab of the management window and press "Register".
[*] [b]Walk up and it opens[/b]: walk toward the gate wearing a registered module and it opens within 3 tiles; after you pass it closes with the gate's close delay. Standing still or walking along the gate doesn't open it.
[*] [b]Driving counts too[/b]: if the driver wears a registered module, the gate opens for any car.
[*] [b]Right-click knows it[/b]: "Open with Knox Pass" and "Close with Knox Pass" accept the module you wear.
[*] [b]When it does nothing[/b]: the watch isn't worn, has no power, or the module's slot is disabled.
[*] [b]When the gate can't open[/b]: if the reader has no power or the doorway is blocked, a note above your head and at the top right says why, once per gate every 30 seconds.
[*] [b]Registered list[/b]: shows who is wearing it; when nobody is, who passed last and when. It never shows where the module is.
[*] [b]Per gate[/b]: turn off "Registered watch modules open it on approach" in the management window and walking no longer opens that gate; driving and right-click still accept the module.
[/list]
[h3]Map markers[/h3]
[list]
[*] The minimap and the world map mark the gates your module opens.
[*] In the map settings, the "Knox Pass" section under "Add-ons" turns the markers off, sets their size, and chooses whether to show gate types.
[/list]
=== 🧰 Getting them
{{img:08-craft-recipes-en.jpg}}
All crafted with a screwdriver:
[table]
[tr][th]Item[/th][th]Skill[/th][th]Materials[/th][th]Where to loot[/th][/tr]
[tr][td]Vehicle Tag[/td][td]Electrical 2[/td][td]A pager or TV remote, 2 electronics scrap, 1 battery[/td][td]Gas station storage, car supply stores, mechanic electrical shelves, electronics stores[/td][/tr]
[tr][td]Gate Reader[/td][td]Electrical 4[/td][td]A radio receiver, 3 electronics scrap, 2 electrical wires[/td][td]Electrician tool boxes, electronics crates, hardware stores, mechanics[/td][/tr]
[tr][td]Boom Barrier Kit[/td][td]Electrical 4[/td][td]1 Gate Reader (any color), 2 iron pipes, 1 steel sheet, 2 electrical wires[/td][td]Crafting only; it isn't found as loot[/td][/tr]
[tr][td]Knox Pass Sensor Module[/td][td]Electrical 3[/td][td]1 Vehicle Tag (any color), 2 electronics scrap[/td][td]Crafting only, with the Map Watch installed[/td][/tr]
[/table]
[list]
[*] [b]Looted color[/b]: random.
[*] [b]Craft in color[/b]: add one use of paint and a paintbrush to craft a tag or reader in that color (see "Shell colors and repainting").
[*] [b]Gates you build[/b]: roll-up garage doors, two-story roll-up doors, two-story gates and double boom barriers all come from the build menu; see "Build your own gates" for materials and skills.
[*] [b]Sensor module[/b]: only craftable with the Map Watch installed, and not when the server turns off "Registered watch modules open gates on approach".
[/list]
=== ⚙️ Server settings
{{img:09-sandbox-options-en.jpg}}
Sandbox page "Minidoracat Knox Pass":
[table]
[tr][th]Option[/th][th]Default[/th][th]Range[/th][/tr]
[tr][td]Default reader range (tiles)[/td][td]8[/td][td]2–50[/td][/tr]
[tr][td]Reader range minimum / maximum (tiles)[/td][td]2 / 30[/td][td]2–50[/td][/tr]
[tr][td]Look-ahead time (seconds)[/td][td]2[/td][td]0–5[/td][/tr]
[tr][td]Self-driving early open distance (tiles)[/td][td]150[/td][td]0–250[/td][/tr]
[tr][td]Default auto-close delay (seconds)[/td][td]2[/td][td]0–120[/td][/tr]
[tr][td]Auto-close delay minimum / maximum (seconds)[/td][td]0 / 30[/td][td]0–120[/td][/tr]
[tr][td]Gate readers need power[/td][td]On[/td][td][/td][/tr]
[tr][td]Vehicle tag drain multiplier (percent)[/td][td]100%[/td][td]0–500%[/td][/tr]
[tr][td]Allow crafting Knox Pass items[/td][td]On[/td][td][/td][/tr]
[tr][td]Spawn Knox Pass items in world loot[/td][td]On[/td][td][/td][/tr]
[tr][td]Readers outside safehouses[/td][td]No limit[/td][td]No limit / No locking / No installing[/td][/tr]
[tr][td]Registered watch modules open gates on approach[/td][td]On[/td][td][/td][/tr]
[tr][td]Watch module range (tiles)[/td][td]3[/td][td]1–8[/td][/tr]
[/table]
[list]
[*] [b]Reader range[/b]: the range around the gate while the car stands still; owners can set each gate to a value within the limits.
[*] [b]Minimum / maximum[/b]: the window's dropdown only lists this range, and each gate's effective value is kept inside it. The close delay limits work the same way.
[*] [b]Look-ahead time[/b]: how far ahead along the car's movement to look; 0 uses the plain range only.
[*] [b]Self-driving early open distance[/b]: when a car under Minidoracat AutoDrive heads for the gate (the gate within about 12 degrees of its direction of travel), the gate opens once the car is this close. The server must have the gate's area loaded first, so in practice it opens about 70–130 tiles out. 0 treats it like any other car.
[*] [b]Gate readers need power[/b]: grid power or a generator both count, and outdoor gates do get grid power.
[*] [b]Tag drain multiplier[/b]: 0 means it never runs out.
[*] [b]Readers outside safehouses[/b]: applies when a gate isn't in the reader owner's safehouse, multiplayer only. "No locking" = the Knox Pass lock can't be turned on, opening works as usual; "No installing" = readers only go in your own safehouse. Gates already locked stay locked, and the owner, a co-manager or an admin can turn the lock off. This stops people from putting a reader on someone else's door and locking it.
[*] [b]Watch modules[/b]: need the Map Watch. When off, walking doesn't open gates and the module can't be crafted; driving and right-click opening still accept the module. The range is how close to the gate line it opens.
[*] [b]Server admins[/b]: roles that can manage safehouses (moderator and admin by default) can manage every reader; if the server owner changed role permissions, the actual permissions apply.
[/list]
=== ⚠️ Known limitations
[list]
[*] [b]Modded gates built another way[/b]: not supported automatically (for example ones that fake opening by swapping textures in code). Mod authors can hook them in through the public interface, and players can ask for support in the feedback section.
[*] [b]Vanilla build-menu garage doors[/b]: not supported (the game itself doesn't open them as a group); for a garage door that opens by itself, build a Knox Pass roll-up garage door instead.
[*] [b]No barricading[/b]: the door pieces of the barriers, roll-up doors and two-story gates you build are garage doors, which the game doesn't let you barricade.
[*] [b]Parked cars don't charge[/b]: a parked car with nobody in it and the engine off doesn't recharge its tag.
[*] [b]Parallel roads[/b]: when a self-driving car passes along another road heading almost straight at the gate (for example a parallel road a few dozen tiles away), the gate may open early and close again a few seconds later.
[*] [b]Map must be loaded[/b]: the server can only open a gate once it has loaded that part of the map (roughly 60–130 tiles ahead of the car).
[*] [b]With AutoDrive[/b]:
[list]
[*] With older AutoDrive versions a self-driving car may now and then see the gate closed a moment before it opens and slow down or drive around; newer versions are not affected.
[*] If the gate never opens, the self-driving car stops in front of it and waits or hands control back, just like at any closed gate.
[*] When the reason is something like an unpowered reader or a tag that isn't registered at that gate, newer AutoDrive versions tell you why in the top-right corner and with a voice line.
[/list]
[*] [b]Low fence gates[/b]: can always be climbed over; the lock doesn't stop climbing.
[*] [b]Barrier lamps[/b]: just a color; they don't glow at night.
[/list]
=== ❓ FAQ
[h3]I drove up and nothing opened?[/h3]
Check that:
[list]
[*] you're in the driver's seat and the tag has charge
[*] this tag is registered at this gate
[*] the reader has power (the window shows it)
[/list]
[h3]The gate won't close?[/h3]
[list]
[*] It waits while a car or a person is in the doorway (zombies don't count).
[*] It also stays open until a registered car has fully passed through, then closes after the close delay.
[/list]
[h3]Can other players open my gate?[/h3]
[list]
[*] Only the tags you registered can; if you share the gate with your faction or safehouse in the management window, those teammates can open and close it on foot too.
[*] Co-managers you add can open and close it, and change its settings and registrations.
[*] Anyone wearing a watch sensor module registered at this gate opens it by walking up.
[*] Once locked, neither bare hands nor zombies can open it, except someone holding that door's original key.
[*] An unlocked gate can still be opened by hand as usual.
[/list]
[h3]Can zombies open my gate?[/h3]
[list]
[*] Not one with the Knox Pass lock on.
[*] An unlocked gate can be opened by zombies when the server lets zombies open doors, as in vanilla.
[/list]
[h3]My teammate can't open the management window?[/h3]
[list]
[*] Only the owner, co-managers and server admins can; sharing with a faction or safehouse only covers opening and closing on foot.
[*] To manage the gate together, add them under "Co-managers".
[/list]
[h3]Can't find a teammate's account?[/h3]
[list]
[*] Offline players need the full account (same upper/lower case).
[*] An account that has never been online on this server can't be found; wait until they log in once.
[/list]
[h3]Is it safe in multiplayer?[/h3]
[list]
[*] Opening, closing, locking, registering and the co-manager list are all checked by the server, and that data lives only on the server.
[/list]
[h3]Removing this mod?[/h3]
[list]
[*] First turn off "Lock (only Knox Pass opens it)" on every locked gate, or take its reader back; otherwise the gate stays locked after removal and can only be broken down unless someone has its original key.
[*] Also dismantle Knox Pass barriers, roll-up doors and gates first, as they may not display or work after removal.
[*] Tags in cars and all other Knox Pass items disappear.
[*] Take sensor modules out of Map Watches first, too; after removal they can't be taken out and keep the slot taken.
[/list]
=== 💬 Feedback
[list]
[*] [b][url=https://github.com/Minidoracat/MinidoracatKnoxPassFor42/issues]GitHub Issues[/url][/b]
[*] [b][url=https://discord.gg/Gur2V67]Discord[/url][/b]
[*] [b]Please include[/b]:
[list]
[*] your game version
[*] your mod list
[*] what happened (which kind of gate, single player or multiplayer)
[/list]
[/list]
=== 📜 Where the name comes from
"Knox Pass" combines the game's Knox County, Kentucky, with the way American toll tags were named (E-ZPass, TollTag).
[list]
[*] [b]August 2, 1993[/b]: the game starts on July 9, 1993. 24 days later, the New York State Thruway opened electronic tolling at Spring Valley, the start of E-ZPass ([url=https://rosap.ntl.bts.gov/view/dot/3157/dot_3157_DS1.pdf]E-ZPass evaluation report, 2000[/url]).
[*] [b]Even earlier[/b]: electronic tolling was already running in Norway in 1987, Dallas in 1989 and Oklahoma in 1991, and in the 1990s the same TollTag could open gated communities ([url=https://transcore.com/wp-content/uploads/2017/01/History-of-RFID-White-Paper.pdf]TransCore's RFID history white paper[/url]).
[*] [b]The tag's shape[/b]: the first TollTag in 1989 was a credit-card-sized plastic box about 6 mm thick that hung on the windshield and could move to another car ([url=https://www.dallasnews.com/news/transportation/2014/08/07/as-tolltags-turn-25-originals-hang-on-for-dallas-area-motorists/]Dallas News, 2014[/url]). The Knox Pass tag is modelled on it.
[*] [b]Sources[/b]: the original quotes with screenshots of the source pages, page numbers and archived links are collected on [url=https://github.com/Minidoracat/MinidoracatKnoxPassFor42/blob/main/docs/name-origin.md]GitHub (in Chinese, quotes in the original English)[/url].
[/list]
