import Foundation
import Security

enum DigestVault {
    private static let service = "cyou.tianli.daydeck.watch-digest"
    private static let account = "latest"

    struct Saved: Codable {
        let digest: WatchDigest
        let receivedAt: Date
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> Saved? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ saved: Saved) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = baseQuery
            add.merge(attrs) { a, _ in a }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
