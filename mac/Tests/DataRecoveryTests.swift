import XCTest
@testable import notifhub

final class DataRecoveryTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var good: DataDomain!

    override func setUpWithError() throws {
        DataRichText.install()
        root = try DataTestKit.tempDir("data-recovery")
        source = root.appendingPathComponent("fixture.sqlite")
        good = domain("fixture")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func domain(_ id: String, sql: String = "SELECT value FROM items LIMIT {LIMIT}") -> DataDomain {
        DataTestKit.domain(id, paths: [source.path], extraction: .sqlite(sql))
    }

    private func makeFixture() throws {
        try DataTestKit.sqlite(source, "CREATE TABLE items (value TEXT); INSERT INTO items VALUES ('synthetic');")
    }

    func testMissingSourceFailsClosedThenRetryReadsRestoredSource() throws {
        XCTAssertEqual(ROSqlite.triage(source.path), .notFound)
        let missing = Extractor.run(good, limit: 10)
        XCTAssertFalse(missing.isUsable, "missing source must not look like an empty success")
        XCTAssertTrue(missing.rows.isEmpty)
        XCTAssertEqual(missing.resolvedCount, 0)
        try makeFixture()
        let restored = Extractor.run(good, limit: 10)
        XCTAssertTrue(restored.isUsable)
        XCTAssertEqual(restored.rows, [["synthetic"]])
    }

    func testCorruptDatabaseFailsVisiblyThenRepairedReadSucceeds() throws {
        try Data("deliberately not a SQLite database".utf8).write(to: source)
        let corrupt = Extractor.run(good, limit: 10)
        XCTAssertFalse(corrupt.isUsable)
        XCTAssertNotNil(corrupt.failure ?? { if case .failed(let m) = corrupt.verdict { return m }; return nil }())
        XCTAssertTrue(corrupt.rows.isEmpty)
        try FileManager.default.removeItem(at: source)
        try makeFixture()
        XCTAssertEqual(Extractor.run(good, limit: 10).rows, [["synthetic"]])
    }

    func testSQLPrepareAndExecutionErrorsAreVisibleAndDoNotPoisonNextRead() throws {
        try makeFixture()
        let prepare = Extractor.run(domain("fixture", sql: "SELECT nonexistent_column FROM items LIMIT {LIMIT}"), limit: 10)
        XCTAssertFalse(prepare.isUsable); XCTAssertNotNil(prepare.failure); XCTAssertTrue(prepare.rows.isEmpty)
        let runtime = Extractor.run(domain("fixture", sql: "SELECT abs(-9223372036854775808) AS value FROM items LIMIT {LIMIT}"), limit: 10)
        XCTAssertFalse(runtime.isUsable, "SQL execution error cannot masquerade as an empty success")
        XCTAssertNotNil(runtime.failure); XCTAssertTrue(runtime.rows.isEmpty)
        XCTAssertEqual(Extractor.run(good, limit: 10).rows, [["synthetic"]])
    }

    @MainActor
    func testModelScanFailureClearsBusyStateAndRetryReplacesIt() async throws {
        try makeFixture()
        let model = DataPageModel(domains: [good])
        model.scan([domain("fixture", sql: "SELECT nonexistent_column FROM items LIMIT {LIMIT}")])
        try await waitUntil("failed scan") { !model.isScanning }
        XCTAssertEqual(model.results[good.id]?.isUsable, false, "failed scan is retained for display")
        model.scan([good])
        try await waitUntil("retry scan") { !model.isScanning }
        XCTAssertEqual(model.results[good.id]?.rows, [["synthetic"]])
    }

    @MainActor
    func testLateObsoleteScanCannotOverwriteNewerResult() async throws {
        let model = DataPageModel(domains: [good])
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        model.limit = 10
        model.scan([good]) { item, _ in
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            defer { finished.signal() }
            return DomainResult(domainID: item.id, columns: ["value"], rows: [["old"]])
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        model.limit = 20
        model.scan([good]) { item, _ in DomainResult(domainID: item.id, columns: ["value"], rows: [["new"]]) }
        try await waitUntil("new scan") { !model.isScanning }
        XCTAssertEqual(model.results[good.id]?.rows, [["new"]])
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        try await Task.sleep(nanoseconds: 200_000_000) // let the old worker hop back to the main actor
        XCTAssertEqual(model.results[good.id]?.rows, [["new"]], "obsolete scan overwrote the newest result")
        XCTAssertFalse(model.isScanning)
    }

    @MainActor
    func testExportWriteFailureIsVisibleAndRetrySucceeds() async throws {
        let registered = DomainRegistry.all[0]
        let model = DataPageModel()
        model.selected = [registered.id]
        model.results[registered.id] = DomainResult(domainID: registered.id, columns: ["value"], rows: [["synthetic"]])
        let blocked = root.appendingPathComponent("destination-is-a-file")
        try Data("synthetic blocker".utf8).write(to: blocked)
        model.performExport(to: blocked)
        XCTAssertTrue(model.exporting, "export runs off the main actor")
        try await waitUntil("failed export") { !model.exporting }
        XCTAssertEqual(model.banner?.kind, .failure)
        XCTAssertNil(model.lastExport)
        model.performExport(to: root)
        try await waitUntil("export retry") { !model.exporting }
        XCTAssertEqual(model.banner?.kind, .info)
        let outcome = try XCTUnwrap(model.lastExport)
        XCTAssertEqual(outcome.files.count, 1)
        let body = try String(contentsOfFile: outcome.directory + "/" + registered.id + ".csv", encoding: .utf8)
        XCTAssertTrue(body.contains("synthetic"))
    }

    func testPartialExportKeepsUsableDomainsAndExplainsSkippedOnes() throws {
        try makeFixture()
        let repaired = Extractor.run(good, limit: 10)
        let failed = domain("failed"), empty = domain("empty"), unscanned = domain("unscanned")
        let domains = [good!, failed, empty, unscanned]
        let results = [good.id: repaired,
                       failed.id: DomainResult(domainID: failed.id, failure: "synthetic failure"),
                       empty.id: DomainResult(domainID: empty.id, columns: ["value"])]
        let partial = try Exporter.export(domains: domains, results: results, format: .csv, masked: false, to: root)
        XCTAssertEqual(partial.files.count, 1)
        XCTAssertEqual(partial.files.first?.name, "fixture.csv")
        XCTAssertEqual(partial.skipped.count, 3)
        for id in [failed.id, empty.id, unscanned.id] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.directory + "/" + id + ".csv"), "skipped \(id) wrote a fake file")
        }
        let manifest = try String(contentsOfFile: partial.directory + "/导出说明.md", encoding: .utf8)
        XCTAssertTrue(manifest.contains("synthetic failure") && manifest.contains("读到 0 条") && manifest.contains("尚未扫描"))
        let repeated = try Exporter.export(domains: domains, results: [:], format: .csv, masked: false, to: root)
        XCTAssertNotEqual(repeated.directory, partial.directory)
        XCTAssertTrue(repeated.files.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repeated.directory + "/fixture.csv"), "retry exposed stale data")
    }
}
