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
    /// UUID của người chơi theo username, dùng để tải head/skin giống ChatCraft.
    @Published private(set) var playerUUIDByName: [String: String] = [:]
    /// Kết quả / danh sách gợi ý khi nhấn Tab trong chat (vd /w WhatDid -> WhatDidYouDo).
    @Published var tabCompletions: [String] = []

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


    /// Fallback nếu server profile không chỉ định protocol version cụ thể.
    private let fallbackProtocolVersion: Int32 = 760
    private var protocolVersion: Int32 = 760
    private var useLoginForSession = false
    private var isForgeServer = false

    private var connection: NWConnection?
    private let buffer = MCByteBuffer()
    private var compressionThreshold: Int32 = -1 // -1 = tắt nén
    private var compressionFailureCount = 0
    private var lastCompressionFailureAt: TimeInterval = 0
    private var connectAttemptToken = UUID()
    private var drainScheduled = false

    private var host: String = ""
    private var port: UInt16 = 25565
    private var username: String = ""
    private var windowActionCounter: Int16 = 0
    private var backgroundObservers: [NSObjectProtocol] = []
    /// true sau khi người dùng bấm Kết nối; khi mạng chập chờn/iOS trả POSIX 53,
    /// client sẽ tự nối lại thay vì để game bị văng khỏi server.
    private var shouldStayConnected = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectDelay: TimeInterval = 1.5
    private var reconnectAttemptCount = 0
    private let maxReconnectAttempts = 6
    private var movementLastSentAt: TimeInterval = 0
    private var jumpTask: DispatchWorkItem?
    private var jumpGeneration = 0
    private var isOnGround = true
    private var movementTasks: [String: Task<Void, Never>] = [:]
    private var movementPrimeTask: Task<Void, Never>?
    private var didPrimeMovementThisSession = false

    /// Trạng thái hiển thị cho giao diện điều khiển.
    /// Giữ logic vật lý nội bộ nhưng cho SwiftUI đọc được an toàn.
    var isOnGroundLabel: String {
        isOnGround ? "Đang đứng" : "Đang trên không"
    }

    // Tự động hoá flow của server Tôi Chơi Network:
    // /login -> chờ 2s -> chọn hotbar 5 -> chuột phải -> chờ GUI -> click slot 23 (Diamond Axe).
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
                guard let self, self.state == .connected else { return }
                BackgroundKeepAlive.shared.start()
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
                if self.shouldStayConnected && self.state != .connected && self.state != .loggingIn && self.state != .connecting {
                    self.scheduleReconnect(reason: "quay lại ứng dụng")
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
    /// `protocolVersion`: chọn đúng version thật của server (vd 1.12.2 = 340) trong màn Sửa server,
    /// tránh bị kick do sai protocol. Không truyền thì dùng mặc định 760.
    func connect(host: String, port: UInt16, username: String, useLogin: Bool = false,
                 protocolVersion: Int32? = nil, isForge: Bool = false) {
        disconnect(silent: true)
        shouldStayConnected = true
        useLoginForSession = useLogin
        isForgeServer = isForge
        reconnectDelay = 1.5
        self.host = host
        self.port = port
        self.username = username
        let token = UUID()
        connectAttemptToken = token

        state = .connecting
        appendLog(.info, "Đang kết nối trực tiếp tới \(host):\(port)...")
        reconnectAttemptCount = 0
        // KHÔNG mở connection tạm để dò protocol trước khi login nữa: proxy này
        // (và nhiều proxy chống bot khác) coi 2 lần connect liên tiếp trong vài trăm ms
        // là hành vi bot và tự đóng socket login ngay lập tức — kết quả là mở
        // được connection probe nhưng connection login thật thì bị kick câm lặng.
        // Login thẳng 1 connection duy nhất, dùng protocol đã chọn thủ công cho server này.
        self.protocolVersion = protocolVersion ?? fallbackProtocolVersion
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
        useLoginForSession = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        movementTasks.values.forEach { $0.cancel() }
        movementTasks.removeAll()
        movementPrimeTask?.cancel()
        movementPrimeTask = nil
        didPrimeMovementThisSession = false
        loginAutomationGeneration = UUID()
        autoMenuSelectionPending = false
        autoMenuRetryCount = 0
        resourcePackPending = false
        resourcePackCompletionWaiters.removeAll()
        connectAttemptToken = UUID() // vô hiệu hoá mọi callback đang chờ (probe/timeout) của lần kết nối trước
        drainScheduled = false
        buffer.reset()
        connection?.cancel()
        connection = nil
        drainScheduled = false
        buffer.reset()
        compressionThreshold = -1
        compressionFailureCount = 0
        lastCompressionFailureAt = 0
        onlinePlayerNames.removeAll()
        playerNamesByUUID.removeAll()
        playerUUIDByName.removeAll()
        tabCompletions.removeAll()
        tabCompletionPrefix = ""
        hotbar = Array(repeating: nil, count: 9)
        playerInventory.removeAll()
        currentWindow = nil
        windowActionCounter = 0
        playerX = 0
        playerY = 0
        playerZ = 0
        playerYaw = 0
        playerPitch = 0
        currentDimension = "Overworld"
        BackgroundKeepAlive.shared.stop()
        // Chat hiện tại chỉ là phiên live. Khi socket thực sự bị disconnect, xoá khỏi
        // màn ChatCraft để lần vào lại là một phiên sạch. MCChatHistoryStore vẫn giữ
        // toàn bộ tin nhắn đã nhận trong Logs của ngày đó.
        log.removeAll()
        if !silent {
            appendLog(.info, "Đã ngắt kết nối.")
        }
        state = .disconnected
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
        conn.start(queue: .main)
        receiveLoop(token: token)

        // Nếu sau 7s vẫn chưa vào được .connected, coi như treo (thường do server yêu cầu
        // online-mode và im lặng chờ Encryption Response, hoặc firewall chặn) → báo lỗi rõ ràng
        // thay vì để người dùng thấy app "kết nối mãi không vào".
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            guard let self, self.connectAttemptToken == token else { return }
            if self.state == .connecting || self.state == .loggingIn {
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
            if shouldStayConnected {
                scheduleReconnect(reason: "socket")
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

        let full = MCVarInt.encode(Int32(body.count)) + body
        connection?.send(content: Data(full), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self else { return }
                // Lỗi socket là trạng thái nội bộ, không đẩy dòng debug vào chat.
                if self.shouldStayConnected { self.scheduleReconnect(reason: "socket") }
            }
        })
    }

    private func networkErrorHint(_ error: NWError) -> String {
        if case .posix(let posix) = error, posix.rawValue == 53 {
            return " — POSIX 53 (socket bị hệ điều hành abort). Đang tự kết nối lại."
        }
        return ""
    }

    private func scheduleReconnect(reason: String) {
        guard shouldStayConnected else { return }
        reconnectAttemptCount += 1
        if reconnectAttemptCount > maxReconnectAttempts {
            shouldStayConnected = false
            appendLog(.error, "Đã thử kết nối lại \(maxReconnectAttempts) lần nhưng vẫn không được (lý do gần nhất: \(reason)). Kiểm tra lại địa chỉ/port hoặc thử lại sau.")
            state = .failed("Không thể kết nối tới \(host):\(port) sau \(maxReconnectAttempts) lần thử.")
            connection?.cancel()
            connection = nil
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            return
        }
        reconnectWorkItem?.cancel()
        connection?.cancel()
        connection = nil
        compressionThreshold = -1
        compressionFailureCount = 0
        lastCompressionFailureAt = 0

        let token = UUID()
        connectAttemptToken = token
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 1.8, 30)
        state = .connecting
        appendLog(.info, "Mất kết nối (\(reason)). Sẽ tự kết nối lại sau \(String(format: "%.1f", delay))s...")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.shouldStayConnected, self.connectAttemptToken == token else { return }
                self.appendLog(.info, "Đang kết nối lại trực tiếp tới \(self.host):\(self.port)...")
                // Giữ nguyên protocolVersion/isForgeServer đã chọn cho server này, không reset về fallback.
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
        // Nếu server chạy Forge, gắn marker FML/FML2 vào cuối địa chỉ để server Forge
        // nhận diện và cho client vanilla-like vào (chuẩn forge handshake trick).
        var handshakeHost = host
        if isForgeServer {
            handshakeHost += protocolVersion >= 404 ? "\0FML2\0" : "\0FML\0"
        }
        var hsPayload: [UInt8] = []
        hsPayload += MCVarInt.encode(protocolVersion)
        hsPayload += mcEncodeString(handshakeHost)
        hsPayload += [UInt8(port >> 8), UInt8(port & 0xFF)]
        hsPayload += MCVarInt.encode(2)
        send(packetId: 0x00, payload: hsPayload)

        // Login Start (0x00): username; các trường optional của 1.19.2 để trống
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
                    self.drainPackets()
                }
                if let error {
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

    private func drainPackets(maxPackets: Int = 8) {
        var processed = 0
        while processed < maxPackets, let raw = buffer.nextRawPacket() {
            processed += 1
            handleRawPacket(raw)
        }

        // Player-list/world packets có thể dồn thành hàng trăm packet ngay sau login.
        // Không chạy vòng lặp vô hạn trên MainActor: nhường một nhịp cho SwiftUI để
        // app vẫn nhận touch, scroll và bàn phím ngay lập tức.
        if processed == maxPackets, buffer.remainingCount > 0, !drainScheduled {
            drainScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.drainScheduled = false
                self.drainPackets(maxPackets: maxPackets)
            }
        }
    }

    /// `raw` = toàn bộ nội dung sau byte độ dài gói (có thể còn nén).
    private func handleRawPacket(_ raw: Data) {
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
                guard let inflated = zlibInflate(rest, expectedSize: expected) else {
                    compressionFailureCount += 1
                    // Không đưa lỗi decoder/nén vào chat. Quan trọng nhất là không
                    // parse phần compressed như packet thường vì sẽ làm lệch TCP stream.
                    return
                }
                guard inflated.count > 0, inflated.count <= 8 * 1024 * 1024 else { return }
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

    // MARK: - Login state

    private func handleLoginPacket(id: Int32, body: Data) {
        switch id {
        case 0x00: // Disconnect (login)
            let (reason, _) = body.readMCString(from: 0) ?? ("Bị từ chối kết nối.", 0)
            let prettyReason = prettyChatJSON(reason)
            appendLog(.error, "Server từ chối đăng nhập: \(prettyReason)")
            // Đây là server CHỦ ĐỘNG từ chối (vd sai protocol version, "Outdated
            // client/server"...), không phải mất mạng thoáng qua. Cứ tự kết nối lại
            // với protocol y hệt sẽ bị từ chối y hệt mãi mãi → dừng hẳn, báo lỗi rõ.
            shouldStayConnected = false
            state = .failed(prettyReason)
            connection?.cancel()

        case 0x01: // Encryption Request -> server yêu cầu tài khoản Minecraft/Microsoft thật
            appendLog(.error, "Server yêu cầu tài khoản Minecraft thật (online-mode). App hiện chỉ hỗ trợ server offline/cracked, không hỗ trợ đăng nhập bằng tài khoản thật.")
            state = .failed("Server yêu cầu tài khoản thật (online-mode)")
            connection?.cancel()

        case 0x02: // Login Success -> chuyển sang Play
            appendLog(.info, "Đăng nhập thành công, vào server...")
            reconnectDelay = 1.5
            reconnectAttemptCount = 0
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            state = .connected
            // Minecraft 1.19.2 gửi Client Information ngay sau Login Success.
            // Một số proxy/plugin chỉ bắt đầu gửi inventory/chat sau khi nhận packet này.
            sendClientInformation()
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

    /// Client Information / Settings — protocol 760, serverbound 0x08.
    /// Gửi cấu hình tối thiểu tương đương Minecraft thật để proxy/plugin biết client
    /// đã vào Play và cho phép chat + inventory interaction.
    private func sendClientInformation() {
        var payload: [UInt8] = []
        payload += mcEncodeString("vi_vn")
        payload.append(12) // view distance
        payload += MCVarInt.encode(0) // chat enabled
        payload.append(1) // chat colors enabled
        payload.append(0x7F) // all skin parts
        payload += MCVarInt.encode(1) // main hand = right
        payload.append(0) // text filtering disabled
        payload.append(1) // allow server listings
        send(packetId: 0x08, payload: payload)
    }

    // MARK: - Play state

    private func handlePlayPacket(id: Int32, body: Data) {
        switch id {
        case 0x20: // Keep Alive (clientbound) — protocol 760 / 1.19.2
            guard body.count >= 8 else { return }
            let longBytes = Array(body.prefix(8))
            send(packetId: 0x12, payload: longBytes) // Keep Alive (serverbound), protocol 760

        case 0x0F: // Tab Complete (clientbound) — protocol 760
            handleTabComplete(body)

        case 0x37: // Player Info — protocol 760 / 1.19.2
            handlePlayerListItem(body)

        case 0x25: // Join Game — protocol 760
            handleJoinGame(body)

        case 0x3E: // Respawn — protocol 760
            handleRespawn(body)

        case 0x39: // Player Position And Look — protocol 760
            handlePlayerPositionAndLook(body)

        case 0x33: // Player Chat (clientbound) — protocol 760
            handlePlayerChatPacket(body)

        case 0x1A: // Disconnect (play)
            let (reason, _) = body.readMCString(from: 0) ?? ("Bạn đã bị ngắt kết nối.", 0)
            appendLog(.error, "Bị ngắt kết nối: \(prettyChatJSON(reason))")
            if shouldStayConnected {
                scheduleReconnect(reason: "server gửi Disconnect")
            } else {
                state = .disconnected
                connection?.cancel()
            }

        case 0x62: // System Chat — protocol 760
            handleSystemChatPacket(body)

        case 0x10: // Close Window (clientbound) — protocol 760
            currentWindow = nil

        case 0x2D: // Open Window — protocol 760
            handleOpenWindow(body)

        case 0x11: // Window Items — protocol 760
            handleWindowItems(body)

        case 0x13: // Set Slot — protocol 760
            handleSetSlot(body)

        case 0x3D: // Resource Pack Send — protocol 760
            handleResourcePackSend(body)

        case 0x55: // Update Health — protocol 760
            handleUpdateHealth(body)

        default:
            break // các gói khác (world, entity...) bỏ qua có chủ đích
        }
    }

    /// 1.19.2 Player Chat: UUID + index + optional signature + message + phần metadata.
    /// Ta chỉ cần message; các trường ký/chế độ chat phía sau được bỏ qua an toàn.
    private func handlePlayerChatPacket(_ body: Data) {
        var idx = 0
        guard body.count >= 16 else { return }
        idx += 16 // sender UUID
        guard let (_, nextIndex) = decodeVarInt(from: body, offset: idx) else { return }
        idx = nextIndex
        guard let (hasSignature, nextFlag) = body.readU8(from: idx) else { return }
        idx = nextFlag
        if hasSignature != 0 {
            guard idx + 256 <= body.count else { return }
            idx += 256
        }
        guard let (message, _) = body.readMCString(from: idx) else { return }
        let segments = chatSegments(from: message)
        let text = segments.map(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appendLog(.chat, text, segments: segments)
    }

    /// 1.19.2 System Chat: Text Component JSON + overlay boolean.
    private func handleSystemChatPacket(_ body: Data) {
        guard let (json, _) = body.readMCString(from: 0) else { return }
        let segments = chatSegments(from: json)
        let text = segments.map(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appendLog(.chat, text, segments: segments)
    }

    // MARK: - Vị trí

    private func handleJoinGame(_ body: Data) {
        // Protocol 760 có cấu trúc Join Game lớn (NBT/registry). App chat không cần
        // giải mã toàn bộ world; chỉ đánh dấu đã vào Play. Không đọc nhầm 4 byte ở
        // giữa packet như bản 1.12.2 cũ.
        currentDimension = "Overworld"
    }

    private func handleRespawn(_ body: Data) {
        // 1.19.2: dimension type + dimension name đều là Identifier/string;
        // giữ UI ở Overworld nếu server không cần thông tin dimension chi tiết.
        currentDimension = "Overworld"
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
        send(packetId: 0x07, payload: MCVarInt.encode(0))
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

        // Teleport Confirm — bắt buộc khi server gửi teleport id.
        send(packetId: 0x00, payload: MCVarInt.encode(teleport.0))

        // Một số server/proxy chặn Chat packet cho tới khi nhận một Player Move.
        // ChatCraft/Minecraft thật phát movement ngay sau khi spawn; client cũ chỉ
        // gửi movement khi người dùng chạm WASD nên server có thể trả “You cannot
        // chat until you move!”. Gửi một bước cực nhỏ rồi trả lại vị trí để kích hoạt
        // PlayerMoveEvent, không tạo dịch chuyển đáng kể cho người chơi.
        if !didPrimeMovementThisSession {
            didPrimeMovementThisSession = true
            let baseX = playerX
            let baseZ = playerZ
            let yawRadians = Double(playerYaw) * .pi / 180.0
            let nudgeX = -sin(yawRadians) * 0.06
            let nudgeZ = cos(yawRadians) * 0.06
            playerX = baseX + nudgeX
            playerZ = baseZ + nudgeZ
            sendPlayerPosition(onGround: true)
            movementPrimeTask?.cancel()
            movementPrimeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.state == .connected else { return }
                self.playerX = baseX
                self.playerZ = baseZ
                self.sendPlayerPosition(onGround: true)
                self.movementPrimeTask = nil
            }
        }
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
        guard state == .connected else { return }
        let now = Date().timeIntervalSince1970
        guard now - movementLastSentAt >= 0.05 else { return }
        let distance = hypot(dx, dz)
        guard distance > 0 else { return }
        // Vanilla walking speed is roughly 4.3 blocks/s => ~0.215 block/tick at 20Hz.
        let maxStep = 0.215
        let scale = min(maxStep / distance, 1.0)
        playerX += dx * scale
        playerZ += dz * scale
        movementLastSentAt = now
        sendPlayerPosition(onGround: isOnGround)
    }

    /// WASD theo hướng nhìn của người chơi. Mỗi lần nhận phím chỉ gửi một bước nhỏ;
    /// giữ phím trên bàn phím vật lý sẽ tự tạo key-repeat, giống thao tác client thật.
    func movePlayer(forward: Double, strafe: Double) {
        guard state == .connected else { return }
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

    /// Jump có nhịp 20Hz, trạng thái onGround đúng trong lúc bay và trở về mặt đất ở cuối.
    func jumpPlayer() {
        guard state == .connected, isOnGround else { return }
        jumpTask?.cancel()
        jumpGeneration += 1
        let generation = jumpGeneration
        isOnGround = false
        let startY = playerY
        let startTime = Date().timeIntervalSince1970
        // Vanilla 1.12 jump: initial vertical velocity 0.42, gravity ~0.08/tick.
        // Tổng thời gian bay khoảng 10.5 ticks và đỉnh cao khoảng 1.1 block.
        let tickDuration = 0.05
        let jumpDuration = 0.525

        func scheduleNext() {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .connected, self.jumpGeneration == generation else { return }
                let elapsed = Date().timeIntervalSince1970 - startTime
                let ticks = min(max(elapsed / tickDuration, 0), jumpDuration / tickDuration)
                self.playerY = startY + (0.42 * ticks) - (0.5 * 0.08 * ticks * ticks)
                let landed = elapsed >= jumpDuration
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

    private func sendPlayerPosition(onGround: Bool) {
        var payload: [UInt8] = []
        payload += playerX.mcBigEndianBytes
        payload += playerY.mcBigEndianBytes
        payload += playerZ.mcBigEndianBytes
        payload.append(onGround ? 1 : 0)
        // Protocol 760 / Minecraft 1.19.2: Player Position = 0x14.
        send(packetId: 0x14, payload: payload)
    }

    // MARK: - Player list + Tab completion

    /// Gửi yêu cầu Tab Complete. Với proxy này app hoàn thành tên người chơi ở phía client
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
        let command = query.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        let playerCommands = ["/w", "/msg", "/tell", "/t", "/r", "/reply", "/whisper", "/m"]
        if prefix.isEmpty && playerCommands.contains(command) {
            tabCompletions = onlinePlayerNames.sorted { $0.lowercased() < $1.lowercased() }
        } else if !prefix.isEmpty {
            tabCompletions = onlinePlayerNames
                .filter { $0.lowercased().hasPrefix(prefix) }
                .sorted { $0.lowercased() < $1.lowercased() }
        } else {
            tabCompletions = []
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
        // Clientbound Tab Complete 760 có transactionId + range + matches.
        guard let (count, nextCount) = decodeVarInt(from: body, offset: idx) else { return }
        idx = nextCount

        var results: [String] = []
        if count > 0 {
            for _ in 0..<Int(count) {
                guard let (match, nextMatch) = body.readMCString(from: idx) else { break }
                idx = nextMatch
                results.append(match)
                // Tooltip của match là optional; không cần cho autocomplete local.
            }
        }
        tabCompletions = results
    }

    /// Parse Player Info của 1.19.x để giữ danh sách tên online.
    /// UUID được lưu kèm username để xử lý chính xác REMOVE_PLAYER.
    private func handlePlayerListItem(_ body: Data) {
        var idx = 0
        guard let (action, nextAction) = decodeVarInt(from: body, offset: idx) else { return }
        idx = nextAction
        guard let (count, nextCount) = decodeVarInt(from: body, offset: idx) else { return }
        idx = nextCount

        // Chỉ publish một lần cho cả packet. Publish từng username làm SwiftUI
        // render lại hàng chục/hàng trăm lần ngay lúc mới vào server.
        var namesChanged = false
        var pendingNames = onlinePlayerNames
        var pendingUUIDMap = playerUUIDByName

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
                pendingNames.insert(name)
                pendingUUIDMap[name] = uuid
                namesChanged = true

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
                    pendingNames.remove(name)
                    pendingUUIDMap.removeValue(forKey: name)
                    namesChanged = true
                }

            default:
                return
            }
        }

        if namesChanged {
            // Chỉ publish một lần cho cả packet. Đây là điểm quan trọng để server
            // có vài trăm người online không làm SwiftUI render lại vài trăm lần lúc vào.
            onlinePlayerNames = pendingNames
            playerUUIDByName = pendingUUIDMap
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
        // 1.19.2: inventory type là VarInt enum, không còn String.
        guard let (_, next2) = decodeVarInt(from: body, offset: idx) else { return }
        idx = next2
        guard let (title, next3) = body.readMCString(from: idx) else { return }
        idx = next3

        windowActionCounter = 0
        currentWindow = MCOpenWindow(
            windowId: windowId,
            title: prettyChatJSON(title),
            slotCount: 54,
            stateId: 0,
            items: [:]
        )
        appendLog(.info, "Server mở 1 menu: \(prettyChatJSON(title))")
    }

    /// Click trực tiếp một ô trong GUI server.
    ///
    /// Các menu kiểu "Chọn máy chủ" của Tôi Chơi dùng LEFT click để chọn
    /// Diamond Axe / Ice / hub. Vì vậy khi người dùng chạm thẳng vào item
    /// trong GUI, app tự gửi LEFT click — không bắt người dùng mở "..." nữa.
    func clickWindowSlot(_ slot: Int, mouseButton: UInt8 = 0) {
        guard state == .connected, let window = currentWindow else { return }
        guard (0...1).contains(mouseButton) else { return }
        sendWindowClick(windowId: window.windowId, stateId: window.stateId, slot: slot, mouseButton: mouseButton, mode: 0)
    }

    /// Hành động "thông minh" cho item trong GUI.
    ///
    /// Không có bit nào trong packet Window Click nói cho client biết "server
    /// muốn LEFT hay RIGHT"; yêu cầu này là logic gameplay của từng menu.
    /// Với flow hiện tại của Tôi Chơi: compass/hotbar = RIGHT (Use Item),
    /// menu chọn server = LEFT. Hàm này gom quy tắc đó vào một chỗ để UI
    /// không cần biết packet/button.
    func smartClickWindowItem(_ item: MCOpenWindowItem) {
        guard state == .connected, currentWindow != nil else { return }
        // Menu server: chọn entry bằng LEFT click.
        clickWindowSlot(item.slot, mouseButton: 0)
    }

    /// Thao tác Drop Stack (mode=4, button=1) cho GUI/inventory.
    func dropAllFromWindowSlot(_ slot: Int) {
        guard state == .connected, let window = currentWindow else { return }
        sendWindowClick(windowId: window.windowId, stateId: window.stateId, slot: slot, mouseButton: 1, mode: 4)
    }

    func dropAllFromInventorySlot(_ slot: Int) {
        guard state == .connected else { return }
        sendWindowClick(windowId: 0, stateId: 0, slot: slot, mouseButton: 1, mode: 4)
    }

    func clickInventorySlot(_ slot: Int, mouseButton: UInt8 = 0) {
        guard state == .connected, (0...1).contains(mouseButton) else { return }
        sendWindowClick(windowId: 0, stateId: 0, slot: slot, mouseButton: mouseButton, mode: 0)
    }

    private func sendWindowClick(windowId: UInt8, stateId: Int32, slot: Int, mouseButton: UInt8, mode: UInt8) {
        // Protocol 760 / 1.19.2: Window Click = windowId + stateId + slot + button + mode
        // + changedSlots(0) + cursorItem(empty).
        var payload: [UInt8] = [windowId]
        payload += MCVarInt.encode(stateId)
        let slotBE = UInt16(bitPattern: Int16(slot))
        payload += [UInt8(slotBE >> 8), UInt8(slotBE & 0xFF), mouseButton]
        payload += MCVarInt.encode(Int32(mode))
        payload += MCVarInt.encode(0) // changed slots count
        payload.append(0) // empty cursor item
        send(packetId: 0x0B, payload: payload)
    }

    /// Đóng menu đang mở (báo cho server biết, giống bấm ESC/đóng GUI trong game thật).
    func closeCurrentWindow() {
        guard let window = currentWindow else { currentWindow = nil; return }
        send(packetId: 0x0C, payload: [window.windowId]) // Close Window (serverbound)
        currentWindow = nil
    }

    // MARK: - Texture pack (Resource Pack)

    private func handleResourcePackSend(_ body: Data) {
        guard let (url, next) = body.readMCString(from: 0),
              let (hash, _) = body.readMCString(from: next) else { return }
        resourcePackPending = true
        appendLog(.info, "Server gửi texture pack, bắt buộc tải và áp dụng...")
        // ACCEPTED = 3 trong protocol 760.
        send(packetId: 0x24, payload: MCVarInt.encode(3))
        downloadResourcePack(urlString: url, hash: hash)
    }

    private func downloadResourcePack(urlString: String, hash: String) {
        guard let url = URL(string: urlString) else {
            finishResourcePack(success: false, message: "Địa chỉ texture pack không hợp lệ.")
            return
        }

        // Nếu pack đã có trong máy theo hash thì dùng ngay, tuyệt đối không tải lại.
        // Việc này loại bỏ một nguồn lag lớn khi reconnect/vào lại server.
        if !hash.isEmpty,
           let dir = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("TexturePacks", isDirectory: true) {
            let cached = dir.appendingPathComponent(hash + ".zip")
            if FileManager.default.fileExists(atPath: cached.path) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await MCResourcePackStore.shared.installDownloadedPack(zipURL: cached, name: cached.lastPathComponent)
                        self.finishResourcePack(success: true, message: "Dùng texture pack đã cache: \(cached.lastPathComponent).")
                    } catch {
                        self.finishResourcePack(success: false, message: "Không áp dụng được texture pack đã cache: \(error.localizedDescription)")
                    }
                }
                return
            }
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
        send(packetId: 0x24, payload: MCVarInt.encode(success ? 0 : 2))
        let waiters = resourcePackCompletionWaiters
        resourcePackCompletionWaiters.removeAll()
        waiters.forEach { $0() }
    }

    // MARK: - Tự động đăng nhập + mở compass + chọn Diamond Axe

    private func attemptAutoLogin() {
        guard useLoginForSession else { return }
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
        guard useLoginForSession else { return }
        sendChatPacket("/login \(password)")
        appendLog(.info, "Đã tự gửi /login. Chờ 2 giây rồi mở la bàn...")
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
            let isCompass = item.itemId == 345 || item.plainName.lowercased().contains("compass") || item.plainName.lowercased().contains("la bàn") || item.plainName.lowercased().contains("chọn máy chủ")
            guard isCompass else {
                self.appendLog(.error, "Hotbar 5 hiện không nhận diện được Compass (itemId=\(item.itemId)); không gửi click nhầm item.")
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
        guard let (stateId, nextState) = decodeVarInt(from: body, offset: idx) else { return }
        idx = nextState
        guard let (count, nextCount) = decodeVarInt(from: body, offset: idx), count >= 0 else { return }
        idx = nextCount

        if windowId == 0 {
            hotbar = Array(repeating: nil, count: 9)
            playerInventory.removeAll()
            for slot in 0..<Int(count) {
                let hbIndex = hotbarIndex(forInventorySlot: slot) ?? -1
                guard let (item, next) = MCSlotParser.parse(body, from: idx, hotbarIndex: hbIndex) else { return }
                idx = next
                if hbIndex >= 0 { hotbar[hbIndex] = item }
                if let item, (5...44).contains(slot) {
                    playerInventory[slot] = item
                }
            }
            return
        }

        guard var window = currentWindow, window.windowId == windowId else { return }
        window.stateId = stateId
        window.slotCount = Int(count)
        window.items.removeAll()
        for slot in 0..<Int(count) {
            let start = idx
            guard let (item, next) = MCSlotParser.parse(body, from: idx, hotbarIndex: -1) else { return }
            let raw = body.subdata(in: (body.startIndex + start)..<(body.startIndex + next))
            idx = next
            if let item {
                window.items[slot] = MCOpenWindowItem(slot: slot, itemId: item.itemId, damage: item.damage,
                                                        nameSegments: item.nameSegments, loreSegments: item.loreSegments,
                                                        rawSlotBytes: raw)
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
        guard let (stateId, nextState) = decodeVarInt(from: body, offset: idx) else { return }
        idx = nextState
        guard let (slot16, nextSlot) = body.readI16BE(from: idx) else { return }
        idx = nextSlot
        let slot = Int(slot16)

        // Window -1 = cursor item, window 0 = player inventory, >0 = server GUI.
        if Int8(bitPattern: windowIdRaw) == -1 { return }
        if windowIdRaw == 0 {
            let hbIndex = hotbarIndex(forInventorySlot: slot) ?? -1
            guard let (item, _) = MCSlotParser.parse(body, from: idx, hotbarIndex: hbIndex) else { return }
            if hbIndex >= 0 { hotbar[hbIndex] = item }
            if (5...44).contains(slot) {
                if let item { playerInventory[slot] = item }
                else { playerInventory.removeValue(forKey: slot) }
            }
            return
        }

        guard var window = currentWindow, window.windowId == windowIdRaw else { return }
        window.stateId = stateId
        let start = idx
        guard let (item, next) = MCSlotParser.parse(body, from: idx, hotbarIndex: -1) else { return }
        let raw = body.subdata(in: (body.startIndex + start)..<(body.startIndex + next))
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
    /// Protocol 760: Held Item Change = 0x28, Use Item = 0x2A.
    func useHotbarItem(_ hotbarIndex: Int) {
        guard state == .connected, (0...8).contains(hotbarIndex) else { return }
        send(packetId: 0x28, payload: [UInt8(hotbarIndex >> 8), UInt8(hotbarIndex & 0xFF)]) // Held Item Change (Short)
        send(packetId: 0x2A, payload: MCVarInt.encode(0)) // Use Item, hand = 0 (main hand), protocol 760
        appendLog(.info, "Đã chuột phải vào ô hotbar \(hotbarIndex + 1).")
    }

    /// Tap trực tiếp item ở hotbar. Không hiện menu "..." cho các action
    /// gameplay thông thường. Compass là item mở menu server nên luôn RIGHT click.
    /// Các item khác hiện tại cũng dùng Use Item (RIGHT) để không vô tình làm
    /// thay đổi inventory; thao tác LEFT/RIGHT nâng cao vẫn nằm trong "...".
    func smartActivateHotbarItem(_ hotbarIndex: Int) {
        guard state == .connected, (0...8).contains(hotbarIndex), let item = hotbar[hotbarIndex] else { return }
        if item.itemId == 345 || item.plainName.lowercased().contains("compass") || item.plainName.lowercased().contains("la bàn") {
            useHotbarItem(hotbarIndex)
            return
        }
        useHotbarItem(hotbarIndex)
    }

    // MARK: - Gửi chat

    /// Protocol 760 / 1.19.2: Chat Message serverbound có timestamp/salt và phần
    /// acknowledgement. Server offline/proxy thường chấp nhận unsigned chat; gửi
    /// đầy đủ khung packet để không bị kick/timeout khi gõ lệnh.
    private func sendChatPacket(_ text: String) {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000.0)
        var payload: [UInt8] = []
        payload += mcEncodeString(text)
        payload += timestamp.mcBigEndianBytes
        payload += Int64.random(in: Int64.min...Int64.max).mcBigEndianBytes
        payload.append(0) // Has Signature = false
        payload += MCVarInt.encode(0) // Message Count
        payload += Array(repeating: UInt8(0), count: 3) // Acknowledged bitset: 20 bits
        send(packetId: 0x03, payload: payload)
    }

    func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard state == .connected, !trimmed.isEmpty else { return }

        if let password = loginPassword(fromCommand: trimmed) {
            MCCredentialStore.savePassword(password, host: host, port: port, username: username)
            appendLog(.info, useLoginForSession ? "Đã lưu mật khẩu — server này đang bật Auto /login." : "Đã lưu mật khẩu. Server này đang tắt Auto /login nên sẽ không tự gửi lệnh khi vào lại.")
            let generation = UUID()
            loginAutomationGeneration = generation
            let token = connectAttemptToken
            sendChatPacket(text)
            if self.useLoginForSession {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, self.connectAttemptToken == token, self.loginAutomationGeneration == generation, self.state == .connected else { return }
                    self.startCompassAutomation(token: token, generation: generation)
                }
            }
            return
        }

        sendChatPacket(text)
        // Không tự thêm vào log — server sẽ gửi lại chính tin nhắn này qua Player/System Chat (clientbound)
    }

    /// Nhận diện lệnh "/login <mật khẩu>" (không phân biệt hoa/thường) để lưu lại mật khẩu.
    private func loginPassword(fromCommand text: String) -> String? {
        let prefix = "/login "
        guard text.count > prefix.count, text.lowercased().hasPrefix(prefix) else { return nil }
        let password = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return password.isEmpty ? nil : password
    }

    // MARK: - Tiện ích

    /// Cho UI thêm thông báo nội bộ mà không cần expose appendLog riêng.
    func appendUserInfo(_ text: String) {
        appendLog(.info, text)
    }

    private func appendLog(_ kind: MCLogEntry.Kind, _ text: String, segments: [MCChatSegment]? = nil) {
        log.append(MCLogEntry(kind: kind, text: text, segments: segments))
        if log.count > 700 { log.removeFirst(log.count - 700) }
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
    /// URL của clickEvent=open_url được kế thừa xuống các đoạn con của component.
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
                // Đổi màu reset các định dạng legacy nhưng vẫn giữ clickEvent của component.
                style = MCChatStyle(colorHex: hex, linkURL: style.linkURL)
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

    // Minecraft JSON chat có thể gắn clickEvent.open_url trực tiếp lên component.
    // Giữ URL trong segment để UI mở bằng một lần chạm, không hiện menu "Chat click action".
    if let click = dict["clickEvent"] as? [String: Any],
       let action = click["action"] as? String,
       action == "open_url",
       let value = click["value"] as? String,
       let url = URL(string: value),
       let scheme = url.scheme?.lowercased(),
       scheme == "http" || scheme == "https" {
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

    func decode(_ compressed: Data) -> Data? {
        guard !compressed.isEmpty else { return nil }
        // Một số proxy Minecraft báo dataLength hơi lệch 1-2 byte. Không để sai
        // length làm decoder bỏ luôn TCP stream; cho phép buffer lớn hơn rồi lấy
        // đúng số byte thực sự giải nén được. Giới hạn 8 MiB để không thể phình RAM.
        let capacity = min(8 * 1024 * 1024, max(expectedSize, expectedSize * 4 + 1024))
        var result = Data(count: capacity)
        let size: Int = result.withUnsafeMutableBytes { dst in
            compressed.withUnsafeBytes { src in
                guard let dstPtr = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = src.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(dstPtr, capacity, srcPtr, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard size > 0 else { return nil }
        return Data(result.prefix(size))
    }

    // Chuẩn Minecraft là zlib/RFC1950. Một vài proxy cũ từng bọc thêm header;
    // thử cả hai dạng để tránh lỗi "packet nén không hợp lệ" làm mất phiên.
    if let inflated = decode(data) { return inflated }
    if data.count > 6 {
        let wrapped = data.dropFirst(2).dropLast(4)
        if let inflated = decode(Data(wrapped)) { return inflated }
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

private extension Int64 {
    var mcBigEndianBytes: [UInt8] {
        let bits = self.bigEndian
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
