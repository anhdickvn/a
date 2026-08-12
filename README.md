# ChatMinecraft v27

Protocol 47 / Minecraft 1.8.x fixes for the Tôi Chơi Waterfall proxy.

Key fixes in v27:
- Correct protocol-47 Join Game parsing: Dimension is a Byte.
- Correct protocol-47 Client Settings packet 0x15: no Difficulty field.
- Send standard MC|Brand plugin message for vanilla 1.8 compatibility.
- Keep packet-level PLAY debug logging for diagnosis.
