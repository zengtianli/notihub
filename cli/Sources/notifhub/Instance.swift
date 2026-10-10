import Foundation

struct Instance: Codable {
    let id: String
    let siteURL: String
    let server: String

    var uploadHost: String { "notifhub-\(id)@\(server)" }
    var webRoot: String { "/var/www/notifhub/\(id)" }
    var dataDir: URL { Paths.home.appendingPathComponent(".local/share/notifhub/instances/\(id)") }
    var labelPrefix: String { "com.notifhub.\(id)" }

    static var configURL: URL {
        let path = ProcessInfo.processInfo.environment["NOTIFHUB_INSTANCE_CONFIG"]
            ?? Paths.home.appendingPathComponent(".config/notifhub/instance.json").path
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func read(_ url: URL) throws -> Instance {
        let value = try JSONDecoder().decode(Instance.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    func validate() throws {
        func matches(_ text: String, _ pattern: String) -> Bool {
            text.range(of: pattern, options: .regularExpression) != nil
        }
        guard matches(id, "^[a-z][a-z0-9-]{0,23}$"), id != "personal",
              matches(server, "^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$"),
              let url = URLComponents(string: siteURL), url.scheme == "https",
              let host = url.host, matches(host, "^[a-zA-Z0-9][a-zA-Z0-9.-]+$"),
              host != "day.example.invalid", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw NSError(domain: "Notifhub.Instance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "实例配置无效：需要独立 id、HTTPS 域名和服务器；不能使用个人 day.example.invalid 或 shell 字符。"])
        }
    }

    static let current: Instance? = {
        let url = configURL
        let explicit = ProcessInfo.processInfo.environment["NOTIFHUB_INSTANCE_CONFIG"] != nil
        guard explicit || FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try read(url) }
        catch { fputs("实例配置读取失败，拒绝回落个人实例：\(error)\n", stderr); exit(2) }
    }()

    static var personalFeatures: Bool { current == nil }

    static func doctor() -> Int32 {
        guard let profile = current else { return 2 }
        print("实例 \(profile.id) · \(profile.siteURL)\n数据库：\(Paths.db.path)\n上传：\(profile.uploadHost)（rrsync 独立根）")
        var failed = 0
        for source in Sources.all() {
            let (ok, detail) = source.health()
            print("\(ok ? "✅" : "❌") \(source.name)：\(detail)")
            if !ok { failed += 1 }
        }
        let daemonOn = Jobs.launchdLoaded(Installer.label)
        print("\(daemonOn ? "✅" : "❌") \(Installer.label)")
        if !daemonOn { failed += 1 }
        let sync = Jobs.readReceipt(Jobs.receiptURL)?.tasks.first { $0.name == "sync" }?.state
        let syncStatus = sync.map { Jobs.status($0, now: Date()) } ?? "没有回执"
        let syncOK = sync != nil && !Jobs.isBad(syncStatus) && syncStatus != "disabled"
        print("\(syncOK ? "✅" : "❌") 云同步任务 \(syncStatus)\(sync?.lastError.map { "：\($0)" } ?? "")")
        if !syncOK { failed += 1 }
        let (remoteRC, output) = run("/usr/bin/rsync", ["--list-only", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10", "\(profile.uploadHost):./"], stderrToo: true, timeout: 30)
        if remoteRC != 0 { failed += 1; print("❌ 上传账户不可用：\(output)") }
        let (webRC, code) = run("/usr/bin/curl", ["-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "15", profile.siteURL], timeout: 20)
        let protected = webRC == 0 && code == "401"
        if !protected { failed += 1 }
        print("\(protected ? "✅" : "❌") 独立登录门：匿名 HTTP \(code)")
        print("个人队列 / handoff / 总部 AI 通路未接入。此检查不证明跨账号认证隔离或真实新通知采集。")
        return failed == 0 ? 0 : 1
    }

    static func command(_ args: [String]) -> Int32 {
        do {
            if args.first == "check", args.count == 2 {
                let value = try read(URL(fileURLWithPath: args[1]))
                let data = try JSONEncoder().encode(value)
                print(String(decoding: data, as: UTF8.self))
            } else if args.first == "activate", args.count == 2 {
                let source = URL(fileURLWithPath: args[1]).standardizedFileURL
                let value = try read(source)
                let target = Paths.home.appendingPathComponent(".config/notifhub/instance.json")
                guard !FileManager.default.fileExists(atPath: target.path) else {
                    throw NSError(domain: "Notifhub.Instance", code: 3, userInfo: [NSLocalizedDescriptionKey: "已有实例配置；拒绝覆盖，请先核对当前用户和配置。"])
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(value).write(to: target, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                print("已选定实例 \(value.id)。请在该用户自己的 Mac/系统账户安装 Notihub.app 后运行 notihub install（会建 ~/.local/bin/notifhub-\(value.id) 软链，指向 App 内采集器）。")
            } else if args.first == "show" {
                let value: [String: Any] = [
                    "ok": true,
                    "id": current?.id ?? "personal", "database": Paths.db.path,
                    "siteURL": Publish.siteURL, "uploadHost": Publish.host,
                    "webRoot": current?.webRoot ?? Publish.remoteDir,
                    "daemonLabel": Installer.label,
                    "webActions": personalFeatures ? "personal" : "disabled",
                ]
                print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            } else {
                print("notihub instance show | check <profile.json> | activate <profile.json>")
                return 2
            }
            return 0
        } catch { fputs("\(error)\n", stderr); return 2 }
    }
}
