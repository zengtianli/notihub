import Foundation


enum OTP {
    static let keywords = "验证码|校验码|动态码|驗證碼|校驗碼|随机码|安全码|verification code|verify code|security code|one[- ]time|OTP|passcode"
    static let trap = "尾号|后四位|卡号|订单|单号|运单|金额|余额|客服电话|热线"

    private static let kwRegex = try! NSRegularExpression(
        pattern: "(\(keywords))|[^a-zA-Z]code[^a-zA-Z]", options: [.caseInsensitive])
    private static let trapRegex = try! NSRegularExpression(
        pattern: "(\(trap))[^0-9]{0,3}[0-9]{4,8}", options: [])
    private static let digitRegex = try! NSRegularExpression(
        pattern: "(^|[^0-9])([0-9]{4,8})([^0-9]|$)", options: [])

    static func isOTP(_ text: String) -> Bool {
        let r = NSRange(text.startIndex..., in: text)
        return kwRegex.firstMatch(in: text, range: r) != nil
    }

    static func extract(_ text: String) -> String? {
        let r = NSRange(text.startIndex..., in: text)
        let masked = trapRegex.stringByReplacingMatches(in: text, range: r, withTemplate: "$1")
        let mr = NSRange(masked.startIndex..., in: masked)
        guard let m = digitRegex.firstMatch(in: masked, range: mr),
              let range = Range(m.range(at: 2), in: masked) else { return nil }
        return String(masked[range])
    }

    static func find(in text: String) -> String? {
        isOTP(text) ? extract(text) : nil
    }
}


struct Config: Codable {
    var retentionDays: Int = 365

    var maxActionAgeSeconds: Int = 300
    var bark = Bark()
    var summary = SummaryCfg()
    var apple = AppleCfg()
    var ai = AICfg()
    var jobs = JobsCfg()
    var rules: [Rule] = Config.defaultRules

    var muteInViews: [String] = ["scripteditor2", "btmnotificationagent", "notificationcenterui"]

