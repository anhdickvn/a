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
        didSet {
            save()
            // Nếu account đang chọn bị xoá (hoặc chưa từng chọn), tự rơi về account đầu tiên
            // để luôn có 1 "tài khoản đang dùng" — vào server nào cũng dùng đúng account này.
            if selectedAccountId == nil || !accounts.contains(where: { $0.id == selectedAccountId }) {
                selectedAccountId = accounts.first?.id
            }
        }
    }
    /// Account đang được chọn ở khung carousel trên đầu màn hình danh sách server.
    /// Đây là account DUY NHẤT dùng để vào MỌI server — không còn chọn riêng theo từng server nữa.
    @Published var selectedAccountId: UUID? {
        didSet { saveSelected() }
    }
    private let key = "mc_accounts"
    private let selectedKey = "mc_selected_account_id"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([MCAccount].self, from: data) {
            self.accounts = decoded
        } else {
            self.accounts = []
        }
        if let idString = UserDefaults.standard.string(forKey: selectedKey), let uuid = UUID(uuidString: idString),
           self.accounts.contains(where: { $0.id == uuid }) {
            self.selectedAccountId = uuid
        } else {
            self.selectedAccountId = self.accounts.first?.id
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func saveSelected() {
        UserDefaults.standard.set(selectedAccountId?.uuidString, forKey: selectedKey)
    }

    func account(for id: UUID?) -> MCAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    /// Account sẽ dùng để đăng nhập khi vào bất kỳ server nào — luôn là account
    /// đang được chọn ở carousel trên đầu màn hình (mặc định = account đầu tiên).
    var currentAccount: MCAccount? {
        account(for: selectedAccountId) ?? accounts.first
    }
}

// MARK: - Danh sách version Minecraft hỗ trợ chọn thủ công (thay vì hardcode 1 protocol)

struct MCVersionOption: Identifiable, Hashable {
    var id: Int32 { protocolVersion }
    let label: String
    let protocolVersion: Int32

    static let all: [MCVersionOption] = [
        .init(label: "1.7.10", protocolVersion: 5),
        .init(label: "1.8.9", protocolVersion: 47),
        .init(label: "1.9.4", protocolVersion: 110),
        .init(label: "1.10.2", protocolVersion: 210),
        .init(label: "1.11.2", protocolVersion: 316),
        .init(label: "1.12.2", protocolVersion: 340),
        .init(label: "1.13.2", protocolVersion: 404),
        .init(label: "1.14.4", protocolVersion: 498),
        .init(label: "1.15.2", protocolVersion: 578),
        .init(label: "1.16.5", protocolVersion: 754),
        .init(label: "1.17.1", protocolVersion: 756),
        .init(label: "1.18.2", protocolVersion: 758),
        .init(label: "1.19.2", protocolVersion: 760),
        .init(label: "1.19.4", protocolVersion: 762),
        .init(label: "1.20.1", protocolVersion: 763),
        .init(label: "1.20.4", protocolVersion: 765),
        .init(label: "1.21.1", protocolVersion: 767),
    ]

    static func label(for protocolVersion: Int32) -> String {
        all.first { $0.protocolVersion == protocolVersion }?.label ?? "Protocol \(protocolVersion)"
    }
}

// MARK: - Hồ sơ 1 server Minecraft đã lưu

struct MCServerProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String            // tên gợi nhớ, vd "Server nhà"
    var host: String            // vd: play.example.com
    var port: UInt16 = 25565
    /// Nếu bật, sau khi Login Success app sẽ tự gửi /login <mật khẩu> và chỉ khi đó
    /// mới chạy flow chuột phải la bàn / mở menu server. Tắt = tuyệt đối không tự gửi login.
    var useLogin: Bool = false
    /// Protocol version dùng khi handshake login. Chọn đúng version thật của server
    /// (vd 1.12.2 = 340) thay vì để app tự đoán/hardcode, tránh bị kick "Outdated client".
    var protocolVersion: Int32 = 760

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, useLogin, protocolVersion
    }

    init(id: UUID = UUID(), name: String, host: String, port: UInt16 = 25565,
         useLogin: Bool = false, protocolVersion: Int32 = 760) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useLogin = useLogin
        self.protocolVersion = protocolVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 25565
        useLogin = try c.decodeIfPresent(Bool.self, forKey: .useLogin) ?? false
        protocolVersion = try c.decodeIfPresent(Int32.self, forKey: .protocolVersion) ?? 760
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
        profiles.insert(MCServerProfile(name: "Tôi Chơi NetWork", host: "proxy.toichoi.com", port: 54321,
                                         protocolVersion: 47), at: 0)
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
    /// URL mở trực tiếp khi người chơi chạm vào đoạn chat (Minecraft clickEvent=open_url).
    var linkURL: String? = nil
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
    /// State ID của container trong protocol 760, bắt buộc khi gửi Click Window.
    var stateId: Int32 = 0
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
