import AppKit

enum Lifecycle {
    static let name = "Notihub · 通知中心"
    static let command = "notihub"
    static let productID = "cyou.tianli.notifhubbar"
    static let updateSource: AppUpdateSource = .manifest(URL(string: ProcessInfo.processInfo.environment["NOTIHUB_UPDATE_MANIFEST_URL"] ?? "https://updates.example.invalid/release.json")!)
    static var windowEntry: String { Help.lifecycleWindowEntry }
    static let portableKeys = ["retentionDays", "maxActionAgeSeconds", "muteInViews",
        "bark.enabled", "bark.server", "bark.group",
        "summary.enabled", "summary.minIntervalSeconds", "summary.minNewEvents", "summary.maxChars",
        "summary.extractAgenda", "summary.timeoutSeconds", "summary.provider",
        "apple.remindersList", "apple.calendarName", "apple.defaultEventMinutes", "apple.defaultDueHour",
        "jobs.enabled", "jobs.disabled", "jobs.queueSeconds", "jobs.syncSeconds", "jobs.summarizeSeconds",
        "ai.enabled", "ai.idleMinutes", "ai.backfillDays", "ai.maxPromptChars"]


    struct Store { let defaults: UserDefaults; let rules: URL }

    static let suiteVariable = "NOTIHUB_LIFECYCLE_SUITE"
    static let suitePrefix = "test.tianli.notihub."
    static let refusal = "设了 APP_LIFECYCLE_SUPPORT_DIR（隔离运行）：还必须给 NOTIHUB_LIFECYCLE_SUITE（以 test.tianli.notihub. 开头的一次性偏好域）和 NOTIFHUB_CONFIG（一份不是本人 ~/.config/notifhub/rules.json 的配置文件），否则会落到本人的设置上，已拒绝。"

    static var isolated: Bool { ProcessInfo.processInfo.environment["APP_LIFECYCLE_SUPPORT_DIR"] != nil }

    static func store() -> Store? {
        let environment = ProcessInfo.processInfo.environment
        guard isolated else {
            let own = Bundle.main.bundleIdentifier == productID ? UserDefaults.standard : UserDefaults(suiteName: productID)
            return Store(defaults: own ?? .standard, rules: Paths.configFile)
        }
        let owners = Paths.home.appendingPathComponent(".config/notifhub", isDirectory: true).standardizedFileURL.path + "/"
        guard let suite = environment[suiteVariable], suite.hasPrefix(suitePrefix), suite.count > suitePrefix.count,
              let defaults = UserDefaults(suiteName: suite),
              let path = environment["NOTIFHUB_CONFIG"], !path.isEmpty,
              !Paths.configFile.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(owners) else { return nil }
        return Store(defaults: defaults, rules: Paths.configFile)
    }

    static func makeConfiguration(_ store: Store) -> AppConfiguration {
        AppConfiguration(productID: productID, files: [AppConfigurationFile(url: store.rules, keys: portableKeys)], defaults: store.defaults)
    }