    struct Bark: Codable {
        var enabled: Bool = true
        var server: String = "https://api.day.app"
        var key: String? = nil
        var keyFile: String = "~/Apps/cli/qinglong/data/config/config.sh"
        var group: String = "notifhub"

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            enabled  = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            server   = try c.decodeIfPresent(String.self, forKey: .server) ?? "https://api.day.app"
            key      = try c.decodeIfPresent(String.self, forKey: .key)
            keyFile  = try c.decodeIfPresent(String.self, forKey: .keyFile)
                ?? "~/Apps/cli/qinglong/data/config/config.sh"
            group    = try c.decodeIfPresent(String.self, forKey: .group) ?? "notifhub"
        }
    }

    struct SummaryCfg: Codable {
        var enabled: Bool = true
        var minIntervalSeconds: Int = 10800
        var minNewEvents: Int = 5
        var maxChars: Int = 12000
        var extractAgenda: Bool = true
        var timeoutSeconds: Int = 180
        var python: String = ""
        var provider: String = ""

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            enabled            = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            minIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .minIntervalSeconds) ?? 10800
            minNewEvents       = try c.decodeIfPresent(Int.self, forKey: .minNewEvents) ?? 5
            maxChars           = try c.decodeIfPresent(Int.self, forKey: .maxChars) ?? 12000
            extractAgenda      = try c.decodeIfPresent(Bool.self, forKey: .extractAgenda) ?? true
            timeoutSeconds     = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 180
            python             = try c.decodeIfPresent(String.self, forKey: .python) ?? ""
            provider           = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        }
    }

    struct AppleCfg: Codable {
        var remindersList: String = ""
        var calendarName: String = ""
        var defaultEventMinutes: Int = 60
        var defaultDueHour: Int = 9

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            remindersList       = try c.decodeIfPresent(String.self, forKey: .remindersList) ?? ""
            calendarName        = try c.decodeIfPresent(String.self, forKey: .calendarName) ?? ""
            defaultEventMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultEventMinutes) ?? 60
            defaultDueHour      = try c.decodeIfPresent(Int.self, forKey: .defaultDueHour) ?? 9
        }
    }

    struct JobsCfg: Codable {
        var enabled: Bool = true
        var disabled: [String] = []
        var queueSeconds: Int = 60
        var syncSeconds: Int = 300
        var summarizeSeconds: Int = 3600

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            enabled          = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            disabled         = try c.decodeIfPresent([String].self, forKey: .disabled) ?? []
            queueSeconds     = try c.decodeIfPresent(Int.self, forKey: .queueSeconds) ?? 60
            syncSeconds      = try c.decodeIfPresent(Int.self, forKey: .syncSeconds) ?? 300
            summarizeSeconds = try c.decodeIfPresent(Int.self, forKey: .summarizeSeconds) ?? 3600
        }
    }

    struct AICfg: Codable {
        var enabled: Bool = true
        var idleMinutes: Int = 15
        var backfillDays: Int = 30
        var maxPromptChars: Int = 2000
        var privatePaths: [String] = AICfg.defaultPrivate
        static let defaultPrivate = ["~/Personal/legal", "~/Archives/ip-legal"]

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            enabled        = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            idleMinutes    = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? 15
            backfillDays   = try c.decodeIfPresent(Int.self, forKey: .backfillDays) ?? 30
            maxPromptChars = try c.decodeIfPresent(Int.self, forKey: .maxPromptChars) ?? 2000
            privatePaths   = try c.decodeIfPresent([String].self, forKey: .privatePaths) ?? AICfg.defaultPrivate
        }
    }

    struct Rule: Codable {
        var name: String
        var enabled: Bool = true
        var apps: [String] = []
        var keywords: [String] = []
        var regex: String? = nil
        var actions: [String] = ["clipboard"]
        var command: String? = nil
        var stop: Bool = false

        init(name: String, enabled: Bool = true, apps: [String] = [], keywords: [String] = [],
             regex: String? = nil, actions: [String] = ["clipboard"],
             command: String? = nil, stop: Bool = false) {
            self.name = name; self.enabled = enabled; self.apps = apps; self.keywords = keywords
            self.regex = regex; self.actions = actions; self.command = command; self.stop = stop
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            name     = try c.decode(String.self, forKey: .name)
            enabled  = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            apps     = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
            keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
            regex    = try c.decodeIfPresent(String.self, forKey: .regex)
            actions  = try c.decodeIfPresent([String].self, forKey: .actions) ?? ["clipboard"]
            command  = try c.decodeIfPresent(String.self, forKey: .command)
            stop     = try c.decodeIfPresent(Bool.self, forKey: .stop) ?? false
        }
    }

    static let defaultRules: [Rule] = [
        Rule(name: "otp", enabled: true, apps: [], keywords: [],
             regex: nil, actions: ["clipboard"], command: nil, stop: true)
    ]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 365
        maxActionAgeSeconds = try c.decodeIfPresent(Int.self, forKey: .maxActionAgeSeconds) ?? 300
        bark = try c.decodeIfPresent(Bark.self, forKey: .bark) ?? Bark()
        summary = try c.decodeIfPresent(SummaryCfg.self, forKey: .summary) ?? SummaryCfg()
        apple = try c.decodeIfPresent(AppleCfg.self, forKey: .apple) ?? AppleCfg()
        ai = try c.decodeIfPresent(AICfg.self, forKey: .ai) ?? AICfg()
        jobs = try c.decodeIfPresent(JobsCfg.self, forKey: .jobs) ?? JobsCfg()
        muteInViews = try c.decodeIfPresent([String].self, forKey: .muteInViews)
            ?? ["scripteditor2", "btmnotificationagent", "notificationcenterui"]
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? Config.defaultRules
    }

    init() {}

    static func load() -> Config {
        let url = Paths.configFile
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            var c = try JSONDecoder().decode(Config.self, from: data)
            if c.rules.isEmpty { c.rules = Config.defaultRules }
            return c
        } catch {
            Log.write("配置解析失败，回落默认值: \(error)")
            Log.err("⚠ \(url.path) 解析失败: \(error.localizedDescription)")
            return Config()
        }
    }

    func save() throws {
        let dir = Paths.configFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Paths.configFile)
    }

    static func initDefault(force: Bool) -> Int32 {
        let file = Paths.configFile
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) {
            guard force else {
                Log.err("已有配置 \(file.path)，拒绝覆盖（里面可能有你改过的规则和折叠设置）。确要重置加 --force（会先备份）。")
                return 1
            }
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.timeZone = displayTZ
            let backup = file.deletingLastPathComponent()
                .appendingPathComponent(file.lastPathComponent + ".bak-" + f.string(from: Date()))
            do { try fm.copyItem(at: file, to: backup) }
            catch { Log.err("备份旧配置失败，未覆盖：\(error.localizedDescription)"); return 1 }
            print("旧配置已备份: \(backup.path)")
        }
        do {
            try Config().save()
            print("已写默认配置: \(file.path)")
            return 0
        } catch { Log.err("写配置失败: \(error)"); return 1 }
    }

    func resolveBarkKey() -> String? {
        if let k = bark.key, !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["BARK_PUSH"], !k.isEmpty { return k }
        let path = bark.keyFile.expandingTilde
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let r = line.range(of: "BARK_PUSH=") else { continue }
            let v = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            if !v.isEmpty { return v }
        }
        return nil
    }
}


