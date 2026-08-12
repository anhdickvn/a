# Minecraft v45 — Chat/Item/Background/WASD Fix

Built from v44 source.

## Fixes in v45
- WASD: finite 3-tick movement pulse (~0.18 block total) from the current server-authoritative position. No idle movement loop.
- SPACE: one jump impulse plus short authoritative resync. No repeated jump physics loop.
- Background: suppress POSIX/NWConnection 53/89 UI errors while app is in background; reconnect is deferred until foreground.
- Item `...`: opens the four actions directly: Display lore, Left click, Right click, Drop all. Drop all uses protocol 340 Click Window mode=4/button=1 (Ctrl+Q stack drop).
- Chat item mentions: standard hoverEvent.show_item remains clickable; inline plugin text such as `item.diamondSword.name 1x` is also made tappable and opens a tooltip with friendly name/count/icon when possible.
- URL: every detected/open_url link is underlined while preserving its Minecraft color and remains tappable.
- GUI/item tooltip keeps lore/enchantment lines parsed from NBT.

## WASD test
Settings -> Ghi Debug WASD / Jump -> enable, enter server, tap W, A, S, D, Space once each.
Expected trace includes `MOVE PULSE START`, three `MOVE PULSE tick` lines, `WIRE TX 0x0D`, and no repeating movement after the third tick.

## Note
The container used for this patch has Swift 6.2 frontend parsing available but not Apple's iPhoneOS/UIKit/SwiftUI SDK, so a full iOS archive cannot be performed here. All Swift sources were checked with `swiftc -frontend -parse`.
