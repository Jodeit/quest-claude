import Foundation
import Security

/// Where scans go: the roomscan server's address (UserDefaults) and its bearer token (Keychain).
final class ServerSettings: ObservableObject {
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    @Published var token: String {
        didSet { Keychain.set(token, for: "token") }
    }
    /// Send the room to the server every couple of seconds while scanning, not just at the end.
    @Published var liveUpdates: Bool {
        didSet { UserDefaults.standard.set(liveUpdates, forKey: "liveUpdates") }
    }

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        token = Keychain.get("token") ?? ""
        liveUpdates = UserDefaults.standard.object(forKey: "liveUpdates") as? Bool ?? true
    }

    var client: ServerClient? { ServerClient(urlString: serverURL, token: token) }
}

enum Keychain {
    private static let service = "dev.qlaude.roomscan"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
