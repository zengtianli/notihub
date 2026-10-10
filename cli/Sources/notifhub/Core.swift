import Foundation
import CryptoKit


enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var dataDir: URL {
        if let s = ProcessInfo.processInfo.environment["NOTIFHUB_DATA_DIR"] {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return Instance.current?.dataDir ?? home.appendingPathComponent(".local/share/notifhub")
    }
    static var db: URL { dataDir.appendingPathComponent("notif.db") }
    static var log: URL { dataDir.appendingPathComponent("notifhub.log") }

    static var configFile: URL {
        if let s = ProcessInfo.processInfo.environment["NOTIFHUB_CONFIG"] {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return Instance.current.map { $0.dataDir.appendingPathComponent("rules.json") }
            ?? home.appendingPathComponent(".config/notifhub/rules.json")
    }

    static var usernotedDB: URL {
        home.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }
    static var usernotedWAL: URL { usernotedDB.deletingLastPathComponent().appendingPathComponent("db-wal") }
    static var remoteRoot: URL {
        home.appendingPathComponent("Library/Group Containers/group.com.apple.UserNotifications/Library/UserNotifications/Remote/default")
    }
    static var chatDB: URL { home.appendingPathComponent("Library/Messages/chat.db") }
    static var chatWAL: URL { home.appendingPathComponent("Library/Messages/chat.db-wal") }


    static let defaultAppBinary = URL(fileURLWithPath: "/Applications/Notihub.app/Contents/Resources/bin/notihub")

    static var selfExecutable: URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: Int(size) + 1)
            if _NSGetExecutablePath(&buf, &size) == 0 {
                return URL(fileURLWithPath: String(cString: buf)).standardizedFileURL.resolvingSymlinksInPath()
            }
        }
        return Bundle.main.executableURL?.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func locateAppBinary(selfPath: URL?, exists: (String) -> Bool) -> URL? {
        if let s = selfPath, s.deletingLastPathComponent().path.hasSuffix(".app/Contents/Resources/bin") {
            return s
        }
        return exists(defaultAppBinary.path) ? defaultAppBinary : nil
    }

    static var appBinary: URL? {
        locateAppBinary(selfPath: selfExecutable) { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func bundle(ofAppBinary bin: URL) -> URL {
        bin.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    static var appBundle: URL? { appBinary.map(bundle(ofAppBinary:)) }

    static var binDir: URL { home.appendingPathComponent(".local/bin") }

    static var installedBinary: URL {
        appBinary ?? binDir.appendingPathComponent("notifhub" + (Instance.current.map { "-\($0.id)" } ?? ""))
    }
    static var launchAgentsDir: URL { home.appendingPathComponent("Library/LaunchAgents") }
    static var launchAgent: URL { home.appendingPathComponent("Library/LaunchAgents/\(Installer.label).plist") }
    static var publishAgent: URL { home.appendingPathComponent("Library/LaunchAgents/\(Installer.publishLabel).plist") }
    static var queueAgent: URL { home.appendingPathComponent("Library/LaunchAgents/\(Installer.queueLabel).plist") }

    static func ensureDataDir() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDir.path)
    }
}


let appleEpoch: Double = 978_307_200  // 2001-01-01 UTC，Apple 各库的纪元

func appleToUnix(_ t: Double) -> Double {
    t > 1e12 ? t / 1e9 + appleEpoch : t + appleEpoch
}

func nowUnix() -> Double { Date().timeIntervalSince1970 }

enum Clock {
    static var systemTZName: String? {
        let real = URL(fileURLWithPath: "/etc/localtime").resolvingSymlinksInPath().path
        guard let r = real.range(of: "zoneinfo/") else { return nil }
        let name = String(real[r.upperBound...])
        return TimeZone(identifier: name) == nil ? nil : name
    }

    static var resolvedFromSystem: Bool {
        ProcessInfo.processInfo.environment["NOTIFHUB_TZ"] != nil || systemTZName != nil
    }

    static var tz: TimeZone {
        if let s = ProcessInfo.processInfo.environment["NOTIFHUB_TZ"],
           let t = TimeZone(identifier: s) { return t }
        if let n = systemTZName, let t = TimeZone(identifier: n) { return t }
        return TimeZone.current   // 退化路径：doctor 会判红，别指望它是对的
    }

    static var sqlModifier: String {
        let mins = tz.secondsFromGMT(for: Date()) / 60
        return "'\(mins >= 0 ? "+" : "-")\(abs(mins)) minutes'"
    }
    static func sqlDay(_ col: String) -> String {
        "date(\(col),'unixepoch',\(sqlModifier))"
    }
    static func sqlHour(_ col: String) -> String {
        "CAST(strftime('%H',\(col),'unixepoch',\(sqlModifier)) AS INTEGER)"
    }
}

