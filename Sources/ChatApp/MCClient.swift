import Foundation
import Network
import Compression
import UIKit

/// Client kết nối TCP tới 1 server Minecraft Java Edition, nói đúng giao thức mạng
/// (KHÔNG chạy Java, KHÔNG vẽ đồ hoạ game) — chỉ đủ để đăng nhập offline, đọc & gửi chat.
///
/// Trước khi login, client tự dò protocol version thật của server (giống "Server List Ping"
/// mà client Minecraft chính chủ / ChatCraft dùng) nên không còn bị cứng vào 1 bản duy nhất.
///
/// Giới hạn đã biết: chỉ hỗ trợ server offline-mode (không yêu cầu tài khoản Minecraft/Microsoft
/// thật). Nếu server bật online-mode, server sẽ gửi "Encryption Request" — client sẽ báo lỗi rõ
/// ràng thay vì treo vô hạn, vì việc đăng nhập tài khoản thật cần thêm luồng xác thực Microsoft
/// riêng (chưa làm trong bản này).
@MainActor
final class MCClient: ObservableObject {
    static let shared = MCClient()
    @Published var state: MCConnectionState = .disconnected
    @Published var log: [MCLogEntry] = []
    @Published var onlinePlayerNames: Set<String> = []
    /// Kết quả / danh sách gợi ý khi nhấn Tab trong chat (vd /w WhatDid -> WhatDidYouDo).
    @Published var tabCompletions: [String] = []
    /// Lịch sử các dòng đã gửi (chat lẫn lệnh, vd "/back") theo đúng thứ tự đã gửi —
    /// dùng cho 2 nút mũi tên lên/xuống ở khung nhập để gọi lại tin đã gõ, giống hệt
    /// phím Up/Down gọi lại lệnh cũ trên client Minecraft thật / ChatCraft, KHÔNG phải
    /// để cuộn màn hình chat.
    @Published var sentMessageHistory: [String] = []

    private var tabCompletionTransaction: Int32 = 0
    private var tabCompletionPrefix = ""
    private var tabCycleIndex = 0
    private var playerNamesByUUID: [String: String] = [:]
    /// Hotbar (9 ô) của người chơi, cập nhật từ Window Items / Set Slot của server.
    @Published var hotbar: [MCItemSlot?] = Array(repeating: nil, count: 9)
    /// Toàn bộ inventory người chơi (windowId 0): slot 5-8 = giáp, 9-35 = balo (main storage),
    /// 36-44 = hotbar — dùng để hiện màn "xem giáp/balo/hotbar" không cần hỏi lại server.
    @Published var playerInventory: [Int: MCItemSlot] = [:]
    /// GUI/menu server đang mở (vd "Chọn máy chủ" khi chuột phải la bàn) — nil = không có menu nào đang mở.
    @Published var currentWindow: MCOpenWindow?

    // Vị trí hiện tại nhận từ packet Player Position And Look.
    @Published var playerX: Double = 0
    @Published var playerY: Double = 0
    @Published var playerZ: Double = 0
    @Published var playerYaw: Float = 0
    @Published var playerPitch: Float = 0
    @Published var currentDimension: String = "Overworld"
    @Published var health: Float = 20
    @Published var food: Int = 20
    @Published var foodSaturation: Float = 5


    /// Dùng khi không dò được version thật (server không phản hồi status) — 340 = 1.12.2.
    private let fallbackProtocolVersion: Int32 = 340
    private var protocolVersion: Int32 = 340

    private var connection: NWConnection?
    private let buffer = MCByteBuffer()
    private var compressionThreshold: Int32 = -1 // -1 = tắt nén
    private var compressionFailureCount = 0
    private var lastSentPacketDescription = "none"
    private var lastCompressionFailureAt: TimeInterval = 0
    private var connectAttemptToken = UUID()

    private var host: String = ""
    private var port: UInt16 = 25565
    private var username: String = ""
    /// Cờ bật/tắt tự động login + mở la bàn (đọc từ MCServerProfile.autoLogin lúc connect()).
    /// KHÔNG đổi cách automation chạy — chỉ quyết định có chạy hay không.
    private var autoLoginEnabled = false
    private var windowActionCounter: Int16 = 0
    private var backgroundObservers: [NSObjectProtocol] = []
    private var enteredBackgroundAt: Date?
    /// true sau khi người dùng bấm Kết nối; khi mạng chập chờn/iOS trả POSIX 53,
    /// client sẽ tự nối lại thay vì để game bị văng khỏi server.
    private var shouldStayConnected = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectDelay: TimeInterval = 4.0

    // Watchdog: NWConnection doesn't reliably surface a socket that died silently
    // (dropped by a NAT/firewall, or the app got throttled hard enough in the
    // background that receive() just never calls back again). Without this, `state`
    // stays stuck on `.connected` forever — chat stops receiving messages and the
    // player list stops updating even though nothing ever reports an error. This is
    // exactly the "để 1 thời gian không chat/hiện player" symptom. We track the last
    // time any packet was actually processed and self-heal by reconnecting if the
    // server goes quiet far longer than vanilla's own ~15s keep-alive interval.
    private var lastPacketReceivedAt: Date = .distantPast
    private var watchdogTask: Task<Void, Never>?
    private let watchdogTimeout: TimeInterval = 45
    /// Tick di chuyển "giả" (gửi lại đúng toạ độ hiện tại) mỗi vài giây khi đang đứng
    /// yên. Client Minecraft thật luôn gửi packet Player/Player Position mỗi tick dù
    /// không di chuyển; app này trước đây CHỈ gửi packet đó khi người dùng chủ động
    /// bấm giữ WASD, nên nhiều proxy có chống AFK/anti-bot (dựa trên việc không thấy
    /// packet vị trí nào trong 1 khoảng thời gian) sẽ tự kick với lý do
    /// "disconnect.timeout" dù Keep Alive vẫn được trả lời đầy đủ. Tick này khắc phục
    /// đúng nguyên nhân đó, không phải chỉ ẩn thông báo lỗi đi.
    private var idleAliveTask: Task<Void, Never>?
    private var movementLastSentAt: TimeInterval = 0
    private var jumpTask: DispatchWorkItem?
    private var jumpGeneration = 0
    private var isOnGround = true
    /// Chỉ gửi movement heartbeat sau khi server đã gửi vị trí spawn/teleport đầu tiên.
    /// Tránh gửi X/Y/Z = 0 trong khoảng Login Success -> Player Position And Look.
    private var hasServerPosition = false
    private var movementTasks: [String: Task<Void, Never>] = [:]

    /// Trạng thái hiển thị cho giao diện điều khiển.
    /// Giữ logic vật lý nội bộ nhưng cho SwiftUI đọc được an toàn.
    var isOnGroundLabel: String {
        isOnGround ? "Đang đứng" : "Đang trên không"
    }

    // Tự động hoá flow của server Tôi Chơi Network:
    // /dn -> chờ 2s -> chọn hotbar 5 -> chuột phải -> chờ GUI -> click slot 23 (Diamond Axe).
    private var loginAutomationGeneration = UUID()
    private var autoMenuSelectionPending = false
    private var autoMenuRetryCount = 0
    private var resourcePackPending = false
    private var resourcePackCompletionWaiters: [() -> Void] = []

    init() {
        setupBackgroundObservers()
    }