struct RuleHit {
    let rule: Config.Rule
    let code: String?
}

enum Engine {
    static func match(_ e: Event, config: Config) -> [RuleHit] {
        let haystack = "\(e.title) \(e.subtitle) \(e.body)"
        let canon = BundleMap.canonical(e.bundle)
        var hits: [RuleHit] = []

        for rule in config.rules where rule.enabled {
            if !rule.apps.isEmpty && !rule.apps.contains(canon) { continue }

            var code: String? = nil
            var matched = false

            if rule.name == "otp" {
                if let c = OTP.find(in: haystack) { matched = true; code = c }
            } else {
                if !rule.keywords.isEmpty {
                    matched = rule.keywords.contains { haystack.localizedCaseInsensitiveContains($0) }
                }
                if !matched, let pat = rule.regex, !pat.isEmpty,
                   let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                    matched = re.firstMatch(in: haystack,
                                            range: NSRange(haystack.startIndex..., in: haystack)) != nil
                }
                if rule.keywords.isEmpty && (rule.regex ?? "").isEmpty && !rule.apps.isEmpty {
                    matched = true
                }
            }

            if matched {
                hits.append(RuleHit(rule: rule, code: code))
                if rule.stop { break }
            }
        }
        return hits
    }
}


enum BarkOrigin {
    static func invalid(_ reason: String) -> NSError {
        NSError(domain: "BarkOrigin", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    static func text(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let result = value as? String else { throw invalid("Bark 来源文本字段必须为字符串") }
        guard !result.unicodeScalars.contains(where: { $0.value < 32 }) else {
            throw invalid("Bark 来源字段不能包含控制字符")
        }
        return result.isEmpty ? nil : result
    }

    static func session(_ raw: Any?) throws -> [String: Any] {
        let value: [String: Any]
        if raw == nil || raw is NSNull { value = [:] }
        else if let dict = raw as? [String: Any] { value = dict }
        else { throw invalid("Bark 会话来源必须为字典") }
        let sid = try text(value["sid"])
        var status = try text(value["status"]) ?? (sid == nil ? "unavailable" : "known")
        guard ["known", "not_created", "unavailable", "not_applicable"].contains(status) else {
            throw invalid("Bark 会话来源状态无效")
        }
        if sid != nil { status = "known" }
        else if status == "known" { status = "unavailable" }
        return ["provider": try text(value["provider"]) as Any? ?? NSNull(),
                "sid": sid as Any? ?? NSNull(), "status": status]
    }

    static func normalize(_ supplied: [String: Any]? = nil,
                          environment: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: Any] {
        let origin = supplied ?? [:]
        let entrypoint = try text(origin["entrypoint"]) ?? CommandLine.arguments.first ?? "Actions.barkReport"
        let pid = origin["pid"] ?? Int(ProcessInfo.processInfo.processIdentifier)
        guard let processID = pid as? Int, !(pid is Bool), processID > 0 else {
            throw invalid("Bark 来源 PID 必须为正整数")
        }
        func first(_ keys: [String]) throws -> String? {
            for key in keys { if let value = try text(environment[key]) { return value } }
            return nil
        }
        var owner: [String: Any] = [:]
        for (provider, keys) in [("codex", ["CODEX_THREAD_ID", "CODEX_SESSION_ID"]),
                                 ("claude", ["CLAUDE_SESSION_ID", "CLAUDE_CODE_SESSION_ID"])] {
            if let sid = try first(keys) { owner = ["provider": provider, "sid": sid, "status": "known"]; break }
        }
        return ["host": try text(origin["host"]) ?? ProcessInfo.processInfo.hostName,
                "component": try text(origin["component"]) ?? URL(fileURLWithPath: entrypoint).lastPathComponent,
                "entrypoint": entrypoint, "pid": processID,
                "job": try text(origin["job"]) ?? first(["BARK_JOB", "SYSTEMD_UNIT", "LAUNCH_JOB_LABEL"]) as Any? ?? NSNull(),
                "run_id": try text(origin["run_id"]) ?? first(["BARK_RUN_ID", "DOCKET_JOB_ID", "DOCKET_CHAT_ID", "INVOCATION_ID"]) ?? "pid:\(processID)",
                "owner_session": try session(origin["owner_session"] ?? owner),
                "model_session": try session(origin["model_session"])]
    }

    static func header(_ origin: [String: Any]) throws -> String {
        let normalized = try normalize(origin)
        func sessionText(_ key: String) -> String {
            let value = normalized[key] as! [String: Any]
            let rawProvider = value["provider"] as? String
            let provider = ["codex": "Codex", "claude": "Claude"][rawProvider ?? ""] ?? rawProvider ?? "引擎未取得"
            if let sid = value["sid"] as? String { return "\(provider) SID=\(sid)" }
            let status = ["not_created": "会话未创建", "unavailable": "SID未取得", "not_applicable": "不适用模型会话"][value["status"] as? String ?? ""]!
            return "\(provider) \(status)"
        }
        return "来源：主机=\(normalized["host"]!)；组件=\(normalized["component"]!)\n"
            + "发送入口：\(normalized["entrypoint"]!)\n"
            + "作业：\(normalized["job"] as? String ?? "名称未取得")；执行=\(normalized["run_id"]!)；PID=\(normalized["pid"]!)\n"
            + "发起会话：\(sessionText("owner_session"))\n"
            + "业务模型会话：\(sessionText("model_session"))\n\n"
    }

    static func rule(_ name: String, eventID: Int64, source: String) -> [String: Any] {
        ["component": "notifhub.collector", "entrypoint": "Actions.perform.bark",
         "job": "rule:\(name)", "run_id": "event:\(eventID):\(source)",
         "owner_session": ["status": "not_applicable"], "model_session": ["status": "not_applicable"]]
    }

    static func safe(_ origin: [String: Any], key: String? = nil) -> [String: Any] {
        origin.mapValues { value in
            if let text = value as? String { return BarkPayload.safe(text, key: key) }
            if let nested = value as? [String: Any] { return safe(nested, key: key) }
            return value
        }
    }
}

enum BarkPayload {
    static let byteBudget = 3584 // APNs 4096，留 512 给服务端信封

    static func safe(_ text: String, key: String? = nil) -> String {
        var result = text
        for (pattern, replacement) in [
            (#"(?im)(\b(?:cookie|jd_cookie)\b["']?\s*[:=]\s*["']?)([^"'\r\n]*)(["']?)"#, "$1[已隐藏凭证]$3"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/-]+"#, "Bearer [已隐藏凭证]"),
            (#"\b(?:sk-[A-Za-z0-9_-]{10,}|gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)"#, "[已隐藏凭证]"),
            (#"(?i)(\b(?:bark[_-]?key|device[_-]?key|api[_-]?key|access[_-]?token|refresh[_-]?token|password|passwd|client[_-]?secret|token|authorization|wskey|pt_key|pt_pin)\b["']?\s*[:=]\s*)(?:"[^"\n]*"|'[^'\n]*'|[^\s,;}&]+)"#, "$1[已隐藏凭证]")
        ] {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        if let key, !key.isEmpty { result = result.replacingOccurrences(of: key, with: "[已隐藏凭证]") }
        return result
    }

    static func encoded(_ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func byteCount(_ payload: [String: Any]) throws -> Int {
        var json = String(decoding: try encoded(payload), as: UTF8.self)
        for (character, escape) in [("<", #"\u003c"#), (">", #"\u003e"#), ("&", #"\u0026"#),
                                    ("\u{2028}", #"\u2028"#), ("\u{2029}", #"\u2029"#)] {
            json = json.replacingOccurrences(of: character, with: escape)
        }
        return json.utf8.count
    }

    static func parts(_ payload: [String: Any], origin: [String: Any]? = nil) throws -> [[String: Any]] {
        if let value = payload["origin"], !(value is [String: Any]) {
            throw BarkOrigin.invalid("Bark 来源必须为字典")
        }
        let source = BarkOrigin.safe(try BarkOrigin.normalize(origin ?? payload["origin"] as? [String: Any]),
                                     key: payload["device_key"] as? String)
        let header = try BarkOrigin.header(source)
        var original = payload
        original["isArchive"] = "1"
        original["origin"] = source
        let body = original["body"] as? String ?? ""
        original["body"] = header + body
        if try byteCount(original) <= byteBudget { return [original] }
        let title = original["title"] as? String ?? ""
        let characters = Array(body)
        func part(_ text: String, _ index: Int, _ total: Int) -> [String: Any] {
            var value = original
            value["title"] = "\(title) [\(index)/\(total)]"
            value["body"] = header + text
            if index > 1 { value["level"] = "passive"; value["sound"] = "" }
            return value
        }
        var total = 2
        while true {
            var chunks: [String] = [], offset = 0
            while offset < characters.count {
                let index = chunks.count + 1
                guard try byteCount(part("", index, total)) < byteBudget else {
                    throw NSError(domain: "BarkPayload", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bark 元信息超过字节预算；完整正文留在本机"])
                }
                var low = 0, high = characters.count - offset
                while low < high {
                    let middle = (low + high + 1) / 2
                    if try byteCount(part(String(characters[offset..<(offset + middle)]), index, total)) <= byteBudget { low = middle }
                    else { high = middle - 1 }
                }
                guard low > 0 else { throw NSError(domain: "BarkPayload", code: 2) }
                chunks.append(String(characters[offset..<(offset + low)])); offset += low
            }
            guard !chunks.isEmpty else { throw NSError(domain: "BarkPayload", code: 3) }
            if chunks.count == total { return chunks.enumerated().map { part($0.element, $0.offset + 1, total) } }
            total = chunks.count
        }
    }
}

struct BarkReceipt {
    var title: String
    var body: String
    var origin: [String: Any] = [:]
    var parts: [[String: Any]] = []
    var error: String? = nil
    var ok: Bool { error == nil && !parts.isEmpty && parts.allSatisfy { $0["ok"] as? Bool == true } }
    var detail: String {
        let data = try? BarkPayload.encoded(["title": title, "body": body, "origin": origin, "parts": parts,
                                            "error": error ?? "", "isArchive": "1", "ok": ok])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "Bark 回执无法编码"
    }
}


enum Actions {
    @discardableResult
    static func perform(_ hit: RuleHit, event: Event, config: Config,
                        store: Store, eventID: Int64) -> [String] {
        var done: [String] = []
        for action in hit.rule.actions {
            switch action {
            case "clipboard":
                guard let code = hit.code ?? OTP.find(in: "\(event.title) \(event.body)") else { continue }
                _ = run("/usr/bin/pbcopy", [], stdin: code)
                store.logAction(eventID: eventID, rule: hit.rule.name, action: "clipboard",
                                detail: code, ok: true)
                done.append("clipboard=\(code)")

            case "notify":
                let title = hit.code.map { "验证码已复制 \($0)" } ?? "\(event.app) · \(event.title)"
                let body = hit.code == nil ? event.body.truncated(80) : event.title.truncated(60)
                localNotify(title: title, body: body, store: store)
                store.logAction(eventID: eventID, rule: hit.rule.name, action: "notify",
                                detail: title, ok: true)
                done.append("notify")

            case "bark":
                let receipt = barkReport(title: "\(event.app) · \(event.title)",
                                         body: (hit.code.map { "验证码 \($0)\n\(event.body)" } ?? event.body), config: config,
                                         origin: BarkOrigin.rule(hit.rule.name, eventID: eventID, source: event.source))
                store.logAction(eventID: eventID, rule: hit.rule.name, action: "bark",
                                detail: receipt.detail, ok: receipt.ok)
                done.append("bark=\(receipt.ok)")

            case "exec":
                guard let cmd = hit.rule.command, !cmd.isEmpty else { continue }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", cmd]
                p.standardInput = FileHandle.nullDevice
                var env = ProcessInfo.processInfo.environment
                env["NOTIF_TITLE"] = event.title
                env["NOTIF_BODY"] = event.body
                env["NOTIF_APP"] = event.app
                env["NOTIF_BUNDLE"] = event.bundle
                env["NOTIF_CODE"] = hit.code ?? ""
                p.environment = env
                let ok = (try? p.run()) != nil
                store.logAction(eventID: eventID, rule: hit.rule.name, action: "exec",
                                detail: cmd.truncated(120), ok: ok)
                done.append("exec")

            default:
                Log.write("未知动作: \(action)（规则 \(hit.rule.name)）")
            }
        }
        return done
    }

    static func selfHash(title: String, body: String) -> String {
        "\(title)|\(body)".sha256()
    }

    static func localNotify(title: String, body: String, store: Store? = nil) {
        store?.markSelfEmitted(selfHash(title: title, body: body))
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        _ = run("/usr/bin/osascript",
                ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
    }

    @discardableResult
    static func bark(title: String, body: String, config: Config) -> Bool {
        barkReport(title: title, body: body, config: config).ok
    }

    static func barkReport(title: String, body: String, config: Config, origin: [String: Any]? = nil) -> BarkReceipt {
        let key = config.resolveBarkKey()
        var receipt = BarkReceipt(title: BarkPayload.safe(title, key: key), body: BarkPayload.safe(body, key: key))
        do {
            let supplied = origin ?? ["component": "notifhub.collector", "entrypoint": "Actions.barkReport",
                                      "owner_session": ["status": "not_applicable"],
                                      "model_session": ["status": "not_applicable"]]
            receipt.origin = BarkOrigin.safe(try BarkOrigin.normalize(supplied), key: key)
        } catch { receipt.error = "Bark 来源字段无效；正文未发送"; return receipt }
        guard config.bark.enabled, let key else { receipt.error = "Bark 未启用或未配置"; return receipt }
        guard let url = URL(string: config.bark.server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/push") else {
            receipt.error = "Bark 服务地址无效"; return receipt
        }
        let payloads: [[String: Any]]
        do {
            payloads = try BarkPayload.parts(["title": receipt.title, "body": receipt.body, "group": config.bark.group, "device_key": key], origin: receipt.origin)
        } catch { receipt.error = "Bark 元信息无法安全分段；完整正文已保留"; return receipt }
        for (offset, payload) in payloads.enumerated() {
            let index = offset + 1
            if receipt.error != nil {
                receipt.parts.append(["part": index, "total": payloads.count, "ok": false, "reason": "前一段失败，未继续发送"])
                continue
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"; req.timeoutInterval = 8
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? BarkPayload.encoded(payload)
            var partOK = false, reason = "Bark 请求超时"
            let sem = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: req) { data, resp, error in
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                partOK = error == nil && status == 200 && (reply?["code"] as? Int) == 200
                reason = partOK ? "" : error != nil ? "Bark 网络请求失败" : "Bark 未确认接收（HTTP \(status)）"
                sem.signal()
            }
            task.resume()
            if sem.wait(timeout: .now() + 10) == .timedOut { task.cancel(); partOK = false }
            if !partOK { receipt.error = reason }
            receipt.parts.append(["part": index, "total": payloads.count, "ok": partOK, "reason": reason,
                                  "payload_bytes": (try? BarkPayload.byteCount(payload)) ?? 0])
        }
        return receipt
    }
}
