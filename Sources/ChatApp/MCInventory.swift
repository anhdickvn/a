import Foundation

/// 1 item trong hotbar (đã parse xong, sẵn sàng hiển thị).
struct MCItemSlot: Identifiable, Equatable {
    var id = UUID()
    var hotbarIndex: Int          // 0-8
    var itemId: Int16             // ID numeric của item (định dạng pre-1.13)
    var damage: Int16 = 0          // damage/meta của item 1.12.2, dùng để chọn model/texture variant
    var count: Int
    /// Tên hiển thị: ưu tiên tên tuỳ chỉnh server đặt (NBT display.Name), có màu.
    /// Nếu server không đặt tên riêng, đây là nil — UI tự hiện tên id.
    var nameSegments: [MCChatSegment]?
    /// Lore từ NBT display.Lore, mỗi dòng giữ màu/format của server.
    var loreSegments: [[MCChatSegment]] = []

    var plainName: String {
        nameSegments?.map(\.text).joined() ?? "Item #\(itemId)"
    }
}

// MARK: - Icon cho item (không tải gói texture đầy đủ — dùng emoji cho các item hay gặp,
// nhẹ và không cần mạng, đủ để nhận diện nhanh khi lướt hotbar/balo/GUI server).

/// ID vật phẩm (kiểu số, giao thức 1.12.2) -> emoji gợi hình, chỉ phủ các item phổ biến.
/// Item không có trong bảng sẽ hiện icon hộp mặc định (xem `mcItemEmoji`).
private let mcItemEmojiTable: [Int16: String] = [
    345: "🧭", // Compass — la bàn

    // Sword: wood 268, stone 272, iron 267, diamond 276, gold 283
    268: "⚔️", 272: "⚔️", 267: "⚔️", 276: "⚔️", 283: "⚔️",
    // Pickaxe: wood 270, stone 274, iron 257, diamond 278, gold 285
    270: "⛏️", 274: "⛏️", 257: "⛏️", 278: "⛏️", 285: "⛏️",
    // Axe: wood 271, stone 275, iron 258, diamond 279, gold 286
    271: "🪓", 275: "🪓", 258: "🪓", 279: "🪓", 286: "🪓",
    // Shovel: wood 269, stone 273, iron 256, diamond 277, gold 284
    269: "🔻", 273: "🔻", 256: "🔻", 277: "🔻", 284: "🔻",
    // Hoe: wood 290, stone 291, iron 292, diamond 293, gold 294
    290: "🪝", 291: "🪝", 292: "🪝", 293: "🪝", 294: "🪝",

    // Giáp da: mũ 298, áo 299, quần 300, giày 301
    298: "🪖", 299: "🥋", 300: "👖", 301: "🥾",
    // Giáp xích: mũ 302, áo 303, quần 304, giày 305
    302: "🪖", 303: "🥋", 304: "👖", 305: "🥾",
    // Giáp sắt: mũ 306, áo 307, quần 308, giày 309
    306: "⛑️", 307: "🦺", 308: "👖", 309: "🥾",
    // Giáp kim cương: mũ 310, áo 311, quần 312, giày 313
    310: "⛑️", 311: "🦺", 312: "👖", 313: "🥾",
    // Giáp vàng: mũ 314, áo 315, quần 316, giày 317
    314: "🪖", 315: "🎽", 316: "👖", 317: "🥾",

    266: "🟡", 264: "💎", 265: "🧱", 263: "⚫", // gold ingot, diamond, iron ingot, coal
    322: "🍎", 297: "🍞", 320: "🍖", 350: "🐟", // food
    373: "🧪", 381: "🐸",                      // potion, magma cream
    340: "📖", 339: "📄", 358: "🗺️",           // book, paper, map
    261: "🏹", 262: "🏹",                      // bow, arrow
    346: "🎣",                                  // fishing rod
    287: "🧵", 288: "🪶",                       // string, feather
    318: "🪨",                                  // flint
]

/// Icon gợi hình cho 1 item (emoji) — không phải texture thật của server, chỉ để dễ nhận biết
/// trong lúc chưa có gói tài nguyên hình ảnh đầy đủ. Item lạ -> hộp mặc định.
func mcItemEmoji(for itemId: Int16) -> String {
    mcItemEmojiTable[itemId] ?? "📦"
}

// MARK: - NBT (Named Binary Tag) — parser tối giản, đủ để lấy display.Name / display.Lore

private enum MCNBT {
    case end
    case byte(Int8)
    case short(Int16)
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)
    case byteArray([Int8])
    case string(String)
    case list([MCNBT])
    case compound([String: MCNBT])
    case intArray([Int32])
    case longArray([Int64])
}

private struct MCNBTReader {
    let data: Data
    var offset: Int

    mutating func readU8() -> UInt8? {
        guard let (v, next) = data.readU8(from: offset) else { return nil }
        offset = next
        return v
    }

    mutating func readI16() -> Int16? {
        guard let (v, next) = data.readI16BE(from: offset) else { return nil }
        offset = next
        return v
    }

    mutating func readI32() -> Int32? {
        guard let (v, next) = data.readI32BE(from: offset) else { return nil }
        offset = next
        return v
    }

