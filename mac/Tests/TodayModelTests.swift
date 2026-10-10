import XCTest
@testable import notifhub

final class TodayModelTests: XCTestCase {
    @MainActor
    func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for model")
    }

    @MainActor
    func testFilterChangeDuringRefreshIsNotLost() async throws {
        let began = expectation(description: "background read started")
        let gate = DispatchSemaphore(value: 0)
        var calls = 0
        let model = TodayModel(startAutomatically: false, loader: { includeAll in
            calls += 1
            if calls == 1 { began.fulfill(); _ = gate.wait(timeout: .now() + 2) }
            var snap = DaySnapshot(date: "test")
            snap.total = includeAll ? 2 : 1
            return snap
        })
        model.refresh()
        await fulfillment(of: [began], timeout: 2)
        model.includeAll = true
        gate.signal()
        try await waitUntil { !model.loading }
        XCTAssertEqual(model.snap.total, 2)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testWriteDoesNotBlockMainActorAndRefreshesAfterCompletion() async throws {
        let began = expectation(description: "background write started")
        let gate = DispatchSemaphore(value: 0)
        var unread = true
        let row = FeedRow(id: 1, ts: 1, canon: "test", app: "test", who: "test", text: "", redacted: false, unread: true)
        let model = TodayModel(startAutomatically: false, loader: { _ in
            var snap = DaySnapshot(date: "test")
            snap.unread = unread ? 1 : 0
            return snap
        }, writer: { ids in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(ids, [1])
            began.fulfill()
            _ = gate.wait(timeout: .now() + 2)
            unread = false
        })
        model.markRead([row])
        await fulfillment(of: [began], timeout: 2)
        XCTAssertTrue(model.writing)
        model.refresh()
        gate.signal()
        try await waitUntil { !model.writing && !model.loading }
        XCTAssertEqual(model.snap.unread, 0)
    }

    @MainActor
    func testWriteAndRecapErrorsReachUI() async throws {
        let error = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture failure"])
        let model = TodayModel(startAutomatically: false, loader: { _ in DaySnapshot(date: "test") }, writer: { _ in throw error }, recap: { _ in throw error })
        model.markRead([FeedRow(id: 1, ts: 1, canon: "test", app: "test", who: "test", text: "", redacted: false, unread: true)])
        try await waitUntil { !model.writing && !model.loading }
        XCTAssertTrue(model.actionProblem?.contains("fixture failure") == true)
        model.openFullRecap()
        try await waitUntil { !model.openingRecap }
        XCTAssertTrue(model.actionProblem?.contains("完整复盘失败") == true)
    }

    @MainActor
    func testBrowserOpenFailureIsVisible() async throws {
        let model = TodayModel(startAutomatically: false, recap: { _ in URL(fileURLWithPath: "/fixture.html") }, opener: { _ in false })
        model.openFullRecap()
        try await waitUntil { !model.openingRecap }
        XCTAssertTrue(model.actionProblem?.contains("无法打开") == true)
    }

    @MainActor
    func testDefaultRecapOpensHTTPSWithoutCreatingLocalFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["NOTIFHUB_DATA_DIR"]
        setenv("NOTIFHUB_DATA_DIR", dir.path, 1)
        defer {
            if let previous { setenv("NOTIFHUB_DATA_DIR", previous, 1) }
            else { unsetenv("NOTIFHUB_DATA_DIR") }
        }
        var opened: URL?
        let model = TodayModel(startAutomatically: false, opener: { opened = $0; return true })
        model.openFullRecap()
        try await waitUntil { !model.openingRecap }
        XCTAssertEqual(opened?.absoluteString, Publish.siteURL)
        XCTAssertEqual(opened?.scheme, "https")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertNil(model.actionProblem)
    }

    func testFullRecapPreservesMailParagraphsAndHidesTrackingURL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["NOTIFHUB_DATA_DIR"]
        setenv("NOTIFHUB_DATA_DIR", dir.path, 1)
        defer {
            if let previous { setenv("NOTIFHUB_DATA_DIR", previous, 1) }
            else { unsetenv("NOTIFHUB_DATA_DIR") }
        }
        let store = try XCTUnwrap(Store())
        let address = "https://example.com/path?tracking=" + String(repeating: "x", count: 300)
        let body = "第一段\n\n第二段\n" + address
        XCTAssertTrue(store.db.run("INSERT INTO events (ts,source,bundle,canon,app,title,body,dedup_key) VALUES (?,?,?,?,?,?,?,?)", [nowUnix(), "mail", "com.apple.mail", "mail", "邮件", "邮件测试", body, "mail-render"]))
        let url = try TodayModel.renderRecap(true)
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("white-space:pre-wrap"))
        XCTAssertTrue(html.contains("第一段\n\n第二段"))
        XCTAssertTrue(html.contains(">example.com</a>"))
        XCTAssertTrue(Recap.renderLine("https://example.com/path。正文不能吞掉", mail: true).hasSuffix("</a>。正文不能吞掉"))
        XCTAssertTrue(html.contains("href=\"\(address)\""))
        XCTAssertFalse(html.contains(">\(address)</a>"))
        XCTAssertEqual(Recap.renderLine("a < b\n<script>x</script>", mail: false), "a &lt; b\n&lt;script&gt;x&lt;/script&gt;")
    }

    func testRealDatabaseReadWriteAndMissingStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("NOTIFHUB_DATA_DIR", dir.path, 1)
        defer { unsetenv("NOTIFHUB_DATA_DIR") }
        XCTAssertThrowsError(try TodayModel.writeRead([1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        let store = try XCTUnwrap(Store())
        XCTAssertTrue(store.db.run("INSERT INTO events (ts,source,bundle,canon,app,title,body,rec_id,dedup_key) VALUES (?,?,?,?,?,?,?,?,?)", [nowUnix(), "fixture", "fixture", "fixture", "Fixture", "Hello", "World", 1, "fixture"]))
        let snap = TodayModel.load(includeAll: true)
        XCTAssertEqual(snap.unread, 1)
        try TodayModel.writeRead(snap.groups.flatMap(\.rows).map(\.id))
        XCTAssertEqual(TodayModel.load(includeAll: true).unread, 0)
        XCTAssertEqual(try store.markRead(ids: [1]), 0)
        XCTAssertTrue(store.db.exec("DROP TABLE events"))
        XCTAssertThrowsError(try store.markRead(ids: [1]))
    }
}
