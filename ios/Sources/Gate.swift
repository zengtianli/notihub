import Foundation
import Security


enum Gate {
    static let prefix = "/_gate"
    static let loginURL = URL(string: API.shared.base + "\(prefix)/api/login")!

    static func blocked(_ resp: URLResponse?) -> Bool {
        (resp?.url?.path ?? "").hasPrefix(prefix + "/")
    }


    private static let service = "cyou.tianli.daydeck.gate"
    private static let account = "password"

    static var hasPassword: Bool { password != nil }

    static var password: String? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func savePassword(_ pw: String) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let attrs: [String: Any] = [
            kSecValueData as String: Data(pw.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add.merge(attrs) { a, _ in a }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func forgetPassword() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    static func seedFromLaunchArg(session: URLSession) async {}


    struct Failure: Error { let message: String }

    static func login(password pw: String, session: URLSession) async throws {
        #if DEBUG
        guard !DemoData.enabled else { throw Failure(message: "演示模式不会连接云端。") }
        #endif
        var req = URLRequest(url: loginURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "password", value: pw)]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let said = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if code == 200, said?["ok"] as? Bool == true { return }
        throw Failure(message: (said?["error"] as? String) ?? "登录失败（HTTP \(code)）")
    }
}