    deinit {
        reconnectWorkItem?.cancel()
        watchdogTask?.cancel()
        idleAliveTask?.cancel()
        connection?.cancel()
        for observer in backgroundObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Lắng nghe app vào/ra khỏi nền để bật/tắt "mẹo" giữ kết nối sống (BackgroundKeepAlive).
    /// Chỉ bật khi đang thực sự kết nối tới server — tránh tốn pin lúc không cần thiết.
    private func setupBackgroundObservers() {
        let nc = NotificationCenter.default
        backgroundObservers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldStayConnected else { return }
                self.enteredBackgroundAt = Date()
                // iOS may suspend arbitrary TCP sockets even when a background mode is
                // enabled. Audio is only a best-effort keep-alive; the foreground path
                // below verifies the socket and reconnects if it went stale.
                if self.state == .connected {
                    BackgroundKeepAlive.shared.start()
                }
            }
        })
        backgroundObservers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.jumpTask?.cancel()
                // Không gọi disconnect khi quay lại foreground. Chỉ dừng audio keep-alive;
                // socket và trạng thái client vẫn được giữ, nếu socket đã bị iOS/server đóng
                // thì shouldStayConnected sẽ tự reconnect.
                BackgroundKeepAlive.shared.stop()
                guard self.shouldStayConnected else { return }

                let backgroundDuration = self.enteredBackgroundAt.map { Date().timeIntervalSince($0) } ?? 0
                self.enteredBackgroundAt = nil

                if self.state != .connected && self.state != .loggingIn && self.state != .connecting {
                    self.scheduleReconnect(reason: "quay lại ứng dụng")
                } else if self.state == .connected && backgroundDuration >= 8 {
                    // A backgrounded NWConnection can look "connected" while its TCP
                    // socket has already been suspended/aborted by iOS. If we have not
                    // received anything for longer than a normal keep-alive interval,
                    // replace the socket immediately instead of waiting for the 45s watchdog.
                    let silentFor = Date().timeIntervalSince(self.lastPacketReceivedAt)
                    if silentFor >= 20 {
                        self.scheduleReconnect(reason: "socket stale sau khi app chạy nền")
                    }
                }
            }
        })
    }

    // MARK: - Kết nối

    func isConnectedTo(host: String, port: UInt16, username: String) -> Bool {
        self.host.caseInsensitiveCompare(host) == .orderedSame &&
        self.port == port &&
        self.username.caseInsensitiveCompare(username) == .orderedSame &&
        (state == .connected || state == .connecting || state == .loggingIn)
    }

    /// `username`: lấy từ MCAccount đã chọn cho server này (đăng nhập kiểu offline/cracked).
    /// `autoLogin`: từ MCServerProfile.autoLogin — chỉ khi BẬT mới chạy automation /dn + GUI.
    /// Tắt thì client chỉ kết nối và chờ toàn bộ event/GUI thật từ server.
    func connect(host: String, port: UInt16, username: String, autoLogin: Bool = false) {
        disconnect(silent: true)
        shouldStayConnected = true
        reconnectDelay = 4.0
        self.host = host
        self.port = port
        self.username = username
        self.autoLoginEnabled = autoLogin
        let token = UUID()
        connectAttemptToken = token

        state = .connecting
        appendLog(.info, "Đang kết nối trực tiếp tới \(host):\(port)...")
        // Không dùng status ping để quyết định protocol. Proxy Tôi Chơi có thể
        // trả status 760 (1.19.x) nhưng flow login tương thích của bản cũ vẫn là
        // flow mà server/proxy đang chấp nhận. Quan trọng là host + port và giữ
        // nguyên wire logic cũ, không tự đổi protocol theo status.
        protocolVersion = fallbackProtocolVersion
        openMainConnection(token: token)
    }

    private func versionHint(for protocolNumber: Int32) -> String {
        switch protocolNumber {
        case 47: return "1.8.x"
        case 107...110: return "1.9.x"
        case 210: return "1.10.x"
        case 315...316: return "1.11.x"
        case 335...340: return "1.12.x"
        case 393...404: return "1.13.x"
        case 477...498: return "1.14.x"
        case 573...578: return "1.15.x"
        case 735...756: return "1.16.x"
        case 757...758: return "1.18.x"
        case 759...761: return "1.19.x"
        case 763...767: return "1.20.x"
        case 768...772: return "1.21.x"
        default: return "không xác định"
        }
    }

    func disconnect(silent: Bool = false) {
        shouldStayConnected = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stopWatchdog()
        stopIdleAliveTicker()
        movementTasks.values.forEach { $0.cancel() }
        movementTasks.removeAll()
        loginAutomationGeneration = UUID()
        autoMenuSelectionPending = false
        autoMenuRetryCount = 0
        resourcePackPending = false
        resourcePackCompletionWaiters.removeAll()
        connectAttemptToken = UUID() // vô hiệu hoá mọi callback đang chờ (probe/timeout) của lần kết nối trước
        connection?.cancel()
        connection = nil
        compressionThreshold = -1
        compressionFailureCount = 0
        lastCompressionFailureAt = 0
        onlinePlayerNames.removeAll()
        playerNamesByUUID.removeAll()
        tabCompletions.removeAll()
        tabCompletionPrefix = ""
        hotbar = Array(repeating: nil, count: 9)
        playerInventory.removeAll()
        currentWindow = nil
        windowActionCounter = 0
        playerX = 0
        playerY = 0
        playerZ = 0
        hasServerPosition = false
        playerYaw = 0
        playerPitch = 0
        currentDimension = "Overworld"
        BackgroundKeepAlive.shared.stop()
        if !silent {
            appendLog(.info, "Đã ngắt kết nối.")
        }
        state = .disconnected
    }

    /// Xóa riêng chat của phiên hiện tại khi người dùng chủ động Disconnect.
    /// Lịch sử đã được MCChatHistoryStore lưu độc lập nên không bị mất.
    func clearCurrentChat() {
        log.removeAll()
        sentMessageHistory.removeAll()
        tabCompletions.removeAll()
        tabCompletionPrefix = ""
        tabCycleIndex = 0
    }

    // MARK: - Dò protocol version (Server List Ping / Status)

    /// Mở 1 kết nối tạm để hỏi server "bạn đang chạy version nào?" trước khi login thật.
    /// Đây là bước mà mọi client Minecraft (kể cả client chính chủ, ChatCraft...) đều làm
    /// khi hiện màn hình chọn server — giúp không bị cứng vào 1 protocol version.
    private func probeProtocolVersion(host: String, port: UInt16, completion: @escaping (Int32?) -> Void) {
        let probeConn = NWConnection(host: .init(host), port: .init(rawValue: port) ?? 25565, using: .tcp)
        let probeBuffer = MCByteBuffer()
        var finished = false

        func finish(_ result: Int32?) {
            guard !finished else { return }
            finished = true
            probeConn.cancel()
            completion(result)
        }

        func receiveStatus() {
            probeConn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                Task { @MainActor in
                    if let data, !data.isEmpty {
                        probeBuffer.append(data)
                        if let raw = probeBuffer.nextRawPacket() {
                            var idx = 0
                            guard let packetId = MCVarInt.decode(next: {
                                guard idx < raw.count else { return nil }
                                defer { idx += 1 }
                                return raw[raw.startIndex + idx]
                            }), packetId == 0x00 else { finish(nil); return }
                            let body = raw.suffix(from: raw.startIndex + idx)
                            guard let (json, _) = Data(body).readMCString(from: 0),
                                  let jsonData = json.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                                  let versionInfo = obj["version"] as? [String: Any],
                                  let protoNum = versionInfo["protocol"] as? Int else {
                                finish(nil); return
                            }
                            finish(Int32(protoNum))
                            return
                        }
                    }
                    if error != nil || isComplete { finish(nil); return }
                    receiveStatus()
                }
            }
        }

        probeConn.stateUpdateHandler = { newState in
            Task { @MainActor in
                switch newState {
                case .ready:
                    // Handshake với next_state = 1 (Status). Protocol version ở đây không quan trọng
                    // với gói Status Response, server luôn trả về version thật của nó.
                    var hsPayload: [UInt8] = []
                    hsPayload += MCVarInt.encode(-1)
                    hsPayload += mcEncodeString(host)
                    hsPayload += [UInt8(port >> 8), UInt8(port & 0xFF)]
                    hsPayload += MCVarInt.encode(1)
                    let hsBody = MCVarInt.encode(0x00) + hsPayload
                    let hsFull = MCVarInt.encode(Int32(hsBody.count)) + hsBody

                    let reqBody = MCVarInt.encode(0x00) // Status Request (0x00), không có payload
                    let reqFull = MCVarInt.encode(Int32(reqBody.count)) + reqBody

                    probeConn.send(content: Data(hsFull) + Data(reqFull), completion: .contentProcessed { _ in })
                    receiveStatus()
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
        }
        probeConn.start(queue: .main)

        // Không để dò version treo quá lâu nếu server chặn status ping.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { finish(nil) }
    }

    // MARK: - Kết nối thật (login)

    private func openMainConnection(token: UUID) {
        let conn = NWConnection(host: .init(host), port: .init(rawValue: port) ?? 25565, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self, self.connectAttemptToken == token else { return }
                self.handleConnectionState(newState)
            }
        }
        conn.viabilityUpdateHandler = { [weak self] viable in
            guard !viable else { return }
            Task { @MainActor in
                guard let self, self.connectAttemptToken == token, self.shouldStayConnected else { return }
                self.scheduleReconnect(reason: "mạng/socket không còn khả dụng")
            }
        }
        conn.betterPathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connectAttemptToken == token, self.shouldStayConnected else { return }
                // Let NWConnection finish the path migration when possible. If the
                // connection has already stopped receiving packets, foreground/watchdog
                // recovery will replace it without touching the visible chat log.
            }
        }
        conn.start(queue: .main)
        receiveLoop(token: token)

        // Nếu sau 7s vẫn chưa vào được .connected, coi như treo (thường do server yêu cầu
        // online-mode và im lặng chờ Encryption Response, hoặc firewall chặn) → báo lỗi rõ ràng
        // thay vì để người dùng thấy app "kết nối mãi không vào".
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            guard let self, self.connectAttemptToken == token else { return }
            if self.state == .connecting || self.state == .loggingIn {
                self.appendLog(.error, "Server chưa phản hồi login, đang giữ phiên và tự thử lại.")
                if self.shouldStayConnected {
                    self.scheduleReconnect(reason: "login timeout")
                } else {
                    self.state = .failed("Hết thời gian chờ khi đăng nhập")
                    self.connection?.cancel()
                }
            }
        }
    }

    private func handleConnectionState(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            startHandshakeAndLogin()
        case .failed(let error):
            appendLog(.error, "Lỗi kết nối: \(error.localizedDescription) [NWError]")
            if shouldStayConnected {
                scheduleReconnect(reason: "kết nối TCP thất bại")
            } else {
                state = .failed(error.localizedDescription)
            }
        case .cancelled:
            break
        default:
            break
        }
    }

    // MARK: - Gửi gói tin

    /// Đóng gói packetID + payload thành 1 gói tin hoàn chỉnh (length-prefixed),
    /// có tính tới nén nếu đã bật.
    private func send(packetId: Int32, payload: [UInt8]) {
        var body = MCVarInt.encode(packetId) + payload

        if compressionThreshold >= 0 {
            // Định dạng khi có nén: [dataLength varint][data (nén nếu vượt ngưỡng, raw nếu không)]
            if body.count >= Int(compressionThreshold) {
                if let compressed = zlibDeflate(Data(body)) {
                    // compression_encode_buffer(..., COMPRESSION_ZLIB) already returns a
                    // complete RFC1950 zlib stream. Do NOT wrap it a second time: doing so
                    // creates a nested/invalid stream that some proxies tolerate briefly
                    // but may later desynchronise the session.
                    let dataLen = MCVarInt.encode(Int32(body.count))
                    body = dataLen + Array(compressed)
                } else {
                    // Nếu zlib không tạo được stream, gửi packet hợp lệ ở dạng RAW.
                    // Tuyệt đối không đặt dataLength > 0 cho dữ liệu chưa nén.
                    body = MCVarInt.encode(0) + body
                }
            } else {
                body = MCVarInt.encode(0) + body // dataLength = 0 nghĩa là không nén
            }
        }

        let wirePayloadLength = body.count
        let compressed = compressionThreshold >= 0 && body.first != 0
        lastSentPacketDescription = String(format: "id=0x%02X bytes=%d %@", packetId, wirePayloadLength, compressed ? "compressed" : "raw")
        let full = MCVarInt.encode(Int32(body.count)) + body
        connection?.send(content: Data(full), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self else { return }
                // NWConnection reports ECANCELED for packets that were already queued
                // when we intentionally cancel a stale socket. That is not a new root
                // cause and must not recursively trigger another reconnect.
                if case .posix(let posix) = error, posix.rawValue == 89, !self.shouldStayConnected {
                    return
                }
                self.appendLog(.error, "Gửi packet thất bại: \(error.localizedDescription)\(self.networkErrorHint(error))")
                if self.shouldStayConnected, self.state != .connecting, self.state != .loggingIn {
                    self.scheduleReconnect(reason: "send packet lỗi")
                }
            }
        })
    }

    private func networkErrorHint(_ error: NWError) -> String {
        if case .posix(let posix) = error, posix.rawValue == 53 {
            return " — POSIX 53 (socket bị hệ điều hành abort). Đang tự kết nối lại."
        }
        if case .posix(let posix) = error, posix.rawValue == 89 {
            return " — POSIX 89/ECANCELED (mạng vừa bị ngắt đột ngột, ví dụ đổi WiFi/4G hoặc app bị đưa ra nền). Đang tự kết nối lại."
        }
        return ""
    }

    /// Polls (every 10s) whether we've heard anything from the server recently. Vanilla
    /// servers send a Keep Alive roughly every 15s, so 45s of total silence while we
    /// still think we're `.connected` means the socket is dead but stuck — force a
    /// reconnect instead of leaving chat/player-list frozen indefinitely.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                guard let self, self.state == .connected else { continue }
                let silentFor = Date().timeIntervalSince(self.lastPacketReceivedAt)
                if silentFor > max(self.watchdogTimeout, 60) {
                    self.appendLog(.error, "Không nhận được dữ liệu từ server trong \(Int(silentFor))s, có thể kết nối đã chết âm thầm — tự kết nối lại.")
                    self.scheduleReconnect(reason: "watchdog: server im lặng quá lâu")
                }
            }
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Minecraft 1.12.2 gửi một Player/Player Position heartbeat khoảng mỗi 20 ticks
    /// (~1 giây) ngay cả khi người chơi đứng yên. Chỉ trả Keep Alive là chưa đủ đối với
    /// một số proxy/plugin chống AFK/anti-bot: chúng còn theo dõi movement tick của client.
    ///
    /// Bản cũ của app chỉ gửi packet 0x0C (Player / On Ground) mỗi ~2 giây. Với server
    /// Tôi Chơi/Velocity/Bungee kiểu này, sau một lúc player bị coi là không còn ở trạng
    /// thái Play bình thường; hậu quả nhìn thấy ở UI là command bị server từ chối bằng
    /// "This command cannot be executed on this server". Ở đây gửi đúng packet 0x0D
    /// (Player Position) với X/Y/Z hiện tại, 1 lần/giây, giống heartbeat của client thật.
    /// Chỉ bắt đầu sau khi đã nhận vị trí đầu tiên từ server.
    private func startIdleAliveTicker() {
        idleAliveTask?.cancel()
        idleAliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard let self, self.state == .connected, self.hasServerPosition else { continue }
                let now = Date().timeIntervalSince1970
                guard now - self.movementLastSentAt >= 0.9 else { continue }
                self.movementLastSentAt = now
                self.sendPlayerPosition(onGround: self.isOnGround)
            }
        }
    }

    private func stopIdleAliveTicker() {
        idleAliveTask?.cancel()
        idleAliveTask = nil
    }

    private func scheduleReconnect(reason: String) {
        guard shouldStayConnected else { return }
        reconnectWorkItem?.cancel()
        connection?.cancel()
        connection = nil
        compressionThreshold = -1
        compressionFailureCount = 0
        lastCompressionFailureAt = 0

        let token = UUID()
        connectAttemptToken = token
        let delay = reconnectDelay + Double.random(in: 0...1.5)
        reconnectDelay = min(reconnectDelay * 1.8, 30)
        state = .connecting
        appendLog(.info, "Sẽ tự kết nối lại sau \(String(format: "%.1f", delay))s (\(reason))...")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.shouldStayConnected, self.connectAttemptToken == token else { return }
                self.protocolVersion = self.fallbackProtocolVersion
                self.appendLog(.info, "Đang kết nối lại trực tiếp tới \(self.host):\(self.port)...")
                self.openMainConnection(token: token)
            }
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startHandshakeAndLogin() {
        state = .loggingIn
        appendLog(.info, "Đang đăng nhập (offline) với tên \(username)...")

        // Handshake (0x00): protocol version, địa chỉ, cổng, next state = 2 (Login)
        var hsPayload: [UInt8] = []
        hsPayload += MCVarInt.encode(protocolVersion)
        hsPayload += mcEncodeString(host)
        hsPayload += [UInt8(port >> 8), UInt8(port & 0xFF)]
        hsPayload += MCVarInt.encode(2)
        send(packetId: 0x00, payload: hsPayload)

        // Login Start (0x00): chỉ cần username ở bản 1.12.2
        send(packetId: 0x00, payload: mcEncodeString(username))
    }

    // MARK: - Nhận dữ liệu

    private func receiveLoop(token: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.connectAttemptToken == token else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    await self.drainPackets()
                }
                if let error {
                    self.appendLog(.error, "Mất kết nối: \(error.localizedDescription)\(self.networkErrorHint(error))")
                    if self.shouldStayConnected {
                        self.scheduleReconnect(reason: "mất socket")
                    } else {
                        self.state = .failed(error.localizedDescription)
                    }
                    return
                }
                if isComplete {
                    if self.state != .disconnected {
                        self.appendLog(.error, "Server đã đóng kết nối.")
                        if self.shouldStayConnected {
                            self.scheduleReconnect(reason: "server đóng socket")
                        } else {
                            self.state = .disconnected
                        }
                    }
                    return
                }
                self.receiveLoop(token: token)
            }
        }
    }

    private func drainPackets(maxPackets: Int = 24) async {
        var processed = 0
        while processed < maxPackets, let raw = buffer.nextRawPacket() {
            processed += 1
            lastPacketReceivedAt = Date()
            await handleRawPacket(raw)
        }

        // Không xử lý hàng nghìn packet liên tiếp trên MainActor. Nhường run-loop
        // để SwiftUI còn nhận touch/scroll/vẽ hình, sau đó xử lý tiếp phần còn lại.
        // (Trước đây phần giải nén bên dưới chạy đồng bộ ngay trên MainActor — vừa
        // vào server, hàng loạt packet Chunk Data/Player Info nén dồn dập tới khiến
        // app "đứng hình" vài giây; giờ việc giải nén được đẩy sang thread nền và
        // có điểm nhường run-loop, KHÔNG đổi bất kỳ logic đăng nhập/giao thức nào.)
        if processed == maxPackets, buffer.remainingCount > 0 {
            await Task.yield()
            await drainPackets(maxPackets: maxPackets)
        }
    }

    /// `raw` = toàn bộ nội dung sau byte độ dài gói (có thể còn nén).
    private func handleRawPacket(_ raw: Data) async {
        var payload = raw
        if compressionThreshold >= 0 {
            var idx = 0
            guard let dataLen = MCVarInt.decode(next: {
                guard idx < raw.count else { return nil }
                defer { idx += 1 }
                return raw[raw.startIndex + idx]
            }) else { return }

            // Minecraft protocol: khi compression đã bật, mỗi packet có thêm
            // Data Length VarInt. 0 = packet không nén; >0 = zlib stream.
            // Không được thử parse packet ID trước khi giải nén, nếu không chỉ
            // cần 1 packet lỗi là toàn bộ TCP stream bị lệch.
            guard dataLen >= 0 else { return }
            let rest = Data(raw.suffix(from: raw.startIndex + idx))
            if dataLen == 0 {
                payload = rest
            } else {
                let expected = Int(dataLen)
                guard expected > 0 else { return }
                // Zlib inflate là việc tốn CPU (packet Chunk Data lúc mới join có thể
                // rất lớn) — chạy trên thread nền (Task.detached) rồi await kết quả,
                // để MainActor rảnh ra vẽ UI trong lúc chờ thay vì đứng hình. Định dạng
                // dữ liệu/điều kiện lỗi giữ y nguyên như cũ.
                guard let inflated = await Self.inflateOffMainThread(rest, expectedSize: expected) else {
                    compressionFailureCount += 1
                    let now = Date().timeIntervalSince1970
                    // Không spam UI hàng trăm dòng khi server/proxy gửi packet
                    // mà client chưa hiểu; chỉ báo tối đa 1 lần / 2 giây.
                    if now - lastCompressionFailureAt >= 2.0 {
                        lastCompressionFailureAt = now
                        appendLog(.error, "Packet nén không hợp lệ (dataLength=\(expected), compressed=\(rest.count)).")
                    }
                    // Tuyệt đối không parse `rest` như packet chưa nén.
                    return
                }
                guard inflated.count == expected else { return }
                payload = inflated
            }
        }

        var idx = 0
        guard let packetId = MCVarInt.decode(next: {
            guard idx < payload.count else { return nil }
            defer { idx += 1 }
            return payload[payload.startIndex + idx]
        }) else { return }
        let body = payload.suffix(from: payload.startIndex + idx)

        switch state {
        case .loggingIn:
            handleLoginPacket(id: packetId, body: Data(body))
        case .connected:
            handlePlayPacket(id: packetId, body: Data(body))
        default:
            break
        }
    }

    /// Giải nén zlib trên 1 thread nền (không đụng tới MainActor / state của client),
    /// dùng đúng hàm `zlibInflate` cũ — chỉ đổi CHỖ chạy, không đổi CÁCH giải nén.
    private static func inflateOffMainThread(_ data: Data, expectedSize: Int) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            zlibInflate(data, expectedSize: expectedSize)
        }.value
    }

    // MARK: - Login state

    private func handleLoginPacket(id: Int32, body: Data) {
        switch id {
        case 0x00: // Disconnect (login)
            let (reason, _) = body.readMCString(from: 0) ?? ("Bị từ chối kết nối.", 0)
            appendLog(.error, "Server từ chối đăng nhập: \(prettyChatJSON(reason))")
            if shouldStayConnected {
                scheduleReconnect(reason: "server từ chối login")
            } else {
                state = .failed(prettyChatJSON(reason))
                connection?.cancel()
            }

        case 0x01: // Encryption Request -> server yêu cầu tài khoản Minecraft/Microsoft thật
            appendLog(.error, "Server yêu cầu tài khoản Minecraft thật (online-mode). App hiện chỉ hỗ trợ server offline/cracked, không hỗ trợ đăng nhập bằng tài khoản thật.")
            state = .failed("Server yêu cầu tài khoản thật (online-mode)")
            connection?.cancel()

        case 0x02: // Login Success -> chuyển sang Play
            appendLog(.info, "Đăng nhập thành công, vào server...")
            reconnectDelay = 4.0
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            state = .connected
            lastPacketReceivedAt = Date()
            startWatchdog()
            startIdleAliveTicker()
            if UIApplication.shared.applicationState == .background {
                BackgroundKeepAlive.shared.start()
            }
            attemptAutoLogin()

        case 0x03: // Set Compression
            var idx = 0
            if let threshold = MCVarInt.decode(next: {
                guard idx < body.count else { return nil }
                defer { idx += 1 }
                return body[body.startIndex + idx]
            }) {
                compressionThreshold = threshold
            }

        default:
            break
        }
    }

    // MARK: - Play state

    private func handlePlayPacket(id: Int32, body: Data) {
        switch id {
        case 0x1F: // Keep Alive (clientbound) — 8 byte long, phải gửi lại y nguyên
            guard body.count >= 8 else { return }
            let longBytes = Array(body.prefix(8))
            send(packetId: 0x0B, payload: longBytes) // Keep Alive (serverbound)

        case 0x0E: // Tab Complete (clientbound) — protocol 340
            handleTabComplete(body)

        case 0x2E: // Player List Item — protocol 340
            handlePlayerListItem(body)

        case 0x23: // Join Game — lấy dimension hiện tại
            handleJoinGame(body)

        case 0x35: // Respawn — đổi dimension
            handleRespawn(body)

        case 0x2F: // Player Position And Look — cập nhật X/Y/Z và xác nhận teleport
            handlePlayerPositionAndLook(body)

        case 0x0F: // Chat Message (clientbound)
            guard let (json, next) = body.readMCString(from: 0) else { return }
            let position = next < body.count ? body[body.startIndex + next] : 0
            let segments = chatSegments(from: json)
            let text = segments.map(\.text).joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            appendLog(position == 1 ? .system : .chat, text, segments: segments)

        case 0x1A: // Disconnect (play)
            let (reason, _) = body.readMCString(from: 0) ?? ("Bạn đã bị ngắt kết nối.", 0)
            let readableReason = prettyChatJSON(reason)
            appendLog(.error, "Bị ngắt kết nối: \(readableReason) · packet cuối: \(lastSentPacketDescription)")

            // Timeout/socket timeout là lỗi phiên TCP tạm thời, không phải một lệnh
            // kick cố ý. Nếu đã bật Stay Connected thì giữ ý định kết nối và dựng lại
            // socket; tuyệt đối không xoá chat/inventory/UI state ở đây. Các lý do kick
            // khác vẫn dừng hẳn để tránh reconnect loop.
            let lower = readableReason.lowercased()
            let transientTimeout = lower.contains("disconnect.timeout") ||
                lower.contains("timed out") ||
                lower.contains("timeout") ||
                lower.contains("read timeout")

            connection?.cancel()
            connection = nil
            compressionThreshold = -1
            compressionFailureCount = 0
            lastCompressionFailureAt = 0
            stopWatchdog()
            stopIdleAliveTicker()

            if shouldStayConnected && transientTimeout {
                state = .connecting
                scheduleReconnect(reason: "server timeout — giữ phiên và kết nối lại")
            } else {
                shouldStayConnected = false
                reconnectWorkItem?.cancel()
                reconnectWorkItem = nil
                state = .disconnected
            }

        case 0x12: // Close Window (clientbound) — server tự đóng menu đang mở
            currentWindow = nil

        case 0x13: // Open Window — server mở 1 GUI (vd menu "Chọn máy chủ" khi chuột phải la bàn)
            handleOpenWindow(body)

        case 0x14: // Window Items — server gửi toàn bộ nội dung 1 window (0 = inventory của mình)
            handleWindowItems(body)

        case 0x16: // Set Slot — server cập nhật 1 ô riêng lẻ
            handleSetSlot(body)

        case 0x34: // Resource Pack Send — server yêu cầu tải texture pack
            handleResourcePackSend(body)

        case 0x41: // Update Health — protocol 340
            handleUpdateHealth(body)

        default:
            break // các gói khác (world, entity...) bỏ qua có chủ đích
        }
    }

    // MARK: - Vị trí

    private func handleJoinGame(_ body: Data) {
        // 1.12.2: Entity ID (Int), GameMode (Byte), Dimension (Int), Difficulty (Byte), ...
        guard body.count >= 9, let dimension = body.readI32BE(from: 5)?.0 else { return }
        currentDimension = dimensionName(dimension)
        // Gửi Client Settings + MC|Brand sau Join Game, đúng thứ tự lifecycle của
        // client vanilla thay vì gửi ngay tại Login Success. Một số proxy/plugin kiểm
        // tra hai packet này sau khi Play state đã được khởi tạo.
        sendClientJoinAnnouncement()
    }

    private func handleRespawn(_ body: Data) {
        guard let dimension = body.readI32BE(from: 0)?.0 else { return }
        currentDimension = dimensionName(dimension)
        // Sau khi server respawn, health/food sẽ được gửi lại; đặt trạng thái tạm thời
        // về mặc định để UI không giữ thanh máu 0 trong lúc chờ packet Update Health.
        health = 20
        food = 20
        foodSaturation = 5
    }

    private func handleUpdateHealth(_ body: Data) {
        guard let healthValue = body.readF32BE(from: 0) else { return }
        var idx = healthValue.1
        guard let (foodValue, next) = decodeVarInt(from: body, offset: idx) else { return }
        idx = next
        guard let saturation = body.readF32BE(from: idx)?.0 else { return }
        health = max(0, healthValue.0)
        food = max(0, min(20, Int(foodValue)))
        foodSaturation = max(0, saturation)
        if health <= 0 {
            appendLog(.error, "Bạn đã chết. Nhấn Respawn để hồi sinh.")
        }
    }

    /// Gửi Client Status action=0 để hồi sinh sau khi chết. Protocol 340 dùng packet 0x03.
    func respawn() {
        guard state == .connected else { return }
        guard health <= 0 else {
            appendLog(.info, "Bạn chưa chết nên server không cần Respawn.")
            return
        }
        send(packetId: 0x03, payload: MCVarInt.encode(0))
        appendLog(.info, "Đã gửi yêu cầu Respawn.")
    }

    private func handlePlayerPositionAndLook(_ body: Data) {
        var idx = 0
        guard let x = body.readF64BE(from: idx) else { return }; idx = x.1
        guard let y = body.readF64BE(from: idx) else { return }; idx = y.1
        guard let z = body.readF64BE(from: idx) else { return }; idx = z.1
        guard let yaw = body.readF32BE(from: idx) else { return }; idx = yaw.1
        guard let pitch = body.readF32BE(from: idx) else { return }; idx = pitch.1
        guard let flags = body.readU8(from: idx) else { return }; idx = flags.1
        guard let teleport = decodeVarInt(from: body, offset: idx) else { return }

        // Protocol 340 dùng flags để báo tọa độ tương đối. Cộng tương đối vào vị trí hiện tại.
        let flagByte = flags.0
        if (flagByte & 0x01) != 0 { playerX += x.0 } else { playerX = x.0 }
        if (flagByte & 0x02) != 0 { playerY += y.0 } else { playerY = y.0 }
        if (flagByte & 0x04) != 0 { playerZ += z.0 } else { playerZ = z.0 }
        if (flagByte & 0x08) != 0 { playerYaw += yaw.0 } else { playerYaw = yaw.0 }
        if (flagByte & 0x10) != 0 { playerPitch += pitch.0 } else { playerPitch = pitch.0 }
        isOnGround = true
        hasServerPosition = true

        // Teleport Confirm — bắt buộc khi server gửi teleport id.
        send(packetId: 0x00, payload: MCVarInt.encode(teleport.0))
    }

    private func dimensionName(_ id: Int32) -> String {
        switch id {
        case -1: return "Nether"
        case 1: return "The End"
        default: return "Overworld"
        }
    }

    // MARK: - Điều khiển vị trí

    /// Movement engine kiểu client: tick 20Hz, tốc độ nhỏ và ổn định; không teleport-style.
    func movePlayer(dx: Double, dz: Double) {
        guard state == .connected, hasServerPosition else { return }
        let now = Date().timeIntervalSince1970
        guard now - movementLastSentAt >= 0.05 else { return }
        let distance = hypot(dx, dz)
        guard distance > 0 else { return }
        let maxStep = 0.14
        let scale = min(maxStep / distance, 1.0)
        playerX += dx * scale
        playerZ += dz * scale
        movementLastSentAt = now
        sendPlayerPosition(onGround: isOnGround)
    }

    /// WASD theo hướng nhìn của người chơi. Mỗi lần nhận phím chỉ gửi một bước nhỏ;
    /// giữ phím trên bàn phím vật lý sẽ tự tạo key-repeat, giống thao tác client thật.
    func movePlayer(forward: Double, strafe: Double) {
        // Do not silently swallow a touch: the UI calls this on every 50 ms tick.
        // A position is required because the server is authoritative; once the
        // initial Player Position And Look has arrived, every WASD tick becomes a
        // real protocol-340 Player Position packet.
        guard state == .connected, hasServerPosition else { return }
        let f = max(-1.0, min(1.0, forward))
        let s = max(-1.0, min(1.0, strafe))
        let length = hypot(f, s)
        guard length > 0 else { return }
        let yawRadians = Double(playerYaw) * .pi / 180.0
        let forwardX = -sin(yawRadians)
        let forwardZ = cos(yawRadians)
        let rightX = cos(yawRadians)
        let rightZ = sin(yawRadians)
        movePlayer(dx: forwardX * (f / length) + rightX * (s / length),
                   dz: forwardZ * (f / length) + rightZ * (s / length))
    }

    /// Bắt đầu gửi chuyển động liên tục khi người dùng giữ W/A/S/D trên màn hình cảm ứng.
    /// Mỗi tick chỉ gửi 1 packet nhỏ để không làm nghẽn socket và không khóa UI.
    func startMoving(forward: Double, strafe: Double) {
        guard state == .connected else { return }
        let key = "\(forward):\(strafe)"
        guard movementTasks[key] == nil else { return }
        movePlayer(forward: forward, strafe: strafe)
        movementTasks[key] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, let self, self.state == .connected else { break }
                self.movePlayer(forward: forward, strafe: strafe)
            }
        }
    }

    func stopMoving(forward: Double, strafe: Double) {
        let key = "\(forward):\(strafe)"
        movementTasks[key]?.cancel()
        movementTasks.removeValue(forKey: key)
    }

    /// Jump thật cho protocol 340. Gửi ngay bước nhảy đầu tiên rồi mô phỏng
    /// quỹ đạo trong các tick tiếp theo; cách cũ bắt đầu ở delta-Y gần 0 nên
    /// nhiều server/proxy không coi đó là một cú nhảy.
    func jumpPlayer() {
        guard state == .connected, hasServerPosition else { return }
        jumpTask?.cancel()
        jumpGeneration += 1
        let generation = jumpGeneration
        let startY = playerY
        let startTime = Date().timeIntervalSince1970
        let duration = 0.62

        // Minecraft client leaves the ground immediately.
        isOnGround = false
        playerY = startY + 0.42
        movementLastSentAt = Date().timeIntervalSince1970
        sendPlayerPosition(onGround: false)

        func scheduleNext() {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .connected, self.jumpGeneration == generation else { return }
                let t = Date().timeIntervalSince1970 - startTime
                let u = min(max(t / duration, 0), 1)
                // Smooth jump arc. The first packet above already moved us off ground.
                self.playerY = startY + (0.42 * 4.0 * u * (1.0 - u))
                let landed = u >= 1.0
                self.isOnGround = landed
                self.movementLastSentAt = Date().timeIntervalSince1970
                self.sendPlayerPosition(onGround: landed)
                if !landed {
                    scheduleNext()
                } else {
                    self.playerY = startY
                    self.sendPlayerPosition(onGround: true)
                    self.jumpTask = nil
                }
            }
            self.jumpTask = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
        scheduleNext()
    }

    private func sendPlayerGroundStatus(onGround: Bool) {
        send(packetId: 0x0C, payload: [onGround ? 1 : 0])
    }

    private func sendPlayerPosition(onGround: Bool) {
        var payload: [UInt8] = []
        payload += playerX.mcBigEndianBytes
        payload += playerY.mcBigEndianBytes
        payload += playerZ.mcBigEndianBytes
        payload.append(onGround ? 1 : 0)
        // Protocol 340: Player Position = 0x0D.
        // 0x0C chỉ chứa duy nhất field On Ground; gửi X/Y/Z với 0x0C làm lệch
        // decoder của server/proxy và có thể khiến connection bị kick.
        send(packetId: 0x0D, payload: payload)
    }

    /// Client Minecraft thật (kể cả ChatCraft chính chủ) LUÔN gửi 2 gói này ngay sau khi
    /// vào Play: Client Settings (0x04) và Plugin Message "MC|Brand" (0x09). App này trước
    /// giờ không gửi — nhiều plugin/proxy chống bot ở server dùng chính 2 tín hiệu này để
    /// phân biệt client thật với bot/script (thường có "thời gian ân hạn" vài chục giây
    /// trước khi kết luận là bot rồi chặn), rất khớp với triệu chứng "đứng yên 1 lúc thì
    /// bị This command cannot be executed" mà không phải do rớt mạng.
    private func sendClientJoinAnnouncement() {
        var settings: [UInt8] = []
        settings += mcEncodeString("vi_VN")          // locale
        settings.append(8)                             // view distance
        settings += MCVarInt.encode(0)                  // chat mode: enabled
        settings.append(1)                              // chat colors: true
        settings.append(0x7F)                           // displayed skin parts: tất cả
        settings += MCVarInt.encode(1)                  // main hand: phải
        send(packetId: 0x04, payload: settings)

        let brandPayload = mcEncodeString("MC|Brand") + mcEncodeString("vanilla")
        send(packetId: 0x09, payload: brandPayload)
    }

    // MARK: - Player list + Tab completion

    /// Gửi yêu cầu Tab Complete của protocol 340. Server sẽ trả về các tên khớp
    /// (rất hữu ích cho /w WhatDid -> WhatDidYouDo).
    func requestTabCompletions(_ text: String) {
        guard state == .connected else { return }
        let query = text
        guard !query.isEmpty else {
            tabCompletions = []
            return
        }
        tabCompletionTransaction += 1
        tabCompletionPrefix = query
        tabCycleIndex = 0

        // Không gửi Tab Complete packet lên proxy/server. Một số proxy/plugin của
        // server này xử lý packet Tab Complete không tương thích với protocol 340 và
        // có thể trả về packet malformed, khiến decoder nén bị lệch. Player List đã có
        // đủ dữ liệu để hoàn thành /w, /r, /msg ở phía client.

        // Hoàn thành ngay bằng Player List, không cần chờ server phản hồi.
        let token = currentCompletionToken(in: query)
        let prefix = token.lowercased()
        if !prefix.isEmpty {
            tabCompletions = onlinePlayerNames
                .filter { $0.lowercased().hasPrefix(prefix) }
                .sorted { $0.lowercased() < $1.lowercased() }
        }
    }

    /// Dùng danh sách Player List để thay phần cuối của lệnh bằng tên người chơi.
    /// Trả về chuỗi mới để UI đặt lại text field.
    func completeLocally(_ text: String) -> String? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard text.hasPrefix("/"), parts.count >= 2 else { return nil }
        let prefix = String(parts.last ?? "")
        guard !prefix.isEmpty else { return nil }
        let matches = onlinePlayerNames
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
            .sorted { $0.lowercased() < $1.lowercased() }
        guard let first = matches.first else { return nil }
        let start = text.dropLast(prefix.count)
        return String(start) + first
    }

    /// Hoàn thành token cuối bằng tên người chơi. Nhấn Tab nhiều lần sẽ xoay qua các kết quả.
    func completeWithNextPlayerName(_ text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let token = currentCompletionToken(in: text)
        guard !token.isEmpty else { return nil }

        let serverMatches = tabCompletions.filter {
            $0.lowercased().hasPrefix(token.lowercased())
        }
        let localMatches = onlinePlayerNames
            .filter { $0.lowercased().hasPrefix(token.lowercased()) }
            .sorted { $0.lowercased() < $1.lowercased() }
        let matches = serverMatches.isEmpty ? localMatches : serverMatches
        guard !matches.isEmpty else { return nil }

        if tabCompletionPrefix != text { tabCycleIndex = 0 }
        let name = matches[tabCycleIndex % matches.count]
        tabCycleIndex = (tabCycleIndex + 1) % matches.count
        tabCompletionPrefix = text

        return String(text.dropLast(token.count)) + name
    }

    private func currentCompletionToken(in text: String) -> String {
        let pieces = text.split(separator: " ", omittingEmptySubsequences: false)
        return String(pieces.last ?? "")
    }

    private func handleTabComplete(_ body: Data) {
        var idx = 0
        // Clientbound Tab Complete của protocol 340 bắt đầu trực tiếp bằng Count.
        guard let (count, nextCount) = decodeVarInt(from: body, offset: idx) else { return }
        idx = nextCount

        var results: [String] = []
        if count > 0 {
            for _ in 0..<Int(count) {
                guard let (match, nextMatch) = body.readMCString(from: idx) else { break }
                idx = nextMatch
                results.append(match)
                // Protocol 1.12.2 không có tooltip field cho từng match.
            }
        }
        tabCompletions = results
    }

    /// Parse Player List Item (0x2D) của 1.12.2 để giữ danh sách tên online.
    /// UUID được lưu kèm username để xử lý chính xác REMOVE_PLAYER.
    private func handlePlayerListItem(_ body: Data) {
        var idx = 0
        guard let (action, nextAction) = decodeVarInt(from: body, offset: idx) else { return }
        idx = nextAction
        guard let (count, nextCount) = decodeVarInt(from: body, offset: idx) else { return }
        idx = nextCount

        for _ in 0..<Int(count) {
            guard idx + 16 <= body.count else { return }
            let uuidData = body.subdata(in: idx..<(idx + 16))
            idx += 16
            let uuid = uuidData.withUnsafeBytes { raw -> String in
                guard let base = raw.baseAddress else { return UUID().uuidString }
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let ns = NSUUID(uuidBytes: bytes)
                return ns.uuidString.lowercased()
            }

            switch action {
            case 0: // ADD_PLAYER
                guard let (name, nextName) = body.readMCString(from: idx) else { return }
                idx = nextName
                guard let (propertyCount, nextProperties) = decodeVarInt(from: body, offset: idx) else { return }
                idx = nextProperties
                for _ in 0..<Int(propertyCount) {
                    guard let (_, n1) = body.readMCString(from: idx) else { return }
                    idx = n1
                    guard let (_, n2) = body.readMCString(from: idx) else { return }
                    idx = n2
                    guard idx < body.count else { return }
                    let signed = body[body.startIndex + idx] != 0
                    idx += 1
                    if signed {
                        guard let (_, n3) = body.readMCString(from: idx) else { return }
                        idx = n3
                    }
                }
                guard let (_, nextGamemode) = decodeVarInt(from: body, offset: idx) else { return }
                idx = nextGamemode
                guard let (_, nextPing) = decodeVarInt(from: body, offset: idx) else { return }
                idx = nextPing
                guard idx < body.count else { return }
                let hasDisplayName = body[body.startIndex + idx] != 0
                idx += 1
                if hasDisplayName {
                    guard let (_, nextDisplay) = body.readMCString(from: idx) else { return }
                    idx = nextDisplay
                }

                playerNamesByUUID[uuid] = name
                onlinePlayerNames.insert(name)

            case 1: // UPDATE_GAMEMODE
                guard let (_, next) = decodeVarInt(from: body, offset: idx) else { return }
                idx = next

            case 2: // UPDATE_LATENCY
                guard let (_, next) = decodeVarInt(from: body, offset: idx) else { return }
                idx = next

            case 3: // UPDATE_DISPLAY_NAME
                guard idx < body.count else { return }
                let hasDisplayName = body[body.startIndex + idx] != 0
                idx += 1
                if hasDisplayName {
                    guard let (_, next) = body.readMCString(from: idx) else { return }
                    idx = next
                }

            case 4: // REMOVE_PLAYER
                if let name = playerNamesByUUID.removeValue(forKey: uuid) {
                    onlinePlayerNames.remove(name)
                }

            default:
                return
            }
        }

        // Giữ kết quả gợi ý local đồng bộ ngay khi server gửi Player List.
        let prefix = currentCompletionToken(in: tabCompletionPrefix).lowercased()
        if !prefix.isEmpty {
            tabCompletions = onlinePlayerNames
                .filter { $0.lowercased().hasPrefix(prefix) }
                .sorted { $0.lowercased() < $1.lowercased() }
        }
    }

    private func decodeVarInt(from data: Data, offset: Int) -> (Int32, Int)? {
        var numRead = 0
        var result: Int32 = 0
        var shift: Int32 = 0
        var idx = offset
        while idx < data.count && numRead < 5 {
            let byte = data[data.startIndex + idx]
            idx += 1
            result |= Int32(byte & 0x7F) << shift
            numRead += 1
            if (byte & 0x80) == 0 { return (result, idx) }
            shift += 7
        }
        return nil
    }

    // MARK: - GUI menu (Open Window / Window Items khi windowId != 0)

    private func handleOpenWindow(_ body: Data) {
        var idx = 0
        guard let (windowId, next1) = body.readU8(from: idx) else { return }
        idx = next1
        guard let (_, next2) = body.readMCString(from: idx) else { return } // inventoryType — không cần
        idx = next2
        guard let (title, next3) = body.readMCString(from: idx) else { return }
        idx = next3
        guard let (slotCount, _) = body.readU8(from: idx) else { return }

        windowActionCounter = 0
        currentWindow = MCOpenWindow(windowId: windowId, title: prettyChatJSON(title), slotCount: Int(slotCount))
        appendLog(.info, "Server mở 1 menu: \(prettyChatJSON(title))")
    }

    /// Mô phỏng click chọn 1 ô trong menu server đang mở (vd chọn tên server trong menu "Chọn máy chủ").
    func clickWindowSlot(_ slot: Int, mouseButton: UInt8 = 0) {
        guard state == .connected, let window = currentWindow else { return }
        guard (0...1).contains(mouseButton) else { return }
        let clicked = window.items[slot]?.rawSlotBytes ?? Data([0xFF, 0xFF])
        sendWindowClick(windowId: window.windowId, slot: slot, mouseButton: mouseButton, mode: 0, clickedSlotBytes: clicked)
    }

    /// Drop Stack (Ctrl+Q) — protocol 340: Click Window mode=4, button=1.
    /// Gửi đúng Slot bytes hiện tại để server chấp nhận và loại toàn bộ stack.
    func dropAllFromWindowSlot(_ slot: Int) {
        guard state == .connected, let window = currentWindow else { return }
        let clicked = window.items[slot]?.rawSlotBytes ?? Data([0xFF, 0xFF])
        sendWindowClick(windowId: window.windowId, slot: slot, mouseButton: 1, mode: 4, clickedSlotBytes: clicked)
    }

    func dropAllFromInventorySlot(_ slot: Int) {
        guard state == .connected else { return }
        let clicked = playerInventory[slot]?.rawSlotBytes ?? Data([0xFF, 0xFF])
        sendWindowClick(windowId: 0, slot: slot, mouseButton: 1, mode: 4, clickedSlotBytes: clicked)
    }

    func clickInventorySlot(_ slot: Int, mouseButton: UInt8 = 0) {
        guard state == .connected, (0...1).contains(mouseButton) else { return }
        let clicked = playerInventory[slot]?.rawSlotBytes ?? Data([0xFF, 0xFF])
        sendWindowClick(windowId: 0, slot: slot, mouseButton: mouseButton, mode: 0, clickedSlotBytes: clicked)
    }

    private func sendWindowClick(windowId: UInt8, slot: Int, mouseButton: UInt8, mode: UInt8, clickedSlotBytes: Data) {
        windowActionCounter &+= 1
        let slotBE = UInt16(bitPattern: Int16(slot))
        let actionBE = UInt16(bitPattern: windowActionCounter)
        var payload: [UInt8] = [windowId, UInt8(slotBE >> 8), UInt8(slotBE & 0xFF), mouseButton,
                                 UInt8(actionBE >> 8), UInt8(actionBE & 0xFF), mode]
        payload.append(contentsOf: clickedSlotBytes)
        send(packetId: 0x07, payload: payload)
    }

    /// Đóng menu đang mở (báo cho server biết, giống bấm ESC/đóng GUI trong game thật).
    func closeCurrentWindow() {
        guard let window = currentWindow else { currentWindow = nil; return }
        send(packetId: 0x08, payload: [window.windowId]) // Close Window (serverbound)
        currentWindow = nil
    }

    // MARK: - Texture pack (Resource Pack)

    private func handleResourcePackSend(_ body: Data) {
        guard let (url, next) = body.readMCString(from: 0),
              let (hash, _) = body.readMCString(from: next) else { return }
        resourcePackPending = true
        appendLog(.info, "Server gửi texture pack, bắt buộc tải và áp dụng...")
        // ACCEPTED = 3 trong protocol 340.
        send(packetId: 0x18, payload: MCVarInt.encode(3))
        downloadResourcePack(urlString: url, hash: hash)
    }

    private func downloadResourcePack(urlString: String, hash: String) {
        guard let url = URL(string: urlString) else {
            finishResourcePack(success: false, message: "Địa chỉ texture pack không hợp lệ.")
            return
        }

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            Task { @MainActor in
                guard let self else { return }
                guard let tempURL, error == nil else {
                    self.finishResourcePack(success: false, message: "Tải texture pack thất bại: \(error?.localizedDescription ?? "lỗi không rõ")")
                    return
                }
                do {
                    let dir = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                        .appendingPathComponent("TexturePacks", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let fileName = (hash.isEmpty ? UUID().uuidString : hash) + ".zip"
                    let dest = dir.appendingPathComponent(fileName)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        // Đã có bản cùng hash: không cần tải/giải nén lại.
                        try? FileManager.default.removeItem(at: tempURL)
                    } else {
                        try FileManager.default.moveItem(at: tempURL, to: dest)
                    }
                    try await MCResourcePackStore.shared.installDownloadedPack(zipURL: dest, name: fileName)
                    self.finishResourcePack(success: true, message: "Đã tải + áp dụng texture pack \(fileName).")
                } catch {
                    self.finishResourcePack(success: false, message: "Không lưu được texture pack: \(error.localizedDescription)")
                }
            }
        }
        task.resume()
    }

    private func finishResourcePack(success: Bool, message: String) {
        resourcePackPending = false
        appendLog(success ? .info : .error, message)
        // SUCCESSFULLY_LOADED = 0, FAILED_DOWNLOAD = 2.
        send(packetId: 0x18, payload: MCVarInt.encode(success ? 0 : 2))
        let waiters = resourcePackCompletionWaiters
        resourcePackCompletionWaiters.removeAll()
        waiters.forEach { $0() }
    }

    // MARK: - Tự động đăng nhập + mở compass + chọn Diamond Axe

    private func attemptAutoLogin() {
        // Chỉ mục để bật/tắt automation từ toggle "Autologin" trong Edit server — mọi bước
        // bên dưới (thời gian chờ, gửi /login, mở la bàn, chọn ô 23...) giữ nguyên y hệt.
        guard autoLoginEnabled else { return }
        guard let password = MCCredentialStore.loadPassword(host: host, port: port, username: username)
                ?? MCCredentialStore.loadAccountPassword(username: username) else { return }
        let generation = UUID()
        loginAutomationGeneration = generation
        let token = connectAttemptToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.connectAttemptToken == token, self.loginAutomationGeneration == generation, self.state == .connected else { return }
            self.sendLoginAndScheduleMenu(password: password, token: token, generation: generation)
        }
    }

    private func sendLoginAndScheduleMenu(password: String, token: UUID, generation: UUID) {
        send(packetId: 0x02, payload: mcEncodeString("/dn \(password)"))
        appendLog(.info, "Đã tự gửi /dn. Chờ 2 giây rồi mở la bàn...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.connectAttemptToken == token, self.loginAutomationGeneration == generation, self.state == .connected else { return }
            self.startCompassAutomation(token: token, generation: generation)
        }
    }

    private func startCompassAutomation(token: UUID, generation: UUID) {
        let action = { [weak self] in
            guard let self, self.connectAttemptToken == token, self.loginAutomationGeneration == generation, self.state == .connected else { return }
            guard let item = self.hotbar[4] else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startCompassAutomation(token: token, generation: generation)
                }
                return
            }
            guard item.itemId == 345 else {
                self.appendLog(.error, "Hotbar 5 hiện không phải Compass (itemId=\(item.itemId)); không gửi click nhầm item.")
                return
            }
            self.useHotbarItem(4) // hotbar 5 (index 4)
            self.autoMenuSelectionPending = true
            self.autoMenuRetryCount = 0
            self.appendLog(.info, "Đã chuột phải la bàn ở hotbar 5; chờ GUI và chọn ô 23...")
            self.retryAutoMenuSelection(token: token, generation: generation)
        }
        if resourcePackPending {
            resourcePackCompletionWaiters.append(action)
        } else {
            action()
        }
    }

    private func retryAutoMenuSelection(token: UUID, generation: UUID) {
        guard autoMenuSelectionPending, state == .connected, connectAttemptToken == token, loginAutomationGeneration == generation else { return }
        if let window = currentWindow, let item = window.items[23] {
            let isDiamondAxe = item.itemId == 279 || item.plainName.lowercased().contains("diamond axe") || item.plainName.lowercased().contains("rìu kim cương")
            if isDiamondAxe {
                autoMenuSelectionPending = false
                clickWindowSlot(23, mouseButton: 0)
                appendLog(.info, "Đã click Diamond Axe ở ô GUI 23.")
                return
            }
        }
        guard autoMenuRetryCount < 24 else {
            autoMenuSelectionPending = false
            appendLog(.error, "Không tìm thấy Diamond Axe ở ô GUI 23 sau 6 giây.")
            return
        }
        autoMenuRetryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.retryAutoMenuSelection(token: token, generation: generation)
        }
    }

    /// Slot 36-44 trong player inventory (windowId 0) tương ứng hotbar 0-8.
    private func hotbarIndex(forInventorySlot slot: Int) -> Int? {
        guard (36...44).contains(slot) else { return nil }
        return slot - 36
    }

    /// windowId == 0: inventory của chính mình (hotbar). windowId khác: GUI server đang mở
    /// (vd menu "Chọn máy chủ") — lưu vào `currentWindow` kèm bytes gốc để có thể click lại.
    private func handleWindowItems(_ body: Data) {
        var idx = 0
        guard let (windowId, next1) = body.readU8(from: idx) else { return }
        idx = next1
        guard let (count, next2) = body.readI16BE(from: idx) else { return }
        idx = next2

        if windowId == 0 {
            for slot in 0..<Int(count) {
                let hbIndex = hotbarIndex(forInventorySlot: slot) ?? -1
                guard let (item, next) = MCSlotParser.parse(body, from: idx, hotbarIndex: hbIndex) else { return }
                idx = next
                if hbIndex >= 0 { hotbar[hbIndex] = item }
                // Giáp (5-8) + balo (9-35) + hotbar (36-44) — dùng cho màn "xem giáp/balo/hotbar".
                if (5...44).contains(slot) {
                    playerInventory[slot] = item
                }
            }
            return
        }

        guard var window = currentWindow, window.windowId == windowId else { return }
        for slot in 0..<Int(count) {
            let start = idx
            guard let (item, next) = MCSlotParser.parse(body, from: idx, hotbarIndex: -1) else { return }
            let raw = body.subdata(in: (body.startIndex + start)..<(body.startIndex + next))
            idx = next
            if let item {
                window.items[slot] = MCOpenWindowItem(slot: slot, itemId: item.itemId, damage: item.damage,
                                                        nameSegments: item.nameSegments, loreSegments: item.loreSegments,
                                                        rawSlotBytes: raw)
            } else {
                window.items.removeValue(forKey: slot)
            }
        }
        currentWindow = window
        if autoMenuSelectionPending {
            retryAutoMenuSelection(token: connectAttemptToken, generation: loginAutomationGeneration)
        }
    }

    private func handleSetSlot(_ body: Data) {
        var idx = 0
        guard let (windowIdRaw, next1) = body.readU8(from: idx) else { return }
        idx = next1
        let windowIdSigned = Int8(bitPattern: windowIdRaw) // -1 = item đang cầm ở con trỏ, bỏ qua
        guard let (slot16, next2) = body.readI16BE(from: idx) else { return }
        idx = next2
        let slot = Int(slot16)

        if windowIdSigned == 0 {
            let hbIndex = hotbarIndex(forInventorySlot: slot) ?? -1
            guard let (item, _) = MCSlotParser.parse(body, from: idx, hotbarIndex: hbIndex) else { return }
            if hbIndex >= 0 { hotbar[hbIndex] = item }
            if (5...44).contains(slot) {
                playerInventory[slot] = item
            }
            return
        }

        guard windowIdSigned > 0, var window = currentWindow, window.windowId == UInt8(windowIdSigned) else { return }
        let start = idx
        guard let (item, next) = MCSlotParser.parse(body, from: idx, hotbarIndex: -1) else { return }
        let raw = body.subdata(in: (body.startIndex + start)..<(body.startIndex + next))
        _ = next
        if let item {
            window.items[slot] = MCOpenWindowItem(slot: slot, itemId: item.itemId, damage: item.damage,
                                                        nameSegments: item.nameSegments, loreSegments: item.loreSegments,
                                                        rawSlotBytes: raw)
        } else {
            window.items.removeValue(forKey: slot)
        }
        currentWindow = window
        if autoMenuSelectionPending {
            retryAutoMenuSelection(token: connectAttemptToken, generation: loginAutomationGeneration)
        }
    }

    /// Mô phỏng hành động "chuột phải" vào 1 item trong hotbar (vd để mở menu server, đổi hub...).
    /// Gửi Held Item Change để server biết đang cầm ô nào, sau đó Use Item để trigger tương tác.
    /// (Lưu ý ID gói tin đúng theo giao thức 340: Held Item Change serverbound = 0x1A,
    /// Use Item serverbound = 0x20 — dùng nhầm 0x1D (Arm Animation, chỉ vung tay không tương
    /// tác) sẽ khiến server KHÔNG mở menu dù client tưởng đã "click" thành công.)
    func useHotbarItem(_ hotbarIndex: Int) {
        guard state == .connected, (0...8).contains(hotbarIndex) else { return }
        send(packetId: 0x1A, payload: [UInt8(hotbarIndex >> 8), UInt8(hotbarIndex & 0xFF)]) // Held Item Change (Short)
        send(packetId: 0x20, payload: MCVarInt.encode(0)) // Use Item, hand = 0 (main hand)
        appendLog(.info, "Đã chuột phải vào ô hotbar \(hotbarIndex + 1).")
    }

    // MARK: - Gửi chat

    func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard state == .connected, !trimmed.isEmpty else { return }

        if let password = loginPassword(fromCommand: trimmed) {
            // Gõ lệnh thủ công chỉ là lệnh của người dùng. Tuyệt đối KHÔNG tự mở
            // Compass/GUI sau /dn hoặc /login: server phải tự gửi GUI nếu muốn mở.
            // Automation chỉ được phép chạy từ attemptAutoLogin() khi profile.autoLogin = true.
            MCCredentialStore.savePassword(password, host: host, port: port, username: username)
            appendLog(.info, "Đã lưu mật khẩu đăng nhập cho tài khoản này.")
            send(packetId: 0x02, payload: mcEncodeString(text))
            recordSentMessage(trimmed)
            return
        }

        send(packetId: 0x02, payload: mcEncodeString(text)) // Chat (serverbound)
        // Không tự thêm vào log — server sẽ gửi lại chính tin nhắn này qua Chat Message (clientbound)
        recordSentMessage(trimmed)
    }

    /// Thêm vào lịch sử gọi lại bằng nút mũi tên lên/xuống. Không thêm dòng trùng liên
    /// tiếp (gõ lại y hệt lệnh vừa gửi không tạo thêm 1 mục lịch sử mới).
    private func recordSentMessage(_ text: String) {
        if sentMessageHistory.last == text { return }
        sentMessageHistory.append(text)
        if sentMessageHistory.count > 200 {
            sentMessageHistory.removeFirst(sentMessageHistory.count - 200)
        }
    }

    /// Nhận diện lệnh đăng nhập (không phân biệt hoa/thường) để lưu lại mật khẩu.
    /// Ưu tiên "/dn " (lệnh của server dùng plugin auth tiếng Việt kiểu AuthMe), nhưng vẫn
    /// nhận "/login " để không phá các server khác đang dùng lệnh chuẩn tiếng Anh.
    private func loginPassword(fromCommand text: String) -> String? {
        let prefixes = ["/dn ", "/login "]
        let lower = text.lowercased()
        guard let prefix = prefixes.first(where: { lower.hasPrefix($0) }), text.count > prefix.count else { return nil }
        let password = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return password.isEmpty ? nil : password
    }

    // MARK: - Tiện ích

    /// Cho UI thêm thông báo nội bộ mà không cần expose appendLog riêng.
    func appendUserInfo(_ text: String) {
        appendLog(.info, text)
    }

    private func appendLog(_ kind: MCLogEntry.Kind, _ text: String, segments: [MCChatSegment]? = nil) {
        // Info/debug nội bộ (click GUI, reconnect, texture pack...) không đưa lên chat.
        // ChatCraft-style UI chỉ hiển thị chat/system thực sự từ server và lỗi cần biết.
        guard kind != .info else { return }
        log.append(MCLogEntry(kind: kind, text: text, segments: segments))
        if log.count > 350 { log.removeFirst(log.count - 350) }
    }
}

