import Foundation

enum LifecycleRelay {
    static let verbs: Set<String> = ["config", "update"]
    static let capabilityKey = "NotihubLifecycleCLI"
    static let timeout: TimeInterval = 60
    static let installTimeout: TimeInterval = 30 + 330 + 20 + 330 + 40

    static func timeout(for words: [String]) -> TimeInterval {
        let positionals = words.filter { !$0.hasPrefix("-") }
        guard positionals.prefix(2) == ["update", "install"],
              !words.contains("--dry-run"), !words.contains("--help"), !words.contains("-h") else { return timeout }
        return installTimeout
    }

    struct Missing: Error { let message: String }

    static func target(appBundle: URL?, info: (URL) -> [String: Any]?, executable: (String) -> Bool) -> Result<URL, Missing> {
        guard let app = appBundle else {
            return .failure(Missing(message: "config / update 由 Notihub.app 执行：这份 notihub 不在 Notihub.app 里，\(Paths.defaultAppBinary.path) 也不存在"))
        }
        guard let info = info(app), info[capabilityKey] as? Int == 1,
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/") else {
            return .failure(Missing(message: "\(app.path) 的主程序还不认 config / update（旧版 Notihub.app，或它的 Info.plist 读不到）：装上新版后再试"))
        }
        let main = app.appendingPathComponent("Contents/MacOS/" + name)
        guard executable(main.path) else { return .failure(Missing(message: "找不到 App 可执行文件 \(main.path)")) }
        return .success(main)
    }

    static func run(_ words: [String]) -> Int32 {
        let main: URL
        switch target(appBundle: Paths.appBundle,
                      info: { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) as? [String: Any] },
                      executable: { FileManager.default.isExecutableFile(atPath: $0) }) {
        case .success(let url): main = url
        case .failure(let missing): return fail(words, "app_missing", missing.message)
        }
        let process = Process()
        process.executableURL = main
        process.arguments = words
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return fail(words, "app_failed", "启动不了 App 可执行文件 \(main.path)：\(error.localizedDescription)")
        }
        var late = false
        let limit = timeout(for: words)
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
            if process.isRunning { late = true; kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let readback = words.first == "update" ? "；当前版本用 notihub update check 回读" : "；设置是否已改用 notihub config status 回读"
        if late { return fail(words, "timeout", "\(Int(limit)) 秒内 App 可执行文件没有结束，已终止" + readback) }
        guard process.terminationReason == .exit else {
            return fail(words, "app_failed", "App 可执行文件被信号 \(process.terminationStatus) 终止" + readback)
        }
        return process.terminationStatus
    }

    static func fail(_ words: [String], _ code: String, _ message: String) -> Int32 {
        if words.contains("--json") {
            let command = words.prefix(2).filter { !$0.hasPrefix("-") }.joined(separator: " ")
            CLI.printJSON(["ok": false, "command": command, "error": ["code": code, "message": message]])
        } else { Log.err(message) }
        return 1
    }
}