var displayTZ: TimeZone { Clock.tz }

func fmtTime(_ unix: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = displayTZ
    return f.string(from: Date(timeIntervalSince1970: unix))
}


enum Log {
    private static let cap = 262_144

    private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.timeZone = displayTZ
        return f
    }()

    static var silent = false

    static func write(_ msg: String) {
        if silent { return }
        Paths.ensureDataDir()
        let line = "\(stampFmt.string(from: Date())) \(msg)\n"
        let p = Paths.log
        if let size = try? FileManager.default.attributesOfItem(atPath: p.path)[.size] as? Int,
           size > cap {
            let text = (try? String(contentsOf: p, encoding: .utf8)) ?? ""
            let tail = text.split(separator: "\n").suffix(500).joined(separator: "\n")
            try? (tail + "\n").write(to: p, atomically: true, encoding: .utf8)
        }
        if let fh = try? FileHandle(forWritingTo: p) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? line.write(to: p, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p.path)
        }
    }

    static func out(_ msg: String) { print(msg) }
    static func err(_ msg: String) { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!) }
}


struct Event {
    var ts: Double            // unix 秒
    var source: String        // usernoted | remote | messages
    var bundle: String        // 原始 bundle id（remote 源可能是 iOS 的）
    var app: String           // 展示名
    var title: String
    var subtitle: String
    var body: String
    var extID: String         // 源内 id：rec_id / AppNotificationIdentifier / ROWID
    var recID: Int64?         // 仅 usernoted：用于「还在队列里 = 没点开」的已读位

    var dedupKey: String {
        let bucket = Int(ts / 60)
        let raw = "\(BundleMap.canonical(bundle))|\(title)|\(body)|\(bucket)"
        return raw.sha256()
    }
}


enum BundleMap {
    private static let table: [String: (canon: String, name: String)] = [
        "com.laiwang.dingtalk":        ("dingtalk", "钉钉"),
        "com.alibaba.dingtalkmac":     ("dingtalk", "钉钉"),
        "com.tencent.xinwechat":       ("wechat", "微信"),
        "com.tencent.xin":             ("wechat", "微信"),
        "com.tencent.wework":          ("wework", "企业微信"),
        "com.tencent.wework.mac":      ("wework", "企业微信"),
        "com.apple.mobilesms":         ("messages", "信息"),
        "com.apple.ichat":             ("messages", "信息"),
        "com.apple.madrid":            ("messages", "信息"),
        "com.netease.macmail":         ("mail163", "网易邮箱"),
        "com.netease.mailmaster":      ("mail163", "网易邮箱"),
        "com.apple.mail":              ("applemail", "邮件"),
        "com.apple.ical":              ("calendar", "日历"),
        "com.robinhood.release.robinhood": ("robinhood", "Robinhood"),
        "com.taobao.fleamarket":       ("xianyu", "闲鱼"),
        "ai.claude":                   ("claude", "Claude Code"),
        "ai.codex":                    ("codex", "Codex"),
    ]

    static func normalize(_ b: String) -> String {
        var s = b.lowercased()
        for suffix in [".notificationserviceextension", ".notificationservice", ".notification"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        return s
    }

    static func canonical(_ b: String) -> String {
        let s = normalize(b)
        return table[s]?.canon ?? s
    }

    static func displayName(_ b: String) -> String {
        let s = normalize(b)
        if let n = table[s]?.name { return n }
        return s.split(separator: ".").last.map(String.init) ?? s
    }
}


extension String {
    func sha256() -> String {
        let d = SHA256.hash(data: Data(self.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }

    func truncated(_ n: Int) -> String {
        count <= n ? self : String(prefix(n)) + "…"
    }

    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}

@discardableResult
func run(_ launchPath: String, _ args: [String], stdin input: String? = nil,
         env: [String: String]? = nil, stderrToo: Bool = false,
         timeout: TimeInterval = 0) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    if let env {
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        p.environment = e
    }
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = stderrToo ? outPipe : Pipe()
    if let input {
        let inPipe = Pipe()
        p.standardInput = inPipe
        do { try p.run() } catch { return (-1, "") }
        inPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
    } else {
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
    }
    var timedOut = false
    if timeout > 0 {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { timedOut = true; p.terminate(); kill(p.processIdentifier, SIGKILL) }
        }
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let body = String(data: data, encoding: .utf8) ?? ""
    if timedOut {
        return (-9, body + "\n[超时 \(Int(timeout))s，已强杀]")
    }
    return (p.terminationStatus, body)
}