// MARK: - Parse chat component JSON đơn giản (text + extra, bỏ qua màu sắc/định dạng)

func prettyChatJSON(_ jsonString: String) -> String {
    return chatSegments(from: jsonString).map(\.text).joined()
}

/// Parse 1 chuỗi JSON chat component (hoặc chuỗi thô có mã màu §) thành danh sách đoạn có màu,
/// giữ nguyên màu/định dạng gốc từ server thay vì xoá đi — dùng để hiển thị giống client thật.
func chatSegments(from jsonString: String) -> [MCChatSegment] {
    guard let data = jsonString.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) else {
        return splitLegacyCodes(jsonString, base: MCChatStyle())
    }
    return walkChatComponent(obj, style: MCChatStyle())
}

private struct MCChatStyle {
    var colorHex: String?
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var linkURL: String? = nil
}

/// Bảng màu 16 màu chuẩn của Minecraft (mã §0-§f).
private let mcColorHex: [Character: String] = [
    "0": "#000000", "1": "#0000AA", "2": "#00AA00", "3": "#00AAAA",
    "4": "#AA0000", "5": "#AA00AA", "6": "#FFAA00", "7": "#AAAAAA",
    "8": "#555555", "9": "#5555FF", "a": "#55FF55", "b": "#55FFFF",
    "c": "#FF5555", "d": "#FF55FF", "e": "#FFFF55", "f": "#FFFFFF",
]

