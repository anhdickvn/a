# Minecraft-FIXED-UI-v22-SESSION-HEARTBEAT

Fix tập trung vào lỗi phiên Minecraft bị server/proxy coi là idle sau một thời gian, sau đó xuất hiện `This command cannot be executed on this server` hoặc `disconnect.timeout`.

## Thay đổi chính
- Player heartbeat khi đứng yên dùng đúng packet `Player Position (0x0D)` của protocol 340, khoảng 1 lần/giây, thay vì chỉ gửi `Player/On Ground (0x0C)` thưa hơn.
- Vẫn trả `Keep Alive` serverbound đúng packet `0x0B`.
- Sửa packet compression outbound: `COMPRESSION_ZLIB` đã là RFC1950/zlib stream hoàn chỉnh, không bọc thêm header/trailer lần hai.
- Khi server chủ động ngắt bằng lý do timeout (`disconnect.timeout`, `timeout`, `timed out`, ...), Stay Connected sẽ giữ phiên và tự dựng lại TCP socket; chat không bị xoá.
- Giữ `Client Settings` + `MC|Brand` sau Join Game để flow gần client Minecraft vanilla hơn.
- Protocol wire hiện tại vẫn là Minecraft Java 1.12.2 / protocol 340, phù hợp với toàn bộ packet mapping của project hiện tại.

## Kiểm tra
`MCClient.swift` đã được kiểm tra cú pháp bằng `swiftc -parse` trên môi trường build hiện tại.

## v24 WASD/JUMP fix
- Touch controls use the existing UIKit touch-down/up path with a larger hit area.
- WASD sends real protocol-340 Player Position packets every 50 ms while held.
- Jump now sends the first off-ground position immediately, then continues the jump arc.
- Movement remains gated until the server's initial Player Position And Look is received, preventing invalid X/Y/Z=0 packets.

## v25 pre-position heartbeat fix
- Root cause of `This command cannot be executed on this server` firing a few seconds
  after joining (right around the auto Diamond Axe click): the idle heartbeat ticker
  only sent packets once `hasServerPosition` was true, and `sendPlayerGroundStatus`
  (0x0C) was defined but never called anywhere. That left a completely silent window
  between Login Success and the server's first Player Position And Look — exactly when
  `/dn` + the compass/menu automation runs — which anti-bot/AFK plugins can read as "no
  real client here".
- `startIdleAliveTicker()` now runs immediately after Login Success: sends `0x0C`
  (no coordinates, so no speed-hack risk) until the server's real spawn position
  arrives, then switches to full `0x0D` Player Position packets as before.
- The auto-login flow no longer opens the compass menu on a blind fixed 2s timer.
  `sendLoginAndScheduleMenu` now waits for `hasServerPosition` to become true (checked
  every 0.25s, minimum 2s) before clicking, capped at a 6s deadline as a fallback so it
  never hangs if a server is slow to send position.

## v26 in-chat debug tracing
- Discovered that every `appendLog(.info, ...)` call throughout the app was silently
  dropped by `appendLog()`'s own `guard kind != .info else { return }` — none of the
  existing timing/automation log lines ever reached the UI, and the small
  `connectionNotice` banner that reads `.info`/`.error` only shows while
  `state != .connected`, so nothing was visible while actually connected either. There
  was no way to see what the automation was doing at the moment the error happened.
- Added a new `MCLogEntry.Kind.debug` case that IS shown, inline in the normal chat
  scroll (`visibleLog` now includes `.debug`), rendered in gray and prefixed `🔧` so it's
  visually distinct from real server chat. A private `dbg(_:)` helper timestamps each
  line as `T+x.xxs` relative to the last Login Success.
- Debug trace points added: Login Success, Join Game, first real spawn position, `/dn`
  sent, the position-wait/menu-open decision (and whether it hit the 6s fallback), the
  right-click on the compass, every GUI window the server opens (id/title/slotCount),
  every retry while scanning slot 23, and the final Diamond Axe click.
- Added `isBlockedCommandMessage(_:)` + `dumpDiagnosticSnapshot(trigger:)`: any incoming
  chat message or disconnect reason containing "cannot be executed" / "unknown command" /
  common Vietnamese equivalents now immediately prints a `⚠️ [DIAGNOSTIC]` block (yellow)
  right under it with elapsed time since login, `hasServerPosition`, the current GUI
  window state (id/slotCount/what's in slot 23), time since the last packet received,
  time since the last heartbeat sent, and the last packet sent — all in one screenshot.
- Fixed a chat-JSON parsing bug: messages using a `translate` key together with `with`
  args used to have the translate key silently replaced by just the args (or dropped
  entirely if `with` was also empty), which could hide part of a server's real response.
  Both are now kept.

## v27 zero-rotation anti-bot fix
- User-reported evidence: `This command cannot be executed on this server` fired at
  T+64.57s and, on a separate repro with a completely different action (no GUI open,
  standing still, sent nothing but a chat command), at T+64.59s — i.e. the exact same
  elapsed time almost to the hundredth of a second, regardless of whether a GUI was open
  or what the player was doing. Both times `hasServerPosition = true`, the idle heartbeat
  was firing every ~0.3s, and the last packet received was 0.00s ago — so the connection
  and the position heartbeat were both completely healthy. Real client (TLauncher /
  vanilla) never reproduces this doing the same thing.
- That signature — a fixed ~60s server-side threshold, independent of network health or
  GUI state — matches a very common anti-bot heuristic: flag any player whose look
  direction (yaw/pitch) hasn't changed at all over a rolling window, since real players'
  hand/mouse always introduces tiny continuous rotation even standing still, while a
  scripted bot's camera is perfectly static.
- Root cause: this app has **never** sent a serverbound packet containing yaw/pitch.
  The idle heartbeat only ever sent `0x0D` (Player Position — X/Y/Z, no rotation), and
  there is no camera/look-around control in the UI at all, so `playerYaw`/`playerPitch`
  are set once from the server's spawn packet and then frozen forever from the server's
  point of view — a textbook zero-rotation bot signature.
- Fix: added `sendIdlePositionAndLook()`, which sends `0x0F` (Player Position And Look)
  instead of `0x0D` once `hasServerPosition` is true, applying a small smooth sin/cos
  jitter (~1-1.5°) to yaw/pitch each tick to mimic natural micro-movement — without
  touching the real `playerYaw`/`playerPitch` state used for WASD movement direction.
