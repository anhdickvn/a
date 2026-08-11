import Foundation
import Network
import UIKit

extension Data {
    fileprivate mutating func appendMCString(_ value: String) {
        let bytes = Data(value.utf8)
        append(contentsOf: MCVarInt.encode(Int32(bytes.count)))
        append(bytes)
    }
}


struct MCServerStatus: Identifiable, Equatable {
    let id: UUID
    var online: Bool = false
    var ping: Int = 0
    var playersOnline: Int = 0
    var playersMax: Int = 0
    var motd: [MCChatSegment] = []
    var favicon: UIImage? = nil
    var error: String? = nil

    static func == (lhs: MCServerStatus, rhs: MCServerStatus) -> Bool {
        lhs.id == rhs.id && lhs.online == rhs.online && lhs.ping == rhs.ping &&
        lhs.playersOnline == rhs.playersOnline && lhs.playersMax == rhs.playersMax &&
        lhs.motd == rhs.motd && lhs.error == rhs.error
    }
}

/// Lightweight Server List Ping used only by the home screen.
/// It never touches the login connection and therefore cannot block entering a server.
private final class MCServerStatusFinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func tryFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

final class MCServerStatusService {
    static let shared = MCServerStatusService()
    private init() {}

    func ping(profile: MCServerProfile) async -> MCServerStatus {
        await withCheckedContinuation { continuation in
            let started = Date()
            let connection = NWConnection(host: NWEndpoint.Host(profile.host),
                                          port: NWEndpoint.Port(rawValue: profile.port) ?? 25565,
                                          using: .tcp)
            let queue = DispatchQueue(label: "mc.status.\(UUID().uuidString)")
            var buffer = Data()
            let finishGate = MCServerStatusFinishGate()

            func finish(_ status: MCServerStatus) {
                guard finishGate.tryFinish() else { return }
                connection.cancel()
                continuation.resume(returning: status)
            }

            func readPacket() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        buffer.append(data)
                        if let packet = MCServerStatusService.extractPacket(from: &buffer) {
                            if let status = MCServerStatusService.parseStatus(packet,
                                                                               id: profile.id,
                                                                               ping: Int(Date().timeIntervalSince(started) * 1000)) {
                                finish(status)
                                return
                            }
                        }
                    }
                    if error != nil || isComplete {
                        finish(MCServerStatus(id: profile.id, error: "Server is offline."))
                    } else {
                        readPacket()
                    }
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let handshake = MCServerStatusService.makeHandshake(host: profile.host,
                                                                          port: profile.port)
                    let request = MCServerStatusService.makeRequest()
                    connection.send(content: handshake + request, completion: .contentProcessed { error in
                        if let error {
                            finish(MCServerStatus(id: profile.id, error: error.localizedDescription))
                        } else {
                            readPacket()
                        }
                    })
                case .failed(let error):
                    finish(MCServerStatus(id: profile.id, error: error.localizedDescription))
                case .cancelled:
                    if !finishGate.isFinished { finish(MCServerStatus(id: profile.id, error: "Server is offline.")) }
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 4.0) {
                if !finishGate.isFinished {
                    finish(MCServerStatus(id: profile.id, error: "Timeout"))
                }
            }
        }
    }

    private static func makeHandshake(host: String, port: UInt16) -> Data {
        var body = Data()
        body.append(contentsOf: MCVarInt.encode(0x00))
        body.append(contentsOf: MCVarInt.encode(760))
        body.appendMCString(host)
        body.append(UInt8((port >> 8) & 0xFF))
        body.append(UInt8(port & 0xFF))
        body.append(contentsOf: MCVarInt.encode(1))
        return frame(body)
    }

    private static func makeRequest() -> Data {
        frame(Data(MCVarInt.encode(0x00)))
    }

    private static func frame(_ body: Data) -> Data {
        var result = Data(MCVarInt.encode(Int32(body.count)))
        result.append(body)
        return result
    }

    private static func extractPacket(from buffer: inout Data) -> Data? {
        guard let (length, lengthBytes) = decodeVarInt(from: buffer), length >= 0 else { return nil }
        let total = lengthBytes + Int(length)
        guard buffer.count >= total else { return nil }
        let packet = buffer.subdata(in: lengthBytes..<total)
        buffer.removeSubrange(0..<total)
        return packet
    }

    private static func decodeVarInt(from data: Data) -> (Int32, Int)? {
        var value: Int32 = 0
        var numRead = 0
        for byte in data.prefix(5) {
            let b = Int32(byte)
            value |= (b & 0x7F) << (7 * numRead)
            numRead += 1
            if (b & 0x80) == 0 { return (value, numRead) }
        }
        return nil
    }

    private static func parseStatus(_ packet: Data, id: UUID, ping: Int) -> MCServerStatus? {
        var offset = 0
        guard let packetId = readVarInt(packet, offset: &offset), packetId == 0x00 else { return nil }
        guard let json = readString(packet, offset: &offset),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let players = object["players"] as? [String: Any]
        let online = players?["online"] as? Int ?? 0
        let max = players?["max"] as? Int ?? 0
        let description = object["description"]
        let motd = MCServerStatusService.segments(from: description)

        var favicon: UIImage?
        if let raw = object["favicon"] as? String,
           let comma = raw.firstIndex(of: ","),
           let imageData = Data(base64Encoded: String(raw[raw.index(after: comma)...]), options: .ignoreUnknownCharacters) {
            favicon = UIImage(data: imageData)
        }

        return MCServerStatus(id: id, online: true, ping: ping,
                              playersOnline: online, playersMax: max,
                              motd: motd, favicon: favicon)
    }

    private static func readVarInt(_ data: Data, offset: inout Int) -> Int32? {
        var value: Int32 = 0
        var numRead = 0
        while offset < data.count && numRead < 5 {
            let b = Int32(data[data.startIndex + offset]); offset += 1
            value |= (b & 0x7F) << (7 * numRead)
            numRead += 1
            if (b & 0x80) == 0 { return value }
        }
        return nil
    }

    private static func readString(_ data: Data, offset: inout Int) -> String? {
        guard let length = readVarInt(data, offset: &offset), length >= 0 else { return nil }
        let end = offset + Int(length)
        guard end <= data.count else { return nil }
        let result = String(data: data.subdata(in: offset..<end), encoding: .utf8)
        offset = end
        return result
    }

    private static func segments(from value: Any?) -> [MCChatSegment] {
        if let string = value as? String {
            return [MCChatSegment(text: string, colorHex: nil)]
        }
        guard let object = value as? [String: Any] else { return [] }
        var result: [MCChatSegment] = []
        let color = colorHex(object["color"] as? String)
        let bold = object["bold"] as? Bool ?? false
        let italic = object["italic"] as? Bool ?? false
        let underline = object["underlined"] as? Bool ?? false
        let strike = object["strikethrough"] as? Bool ?? false
        if let text = object["text"] as? String, !text.isEmpty {
            result.append(MCChatSegment(text: text, colorHex: color, bold: bold,
                                        italic: italic, underline: underline, strikethrough: strike))
        }
        if let extra = object["extra"] as? [[String: Any]] {
            for child in extra {
                result.append(contentsOf: segments(from: child))
            }
        }
        return result
    }

    private static func colorHex(_ name: String?) -> String? {
        guard let name = name?.lowercased() else { return nil }
        let map: [String: String] = [
            "black":"#000000", "dark_blue":"#0000AA", "dark_green":"#00AA00",
            "dark_aqua":"#00AAAA", "dark_red":"#AA0000", "dark_purple":"#AA00AA",
            "gold":"#FFAA00", "gray":"#AAAAAA", "dark_gray":"#555555",
            "blue":"#5555FF", "green":"#55FF55", "aqua":"#55FFFF",
            "red":"#FF5555", "light_purple":"#FF55FF", "yellow":"#FFFF55", "white":"#FFFFFF"
        ]
        return map[name]
    }
}
