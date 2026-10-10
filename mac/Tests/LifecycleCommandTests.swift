import Foundation
import XCTest
@testable import notifhub

final class LifecycleCommandTests: XCTestCase {
    private static var macRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    func testHelpConstantsAreTheSharedLayersOwnLines() {
        XCTAssertEqual(Help.lifecycleReads.joined(separator: "\n"), AppLifecycleCLI.helpRead(Lifecycle.command))
        XCTAssertEqual(Help.lifecycleWrites.joined(separator: "\n"), AppLifecycleCLI.helpWrite(Lifecycle.command))
        XCTAssertEqual(Help.lifecycleWrites.last, AppLifecycleCLI.helpInstall(Lifecycle.command), "upgrading is a listed write command")
        XCTAssertEqual(Help.lifecycleWindowOnly, AppLifecycleCLI.helpWindowOnly(windowEntry: Lifecycle.windowEntry))
        XCTAssertEqual(LifecycleRelay.verbs, Set(AppLifecycleCLI.verbs), "the relay forwards exactly the verbs the shared layer handles")
        let top = Help.main
        for line in Help.lifecycleReads + Help.lifecycleWrites {
            XCTAssertTrue(top.contains("\n" + line + "\n"), "top-level help must list this line at the start of a line: \(line)")
        }
        let windowOnly = top.components(separatedBy: "仅在窗口中").dropFirst().joined().components(separatedBy: "暂无命令：")
        XCTAssertEqual(windowOnly.count, 2)
        XCTAssertTrue(windowOnly[0].contains(Help.lifecycleWindowOnly))
        XCTAssertFalse(windowOnly[0].contains("升级到新版"), "upgrading has a command; it is not window-only")
        let noCommand = windowOnly[1].components(separatedBy: "\n").prefix { !$0.contains("窗口里的搜索框") }.joined(separator: "\n")
        XCTAssertTrue(noCommand.contains("手机端"))
        for gone in ["升级到新版", "同步状态", "静默安装"] {
            XCTAssertFalse(noCommand.contains(gone), "「\(gone)」 is no longer without a command")
        }
        for stale in ["升级到新版 / 下载新版", "命令不做静默安装", "由运行中的 App 持有"] {
            XCTAssertFalse(top.contains(stale), "top-level help still says: \(stale)")
        }
        XCTAssertTrue(top.contains(Help.lifecycleHandOff))
        XCTAssertTrue(Help.lifecycleHandOff.contains("state: handed_off") && Help.lifecycleHandOff.contains("notihub update check"))
    }

    func testCommandUpgradeTellsTheTransactionWhetherToReopen() {
        let store = Lifecycle.Store(defaults: UserDefaults(suiteName: "test.tianli.notihub.unit-\(UUID().uuidString)")!,
                                    rules: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).json"))
        let running = Lifecycle.product(store).runningApp
        XCTAssertNotNil(running, "the product names the running app itself so an isolated run never reaches the owner's Notihub")
        unsetenv(CollectorUpdate.reopenVariable)
        let apps = running?() ?? []
        XCTAssertEqual(apps, Lifecycle.runningApps())
        XCTAssertFalse(apps.contains(ProcessInfo.processInfo.processIdentifier), "the command process is never the running app")
        XCTAssertEqual(ProcessInfo.processInfo.environment[CollectorUpdate.reopenVariable], apps.isEmpty ? "0" : "1")
    }

    func testWindowEntryIsOneConstant() throws {
        XCTAssertEqual(Lifecycle.windowEntry, Help.lifecycleWindowEntry)
        let entry = try String(contentsOf: Self.macRoot.appendingPathComponent("Sources/notifhub/NotifhubBarApp.swift"), encoding: .utf8)
        XCTAssertTrue(entry.contains("Button(Lifecycle.windowEntry) { AppLifecycleUI.shared.show() }"))
        XCTAssertFalse(entry.contains("\"" + Help.lifecycleWindowEntry + "\""), "the panel button must not carry its own copy of the title")
        let store = Lifecycle.Store(defaults: UserDefaults(suiteName: "test.tianli.notihub.unit-\(UUID().uuidString)")!,
                                    rules: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).json"))
        let product = Lifecycle.product(store)
        XCTAssertEqual(product.windowEntry, Help.lifecycleWindowEntry)
        XCTAssertEqual(product.command, "notihub")
        XCTAssertTrue(AppLifecycleCLI.help(product.command, windowEntry: product.windowEntry).contains("「\(Help.lifecycleWindowEntry)」窗口里的各项"))
    }

    func testPortableKeysAreFieldsOfTheCollectorsConfig() throws {
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any])
        for key in Lifecycle.portableKeys {
            var current: Any? = encoded
            for part in key.split(separator: ".") { current = (current as? [String: Any])?[String(part)] }
            XCTAssertNotNil(current, "\(key) is not a field of Config")
        }
        for local in ["rules", "bark.key", "bark.keyFile", "summary.python", "ai.privatePaths"] {
            XCTAssertFalse(Lifecycle.portableKeys.contains(local), "\(local) stays on this Mac")
        }
    }

    func testImportWithAWrongTypeIsRefusedBeforeAnythingIsWritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notihub-lifecycle-unit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "test.tianli.notihub.unit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rules = folder.appendingPathComponent("rules.json")
        try Data(#"{"retentionDays":90,"bark":{"enabled":false,"keyFile":"~/private"},"rules":[]}"#.utf8).write(to: rules)
        let store = Lifecycle.Store(defaults: defaults, rules: rules)
        func file(_ values: [String: Any], product: String = Lifecycle.productID) throws -> String {
            let url = folder.appendingPathComponent(UUID().uuidString + ".json")
            try JSONSerialization.data(withJSONObject: ["version": 1, "product": product, "values": values]).write(to: url)
            return url.path
        }
        let good = try file(["file.0.retentionDays": 30, "file.0.bark.enabled": true, "file.0.muteInViews": ["a"]])
        XCTAssertNil(Lifecycle.importProblem(["config", "import", good, "--yes"], store: store))
        let wrong = try file(["file.0.retentionDays": "thirty"])
        let problem = try XCTUnwrap(Lifecycle.importProblem(["config", "import", wrong, "--yes", "--json"], store: store))
        XCTAssertTrue(problem.contains("retentionDays") && problem.contains("原配置已保留"), problem)
        XCTAssertNotNil(Lifecycle.importProblem(["config", "import", try file(["file.0.bark.enabled": "yes"]), "--yes"], store: store))
        XCTAssertNil(Lifecycle.importProblem(["config", "import", wrong], store: store))
        XCTAssertNil(Lifecycle.importProblem(["config", "import", try file(["file.0.retentionDays": "x"], product: "someone.else"), "--yes"], store: store))
        XCTAssertNil(Lifecycle.importProblem(["config", "status"], store: store))
        try Data(#"{"retentionDays":"broken"}"#.utf8).write(to: rules)
        XCTAssertNil(Lifecycle.importProblem(["config", "import", wrong, "--yes"], store: store))
    }

}
