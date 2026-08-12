import Foundation

enum MCVarInt {
    /// Mã hoá 1 số Int32 thành VarInt (định dạng nén số của giao thức Minecraft)
    static func encode(_ value: Int32) -> [UInt8] {
        var v = UInt32(bitPattern: value)
        var bytes: [UInt8] = []
        repeat {
            var temp = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { temp |= 0x80 }
            bytes.append(temp)
        } while v != 0
        return bytes
    }

    /// Giải mã VarInt từ 1 nguồn byte tuần tự (đóng bằng closure `next`).
    /// Trả về nil nếu hết dữ liệu giữa chừng.
    static func decode(next: () -> UInt8?) -> Int32? {
        var result: Int32 = 0
        var shift: Int32 = 0
        while true {
            guard let byte = next() else { return nil }
            result |= Int32(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift >= 32 { return nil } // VarInt quá dài, dữ liệu hỏng
        }
        return result
    }
}

/// Bộ đệm byte tích luỹ từ socket, cho phép "thử đọc" 1 gói tin hoàn chỉnh,
/// và nếu chưa đủ dữ liệu thì trả nil để chờ nhận thêm.
final class MCByteBuffer {
    private var storage = Data()
    private var readIndex = 0

    func append(_ data: Data) {
        storage.append(data)
    }

    /// Số byte còn chưa đọc.
    var remainingCount: Int { storage.count - readIndex }

    /// Cố gắng đọc chính xác `count` byte kể từ vị trí hiện tại mà KHÔNG di chuyển con trỏ
    /// nếu không đủ dữ liệu (giữ nguyên buffer để lần sau thử lại).
    private func peekBytes(_ count: Int) -> [UInt8]? {
        guard remainingCount >= count else { return nil }
        let start = storage.index(storage.startIndex, offsetBy: readIndex)
        let end = storage.index(start, offsetBy: count)
        return Array(storage[start..<end])
    }

    /// Thử đọc 1 VarInt mà không tiêu thụ buffer nếu chưa đủ byte.
    /// Trả về (giá trị, số byte đã dùng) hoặc nil.
    private func peekVarInt() -> (Int32, Int)? {
        var result: Int32 = 0
        var shift: Int32 = 0
        var used = 0
        while true {
            guard let byte = peekBytes(used + 1)?.last else { return nil }
            used += 1
            result |= Int32(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift >= 32 || used > 5 { return nil }
        }
        return (result, used)
    }

    private func consume(_ count: Int) {
        readIndex += count
        // dọn bớt buffer định kỳ để tránh phình bộ nhớ
        if readIndex > 65536 {
            storage.removeFirst(readIndex)
            readIndex = 0
        }
    }

    /// Cố gắng lấy ra 1 gói tin hoàn chỉnh dạng [length-prefixed]: trả về phần dữ liệu
    /// SAU byte độ dài (tức là packetID + payload, có thể còn nén). Trả nil nếu chưa đủ.
    func nextRawPacket() -> Data? {
        guard let (length, lenBytes) = peekVarInt(), length >= 0 else { return nil }
        let total = lenBytes + Int(length)
        guard let bytes = peekBytes(total) else { return nil }
        consume(total)
        return Data(bytes[lenBytes...])
    }
}

// MARK: - Đọc/ghi các kiểu dữ liệu cơ bản trên Data

extension Data {
    /// Đọc 1 chuỗi UTF-8 có tiền tố độ dài VarInt, bắt đầu từ offset, trả về (chuỗi, offset mới).
    func readMCString(from offset: Int) -> (String, Int)? {
        var idx = offset
        guard let len = MCVarInt.decode(next: {
            guard idx < self.count else { return nil }
            defer { idx += 1 }
            return self[self.startIndex + idx]
        }) else { return nil }
        let length = Int(len)
        guard idx + length <= self.count else { return nil }
        let start = self.startIndex + idx
        let end = start + length
        let str = String(data: self[start..<end], encoding: .utf8) ?? ""
        return (str, idx + length)
    }

    /// Đọc UInt8 tại offset, trả về (giá trị, offset mới) hoặc nil nếu hết dữ liệu.
    func readU8(from offset: Int) -> (UInt8, Int)? {
        guard offset < count else { return nil }
        return (self[startIndex + offset], offset + 1)
    }

    /// Đọc Int16 big-endian tại offset.
    func readI16BE(from offset: Int) -> (Int16, Int)? {
        guard offset + 2 <= count else { return nil }
        let hi = self[startIndex + offset], lo = self[startIndex + offset + 1]
        return (Int16(bitPattern: UInt16(hi) << 8 | UInt16(lo)), offset + 2)
    }

    /// Đọc Int32 big-endian tại offset.
    func readI32BE(from offset: Int) -> (Int32, Int)? {
        guard offset + 4 <= count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(self[startIndex + offset + i]) }
        return (Int32(bitPattern: v), offset + 4)
    }

    /// Đọc UInt64 big-endian tại offset.
    func readU64BE(from offset: Int) -> (UInt64, Int)? {
        guard offset + 8 <= count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(self[startIndex + offset + i]) }
        return (v, offset + 8)
    }

    func readI64BE(from offset: Int) -> (Int64, Int)? {
        guard let v = readU64BE(from: offset) else { return nil }
        return (Int64(bitPattern: v.0), v.1)
    }

    func readU16BE(from offset: Int) -> (UInt16, Int)? {
        guard offset + 2 <= count else { return nil }
        let v = (UInt16(self[startIndex + offset]) << 8) | UInt16(self[startIndex + offset + 1])
        return (v, offset + 2)
    }
}

func mcEncodeString(_ s: String) -> [UInt8] {
    let utf8 = Array(s.utf8)
    return MCVarInt.encode(Int32(utf8.count)) + utf8
}