private let mcNamedColorHex: [String: String] = [
    "black": "#000000", "dark_blue": "#0000AA", "dark_green": "#00AA00", "dark_aqua": "#00AAAA",
    "dark_red": "#AA0000", "dark_purple": "#AA00AA", "gold": "#FFAA00", "gray": "#AAAAAA",
    "dark_gray": "#555555", "blue": "#5555FF", "green": "#55FF55", "aqua": "#55FFFF",
    "red": "#FF5555", "light_purple": "#FF55FF", "yellow": "#FFFF55", "white": "#FFFFFF",
]

/// Tách 1 chuỗi thô chứa mã màu kiểu cũ (§0-§f màu, §l/§o/§n/§m định dạng, §r reset)
/// thành các đoạn (segment) có màu/định dạng riêng, kế thừa style ban đầu `base`.
private func splitLegacyCodes(_ text: String, base: MCChatStyle) -> [MCChatSegment] {
    var segments: [MCChatSegment] = []
    var style = base
    var current = ""
    let chars = Array(text)
    var i = 0

    func flush() {
        guard !current.isEmpty else { return }
        segments.append(MCChatSegment(text: current, colorHex: style.colorHex, bold: style.bold,
                                       italic: style.italic, underline: style.underline,
                                       strikethrough: style.strikethrough, linkURL: style.linkURL))
        current = ""
    }

    while i < chars.count {
        if chars[i] == "\u{00A7}", i + 1 < chars.count {
            flush()
            let code = Character(String(chars[i + 1]).lowercased())
            if let hex = mcColorHex[code] {
                style = MCChatStyle(colorHex: hex) // đổi màu sẽ reset định dạng, đúng hành vi thật của Minecraft
            } else {
                switch code {
                case "l": style.bold = true
                case "o": style.italic = true
                case "n": style.underline = true
                case "m": style.strikethrough = true
                case "r": style = base
                default: break // §k (obfuscated) không hỗ trợ hiệu ứng nhấp nháy, bỏ qua
                }
            }
            i += 2
            continue
        }
        current.append(chars[i])
        i += 1
    }
    flush()
    return segments
}

