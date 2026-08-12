Minecraft FIXED UI v43

Based on v42.

Movement changes:
- W/A/S/D: one conservative 0x0D position move per tap (~0.06 block).
- At most one 0x0E position+look fallback after 120ms if no server correction.
- No idle player-position heartbeat; server Keep Alive remains authoritative.
- SPACE: one small upward 0x0E jump packet, gated by server onGround state.
- Server correction cancels any movement probe.

Build compatibility:
- Removed iOS 17-only ContentUnavailableView usage.
- Uses the iOS 16-compatible onChange(of:perform:) form.
- Removed the invalid animated: argument from UITextView.scrollRangeToVisible.
