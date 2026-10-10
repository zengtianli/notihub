import XCTest
@testable import notifhub

final class RecoveryAcceptanceTests: XCTestCase {
    @MainActor
    func testMissingStoreIsVisibleAndRefreshRecoversWhenCollectorCreatesDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notifhub-recovery-" + UUID().uuidString)
        let previous = ProcessInfo.processInfo.environment["NOTIFHUB_DATA_DIR"]
        setenv("NOTIFHUB_DATA_DIR", directory.path, 1)
        defer {
            if let previous { setenv("NOTIFHUB_DATA_DIR", previous, 1) }
            else { unsetenv("NOTIFHUB_DATA_DIR") }
            try? FileManager.default.removeItem(at: directory)
        }

        let model = TodayModel(startAutomatically: false)
        model.refresh()
        try await waitUntil { !model.loading }
        XCTAssertTrue(model.snap.problem?.contains("读不到") == true)
        XCTAssertNil(model.refreshedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "A failed read must not manufacture an empty store")

        let store = try XCTUnwrap(Store())
        XCTAssertTrue(store.db.run("INSERT INTO events (ts,source,bundle,canon,app,title,body,rec_id,dedup_key) VALUES (?,?,?,?,?,?,?,?,?)", [nowUnix(), "fixture", "fixture", "fixture", "Fixture", "Recovered", "Synthetic recovery record", 1, "recovery-fixture"]))
        model.refresh()
        try await waitUntil { !model.loading }
        XCTAssertNil(model.snap.problem)
        XCTAssertNotNil(model.refreshedAt)
        XCTAssertEqual(model.snap.total, 1)
        XCTAssertEqual(model.snap.unread, 1)
        XCTAssertEqual(model.badge.unread, 1)
        XCTAssertEqual(model.snap.groups.flatMap(\.rows).first?.text, "Synthetic recovery record")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Recovery refresh did not finish")
    }
}