/// Duyệt đệ quy 1 chat component JSON (text/extra/translate/color/bold...) thành danh sách đoạn có màu.
private func walkChatComponent(_ obj: Any, style: MCChatStyle) -> [MCChatSegment] {
    if let s = obj as? String {
        return splitLegacyCodes(s, base: style)
    }
    guard let dict = obj as? [String: Any] else { return [] }

    var st = style
    if let colorName = dict["color"] as? String {
        st.colorHex = mcNamedColorHex[colorName] ?? (colorName.hasPrefix("#") ? colorName : st.colorHex)
    }
    if let b = dict["bold"] as? Bool { st.bold = b }
    if let it = dict["italic"] as? Bool { st.italic = it }
    if let u = dict["underlined"] as? Bool { st.underline = u }
    if let s2 = dict["strikethrough"] as? Bool { st.strikethrough = s2 }
    // Minecraft chat components có thể gắn URL qua clickEvent thay vì viết URL
    // thẳng trong text. Đây chính là kiểu server dùng cho "Đăng nhập", "Đăng ký",
    // "Đổi mật khẩu"; trước đây parser bỏ qua clickEvent nên các link này không click được.
    if let click = dict["clickEvent"] as? [String: Any],
       let action = click["action"] as? String,
       action == "open_url",
       let value = click["value"] as? String,
       URL(string: value) != nil {
        st.linkURL = value
    }

    var segments: [MCChatSegment] = []
    if let text = dict["text"] as? String, !text.isEmpty {
        segments += splitLegacyCodes(text, base: st)
    }
    if let translate = dict["translate"] as? String {
        let withArr = (dict["with"] as? [Any])?.flatMap { walkChatComponent($0, style: st) } ?? []
        segments += withArr.isEmpty ? splitLegacyCodes(translate, base: st) : withArr
    }
    if let extra = dict["extra"] as? [Any] {
        segments += extra.flatMap { walkChatComponent($0, style: st) }
    }
    return segments
}

