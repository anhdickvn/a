import Foundation
import Security

/// Lưu mật khẩu gõ qua lệnh "/login <mật khẩu>" vào Keychain của hệ thống (được iOS mã hoá
/// và khoá theo app — an toàn hơn nhiều so với lưu ở UserDefaults dạng chữ thường).
/// Khoá theo host:port:username để mỗi server/tài khoản có mật khẩu riêng.
enum MCCredentialStore {
    private static let service = "ChatApp.MCLogin"

    private static func account(host: String, port: UInt16, username: String) -> String {
        "\(host):\(port)|\(username)"
    }

    static func savePassword(_ password: String, host: String, port: UInt16, username: String) {
        let acc = account(host: host, port: port, username: username)
        let data = Data(password.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc,
        ]
        SecItemDelete(query as CFDictionary) // ghi đè nếu đã có mật khẩu cũ

        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(newItem as CFDictionary, nil)
    }

    static func loadPassword(host: String, port: UInt16, username: String) -> String? {
        let acc = account(host: host, port: port, username: username)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(host: String, port: UInt16, username: String) {
        let acc = account(host: host, port: port, username: username)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Mật khẩu gắn theo tài khoản (nhập lúc "Thêm tài khoản", dùng chung cho mọi server)

    /// Khoá riêng theo username (không kèm host/port) — nhập 1 lần ở màn "Thêm tài khoản",
    /// vào server nào cũng tự /login bằng mật khẩu này nếu server đó chưa có mật khẩu riêng.
    private static func accountKey(username: String) -> String { "account|\(username)" }

    static func saveAccountPassword(_ password: String, username: String) {
        let acc = accountKey(username: username)
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc,
        ]
        SecItemDelete(query as CFDictionary)

        guard !password.isEmpty else { return } // password rỗng nghĩa là xoá, không lưu gì thêm

        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(newItem as CFDictionary, nil)
    }

    static func loadAccountPassword(username: String) -> String? {
        let acc = accountKey(username: username)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAccountPassword(username: String) {
        let acc = accountKey(username: username)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
