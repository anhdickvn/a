# Minecraft v40

Based on v39. Movement logic is preserved.

Fixes in v40:
- GUI/inventory `...` opens the item tooltip directly; no intermediate action sheet.
- Chat `show_item` hover opens a detailed item view with quantity, lore and parsed enchantments.
- GUI/inventory item NBT enchantments are shown inside the display-lore tooltip.
- Hover-item tap data preserves enchantments through the local `minecraft-item://` bridge.
- Background handling no longer starts the silent-audio keep-alive or sends idle movement while the app is backgrounded.
- Network send/receive errors while backgrounded are deferred until foreground instead of immediately surfacing POSIX 89.
- Foreground recovery uses a delayed stale-socket check and reconnect, matching the expected ChatCraft-like behavior more closely.
- Background audio mode was removed from Info.plist.