    private static func mode(of file: URL) -> NSNumber? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber
    }
    private static func keep(_ mode: NSNumber?, on file: URL) {
        guard let mode, let now = Self.mode(of: file), now != mode else { return }
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }


    static let appPIDVariable = "NOTIHUB_LIFECYCLE_APP_PID"

    static func runningApps() -> [Int32] {
        if isolated, let named = ProcessInfo.processInfo.environment[appPIDVariable] { return Int32(named).map { [$0] } ?? [] }
        let own = ProcessInfo.processInfo.processIdentifier, bundle = Bundle.main
        var apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle.bundleIdentifier ?? productID)
            .filter { $0.processIdentifier != own }
        if isolated {
            let here = bundle.bundleURL.resolvingSymlinksInPath().path
            apps = apps.filter { $0.bundleURL?.resolvingSymlinksInPath().path == here }
        }
        return apps.map(\.processIdentifier)
    }

    static func product(_ store: Store) -> AppLifecycleCLI.Product {
        var product = AppLifecycleCLI.Product(command: command, name: name, configuration: makeConfiguration(store),
                                              updateSource: updateSource, windowEntry: windowEntry)
        product.runningApp = {
            let apps = runningApps()
            setenv(CollectorUpdate.reopenVariable, apps.isEmpty ? "0" : "1", 1)
            return apps
        }
        let before = mode(of: store.rules)
        product.changed = { keep(before, on: store.rules) }
        return product
    }

    static func run(_ words: [String]) -> Int32 {
        func refuse(_ code: String, _ message: String) -> Int32 {
            if words.contains("--json") {
                let command = words.prefix(2).filter { !$0.hasPrefix("-") }.joined(separator: " ")
                CLI.printJSON(["ok": false, "command": command, "error": ["code": code, "message": message]])
            } else { fputs(message + "\n", stderr) }
            return 1
        }
        guard let store = store() else { return refuse("isolation_incomplete", refusal) }
        if let problem = importProblem(words, store: store) { return refuse("import_rejected", problem) }
        return AppLifecycleCLI.run(words, product: product(store))
    }

    static func importProblem(_ words: [String], store: Store) -> String? {
        let positionals = words.filter { !$0.hasPrefix("-") }
        guard positionals.count == 3, positionals[0] == "config", positionals[1] == "import", words.contains("--yes"),
              let data = FileManager.default.contents(atPath: (positionals[2] as NSString).expandingTildeInPath),
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              envelope["product"] as? String == productID, let values = envelope["values"] as? [String: Any] else { return nil }
        func unreadable(_ object: [String: Any]) -> Error? {
            do { _ = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: object)); return nil }
            catch { return error }
        }
        var rules = (try? Data(contentsOf: store.rules)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        guard unreadable(rules) == nil else { return nil }
        for key in portableKeys {
            guard let value = values["file.0." + key] else { continue }
            let parts = key.split(separator: ".").map(String.init)
            if parts.count == 1 { rules[key] = value } else {
                var group = rules[parts[0]] as? [String: Any] ?? [:]
                group[parts[1]] = value
                rules[parts[0]] = group
            }
        }
        guard let error = unreadable(rules) else { return nil }
        var field = ""
        if case DecodingError.typeMismatch(_, let context) = error { field = context.codingPath.map(\.stringValue).joined(separator: ".") }
        return "导入未完成，原配置已保留：" + (field.isEmpty ? "文件里有字段" : "字段 \(field) ") + "的类型不对，采集器会读不出整份 rules.json"
    }


    @MainActor private(set) static var changes = 0

    @MainActor @discardableResult
    static func installApp(_ store: Store) -> AppConfiguration {
        let configuration = makeConfiguration(store)
        let before = mode(of: store.rules)
        var seen = try? configuration.exportData()
        configuration.onChange = { [weak configuration] in
            guard let configuration else { return }
            let now = try? configuration.exportData()
            guard now != seen else { return }
            seen = now
            keep(before, on: store.rules)
            changes += 1
            TodayModel.shared.refresh()
        }
        AppLifecycleUI.install(name: name, configuration: configuration, updateSource: updateSource)
        AppLifecycleCLI.follow(configuration)
        return configuration
    }


    static let probeFlag = "--lifecycle-follow-probe"
    @MainActor private static var probeWrite: (() -> Void)?

    private static func cloudSwitch(in view: NSView?) -> NSSwitch? {
        guard let view else { return nil }
        if let toggle = view as? NSSwitch { return toggle }
        for child in view.subviews { if let found = cloudSwitch(in: child) { return found } }
        return nil
    }

    @MainActor
    static func runFollowProbe(_ words: [String]) -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard isolated, let store = store(), environment["NOTIFHUB_DATA_DIR"]?.isEmpty == false,
              words.count == 2, !words[1].hasPrefix("-") else {
            fputs("\(probeFlag) <状态文件> 只在隔离运行里可用（另需 NOTIFHUB_DATA_DIR 指到临时目录）。" + refusal + "\n", stderr)
            exit(64)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let configuration = installApp(store)
        let state = URL(fileURLWithPath: words[1])
        let built: [String: Bool]
        do { built = try AppLifecycleUI.shared.offscreenSnapshot(to: state.deletingPathExtension().appendingPathExtension("png")) }
        catch { fputs("设置窗口离屏构造失败：\(error.localizedDescription)\n", stderr); exit(1) }
        let control = NSApp.windows.lazy.compactMap { cloudSwitch(in: $0.contentView) }.first
        let today = TodayModel.shared   // 生产启动时菜单栏就持有它；导入后的重读由 installApp 里的 onChange 触发
        var tick = 0
        probeWrite = {
            tick += 1
            let rules = Config.load()
            let seen: [String: Any] = [
                "enabled": configuration.enabled, "status": configuration.status, "changes": changes, "tick": tick,
                "window_switch": control.map { $0.state == .on } ?? NSNull(), "window_built": built,
                "windows_on_screen": NSApp.windows.filter(\.isVisible).count,
                "policy_prohibited": NSApp.activationPolicy() == .prohibited,
                "retentionDays": rules.retentionDays, "muteInViews": rules.muteInViews, "today_loads": today.loadCount]
            try? JSONSerialization.data(withJSONObject: seen, options: [.sortedKeys]).write(to: state, options: .atomic)
        }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in MainActor.assumeIsolated { probeWrite?() } }
        app.run()
        exit(0)
    }
}
