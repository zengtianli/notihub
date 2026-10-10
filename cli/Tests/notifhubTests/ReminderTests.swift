import XCTest
@testable import notifhub

final class ReminderTests: XCTestCase {
    var root: URL!
    var previous: [String: String?] = [:]
    var savedSilent = false
    let date = "2026-10-07"
    let item: [String: Any] = ["id": 7, "kind": "todo", "title": "示例待办", "srcDate": "2026-10-06", "dueTS": 1_791_388_800.0, "extra": "kept"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("notihub-reminders-\(UUID().uuidString)")
        _ = try DataFixture.build(at: root)
        let vars = ["NOTIHUB_DATA_HOME": root.path, "NOTIFHUB_DATA_DIR": root.appendingPathComponent("data").path,
                    "NOTIFHUB_CONFIG": root.appendingPathComponent("no-rules.json").path,
                    "NOTIHUB_CLOUD_CONFIG": root.appendingPathComponent("no-cloud.json").path]
        for (key, value) in vars { previous[key] = ProcessInfo.processInfo.environment[key]; setenv(key, value, 1) }
        savedSilent = Log.silent; Log.silent = true
    }

    override func tearDownWithError() throws {
        for (key, value) in previous { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
        Log.silent = savedSilent
        try FileManager.default.removeItem(at: root)
    }

    func store(_ name: String = "Data-AAAA.sqlite") -> URL {
        root.appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores/\(name)")
    }
    func sql(_ sql: String, name: String = "Data-AAAA.sqlite") throws {
        let (rc, error) = notifhub.run("/usr/bin/sqlite3", [store(name).path, sql], stderrToo: true)
        XCTAssertEqual(rc, 0, error)
    }
    func command(_ args: [String]) throws -> (Int32, Any) {
        let bin = ProcessInfo.processInfo.environment["NOTIHUB_TEST_BIN"]
            ?? Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("notifhub").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bin), "isolated CLI binary not found: \(bin)")
        let (rc, out) = notifhub.run(bin, args, env: ["HOME": root.path], timeout: 20)
        return (rc, try JSONSerialization.jsonObject(with: Data(out.utf8)))
    }
    func payload(_ items: [[String: Any]]? = nil) -> [String: Any] { ["items": items ?? [item], "generatedAt": 123, "extraField": "kept"] }
    func insert(_ id: Int, due: Double?, completion: Double?, completed: Bool, deleted: Bool = false, name: String = "Data-AAAA.sqlite", notes: String = "") throws {
        let dueSQL = due.map { String($0 - appleEpoch) } ?? "NULL"
        let completedSQL = completion.map { String($0 - appleEpoch) } ?? "NULL"
        let escaped = notes.replacingOccurrences(of: "'", with: "''")
        try sql("INSERT INTO ZREMCDREMINDER VALUES(\(id),'row-\(id)',1,\(completed ? 1 : 0),\(dueSQL),1,'\(escaped)',\(deleted ? 1 : 0),\(completedSQL));", name: name)
    }
    func bounds() throws -> (Double, Double) {
        let f = Extractor.timeFormatter("yyyy-MM-dd")
        let start = try XCTUnwrap(f.date(from: date))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Clock.tz
        return (start.timeIntervalSince1970, try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: start)).timeIntervalSince1970)
    }

    func testKeyMatchesPhoneAndIgnoresID() throws {
        XCTAssertEqual(try LocalReminders.key(for: item), "b4fa7df0f97b98d2")
        var changed = item; changed["id"] = 900
        XCTAssertEqual(try LocalReminders.key(for: item), try LocalReminders.key(for: changed))
        changed["dueTS"] = NSNull(); changed["srcDate"] = NSNull()
        XCTAssertEqual(try LocalReminders.key(for: changed), String("todo|示例待办||".sha256().prefix(16)))
        changed["dueTS"] = "invalid"
        XCTAssertThrowsError(try LocalReminders.key(for: changed))
    }

    func testMarkerUsesOnlyLastNonemptyLine() {
        XCTAssertEqual(LocalReminders.marker(in: "原文\n  notihub:agenda/abc  \n"), "abc")
        XCTAssertNil(LocalReminders.marker(in: "notihub:agenda/abc\n普通末行"))
        XCTAssertNil(LocalReminders.marker(in: "notihub:agenda/"))
        XCTAssertNil(LocalReminders.marker(in: "正文中 notihub:agenda/abc"))
    }

    func testMalformedCloudItemsFailBeforeLookup() throws {
        XCTAssertThrowsError(try LocalReminders.key(for: ["id": 7, "title": "x"]))
        var missing: [String: Any] = ["items": "invalid"]
        XCTAssertThrowsError(try LocalReminders.addPresence(to: &missing))
    }

    func testDayUsesClockIgnoresProcessTZAndHandlesDST() throws {
        let oldTZ = ProcessInfo.processInfo.environment["TZ"]
        let oldClock = ProcessInfo.processInfo.environment["NOTIFHUB_TZ"]
        defer {
            if let oldTZ { setenv("TZ", oldTZ, 1) } else { unsetenv("TZ") }
            if let oldClock { setenv("NOTIFHUB_TZ", oldClock, 1) } else { unsetenv("NOTIFHUB_TZ") }
        }
        setenv("NOTIFHUB_TZ", "America/Los_Angeles", 1)
        setenv("TZ", "Asia/Tokyo", 1)
        let f = Extractor.timeFormatter("yyyy-MM-dd")
        let start = try XCTUnwrap(f.date(from: "2026-03-08")).timeIntervalSince1970
        try insert(2, due: start, completion: nil, completed: false)
        try insert(3, due: start + 23 * 3600 - 1, completion: nil, completed: false)
        try insert(4, due: start + 23 * 3600, completion: nil, completed: false)
        let (rc, value) = try command(["data", "reminders", "--date", "2026-03-08", "--json"])
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(Set((value as? [[String: String]] ?? []).compactMap { $0["标题"] }), ["row-2", "row-3"])
        setenv("TZ", "UTC", 1)
        let (_, same) = try command(["data", "reminders", "--date", "2026-03-08", "--json"])
        XCTAssertEqual(value as? [[String: String]], same as? [[String: String]])
    }

    func testPresenceAcrossStoresAndBeyondPreviewLimit() throws {
        let key = try LocalReminders.key(for: item)
        for id in 2...30 { try insert(id, due: nil, completion: nil, completed: false) }
        try insert(31, due: nil, completion: 1_790_000_000, completed: true, name: "Data-BBBB.sqlite", notes: "备注\nnotihub:agenda/\(key)")
        let before = try Data(contentsOf: store("Data-BBBB.sqlite"))
        var other = item; other["title"] = "另一条"
        var p = payload([item, other]); try LocalReminders.addPresence(to: &p)
        let rows = try XCTUnwrap(p["items"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["inReminders"] as? Bool }, [true, false])
        XCTAssertEqual(rows[0]["reminderKey"] as? String, key)
        XCTAssertEqual(rows[0]["extra"] as? String, "kept")
        XCTAssertEqual(p["extraField"] as? String, "kept")
        XCTAssertEqual(p["reminderScope"] as? String, LocalReminders.scope)
        XCTAssertEqual(before, try Data(contentsOf: store("Data-BBBB.sqlite")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store("Data-BBBB.sqlite").path + "-shm"))
    }

    func testDeletedMarkerDoesNotMatch() throws {
        try insert(2, due: nil, completion: nil, completed: false, deleted: true, notes: LocalReminders.notePrefix + (try LocalReminders.key(for: item)))
        var p = payload(); try LocalReminders.addPresence(to: &p)
        XCTAssertEqual((p["items"] as? [[String: Any]])?.first?["inReminders"] as? Bool, false)
    }

    func testDaySelectionCompletionColumnAndLimits() throws {
        let (a, b) = try bounds()
        try insert(2, due: a, completion: nil, completed: false)
        try insert(3, due: b - 1, completion: nil, completed: false)
        try insert(4, due: b, completion: nil, completed: false)
        try insert(5, due: a - 1, completion: nil, completed: false)
        try insert(6, due: a - 86400, completion: a, completed: true, name: "Data-BBBB.sqlite")
        try insert(7, due: nil, completion: b - 1, completed: true)
        try insert(8, due: a, completion: b, completed: true)
        try insert(9, due: a, completion: a - 1, completed: true)
        try insert(10, due: nil, completion: nil, completed: false)
        try insert(11, due: a, completion: nil, completed: true)
        try insert(12, due: a, completion: nil, completed: false, deleted: true)
        let (rc, json) = try command(["data", "reminders", "--date", date, "--json"])
        let rows = try XCTUnwrap(json as? [[String: String]])
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(Set(rows.compactMap { $0["标题"] }), ["row-2", "row-3", "row-6", "row-7"])
        XCTAssertEqual(rows.first { $0["标题"] == "row-6" }?["完成时间"], fmtTime(a))
        XCTAssertEqual(rows.first { $0["标题"] == "row-2" }?["完成时间"], "")
        XCTAssertEqual(rows.first?.count, 7)
        let (_, limited) = try command(["data", "reminders", "--date", date, "--limit", "1", "--json"])
        XCTAssertEqual((limited as? [Any])?.count, 1)
    }

    func testDatedQueryDoesNotCapAtTwenty() throws {
        let (a, _) = try bounds()
        for id in 2...31 { try insert(id, due: a, completion: nil, completed: false) }
        let (rc, dated) = try command(["data", "reminders", "--date", date, "--json"])
        XCTAssertEqual(rc, 0); XCTAssertEqual((dated as? [Any])?.count, 30)
        let (_, preview) = try command(["data", "reminders", "--json"])
        XCTAssertEqual((preview as? [Any])?.count, 20)
    }

    func testInvalidDateAndArgumentsHaveJSONUsageErrors() throws {
        for args in [["--date", "2026-02-30"], ["--date", "2026-13-01"], ["--date"], ["--bogus"], ["--limit", "0"], ["--limit", "x"], ["extra"], ["--csv"]] {
            let (rc, value) = try command(["data", "reminders", "--json"] + args)
            let error = try XCTUnwrap(value as? [String: Any])
            XCTAssertEqual(rc, 64, args.description)
            XCTAssertEqual(error["ok"] as? Bool, false)
            XCTAssertEqual(error["usageError"] as? Bool, true)
            XCTAssertNotNil(error["error"] as? String)
        }
    }

    func testEmptyDayReturnsArray() throws {
        let (rc, value) = try command(["data", "reminders", "--date", "2002-01-01", "--json"])
        XCTAssertEqual(rc, 0); XCTAssertEqual((value as? [Any])?.count, 0)
    }

    func testUnreadableStoreFailsInsteadOfReportingAbsence() throws {
        try Data(repeating: 0x5a, count: 4096).write(to: store("Data-BBBB.sqlite"))
        var p = payload(); XCTAssertThrowsError(try LocalReminders.addPresence(to: &p))
        let (rc, value) = try command(["data", "reminders", "--date", date, "--json"])
        let error = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(rc, 1); XCTAssertEqual(error["ok"] as? Bool, false)
        XCTAssertNotNil(error["error"] as? String)
    }

    func testCloudOpenUsesSameLookupAndPreservesFields() throws {
        try insert(2, due: nil, completion: nil, completed: false, notes: LocalReminders.notePrefix + (try LocalReminders.key(for: item)))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SelfTestCloudStub.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let client = CloudClient(connection: CloudConnection(id: "personal", url: URL(string: "https://fixture.invalid")!, token: String(repeating: "f", count: 40)), session: session)
        let data = try JSONSerialization.data(withJSONObject: payload())
        SelfTestCloudStub.reset { _, _, _ in (200, String(decoding: data, as: UTF8.self)) }
        let plan = try CloudCLI.parse(["open", "--json"]).get()
        let result = try blockingAwait { await CloudCLI.perform(plan, client: client) }.get()
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual((result.json["items"] as? [[String: Any]])?.first?["inReminders"] as? Bool, true)
        XCTAssertEqual(result.json["generatedAt"] as? Int, 123)
        XCTAssertEqual(SelfTestCloudStub.seen.map(\.method), ["GET"])
        try Data(repeating: 0x5a, count: 4096).write(to: store())
        let failed = try blockingAwait { await CloudCLI.perform(plan, client: client) }.get()
        XCTAssertEqual(failed.code, 1); XCTAssertEqual(failed.json["ok"] as? Bool, false)
        XCTAssertEqual(failed.json["errorCode"] as? String, "reminders_unreadable")
        let textPlan = try CloudCLI.parse(["open"]).get()
        let text = try blockingAwait { await CloudCLI.perform(textPlan, client: client) }.get()
        XCTAssertEqual(text.code, 0)
        XCTAssertNil((text.json["items"] as? [[String: Any]])?.first?["inReminders"])
    }

    func testNoPermissionDoesNotPromptAndKeepsExistingExitCode() throws {
        let reminders = root.appendingPathComponent("Library/Group Containers/group.com.apple.reminders")
        let safari = root.appendingPathComponent("Library/Safari")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: reminders.path)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: safari.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: reminders.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: safari.path)
        }
        let (rc, value) = try command(["data", "reminders", "--json"])
        XCTAssertEqual(rc, 2); XCTAssertEqual((value as? [String: Any])?["ok"] as? Bool, false)
        var p = payload()
        do { try LocalReminders.addPresence(to: &p); XCTFail("denied source must fail") }
        catch let error as LocalReminders.Failure { XCTAssertEqual(error.code, 2) }
    }
}
