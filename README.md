# Minecraft

iOS Minecraft Java chat client based on the existing ChatCraft-style project.

## Connection logic
- Default connection target remains `proxy.toichoi.com:54321` in the saved default server profile.
- The client intentionally keeps the existing legacy login flow instead of changing the login protocol just because Server List Ping reports a newer version such as protocol 760 (1.19.x).
- Status/version probing is not used to choose the login protocol.
- Login/play disconnects, socket failures and login timeouts use automatic reconnect while the user session is still active.
- Leaving the chat screen or putting the app in the background does not explicitly disconnect the shared client.
- The iOS background keep-alive remains available while the app is backgrounded; force-quitting an iOS app cannot be prevented by an application.

## Compression / packet stability
- Minecraft compression accepts both raw DEFLATE and RFC1950-wrapped streams to tolerate proxies that differ in framing.
- Invalid compressed packets are discarded without trying to parse the compressed bytes as a normal packet.
- Packet draining is limited per main-thread turn so a burst of server packets cannot monopolize SwiftUI's run loop.
- Internal info/debug messages are not rendered in the chat view.

## ChatCraft-style UI
- App display name: `Minecraft`.
- Default appearance: dark.
- Settings still provides Dark / Light / Auto.
- Bottom navigation remains ChatCraft-style: ChatCraft, Logs, In-App purchases, Settings.
- Chat text is larger and the main chat background is black.
- Display Lore opens as a light/white screen like the reference ChatCraft behavior.
- GUI is compact, has item icons, `...` actions and a `Close window` button.
- XYZ / coordinate panels were removed from the GUI.
- GUI actions include Display lore, Left click, Right click and Drop all.

## Player list / commands
- Player List Item is decoded using the protocol-340 clientbound packet ID `0x2E`.
- The Players button shows the current online count and every player name received from the server.
- `/w`, `/r`, `/msg` and other slash commands can complete player names locally from the live player list without sending repeated Tab Complete packets to the proxy.

## Controls
- W/A/S/D buttons are press-and-hold controls with repeated movement packets.
- Jump remains available as a dedicated button.
- Movement packets are throttled to a stable 20 Hz cadence.

## Logs
- Logs stores only actual server chat messages for the current day.
- Minecraft color/style segments are preserved.

## Build
The project is generated from `project.yml` and targets iOS 16.0. The GitHub repository/project target remains compatible with the existing `a` repository workflow.
