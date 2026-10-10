import Foundation
import CryptoKit
import Darwin

enum CollectorUpdate {
    struct State: Codable {
        var schema = 1
        let pid: String
        let program: String
        let watchpointsMin: Int
        let logOffset: UInt64
        let plistsSha: [String: String]
    }
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let label = "com.notifhub.daemon"
    static var target: String { "gui/\(getuid())/" + label }
    static var log: URL { home.appendingPathComponent(".local/share/notifhub/notifhub.log") }
    static var agents: URL { home.appendingPathComponent("Library/LaunchAgents") }
    static let fm = FileManager.default

    static func main(_ args: [String]) -> Int32 {
        if args == ["--help"] || args == ["help"] {
            print("collector-update snapshot | verify --state FILE --app APP [--restore-app APP] | install --app APP --target APP --parent-pid PID --task-dir DIR")
            return 0
        }
        do {
            guard let action = args.first else { throw Failure("缺少 collector-update 子命令") }
            var options: [String: String] = [:]
            var index = 1
            while index < args.count {
                let key = args[index]
                guard key.hasPrefix("--"), index + 1 < args.count, options[key] == nil else { throw Failure("更新参数无效") }
                options[key] = args[index + 1]; index += 2
            }
            switch action {
            case "snapshot":
                guard options.isEmpty else { throw Failure("snapshot 不接受参数") }
                try printState(snapshot())
            case "verify":
                guard Set(options.keys).isSubset(of: ["--state", "--app", "--restore-app"]),
                      let statePath = options["--state"], let appPath = options["--app"] else { throw Failure("verify 需要 --state 和 --app") }
                let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                let state = try decoder.decode(State.self, from: Data(contentsOf: URL(fileURLWithPath: statePath)))
                let app = URL(fileURLWithPath: appPath)
                do {
                    let result = try verify(state: state, app: app)
                    try printJSON(result)
                } catch {
                    var result: [String: Any] = ["updated": false, "reason": error.localizedDescription]
                    if let previous = options["--restore-app"] {
                        result["restored"] = try restore(app: app, previous: URL(fileURLWithPath: previous), minimum: state.watchpointsMin)
                    }
                    try printJSON(result)
                    return 1
                }
            case "install":
                guard Set(options.keys) == ["--app", "--target", "--parent-pid", "--task-dir"],
                      let app = options["--app"], let destination = options["--target"],
                      let parent = Int32(options["--parent-pid"] ?? ""), parent > 0, parent != getpid(),
                      let directory = options["--task-dir"] else { throw Failure("install 需要新包、装机路径、旧 GUI PID 与临时目录") }
                try printJSON(install(source: URL(fileURLWithPath: app), destination: URL(fileURLWithPath: destination), parent: parent, directory: URL(fileURLWithPath: directory)))
            default: throw Failure("未知 collector-update 子命令")
            }
            return 0
        } catch {
            fputs("collector-update: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    @discardableResult static func command(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("\(URL(fileURLWithPath: path).lastPathComponent) 失败：" + String(decoding: data.prefix(4096), as: UTF8.self)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func field(_ text: String, _ key: String) -> String? {
        let pattern = "(?m)^\\s*" + NSRegularExpression.escapedPattern(for: key) + " = (.+)$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func watchpointCount(in text: String, forPID pid: String) throws -> Int {
        guard let start = text.range(of: "daemon 启动 pid=\(pid)\n", options: .backwards) else {
            throw Failure("找不到当前采集器 PID \(pid) 的启动记录")
        }
        let segment = String(text[start.upperBound...])
        guard !segment.contains("daemon 启动 pid=") else {
            throw Failure("监听记录属于其他采集器进程")
        }
        let expression = try! NSRegularExpression(pattern: "已挂 (\\d+) 个监视点")
        guard let last = expression.matches(in: segment, range: NSRange(segment.startIndex..., in: segment)).last,
              let value = Range(last.range(at: 1), in: segment), let count = Int(segment[value]), count >= 1,
              let mounted = Range(last.range, in: segment) else {
            throw Failure("当前采集器 PID \(pid) 尚未挂上有效监视点")
        }
        guard !segment[mounted.upperBound...].contains("一个监视点都挂不上") else {
            throw Failure("当前采集器 PID \(pid) 已失去完全磁盘访问监视点")
        }
        return count
    }
    static func hashes() throws -> [String: String] {
        guard fm.fileExists(atPath: agents.path) else { return [:] }
        var result: [String: String] = [:]
        for path in try fm.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)
            where path.lastPathComponent.hasPrefix("com.notifhub.") && path.pathExtension == "plist" {
            result[path.lastPathComponent] = SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    static func daemon() throws -> (pid: String, program: String) {
        let text = try command("/bin/launchctl", ["print", target])
        guard field(text, "state") == "running", let pid = field(text, "pid"), Int32(pid) != nil,
              let program = field(text, "program") else { throw Failure("原采集器没有健康的运行状态") }
        let actual = try command("/bin/ps", ["-p", pid, "-o", "command="])
        guard actual == program + " daemon" else { throw Failure("采集器进程与 launchd 程序路径不一致") }
        return (pid, program)
    }
    static func readLog(from offset: UInt64 = 0, tailLimit: UInt64? = nil) throws -> (String, UInt64) {
        let handle = try FileHandle(forReadingFrom: log); defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard end >= offset else { throw Failure("采集器日志在更新期间被截断，不能确认监视点基线") }
        let start = tailLimit.map { max(offset, end > $0 ? end - $0 : 0) } ?? offset
        try handle.seek(toOffset: start)
        return (String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self), end)
    }
    static func snapshot() throws -> State {
        let current = try daemon()
        let (text, end) = try readLog()
        let count = try watchpointCount(in: text, forPID: current.pid)
        let properties = try hashes()
        guard properties[label + ".plist"] != nil else { throw Failure("缺少原采集器 LaunchAgent") }
        return State(pid: current.pid, program: current.program, watchpointsMin: count, logOffset: end, plistsSha: properties)
    }
    static func wait(binary: String, oldPID: String, offset: UInt64, minimum: Int) throws -> (pid: String, count: Int) {
        let deadline = Date().addingTimeInterval(35)
        var reason = "新采集器尚未启动"
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            let (text, _) = try readLog(from: offset)
            do {
                let current = try daemon()
                guard current.pid != oldPID else { throw Failure("采集器仍是原进程") }
                guard current.program == binary else { throw Failure("新采集器未从装机 App 启动") }
                let count = try watchpointCount(in: text, forPID: current.pid)
                guard count >= minimum else { throw Failure("监视点 \(count) 少于更新前的 \(minimum)") }
                return (current.pid, count)
            } catch { reason = error.localizedDescription }
        }
        throw Failure("35 秒内采集器未恢复：" + reason)
    }
    static func verify(state: State, app: URL) throws -> [String: Any] {
        guard state.schema == 1, state.watchpointsMin >= 1,
              state.program == app.appendingPathComponent("Contents/Resources/bin/notihub").path else { throw Failure("回执与待验证采集器路径不匹配") }
        Thread.sleep(forTimeInterval: 1.1)
        try command("/bin/launchctl", ["kickstart", "-k", target])
        let current = try wait(binary: state.program, oldPID: state.pid, offset: state.logOffset, minimum: state.watchpointsMin)
        guard try hashes() == state.plistsSha else { throw Failure("更新期间 LaunchAgent 配置发生变化") }
        return ["updated": true, "watchpoints": current.count, "process": current.pid,
                "program": state.program, "plists_preserved": true]
    }
    static func identity(_ app: URL) throws -> String {
        guard Bundle(url: app)?.bundleIdentifier == "cyou.tianli.notifhubbar",
              fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/Resources/bin/notihub").path) else { throw Failure("不是完整的 Notihub App") }
        try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let description = try command("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        guard let team = description.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }),
              team != "TeamIdentifier=not set" else { throw Failure("采集器更新需要稳定的 Developer ID 身份") }
        return String(team)
    }
    static func restore(app: URL, previous: URL, minimum: Int) throws -> [String: Any] {
        _ = try identity(previous)
        let trash = home.appendingPathComponent(".Trash/notihub-failed-" + UUID().uuidString)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        if fm.fileExists(atPath: app.path) { try fm.moveItem(at: app, to: trash.appendingPathComponent(app.lastPathComponent)) }
        try fm.moveItem(at: previous, to: app)
        let oldPID = (try? daemon().pid) ?? ""
        let (_, offset) = try readLog()
        Thread.sleep(forTimeInterval: 1.1)
        try command("/bin/launchctl", ["kickstart", "-k", target])
        let current = try wait(binary: app.appendingPathComponent("Contents/Resources/bin/notihub").path, oldPID: oldPID, offset: offset, minimum: minimum)
        return ["ok": true, "watchpoints": current.count, "pid": current.pid, "failed_app": trash.path]
    }
    static func running(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid], info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, Int32(info.kp_proc.p_stat) == SZOMB { return false }
        return true
    }
    static var isolatedRoot: URL? {
        ProcessInfo.processInfo.environment["APP_LIFECYCLE_SUPPORT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    }
    static let reopenVariable = "NOTIHUB_UPGRADE_REOPEN"
    static func install(source: URL, destination: URL, parent: Int32, directory: URL) throws -> [String: Any] {
        _ = setsid()   // fails only for a process-group leader, which a group signal for the caller cannot reach anyway
        signal(SIGHUP, SIG_IGN); signal(SIGINT, SIG_IGN)
        var reopen = ProcessInfo.processInfo.environment[reopenVariable] != "0"
        var trash = home.appendingPathComponent(".Trash")
        if let root = isolatedRoot {
            guard destination.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                throw Failure("隔离运行（APP_LIFECYCLE_SUPPORT_DIR）只能替换隔离目录里的 App，未替换 \(destination.path)")
            }
            reopen = false
            trash = root.appendingPathComponent("trash")
        }
        guard source.standardizedFileURL != destination.standardizedFileURL, destination.pathExtension == "app",
              fm.isWritableFile(atPath: destination.deletingLastPathComponent().path),
              fm.isWritableFile(atPath: directory.path),
              try identity(source) == identity(destination) else { throw Failure("新旧 App 身份或安装位置不符合更新要求") }
        let daemonPlist = agents.appendingPathComponent(label + ".plist")
        let plist = (try? Data(contentsOf: daemonPlist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let program = (plist?["ProgramArguments"] as? [String])?.first
        let usesApp = program == destination.appendingPathComponent("Contents/Resources/bin/notihub").path
        let state = usesApp ? try snapshot() : nil
        let originalPlists = try hashes()
        let deadline = Date().addingTimeInterval(60)
        while running(parent) && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        guard !running(parent) else { throw Failure("旧 Notihub 窗口未退出，未替换安装包") }
        let next = destination.deletingLastPathComponent().appendingPathComponent(".Notihub-upgrade-" + UUID().uuidString + ".app")
        let previous = directory.appendingPathComponent("previous-Notihub.app")
        try command("/usr/bin/ditto", [source.path, next.path])
        defer { try? fm.removeItem(at: next) }
        _ = try identity(next)
        try fm.moveItem(at: destination, to: previous)
        do { try fm.moveItem(at: next, to: destination) }
        catch { try fm.moveItem(at: previous, to: destination); throw error }
        do {
            if let state { _ = try verify(state: state, app: destination) }
            guard try hashes() == originalPlists else { throw Failure("更新期间 LaunchAgent 配置发生变化") }
        } catch {
            if let state { _ = try restore(app: destination, previous: previous, minimum: state.watchpointsMin) }
            else {
                try fm.moveItem(at: destination, to: directory.appendingPathComponent("failed-Notihub.app"))
                try fm.moveItem(at: previous, to: destination)
            }
            if reopen { _ = try? command("/usr/bin/open", ["-g", "-j", destination.path]) }
            throw error
        }
        let backup = trash.appendingPathComponent("notihub-upgrade-" + UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try fm.moveItem(at: previous, to: backup.appendingPathComponent("Notihub.app"))
        if reopen { try command("/usr/bin/open", ["-g", "-j", destination.path]) }
        return ["updated": true, "app": destination.path, "collector_verified": usesApp,
                "plists_preserved": true, "backup": backup.path, "reopened": reopen]
    }
    static func printState(_ state: State) throws {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(state), as: UTF8.self))
    }
    static func printJSON(_ value: [String: Any]) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }
}