// MARK: - zlib nén/giải nén (Minecraft dùng định dạng zlib chuẩn, RFC1950)

private func zlibInflate(_ data: Data, expectedSize: Int) -> Data? {
    guard expectedSize > 0, !data.isEmpty, expectedSize <= 8 * 1024 * 1024 else { return nil }

    func decodeRaw(_ compressed: Data) -> Data? {
        guard !compressed.isEmpty else { return nil }
        var result = Data(count: expectedSize)
        let size: Int = result.withUnsafeMutableBytes { dst in
            compressed.withUnsafeBytes { src in
                guard let dstPtr = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = src.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(dstPtr, expectedSize, srcPtr, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        return size == expectedSize ? result : nil
    }

    // Notchian/legacy Minecraft implementations normally carry raw DEFLATE here.
    // Một số proxy lại bọc thêm RFC1950 header + Adler32. Thử raw trước, sau đó mới
    // thử bỏ wrapper để tương thích cả hai mà không làm lệch TCP stream.
    if let raw = decodeRaw(data) { return raw }
    if data.count > 6 {
        let wrapped = data.dropFirst(2).dropLast(4)
        if let raw = decodeRaw(Data(wrapped)) { return raw }
    }
    return nil
}

private func zlibDeflate(_ data: Data) -> Data? {
    guard !data.isEmpty else { return nil }
    let capacity = max(data.count + 64, data.count * 2)
    var dst = Data(count: capacity)
    let compressedSize: Int = dst.withUnsafeMutableBytes { dstBuf in
        data.withUnsafeBytes { srcBuf in
            guard let dstPtr = dstBuf.bindMemory(to: UInt8.self).baseAddress,
                  let srcPtr = srcBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dstPtr, capacity, srcPtr, data.count, nil, COMPRESSION_ZLIB)
        }
    }
    guard compressedSize > 0 else { return nil }
    return Data(dst.prefix(compressedSize))
}

private extension Double {
    var mcBigEndianBytes: [UInt8] {
        let bits = bitPattern.bigEndian
        return withUnsafeBytes(of: bits) { Array($0) }
    }
}

private extension Float {
    var mcBigEndianBytes: [UInt8] {
        let bits = bitPattern.bigEndian
        return withUnsafeBytes(of: bits) { Array($0) }
    }
}

private extension Data {
    func readF64BE(from offset: Int) -> (Double, Int)? {
        guard offset + 8 <= count else { return nil }
        var bits: UInt64 = 0
        for i in 0..<8 { bits = (bits << 8) | UInt64(self[startIndex + offset + i]) }
        return (Double(bitPattern: bits), offset + 8)
    }
    func readF32BE(from offset: Int) -> (Float, Int)? {
        guard offset + 4 <= count else { return nil }
        var bits: UInt32 = 0
        for i in 0..<4 { bits = (bits << 8) | UInt32(self[startIndex + offset + i]) }
        return (Float(bitPattern: bits), offset + 4)
    }
}
