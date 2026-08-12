import Foundation
import Network

/// Kết quả 1 lần "Server List Ping" — giống thông tin hiện trong màn chọn server của
/// Minecraft thật (MOTD, số người chơi online/max, ping ms). Chỉ để HIỂN THỊ trong danh
/// sách server (tooltip), không liên quan gì tới flow đăng nhập thật trong MCClient.
struct MCServerStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case loading
        case online
        case offline(String) // lý do ngắn, vd "Không phản hồi"
    }
    var phase: Phase = .loading
    var motd: String = ""
    var onlinePlayers: Int = 0
    var maxPlayers: Int = 0
    var pingMs: Int = 0
    var versionName: String = ""
}

/// Tự động "ping" từng server đã lưu (kiểu Status Ping) để lấy thông tin hiển thị nhanh
/// trong danh sách, KHÔNG mở phiên đăng nhập thật, không đụng tới MCClient.
@MainActor
final class MCServerStatusStore: ObservableObject {
    @Published private(set) var statuses: [UUID: MCServerStatus] = [:]
    private var inFlight: Set<UUID> = []

    func status(for profileId: UUID) -> MCServerStatus? { statuses[profileId] }

    /// Ping lại toàn bộ danh sách server (vd khi mở màn hình hoặc kéo-refresh).
    func refreshAll(_ profiles: [MCServerProfile]) {
        for profile in profiles { refresh(profile) }
    }

    func refresh(_ profile: MCServerProfile) {
        guard !inFlight.contains(profile.id) else { return }
        inFlight.insert(profile.id)
        statuses[profile.id] = MCServerStatus(phase: .loading)

        let host = profile.host
        let port = profile.port
        let profileId = profile.id

        Task { @MainActor [weak self] in
            let result = await MCStatusPingSession(host: host, port: port).run()
            guard let self else { return }
            self.inFlight.remove(profileId)
            self.statuses[profileId] = result
        }
    }
}

/// 1 phiên "Status Ping" dùng-1-lần: mở TCP riêng, hỏi Status, đo round-trip bằng gói
/// Ping/Pong, rồi tự đóng. Tách hẳn khỏi MCClient để không ảnh hưởng logic đăng nhập thật.
@MainActor
private final class MCStatusPingSession {
    private let host: String
    private let port: UInt16
    private let connection: NWConnection
    private let buffer = MCByteBuffer()
    private var awaitingPong = false
    private var pingSentAt: DispatchTime = .now()
    private var baseStatus = MCServerStatus(phase: .loading)
    private var continuation: CheckedContinuation<MCServerStatus, Never>?
    private var finished = false

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        connection = NWConnection(host: .init(host), port: .init(rawValue: port) ?? 25565, using: .tcp)
    }

    func run() async -> MCServerStatus {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            connection.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in self?.handleState(newState) }
            }
            connection.start(queue: .main)

            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.finish(.offline("Hết thời gian chờ"))
            }
        }
    }

    @MainActor
    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendHandshakeAndStatusRequest()
            receiveNext()
        case .failed, .cancelled:
            finish(.offline("Không kết nối được"))
        default:
            break
        }
    }

    private func sendHandshakeAndStatusRequest() {
        var hsPayload: [UInt8] = []
        hsPayload += MCVarInt.encode(-1)
        hsPayload += mcEncodeString(host)
        hsPayload += [UInt8(port >> 8), UInt8(port & 0xFF)]
        hsPayload += MCVarInt.encode(1) // next state = 1 (Status)
        let hsBody = MCVarInt.encode(0x00) + hsPayload
        let hsFull = MCVarInt.encode(Int32(hsBody.count)) + hsBody

        let reqBody = MCVarInt.encode(0x00) // Status Request
        let reqFull = MCVarInt.encode(Int32(reqBody.count)) + reqBody

        connection.send(content: Data(hsFull) + Data(reqFull), completion: .contentProcessed { _ in })
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainAvailablePackets()
                }
                if error != nil {
                    self.finish(.offline("Không phản hồi"))
                    return
                }
                if isComplete {
                    self.finish(self.awaitingPong ? self.baseStatus : .offline("Đóng kết nối"))
                    return
                }
                if !self.finished { self.receiveNext() }
            }
        }
    }

    @MainActor
    private func drainAvailablePackets() {
        while let raw = buffer.nextRawPacket() {
            var idx = 0
            guard let packetId = MCVarInt.decode(next: {
                guard idx < raw.count else { return nil }
                defer { idx += 1 }
                return raw[raw.startIndex + idx]
            }) else { continue }
            let body = Data(raw.suffix(from: raw.startIndex + idx))

            if !awaitingPong, packetId == 0x00 {
                handleStatusResponse(body)
            } else if awaitingPong, packetId == 0x01 {
                let elapsedMs = Int(Double(DispatchTime.now().uptimeNanoseconds - pingSentAt.uptimeNanoseconds) / 1_000_000)
                baseStatus.pingMs = max(elapsedMs, 1)
                finish(baseStatus)
                return
            }
        }
    }

    private func handleStatusResponse(_ body: Data) {
        guard let (json, _) = body.readMCString(from: 0),
              let jsonData = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            finish(.offline("Phản hồi không hợp lệ"))
            return
        }
        let players = obj["players"] as? [String: Any]
        let versionInfo = obj["version"] as? [String: Any]
        let motd: String
        if let descString = obj["description"] as? String {
            motd = prettyChatJSON(descString)
        } else if let descObj = obj["description"],
                  let descData = try? JSONSerialization.data(withJSONObject: descObj),
                  let descJSONString = String(data: descData, encoding: .utf8) {
            motd = prettyChatJSON(descJSONString)
        } else {
            motd = ""
        }

        baseStatus = MCServerStatus(
            phase: .online,
            motd: motd,
            onlinePlayers: (players?["online"] as? Int) ?? 0,
            maxPlayers: (players?["max"] as? Int) ?? 0,
            pingMs: 0,
            versionName: (versionInfo?["name"] as? String) ?? ""
        )

        // Gửi Ping (0x01) kèm timestamp để đo round-trip thật, giống mọi client Minecraft.
        awaitingPong = true
        pingSentAt = .now()
        let payload = withUnsafeBytes(of: Int64(Date().timeIntervalSince1970 * 1000).bigEndian) { Array($0) }
        let pingBody = MCVarInt.encode(0x01) + payload
        let pingFull = MCVarInt.encode(Int32(pingBody.count)) + pingBody
        connection.send(content: Data(pingFull), completion: .contentProcessed { _ in })

        // Không chờ pong vô hạn — nếu server im lặng, vẫn hiện info cơ bản (online/max/MOTD).
        let fallback = baseStatus
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.finished, self.awaitingPong else { return }
            self.finish(fallback)
        }
    }

    private func finish(_ status: MCServerStatus) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        continuation?.resume(returning: status)
        continuation = nil
    }
}
