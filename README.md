# Minecraft

iOS Minecraft Java chat client based on the existing ChatCraft-style project.

## Connection logic
- Default connection target remains `proxy.toichoi.com:54321` in the saved default server profile.
- The client uses protocol 760 (Minecraft 1.19.2) for the Tôi Chơi proxy and does not switch protocol based on Server List Ping. Core keep-alive, join, player-info, position, health, resource-pack, chat, held-item and use-item packet IDs are selected for protocol 760.
- Login/play disconnects, socket failures and login timeouts use automatic reconnect while the user session is still active.
- Each saved server has an explicit “Sử dụng /login khi vào server” toggle. When disabled, no automatic `/login` or compass/right-click automation is sent.
- Leaving the chat screen or putting the app in the background does not explicitly disconnect the shared client.
- The iOS background keep-alive remains available while the app is backgrounded; force-quitting an iOS app cannot be prevented by an application.

## Compression / packet stability
- Minecraft compression accepts both raw DEFLATE and RFC1950-wrapped streams to tolerate proxies that differ in framing.
- Invalid compressed packets are discarded without trying to parse the compressed bytes as a normal packet.
- Packet draining is limited per main-thread turn so a burst of server packets cannot monopolize SwiftUI's run loop.
- Internal info/debug messages are not rendered in the chat view.

## ChatCraft-style UI (v6)
- App display name: `Minecraft`.
- Default appearance: dark.
- Settings still provides Dark / Light / Auto.
- Bottom navigation remains ChatCraft-style: Chat, Logs, Settings.
- Chat text uses a tighter ChatCraft-like size/spacing, black background, and the supplied blue arrow controls above the composer.
- Display Lore opens on a black background with Minecraft colors preserved, without Left/Right click buttons.
- GUI is compact like the supplied ChatCraft reference, opens from the briefcase button after commands such as `/ah` or `/k 1`, has real Minecraft item icons, `...` actions and a close button.
- XYZ / coordinate panels were removed from the GUI.
- GUI actions include Display lore, Left click, Right click and Drop all.

## Player list / commands
- Player List Item is decoded using the protocol-340 clientbound packet ID `0x2E`.
- The Players button shows the current online count, every player name received from the server, and cached skin/head avatars on a black background.
- `/w`, `/r`, `/msg` and other slash commands can complete player names locally from the live player list without sending repeated Tab Complete packets to the proxy.

## Controls
- W/A/S/D buttons are press-and-hold controls with repeated movement packets.
- Jump remains available as a dedicated button.
- Movement packets use the correct protocol-340 Player Position packet and are throttled to a stable 20 Hz cadence, so touch WASD and Jump are actually sent as movement.

## Logs
- Logs stores only actual server chat messages for the current day.
- Minecraft color/style segments are preserved.

## Build
The project is generated from `project.yml` and targets iOS 16.0. The GitHub repository/project target remains compatible with the existing `a` repository workflow.

## Asset caching
- Vanilla Minecraft 1.12.2 item/block assets are downloaded once on first use and kept in Application Support for future sessions.
- The previous `extracted` cache location is recognized, so old installations do not download the client jar again.
- A server resource pack is downloaded by its hash and extracted only once; subsequent reconnects reuse the cached extracted pack.


## Final UI / behavior in this revision
- Bottom navigation is exactly `Chat`, `Logs`, `Settings`; there is no In-App Purchases tab.
- Player, health, and backpack screens stay inside the Chat screen instead of opening a separate modal GUI.
- Player shows the live total online count plus cached player head icons on a black background.
- Health shows hearts, food and Respawn.
- Backpack shows hotbar/inventory and automatically shows a server GUI when `/ah`, `/k 1`, or another server action opens a Minecraft window. Tapping a GUI row performs a left click; the `...` action opens Display Lore without Left/Right buttons.
- WASD is press-and-hold at a 20 Hz cadence and Jump sends real protocol-340 Player Position packets; movement is not simulated only in the UI.
- Logs are grouped into one entry per day, with the day's complete chat history inside.
- Returning from `<` reuses the singleton client/log/socket and scrolls to the latest chat instead of starting from an empty chat.
- Vanilla Minecraft 1.12.2 assets are downloaded once into Application Support and reused permanently; server resource packs are cached by hash and extracted once. All download/extraction/index work stays off the SwiftUI main render path.
- Player head icons are also cached in Application Support so they are not downloaded again on every visit.
- The connection is kept alive while the app is backgrounded when iOS permits background execution; force-quitting the app still cannot be prevented by an iOS application.


## v6 fixes
- Live chat is capped at 700 rendered entries to prevent unbounded SwiftUI memory/render growth.
- The cap does not affect Logs: every server chat line is archived for the current day.
- Log persistence observes the newest message ID, so a new message is still archived even when the 700-entry live window is full.
- The live chat is cleared when the Minecraft socket disconnects/reconnects; Logs remains intact. Returning with the same live connection still preserves the current chat and scrolls to the newest line.
- The composer now has the ChatCraft reference arrows: down on the left for older sent text and up on the right for newer sent text.
- Protocol 340 Confirm Transaction packets are ACKed after GUI clicks, preventing inventory/menu interaction from being left waiting by the server.
- After the first server position packet, the client primes a tiny movement and returns to the original position. This handles servers that reject chat/commands until a PlayerMove event has occurred.
- Server-provided command errors keep the server's original colors. The client does not fabricate a success response; if a command is genuinely rejected by the server, its red server message remains truthful.

## Smart Minecraft GUI clicks
- Compass/hotbar item: direct tap performs Minecraft RIGHT-click / Use Item; no `...` menu is required.
- Server-selection GUI opened by the compass: direct tap on Diamond Axe / Ice / hub entries performs LEFT-click.
- `...` remains available for advanced inventory actions (lore, explicit left/right click, drop) and is not required for the normal server-selection flow.
- This is context-aware behavior. Minecraft's Window Click packet itself does not expose a field saying which mouse button a particular server menu expects, so the app uses the known Tôi Chơi interaction model rather than guessing per packet.
