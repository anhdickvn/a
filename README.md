# Minecraft FIXED UI v21

## Root cause fixed: Bungee DecoderException / Unknown zlib header

The affected iOS build used Apple's `COMPRESSION_ZLIB`. Apple's API emits **raw DEFLATE (RFC 1951)**, not an RFC 1950 zlib-wrapped stream. Minecraft/Netty/Bungee compression expects the zlib wrapper. The client therefore could work until the first compressed clientbound/serverbound traffic and then the proxy could report `DecoderException` / `Unknown zlib header`.

v21 explicitly wraps the raw DEFLATE stream with a valid zlib header and Adler-32 trailer before sending it. Incoming packets continue to accept both raw and wrapped streams.

## Chat

- Normal, non-inverted ScrollView.
- Old messages are above; newest message is at the bottom.
- Opening the chat starts at the newest message.
- New messages only auto-scroll when already at the bottom.
- While reading history, new messages do not move the viewport.
- Removed all Y-axis scale/inversion from chat rows.

## Account UI

- Account remains horizontally pageable when there are multiple accounts.
- Compact 72x72 skin icon and username.
- Server list layout is otherwise preserved.

## Movement

- Touch-held WASD movement ticks at 20 Hz (50 ms), not once per second.
- Idle heartbeat remains separate at approximately 1 Hz.

## Diagnostics

If the server still disconnects, the chat notice now includes the last outbound packet id/size/compression state, which helps identify the exact packet immediately preceding a proxy disconnect.