    mutating func readI64() -> Int64? {
        guard offset + 8 <= data.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[data.startIndex + offset + i]) }
        offset += 8
        return Int64(bitPattern: v)
    }

    mutating func readF32() -> Float? {
        guard let bits = readI32() else { return nil }
        return Float(bitPattern: UInt32(bitPattern: bits))
    }

    mutating func readF64() -> Double? {
        guard let bits = readI64() else { return nil }
        return Double(bitPattern: UInt64(bitPattern: bits))
    }

    /// Chuỗi NBT: Short độ dài (unsigned) + UTF-8 bytes.
    mutating func readNBTString() -> String? {
        guard let (hi, n1) = data.readU8(from: offset), let (lo, n2) = data.readU8(from: n1) else { return nil }
        let len = Int(UInt16(hi) << 8 | UInt16(lo))
        offset = n2
        guard offset + len <= data.count else { return nil }
        let start = data.startIndex + offset
        let str = String(data: data[start..<start + len], encoding: .utf8) ?? ""
        offset += len
        return str
    }

    /// Đọc payload của 1 tag theo tagId (không đọc tên — tên đọc riêng ở nơi gọi khi cần).
    mutating func readPayload(tagId: UInt8) -> MCNBT? {
        switch tagId {
        case 0: return .end
        case 1: return readU8().map { .byte(Int8(bitPattern: $0)) }
        case 2: return readI16().map(MCNBT.short)
        case 3: return readI32().map(MCNBT.int)
        case 4: return readI64().map(MCNBT.long)
        case 5: return readF32().map(MCNBT.float)
        case 6: return readF64().map(MCNBT.double)
        case 7: // Byte_Array: Int32 length + bytes
            guard let len = readI32(), len >= 0, offset + Int(len) <= data.count else { return nil }
            let bytes = data[data.startIndex + offset..<data.startIndex + offset + Int(len)].map { Int8(bitPattern: $0) }
            offset += Int(len)
            return .byteArray(bytes)
        case 8: return readNBTString().map(MCNBT.string)
        case 9: // List: Byte elemTagId + Int32 length + payloads (không tên)
            guard let elemId = readU8(), let len = readI32(), len >= 0 else { return nil }
            var items: [MCNBT] = []
            for _ in 0..<len {
                guard let v = readPayload(tagId: elemId) else { return nil }
                items.append(v)
            }
            return .list(items)
        case 10: // Compound: các tag có tên, kết thúc bằng TAG_End
            var dict: [String: MCNBT] = [:]
            while true {
                guard let childId = readU8() else { return nil }
                if childId == 0 { break }
                guard let name = readNBTString(), let value = readPayload(tagId: childId) else { return nil }
                dict[name] = value
            }
            return .compound(dict)
        case 11: // Int_Array
            guard let len = readI32(), len >= 0 else { return nil }
            var vals: [Int32] = []
            for _ in 0..<len { guard let v = readI32() else { return nil }; vals.append(v) }
            return .intArray(vals)
        case 12: // Long_Array
            guard let len = readI32(), len >= 0 else { return nil }
            var vals: [Int64] = []
            for _ in 0..<len { guard let v = readI64() else { return nil }; vals.append(v) }
            return .longArray(vals)
        default:
            return nil // tag lạ — không rõ cách đọc, coi như hỏng
        }
    }

    /// Đọc 1 tag "gốc" đầy đủ: TagID + Name + Payload. Dùng cho NBT gắn kèm trong Slot.
    mutating func readRootTag() -> MCNBT? {
        guard let tagId = readU8() else { return nil }
        if tagId == 0 { return .end }
        guard readNBTString() != nil else { return nil } // tên root thường rỗng, bỏ qua
        return readPayload(tagId: tagId)
    }
}

private extension MCNBT {
    func get(_ key: String) -> MCNBT? {
        if case .compound(let dict) = self { return dict[key] }
        return nil
    }
    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var asStringList: [String]? {
        if case .list(let values) = self {
            return values.compactMap { value in
                if case .string(let s) = value { return s }
                return nil
            }
        }
        return nil
    }
}

// MARK: - Slot data (protocol 760 / Minecraft 1.19.2)

enum MCSlotParser {
    /// Protocol 760 / 1.19.2: Slot = Present(bool) + Item ID(VarInt) + Count(byte) + Optional NBT.
    /// Không còn Short itemId + damage như 1.12.2.
    static func parse(_ data: Data, from offset: Int, hotbarIndex: Int) -> (MCItemSlot?, Int)? {
        guard let (present, next1) = data.readU8(from: offset) else { return nil }
        if present == 0 { return (nil, next1) }

        guard let (itemId, next2) = decodeVarInt(from: data, offset: next1),
              let (countByte, next3) = data.readU8(from: next2) else { return nil }

        var reader = MCNBTReader(data: data, offset: next3)
        var displayNameSegments: [MCChatSegment]?
        var loreSegments: [[MCChatSegment]] = []
        var finalOffset = next3

        // Optional NBT: 0x00 = no tag; otherwise it starts with a normal NBT root tag.
        guard let firstByte = data.readU8(from: next3)?.0 else { return nil }
        if firstByte == 0 {
            finalOffset = next3 + 1
        } else {
            guard let root = reader.readRootTag() else { return nil }
            finalOffset = reader.offset
            if let display = root.get("display") {
                if let name = display.get("Name")?.asString {
                    displayNameSegments = chatSegments(from: name)
                }
                if let lore = display.get("Lore")?.asStringList {
                    loreSegments = lore.map { chatSegments(from: $0) }
                }
            }
        }

        let item = MCItemSlot(
            hotbarIndex: hotbarIndex,
            itemId: Int16(clamping: Int(itemId)),
            damage: 0,
            count: Int(countByte),
            nameSegments: displayNameSegments,
            loreSegments: loreSegments
        )
        return (item, finalOffset)
    }

    private static func decodeVarInt(from data: Data, offset: Int) -> (Int32, Int)? {
        var numRead = 0
        var result: Int32 = 0
        var shift: Int32 = 0
        var idx = offset
        while idx < data.count && numRead < 5 {
            let byte = data[data.startIndex + idx]
            idx += 1
            result |= Int32(byte & 0x7F) << shift
            numRead += 1
            if byte & 0x80 == 0 { return (result, idx) }
            shift += 7
        }
        return nil
    }
}
