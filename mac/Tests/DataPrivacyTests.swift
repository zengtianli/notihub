import Foundation
import SQLite3
import XCTest
@testable import notifhub

final class DataPrivacyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        DataRichText.install()
        root = try DataTestKit.tempDir("data-privacy")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static var macRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private static var engineRoot: URL { macRoot.appendingPathComponent("Sources/notifhub/shared") }

    private func signature(_ url: URL) throws -> [String] {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return [try DataTestKit.sha256(url), "\((a[.size] as? NSNumber)?.int64Value ?? -1)",
                "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)",
                "\((a[.posixPermissions] as? NSNumber)?.intValue ?? -1)"]
    }

    private func snapshotDirs() -> Set<String> {
        let prefix = "notihub-data-\(ProcessInfo.processInfo.processIdentifier)-"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(entries.filter { $0.hasPrefix(prefix) })
    }

    func testWALSourceUnchangedSnapshotPrivateAndRemoved() throws {
        let source = root.appendingPathComponent("source.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &handle), SQLITE_OK)
        let writer = try XCTUnwrap(handle)
        defer { sqlite3_close(writer) }
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA wal_autocheckpoint=0", "CREATE TABLE items(value TEXT)",
                    "PRAGMA wal_checkpoint(TRUNCATE)", "INSERT INTO items VALUES ('wal-only-synthetic')"] {
            XCTAssertEqual(sqlite3_exec(writer, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        let files = ["", "-wal", "-shm"].map { URL(fileURLWithPath: source.path + $0) }
        let walSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: files[1].path)[.size] as? NSNumber)
        XCTAssertGreaterThan(walSize.intValue, 0, "fixture must have a live WAL")
        let before = try files.map(signature)
        let existing = snapshotDirs()

        let table = try ROSqlite.query(sources: [source.path], sql: "SELECT value FROM items")
        XCTAssertEqual(table.rows, [["wal-only-synthetic"]], "WAL data must be read from the copy")

        let done = DispatchSemaphore(value: 0)
        var slow: [[String]] = []
        DispatchQueue.global(qos: .userInitiated).async {
            slow = (try? ROSqlite.query(sources: [source.path],
                sql: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<3000000) SELECT sum(x) FROM n").rows) ?? []
            done.signal()
        }
        var observed: [String: Int] = [:]
        while done.wait(timeout: .now() + .milliseconds(2)) == .timedOut {
            for name in snapshotDirs().subtracting(existing) {
                let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
                if let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber {
                    observed[name] = mode.intValue
                }
            }
        }
        XCTAssertEqual(slow, [["4500001500000"]])
        XCTAssertFalse(observed.isEmpty, "snapshot directory was never observed")
        XCTAssertTrue(observed.values.allSatisfy { $0 == 0o700 }, "snapshot directory must be 0700: \(observed.values)")

        XCTAssertThrowsError(try ROSqlite.query(sources: [source.path], sql: "UPDATE items SET value='forbidden'"),
                             "read-only execution errors must surface")
        XCTAssertThrowsError(try ROSqlite.query(sources: [source.path], sql: "SELECT missing FROM absent"))
        XCTAssertEqual(snapshotDirs().subtracting(existing), [], "temporary copies must be deleted after success and failure")
        XCTAssertEqual(try files.map(signature), before, "original db/-wal/-shm changed")
    }

    func testMaskedAndRawExportsArePrivateAndIsolated() throws {
        let domain = DataDomain(id: "privacy-fixture", name: "合成隐私夹具", symbol: "lock", summary: "Synthetic",
                                sources: [], extraction: .sqlite(""), sensitiveColumns: [1, 2])
        let result = DomainResult(domainID: domain.id, columns: ["说明", "电话", "邮箱"],
                                  rows: [["公开合成说明", "13800138000", "synthetic.person@example.org"]])
        for format in ExportFormat.allCases {
            let masked = try Exporter.export(domains: [domain], results: [domain.id: result], format: format, masked: true, to: root)
            let raw = try Exporter.export(domains: [domain], results: [domain.id: result], format: format, masked: false, to: root)
            XCTAssertNotEqual(masked.directory, raw.directory)
            for dir in [masked.directory, raw.directory] {
                let mode = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber
                XCTAssertEqual(mode?.intValue, 0o700, "export directory must be private")
                XCTAssertTrue((dir as NSString).lastPathComponent.hasPrefix("export-"))
            }
            let maskedText = try String(contentsOfFile: masked.directory + "/" + domain.id + "." + format.ext, encoding: .utf8)
            let rawText = try String(contentsOfFile: raw.directory + "/" + domain.id + "." + format.ext, encoding: .utf8)
            XCTAssertFalse(maskedText.contains("13800138000") || maskedText.contains("synthetic.person@example.org"))
            XCTAssertTrue(maskedText.contains("公开合成说明") && maskedText.contains("*"))
            XCTAssertTrue(rawText.contains("13800138000") && rawText.contains("synthetic.person@example.org"))
        }
    }

    @MainActor
    func testDataPageMakesNoNetworkRequests() async throws {
        let source = root.appendingPathComponent("fixture.sqlite")
        try DataTestKit.sqlite(source, "CREATE TABLE items(value TEXT); INSERT INTO items VALUES ('offline');")
        let domain = DataTestKit.domain("offline", paths: [source.path], extraction: .sqlite("SELECT value FROM items LIMIT {LIMIT}"))
        XCTAssertTrue(URLProtocol.registerClass(NetworkTripwire.self))
        defer { URLProtocol.unregisterClass(NetworkTripwire.self) }
        NetworkTripwire.reset()
        _ = try? await URLSession.shared.data(from: URL(string: "https://tripwire.invalid/self-check")!)
        XCTAssertEqual(NetworkTripwire.count, 1, "tripwire must see ordinary requests")
        NetworkTripwire.reset()

        let model = DataPageModel(domains: [domain])
        model.scanAll()
        try await waitUntil("offline scan") { !model.isScanning }
        XCTAssertEqual(model.results[domain.id]?.rows, [["offline"]])
        model.selected = [domain.id]
        model.performExport(to: root)
        try await waitUntil("offline export") { !model.exporting }
        XCTAssertEqual(model.lastExport?.files.count, 1)
        XCTAssertEqual(NetworkTripwire.count, 0, "data page must not touch the network")

        let network = try NSRegularExpression(pattern: #"\b(URLSession|URLRequest|NWConnection|NWPathMonitor|CFSocket|CFStream|WKWebView|NSURLConnection)\b"#)
        for file in try dataModuleFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(network.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                         "\(file.lastPathComponent) references a network API")
        }
    }

    func testCloudSummaryAndStartupPathsDoNotReferenceDataModule() throws {
        var types = Set<String>()
        let decl = try NSRegularExpression(pattern: #"(?m)^(?:(?:private|fileprivate|internal|public|final)\s+)*(?:enum|struct|class|protocol|typealias|actor)\s+([A-Z][A-Za-z0-9_]*)"#)
        for file in try dataModuleFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in decl.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                types.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
        for required in ["DomainRegistry", "DataDomain", "Extractor", "DomainResult", "Exporter", "ExportFormat",
                         "ExportOutcome", "Masker", "ROSqlite", "SourceSpec", "DataPageModel", "DataProbe", "DataRichText"] {
            XCTAssertTrue(types.contains(required), "static check lost track of \(required); the scan would be vacuous")
        }
        let guarded = ["Publish.swift", "JSONFeed.swift", "Summary.swift", "AIWork.swift", "Today.swift", "Cloud.swift"].map { Self.engineRoot.appendingPathComponent($0) }
            + ["TodayModel.swift", "TodayPanelView.swift", "CloudModel.swift", "DataWatch.swift"].map {
                Self.macRoot.appendingPathComponent("Sources/notifhub/\($0)") }
        let words = try NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#)
        for file in guarded {
            let text = try String(contentsOf: file, encoding: .utf8)
            let used = Set(words.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) })
            XCTAssertEqual(used.intersection(types), [], "\(file.lastPathComponent) references the data module")
        }
        let entry = try String(contentsOf: Self.macRoot.appendingPathComponent("Sources/notifhub/NotifhubBarApp.swift"), encoding: .utf8)
        let entryUsed = Set(words.matches(in: entry, range: NSRange(entry.startIndex..., in: entry)).map { String(entry[Range($0.range, in: entry)!]) })
        XCTAssertEqual(entryUsed.intersection(types).subtracting(["DataRichText", "DataProbe"]), [],
                       "app startup must not touch the data module beyond the RTFD reader and --data-probe")
    }

    @MainActor
    func testLeavingDataPageReleasesModelEvenWithScanInFlight() async throws {
        let domain = DataTestKit.domain("held", paths: [], extraction: .sqlite(""))
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        weak var weakModel: DataPageModel?
        do {
            let model = DataPageModel(domains: [domain]) { item, _ in
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                return DomainResult(domainID: item.id, columns: ["value"], rows: [["late"]])
            }
            weakModel = model
            model.scanAll()
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            model.release()
            XCTAssertTrue(model.results.isEmpty && !model.isScanning && model.selected.isEmpty)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(weakModel, "an in-flight scan kept the data page model alive after leaving")
        release.signal()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(weakModel)
    }

    private func dataModuleFiles() throws -> [URL] {
        let dataDir = Self.engineRoot.appendingPathComponent("Data")
        let engine = try FileManager.default.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let page = ["DataPageModel.swift", "DataPageView.swift", "DataProbe.swift", "StickiesReader.swift"]
            .map { Self.macRoot.appendingPathComponent("Sources/notifhub/\($0)") }
        XCTAssertGreaterThanOrEqual(engine.count, 4, "engine Data/ directory looks incomplete")
        return engine + page
    }
}

private final class NetworkTripwire: URLProtocol {
    private static let lock = NSLock()
    private static var seen = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return seen }
    static func reset() { lock.lock(); seen = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seen += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
