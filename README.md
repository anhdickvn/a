# Minecraft v30 - ChatCraft scroll + WASD touch fix

Changes:
- Chat transcript is updated only when transcript data changes; typing in the message box no longer rebuilds the UITextView and make the scrollbar jitter.
- When at bottom, new server chat follows the latest message.
- When scrolled up, incoming chat preserves the viewport and old chat remains readable.
- Vertical scrollbar is visible and white for a ChatCraft-like appearance.
- WASD movement state is no longer @Published every movement tick. Coordinate display is published only on server correction/release, so SwiftUI no longer recreates the UIKit WASD button while the finger is held.
- Movement debug is buffered and published when the key is released / jump finishes, so debug logging cannot break hold-to-move touches.
- URL click events in chat open directly instead of showing the extra "Chat click action" dialog.
- Chat hover show_item events can be tapped to open an item tooltip with a friendly item name/count instead of raw `tile.*.name` text.
- Tab completion behavior is preserved.
- iOS 16 compatibility and previous protocol fixes are preserved.

- v30-fix: Tắt hoàn toàn protocol/diagnostic debug chạy nền; chỉ giữ Debug WASD / Jump khi người dùng bật trong Settings. Không còn ring-buffer RX/TX, T+ protocol log, hay snapshot chẩn đoán tự động. Logic kết nối/gameplay hiện tại được giữ nguyên.


## v36 UI fixes
- GUI item count is shown next to each item and native resource-pack textures are used.
- One-tap `...` keeps item lore/actions accessible.
- Chat hover items preserve display name, count and lore when opened.
- TAB suggestions use the live Player List captured from server packets and show matching player names vertically.
- Chat input is placed in the keyboard safe-area inset so the keyboard pushes the transcript upward instead of covering it.
