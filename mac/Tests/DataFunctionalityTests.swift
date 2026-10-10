import Foundation
import XCTest
@testable import notifhub

final class DataFunctionalityTests: XCTestCase {
    private var root: URL!
    private let sql = "SELECT unix AS 时间, phone AS 电话, body AS 正文, amount AS 字数, blank AS 空值 FROM items ORDER BY id LIMIT {LIMIT}"
    private let special = "逗号,引号\"换行\n第二行"

    override func setUpWithError() throws {
        DataRichText.install()
        root = try DataTestKit.tempDir("data-functionality")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func itemsDB(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try DataTestKit.sqlite(url, """
        CREATE TABLE items(id INTEGER, unix INTEGER, phone TEXT, body TEXT, amount INTEGER, blank TEXT);
        INSERT INTO items VALUES(1,1704067200,'13800138000','逗号,引号"换行
        第二行',42,NULL);
        INSERT INTO items VALUES(2,0,'','普通',7,NULL);
        """)
        return url
    }

    private var date: String { DataTestKit.systemTime(1704067200) }
    private var expected: [[String]] { [[date, "13800138000", special, "42", ""], ["", "", "普通", "7", ""]] }

    func testSQLiteColumnsSystemTimeLimitAndMultiSourceMerge() throws {
        let source = try itemsDB("fixture.sqlite"), second = try itemsDB("fixture-2.sqlite")
        let fixture = DataTestKit.domain("fixture", paths: [source.path], extraction: .sqlite(sql), times: [0], sensitive: [1])
        let result = Extractor.run(fixture, limit: 10)
        XCTAssertTrue(result.isUsable, result.failure ?? "")
        XCTAssertEqual(result.columns, ["时间", "电话", "正文", "字数", "空值"])
        XCTAssertEqual(result.rows, expected, "row values / system-time formatting / NULL handling changed")
        XCTAssertFalse(result.truncated)
        let limited = Extractor.run(fixture, limit: 1)
        XCTAssertEqual(limited.rows, [expected[0]]); XCTAssertTrue(limited.truncated)
        let multi = DataTestKit.domain("multi", paths: [source.path, second.path], extraction: .sqlite(sql), times: [0])
        let merged = Extractor.run(multi, limit: 3)
        XCTAssertTrue(merged.isUsable)
        XCTAssertEqual(merged.resolvedCount, 2)
        XCTAssertEqual(merged.rows, expected + [expected[0]])
        XCTAssertTrue(merged.truncated)
        let bad = DataTestKit.domain("bad", paths: [source.path], extraction: .sqlite(sql), times: [3])
        let rejected = Extractor.run(bad, limit: 10)
        XCTAssertFalse(rejected.isUsable)
        XCTAssertTrue(rejected.rows.isEmpty)
        XCTAssertEqual(rejected.failure?.contains("列声明对账失败"), true, "misaligned timestamp declaration must fail closed")
    }

    func testSafariBookmarksStickiesRTFDAndICloudMetadata() throws {
        let fm = FileManager.default
        let bookmarks = root.appendingPathComponent("Bookmarks.plist")
        let tree: [String: Any] = ["Children": [["Title": "BookmarksBar", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URIDictionary": ["title": "Synthetic"], "URLString": "https://example.invalid/fixture"]
        ]]]]
        try PropertyListSerialization.data(fromPropertyList: tree, format: .binary, options: 0).write(to: bookmarks)
        let bookmarkResult = Extractor.run(DataTestKit.domain("bookmark", paths: [bookmarks.path], extraction: .safariBookmarks), limit: 10)
        XCTAssertEqual(bookmarkResult.rows, [["个人收藏", "Synthetic", "https://example.invalid/fixture"]])

        let stickies = root.appendingPathComponent("stickies", isDirectory: true)
        let package = stickies.appendingPathComponent("sample.rtfd", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("{\\rtf1\\ansi\\ansicpg936{\\fonttbl\\f0 Helvetica;}\\f0 Synthetic \\uc0\\u20415 \\u31614 }".utf8)
            .write(to: package.appendingPathComponent("TXT.rtf"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1704067200)], ofItemAtPath: package.path)
        XCTAssertNotNil(Extractor.richTextReader, "GUI must inject the AppKit RTF reader")
        let sticky = Extractor.run(DataTestKit.domain("sticky", paths: [stickies.path], extraction: .stickies, times: [3]), limit: 10)
        XCTAssertTrue(sticky.isUsable, sticky.failure ?? "")
        XCTAssertNil(sticky.note, "AppKit path must not be labelled as the CLI plain-text approximation")
        XCTAssertEqual(sticky.rows, [["sample", "Synthetic 便签", "12", date]])

        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: false)
        let cloudFile = cloud.appendingPathComponent("sample.txt")
        try Data("test".utf8).write(to: cloudFile)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1704067200)], ofItemAtPath: cloudFile.path)
        let cloudResult = Extractor.run(DataTestKit.domain("cloud", paths: [cloud.path], extraction: .icloudDrive, times: [2]), limit: 10)
        XCTAssertEqual(cloudResult.rows, [["sample.txt", "4", date, "已下载"]])
    }

    func testExportCSVJSONPrivateDirectoryManifestAndNoEmptyFiles() throws {
        let source = try itemsDB("fixture.sqlite")
        let fixture = DataTestKit.domain("fixture", paths: [source.path], extraction: .sqlite(sql), times: [0], sensitive: [1])
        let result = Extractor.run(fixture, limit: 10)
        let csv = try Exporter.export(domains: [fixture], results: [fixture.id: result], format: .csv, masked: false, to: root)
        let dirName = (csv.directory as NSString).lastPathComponent
        XCTAssertTrue(dirName.hasPrefix("export-") && UUID(uuidString: String(dirName.dropFirst(7))) != nil, "export-<UUID>/ expected, got \(dirName)")
        let mode = try FileManager.default.attributesOfItem(atPath: csv.directory)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        let csvData = try Data(contentsOf: URL(fileURLWithPath: csv.directory).appendingPathComponent("fixture.csv"))
        let expectedCSV = "\u{FEFF}时间,电话,正文,字数,空值\n\(date),13800138000,\"逗号,引号\"\"换行\n第二行\",42,\n,,普通,7,\n"
        XCTAssertEqual(csv.files.count, 1); XCTAssertEqual(csv.files.first?.rows, 2)
        XCTAssertEqual(csvData, Data(expectedCSV.utf8), "CSV BOM / RFC4180 escaping / rows changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: csv.directory + "/导出说明.md"))

        let json = try Exporter.export(domains: [fixture], results: [fixture.id: result], format: .json, masked: true, to: root)
        let objects = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: json.directory).appendingPathComponent("fixture.json"))) as? [[String: String]]
        XCTAssertEqual(objects, [["时间": date, "电话": "1380*****00", "正文": special, "字数": "42", "空值": ""],
                                 ["时间": "", "电话": "", "正文": "普通", "字数": "7", "空值": ""]])
        XCTAssertNotEqual(json.directory, csv.directory, "repeated export directory collision")

        let missing = DataTestKit.domain("gone", paths: [root.appendingPathComponent("absent.sqlite").path], extraction: .sqlite(sql), times: [0])
        let unreadable = Extractor.run(missing, limit: 10)
        XCTAssertFalse(unreadable.isUsable)
        let mixed = try Exporter.export(domains: [fixture, missing], results: [fixture.id: result, missing.id: unreadable],
                                        format: .csv, masked: false, to: root)
        XCTAssertEqual(mixed.files.map(\.name), ["fixture.csv"])
        let written = try FileManager.default.contentsOfDirectory(atPath: mixed.directory).sorted()
        XCTAssertEqual(written, ["fixture.csv", "导出说明.md"], "unreadable domain must not leave an empty file")
        let manifest = try String(contentsOfFile: mixed.directory + "/导出说明.md", encoding: .utf8)
        XCTAssertTrue(manifest.contains("未导出") && manifest.contains("gone"))
    }

    @MainActor
    func testDataPageModelScanSelectAndBackgroundExport() async throws {
        let source = try itemsDB("fixture.sqlite")
        let fixture = DataTestKit.domain("fixture", paths: [source.path], extraction: .sqlite(sql), times: [0], sensitive: [1])
        let model = DataPageModel(domains: [fixture])
        XCTAssertFalse(model.masked, "masking defaults to off")
        XCTAssertTrue(model.results.isEmpty, "the model must not read anything until the page scans")
        model.limit = 1
        model.scanAll()
        try await waitUntil("scan") { !model.isScanning }
        XCTAssertEqual(model.results[fixture.id]?.rows.count, 1)
        XCTAssertEqual(model.results[fixture.id]?.truncated, true)
        model.limit = 5_000
        model.scanAll()
        try await waitUntil("rescan") { !model.isScanning }
        XCTAssertEqual(model.results[fixture.id]?.rows, expected, "preview shows original values, masking only affects exports")
        model.selectReadable()
        XCTAssertEqual(model.selected, [fixture.id])
        XCTAssertEqual(model.exportableSummary.rows, 2)
        model.masked = true
        model.performExport(to: root)
        XCTAssertTrue(model.exporting, "export returns before the worker completes")
        try await waitUntil("export") { !model.exporting }
        let outcome = try XCTUnwrap(model.lastExport)
        XCTAssertEqual(outcome.files.count, 1)
        let text = try String(contentsOfFile: outcome.directory + "/fixture.csv", encoding: .utf8)
        XCTAssertFalse(text.contains("13800138000"), "masking applies to the exported file")
        XCTAssertEqual(model.results[fixture.id]?.rows.first?[1], "13800138000", "masking must not change the preview")
    }

    private func withSharedFixture(_ body: (URL) throws -> Void) throws {
        let home = root.appendingPathComponent("datahome", isDirectory: true)
        try DataFixture.build(at: home)
        let previous = ProcessInfo.processInfo.environment["NOTIHUB_DATA_HOME"]
        setenv("NOTIHUB_DATA_HOME", home.path, 1)
        defer { if let previous { setenv("NOTIHUB_DATA_HOME", previous, 1) } else { unsetenv("NOTIHUB_DATA_HOME") } }
        try body(home)
    }

    func testFifteenDomainsReadFromSharedFixtureIncludingAppKitStickies() throws {
        try withSharedFixture { home in
            XCTAssertEqual(DomainRegistry.all.count, 15)
            XCTAssertEqual(Set(DomainRegistry.all.map(\.id)).count, 15)
            let chat = home.appendingPathComponent("Library/Messages/chat.db")
            let before = try DataTestKit.sha256(chat)
            var results: [String: DomainResult] = [:]
            for domain in DomainRegistry.all { results[domain.id] = Extractor.run(domain, limit: 100) }
            let unreadable = DomainRegistry.all.filter { results[$0.id]?.isUsable != true || results[$0.id]?.rows.isEmpty != false }
            XCTAssertEqual(unreadable.map(\.id), [], "fixture domains not read: \(unreadable.map { results[$0.id]?.statusLabel ?? "?" })")
            for (id, r) in results { XCTAssertTrue(r.rows.allSatisfy { $0.count == r.columns.count }, "\(id) ragged rows") }
            XCTAssertEqual(results["contacts"]?.resolvedCount, 3)
            XCTAssertEqual(results["contacts"]?.rows.count, 3)
            XCTAssertEqual(results["reminders"]?.rows.count, 2)
            XCTAssertEqual(results["safari-bookmarks"]?.rows.map { $0[0] }.sorted(), ["个人收藏", "阅读列表"])
            XCTAssertEqual(results["safari-tabs"]?.rows.count, 1, "only open tabs (type=0)")
            XCTAssertEqual(results["icloud-drive"]?.rows.count, 2)
            XCTAssertEqual(results["stickies"]?.rows.first?[1], DataFixture.stickyText, "AppKit RTFD reader result")
            XCTAssertNil(results["stickies"]?.note, "GUI path must use the injected AppKit reader, not the CLI approximation")
            XCTAssertEqual(results["podcasts"]?.rows.first?[3], DataTestKit.systemTime(DataFixture.t0 + 978_307_200))
            XCTAssertEqual(try DataTestKit.sha256(chat), before, "reading changed chat.db")
            XCTAssertFalse(FileManager.default.fileExists(atPath: chat.path + "-shm"))
        }
    }

    func testAttributedBodyDecodingMatchesTextAndRecoversMissingBodies() throws {
        try withSharedFixture { _ in
            let messages = Extractor.run(DomainRegistry.messages, limit: 100)
            XCTAssertTrue(messages.isUsable, messages.statusLabel)
            let bodies = messages.rows.map { $0.last ?? "" }
            XCTAssertTrue(bodies.contains(DataFixture.onlyInAttributedBody), "body stored only in attributedBody was dropped")
            XCTAssertTrue(bodies.contains("看这张图"), "U+FFFC attachment placeholder must be stripped")
            XCTAssertFalse(bodies.contains(""), "attachment-only message must be filtered out")
            let check = try IMessageBody.selfCheck(sources: DomainRegistry.messages.sources.flatMap { $0.resolve() })
            XCTAssertGreaterThan(check.compared, 0)
            XCTAssertEqual(check.mismatched, 0, "attributedBody decoding disagrees with text: \(check)")
            XCTAssertGreaterThanOrEqual(check.recovered, 2)
            XCTAssertTrue(check.passed)
            let long = String(repeating: "长", count: 60)
            XCTAssertEqual(IMessageBody.decode(DataFixture.typedstream(long)), long, "0x81 length prefix")
        }
    }

    func testOutgoingCallWithDurationCountsAsAnswered() throws {
        try withSharedFixture { _ in
            let calls = Extractor.run(DomainRegistry.callHistory, limit: 100)
            XCTAssertTrue(calls.isUsable, calls.statusLabel)
            let columns = calls.columns
            let duration = try XCTUnwrap(columns.firstIndex(of: "时长秒")), direction = try XCTUnwrap(columns.firstIndex(of: "方向"))
            let answered = try XCTUnwrap(columns.firstIndex(of: "接通"))
            let outgoing = try XCTUnwrap(calls.rows.first { $0[direction] == "呼出" && $0[duration] == "125" })
            XCTAssertEqual(outgoing[answered], "已接通", "outgoing call with duration (ZANSWERED=0) must count as answered")
            XCTAssertTrue(calls.rows.contains { $0[duration] == "0" && $0[answered] == "未接通" })
        }
    }

    func testDataProbeWritesStatusAndCountsOnly() throws {
        try withSharedFixture { home in
            try FileManager.default.removeItem(at: home.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared"))
            try Data(repeating: 0x5A, count: 4096).write(to: home.appendingPathComponent("Library/Application Support/Knowledge/knowledgeC.db"))
            let output = root.appendingPathComponent("probe/probe.json")
            try DataProbe.run(output: output)
            let text = try String(contentsOf: output, encoding: .utf8)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let domains = try XCTUnwrap(json["domains"] as? [[String: Any]])
            XCTAssertEqual(domains.count, 15)
            let status = Dictionary(uniqueKeysWithValues: domains.map { ($0["id"] as! String, $0["status"] as! String) })
            XCTAssertEqual(status["voicememos"], "missing")
            XCTAssertEqual(status["screentime"], "corrupt")
            XCTAssertEqual(status.values.filter { $0 == "ok" }.count, 13)
            let rows = Dictionary(uniqueKeysWithValues: domains.map { ($0["id"] as! String, $0["rows"] as! Int) })
            XCTAssertEqual(rows["voicememos"], 0)
            XCTAssertEqual(rows["contacts"], 3, "multi-source contacts merged")
            for domain in DomainRegistry.all where status[domain.id] == "ok" {
                XCTAssertEqual(rows[domain.id], Extractor.count(domain).total, "\(domain.id) probe count")
                XCTAssertGreaterThan(rows[domain.id] ?? 0, 0, "\(domain.id) readable but 0 rows on the fixture")
            }
            XCTAssertEqual(Set(domains.flatMap(\.keys)), ["id", "status", "rows", "sources"])
            for secret in [DataFixture.phoneA, DataFixture.emailA, DataFixture.personA, DataFixture.onlyInAttributedBody, "example.org", home.path] {
                XCTAssertFalse(text.contains(secret), "probe output leaked content or paths")
            }
            let mode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
    }
}
