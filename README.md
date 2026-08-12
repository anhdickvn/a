# Minecraft-FIXED-UI-v16

Based on v15.

Changes in v16:
- Chat components now preserve Minecraft `clickEvent.action=open_url`, including links attached to text such as Đăng nhập, Đăng ký, and Đổi mật khẩu. Links are blue, underlined, and open through iOS after the existing chat click-action confirmation.
- Raw URLs remain auto-detected and underlined.
- Client Settings + `MC|Brand` are sent after Join Game instead of immediately at Login Success, matching the Play-state lifecycle more closely.
- Idle movement heartbeat uses the protocol-340 Player packet at 20Hz when stationary, matching the normal vanilla C03 player tick behavior more closely.
- Server-issued Play Disconnect is no longer immediately auto-reconnected; this prevents kick/reconnect loops such as a proxy repeatedly returning `This command cannot be executed on this server`. The exact server disconnect reason remains visible in the connection notice/log.
- WASD/JUMP touch buttons use direct UIKit touch-down/up handling with larger hit targets and exclusive touch handling.

Important: this does not spoof another launcher/client identity or bypass a server's anti-bot/anti-cheat/session checks. It only makes the protocol lifecycle more standards-compliant and exposes the server's actual disconnect reason.
