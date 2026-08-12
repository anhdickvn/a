# Minecraft iOS – v27 Confirm Transaction Fix

Fix for protocol disconnect seen on Minecraft 1.12.x servers where the server repeatedly sends Play packet 0x11 (Confirm Transaction) and then disconnects with `disconnect.timeout`.

## Fix
- Handle clientbound Play 0x11 Confirm Transaction.
- Parse Window ID (u8), Action Number (i16 big-endian), Accepted (bool).
- Echo the same fields in serverbound Play 0x05 Confirm Transaction.
- Correct diagnostic packet naming: RX 0x11 / TX 0x05.
- Add confirm-transaction RX/TX timing/details to protocol diagnostics.
- Keep existing chat/UI/GUI behavior unchanged.

## Validation
`swiftc -parse Sources/ChatApp/MCClient.swift Sources/ChatApp/MCVarInt.swift` passes on the source tree.

Build using the project's Xcode archive command as usual.


## v28 WASD / Jump debug
- Dedicated movement controller combines held W/A/S/D inputs into one 20 Hz loop.
- Settings > Chẩn đoán > Ghi Debug WASD / Jump enables a separate movement trace.
- Trace records touch down/up, state guards, server-position availability, yaw, local coordinate deltas, jump start, and server movement corrections.
- Debug is kept out of the normal chat transcript unless protocol debug is explicitly enabled.
