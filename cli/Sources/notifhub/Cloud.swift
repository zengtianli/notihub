import Foundation


struct CloudConnection: Decodable {
    let id: String
    let url: URL
    let token: String

    static var configURL: URL? {
        let env = ProcessInfo.processInfo.environment
        if let s = env["NOTIHUB_CLOUD_CONFIG"] { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        if env["NOTIFHUB_DATA_DIR"] != nil { return nil }
        let id = Instance.current?.id ?? "personal"
        return Paths.home.appendingPathComponent(".config/notifhub/cloud-\(id).json")
    }

    static var expectedURL: URL { URL(string: Publish.siteURL)! }

    static func load() throws -> Self {
        let id = Instance.current?.id ?? "personal"
        guard let file = configURL else {
            throw CloudFailure.notConfigured("数据目录已被 NOTIFHUB_DATA_DIR 改到隔离位置，不连接云端；确需连接请显式设置 NOTIHUB_CLOUD_CONFIG。")
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CloudFailure.notConfigured("尚未连接云端。请先安装此实例的云端同步配置。")
        }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file)) }
        catch { throw CloudFailure.notConfigured("云端配置读不出来：\(file.path)") }
        try value.validate(expectedID: id, expectedURL: expectedURL)
        return value
    }

    func validate(expectedID: String, expectedURL: URL) throws {
        guard id == expectedID, url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil, url.path.isEmpty || url.path == "/",
              url.host == expectedURL.host, token.count >= 32,
              !token.contains(where: { $0.isWhitespace }) else {
            throw CloudFailure.notConfigured("云端配置与当前实例不一致，请检查域名和凭据。")
        }
    }
}

struct CloudFailure: LocalizedError {
    enum Kind { case notConfigured, http, network, format, invalid }
    let message: String
    var kind: Kind = .network
    var status: Int? = nil
    init(_ message: String) { self.message = message }
    init(_ message: String, kind: Kind, status: Int? = nil) {
        self.message = message; self.kind = kind; self.status = status
    }
    static func notConfigured(_ m: String) -> Self { Self(m, kind: .notConfigured) }
    static func invalid(_ m: String) -> Self { Self(m, kind: .invalid) }
    var errorDescription: String? { message }
}

final class CloudRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct CloudClient {
    let connection: CloudConnection
    let session: URLSession

    init(connection: CloudConnection, session: URLSession? = nil) {
        self.connection = connection
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 25
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config, delegate: CloudRedirectGuard(), delegateQueue: nil)
        }
    }

    func raw(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: connection.url.appendingPathComponent("native/api/" + path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "X-Notifhub-Request")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw CloudFailure("云端连不上：\(error.localizedDescription)", kind: .network) }
        guard let http = response as? HTTPURLResponse else { throw CloudFailure("云端没有返回有效响应。", kind: .network) }
        guard (200...299).contains(http.statusCode) else {
            let code = http.statusCode
            if code == 401 { throw CloudFailure("云端凭据无效，请检查当前实例的连接配置。", kind: .http, status: code) }
            if (300...399).contains(code) { throw CloudFailure("云端原生接口尚未就绪，连接被重定向。", kind: .http, status: code) }
            throw CloudFailure("云端请求失败（HTTP \(code)），请稍后重试。", kind: .http, status: code)
        }
        return data
    }

    func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let data = try await raw(path, method: method, body: body)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CloudFailure("云端数据格式不兼容，请刷新或更新应用。", kind: .format) }
    }


    static let statuses: Set<String> = ["open", "done", "dropped"]

    func setStatus(id: Int64, status: String) async throws -> CloudStatus {
        guard Self.statuses.contains(status) else { throw CloudFailure.invalid("状态只能是 open / done / dropped") }
        let body = try JSONSerialization.data(withJSONObject: ["status": status])
        let receipt: CloudStatus = try await request("agenda/\(id)", method: "PATCH", body: body)
        guard receipt.status == status, receipt.id == nil || receipt.id == id else {
            throw CloudFailure("云端回执与请求不符（\(receipt.id.map(String.init) ?? "?")/\(receipt.status)）", kind: .format)
        }
        return receipt
    }

    func saveNote(_ input: CloudNoteInput) async throws -> CloudNote {
        try input.validate()
        return try await request("notes", method: "POST", body: JSONEncoder().encode(input))
    }
}

struct CloudDayIndex: Decodable, Identifiable {
    var id: String { date }
    let date: String
    let total: Int
    let headline: String?
    let agendaOpen: Int
}
struct CloudIndex: Decodable {
    let days: [CloudDayIndex]
    let lastSync: Double
    let timezone: String

    func initialDate(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timezone) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        return days.first(where: { $0.date <= today })?.date ?? days.first?.date ?? ""
    }
}
struct CloudSummary: Decodable { let headline: String; let text: String }
struct CloudItem: Decodable {
    let ts: Double
    let app: String
    let who: String
    let lines: [String]
    let redacted: Bool
}
struct CloudAgenda: Decodable, Identifiable {
    let id: Int64
    let title: String
    let status: String
    let dueTS: Double?
    let note: String?
}
struct CloudNote: Decodable, Identifiable { let id: Int64; let text: String; let ts: Double }
struct CloudDay: Decodable {
    let date: String
    let total: Int
    let items: [CloudItem]
    let summary: CloudSummary?
    let agenda: [CloudAgenda]
    let cloudNotes: [CloudNote]
}
struct CloudOpen: Decodable { let items: [CloudAgenda] }
struct CloudStatus: Decodable { var id: Int64? = nil; let status: String }
struct CloudNoteInput: Encodable {
    let text: String; let date: String; let idempotencyKey: String

    func validate() throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, text.count <= 20000 else { throw CloudFailure.invalid("随手记内容为空或超过 20000 字") }
        guard Recap.validDate(date) else { throw CloudFailure.invalid("日期无效：\(date)（要 YYYY-MM-DD）") }
        guard (8...100).contains(idempotencyKey.count) else { throw CloudFailure.invalid("幂等键长度要 8–100") }
    }
}
