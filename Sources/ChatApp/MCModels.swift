import Foundation

// MARK: - Tài khoản (Account) — 1 username offline có thể dùng cho nhiều server

struct MCAccount: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var username: String   // username offline (server offline/cracked không cần mật khẩu)

    var initials: String {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

final class MCAccountStore: ObservableObject {
    @Published var accounts: [MCAccount] {
        didSet { save() }
    }
    private let key = "mc_accounts"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MCAccount].self, from: data) {
            self.accounts = decoded
        } else {
            self.accounts = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func account(for id: UUID?) -> MCAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }
}

// MARK: - Hồ sơ 1 server Minecraft đã lưu

struct MCServerProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String            // tên gợi nhớ, vd "Server nhà"
    var host: String            // vd: play.example.com
    var port: UInt16 = 25565
    var accountId: UUID?        // tham chiếu tới MCAccount đã lưu trong MCAccountStore
    /// Bật: vào server xong tự gửi "/login <mật khẩu>", chờ rồi tự mở la bàn + chọn item
    /// (dùng lại đúng automation có sẵn trong MCClient). Tắt: vào server bình thường,
    /// không tự làm gì cả — người dùng tự gõ lệnh. Mặc định bật để giữ hành vi cũ.
    var autoLogin: Bool = true

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, accountId, autoLogin
    }

    init(id: UUID = UUID(), name: String, host: String, port: UInt16 = 25565, accountId: UUID? = nil, autoLogin: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.accountId = accountId
        self.autoLogin = autoLogin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 25565
        accountId = try c.decodeIfPresent(UUID.self, forKey: .accountId)
        // Hồ sơ server lưu từ bản cũ chưa có field này -> mặc định true (giữ hành vi cũ).
        autoLogin = try c.decodeIfPresent(Bool.self, forKey: .autoLogin) ?? true
    }
}

final class MCProfileStore: ObservableObject {
    @Published var profiles: [MCServerProfile] {
        didSet { save() }
    }
    private let key = "mc_server_profiles"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MCServerProfile].self, from: data) {
            self.profiles = decoded
        } else {
            self.profiles = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func ensureDefaultServer() {
        let exists = profiles.contains {
            $0.host.caseInsensitiveCompare("proxy.toichoi.com") == .orderedSame && $0.port == 54321
        }
        guard !exists else { return }
        profiles.insert(MCServerProfile(name: "Tôi Chơi NetWork", host: "proxy.toichoi.com", port: 54321, accountId: nil), at: 0)
    }
}

// MARK: - 1 dòng trong log chat / hệ thống

struct MCLogEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case chat          // tin nhắn chat thường
        case system        // thông báo hệ thống (join/leave, server broadcast...)
        case info          // thông tin nội bộ app (đang kết nối, đã kết nối...)
        case error         // lỗi / bị kick
    }
    var id: UUID = UUID()
    var kind: Kind
    var text: String                       // bản plain-text (không mã màu) — dùng cho log info/error
    var segments: [MCChatSegment]? = nil   // có màu — dùng cho chat/system, nil thì hiện `text` bình thường
    var timestamp: Date = Date()
}

// MARK: - 1 đoạn text có màu/định dạng riêng (từ mã màu § kiểu cũ hoặc field "color" trong JSON chat)

struct MCChatSegment: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String
    var colorHex: String?   // dạng "#RRGGBB", nil = màu mặc định
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
}

// MARK: - GUI menu server gửi (mở khi chuột phải la bàn/compass, vd "Chọn máy chủ")

/// 1 item trong 1 GUI/menu do server mở (khác với hotbar của người chơi).
struct MCOpenWindowItem: Identifiable {
    var id: Int { slot }
    var slot: Int
    var itemId: Int16
    var damage: Int16 = 0
    var nameSegments: [MCChatSegment]?
    var loreSegments: [[MCChatSegment]] = []
    /// Bytes gốc y nguyên từ server (dùng để gửi lại đúng dữ liệu khi click chọn item này).
    var rawSlotBytes: Data

    var plainName: String {
        nameSegments?.map(\.text).joined() ?? "Item #\(itemId)"
    }
}

/// 1 cửa sổ/menu server đang mở, vd menu chọn server, menu shop... (windowId != 0).
struct MCOpenWindow {
    var windowId: UInt8
    var title: String
    var slotCount: Int
    var items: [Int: MCOpenWindowItem] = [:]
}


// MARK: - Trạng thái kết nối

enum MCConnectionState: Equatable {
    case disconnected
    case connecting
    case loggingIn
    case connected
    case failed(String)
}
