import Combine
import XCTest
@testable import notifhub

final class DataWatchTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notihub-watch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("NOTIFHUB_DATA_DIR")
        unsetenv("NOTIFHUB_CONFIG")
        try? FileManager.default.removeItem(at: dir)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("超时：\(what)")
    }

    private func settle(_ seconds: TimeInterval = 0.4) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func append(_ url: URL, _ text: String) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        h.write(Data(text.utf8))
        try h.close()
    }

    func testWatcherSurvivesInPlaceWriteAtomicSaveRenameAndRecreate() throws {
        let file = dir.appendingPathComponent("rules.json")
        try Data("{}".utf8).write(to: file)
        let count = Counter()
        let watcher = try XCTUnwrap(DataWatcher(dirs: [dir], files: [file], debounce: 0.05, onChange: { count.bump() }))
        try withExtendedLifetime(watcher) {
            var before = count.value
            XCTAssertNoThrow(try append(file, " "))
            waitFor("原地写") { count.value > before }

            before = count.value
            XCTAssertNoThrow(try Data("{\"a\":1}".utf8).write(to: file, options: .atomic))
            waitFor("原子保存") { count.value > before }
            settle()
            before = count.value
            XCTAssertNoThrow(try append(file, " "))
            waitFor("原子保存后重挂到新 inode") { count.value > before }

            settle()
            before = count.value
            let moved = dir.appendingPathComponent("rules.json.bak")
            XCTAssertNoThrow(try FileManager.default.moveItem(at: file, to: moved))
            waitFor("改名") { count.value > before }

            settle()
            try? FileManager.default.removeItem(at: moved)
            settle()
            before = count.value
            XCTAssertNoThrow(try Data("{}".utf8).write(to: file))
            waitFor("删除后重建") { count.value > before }
            settle()
            before = count.value
            XCTAssertNoThrow(try append(file, " "))
            waitFor("重建后的原地写") { count.value > before }
        }
    }

    func testWatcherReportsLostDataDirectory() throws {
        let lost = Counter()
        let watcher = try XCTUnwrap(DataWatcher(dirs: [dir], files: [], debounce: 0.05, onChange: {}, onLost: { lost.bump() }))
        try withExtendedLifetime(watcher) {
            XCTAssertNoThrow(try FileManager.default.moveItem(at: dir, to: dir.appendingPathExtension("moved")))
            waitFor("数据目录被移走") { lost.value == 1 }
        }
        try? FileManager.default.removeItem(at: dir.appendingPathExtension("moved"))
        XCTAssertNil(DataWatcher(dirs: [dir], files: [], onChange: {}), "目录不存在时不能假装在监视")
    }

    func testFingerprintIgnoresOwnReadsAndUnrelatedWritesButSeesTodayChanges() throws {
        setenv("NOTIFHUB_DATA_DIR", dir.path, 1)
        setenv("NOTIFHUB_CONFIG", dir.appendingPathComponent("rules.json").path, 1)
        let rules = dir.appendingPathComponent("rules.json")
        let probe = TodayProbe()
        func fp() throws -> DayFingerprint { try XCTUnwrap(probe.fingerprint(dbPath: Paths.db.path, rulesURL: rules)) }

        let missing = try fp()
        XCTAssertFalse(missing.hasDatabase)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.db.path), "算指纹不能把空库建出来")

        let writer = try XCTUnwrap(Store())
        func run(_ sql: String, _ binds: [Any?]) { XCTAssertTrue(writer.db.run(sql, binds)) }
        run("INSERT INTO events (ts,source,bundle,canon,app,title,body,rec_id,dedup_key) VALUES (?,?,?,?,?,?,?,?,?)",
            [nowUnix(), "fixture", "fixture", "fixture", "Fixture", "Hello", "World", 1, "a"])
        let base = try fp()
        XCTAssertEqual(base.day, Recap.today(), "指纹的划天必须与读库用的 Recap.today() 一致")
        XCTAssertNotEqual(base, missing)
        XCTAssertEqual(base.events[0], 1)

        _ = TodayModel.load(includeAll: false)
        XCTAssertEqual(try fp(), base, "自己读库不能改变指纹，否则会自己吵醒自己")

        run("INSERT INTO state(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", ["fixture.watermark", "1"])
        run("INSERT INTO events (ts,source,bundle,canon,app,title,body,rec_id,dedup_key) VALUES (?,?,?,?,?,?,?,?,?)",
            [nowUnix() - 3 * 86_400, "fixture", "fixture", "fixture", "Fixture", "Old", "Old", 9, "old"])
        XCTAssertEqual(try fp(), base, "与今天无关的写入不该触发重读")

        run("INSERT INTO events (ts,source,bundle,canon,app,title,body,rec_id,dedup_key) VALUES (?,?,?,?,?,?,?,?,?)",
            [nowUnix(), "fixture", "fixture", "fixture", "Fixture", "Hi", "Again", 2, "b"])
        let added = try fp()
        XCTAssertNotEqual(added, base)
        run("UPDATE events SET dismissed_at=? WHERE rec_id=1", [nowUnix()])
        let dismissed = try fp()
        XCTAssertNotEqual(dismissed, added)
        run("INSERT INTO notes(ts,date,text) VALUES(?,?,?)", [nowUnix(), Recap.today(), "note"])
        let noted = try fp()
        XCTAssertNotEqual(noted, dismissed)
        try Data("{}".utf8).write(to: rules)
        XCTAssertNotEqual(try fp(), noted)
    }

    func testUtcMidnightMatchesFoundation() throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        var t = try XCTUnwrap(f.date(from: "1999-12-25")).timeIntervalSince1970
        while t < 1_900_000_000 {   // 覆盖闰年 2 月 29 日、世纪年 2000、年末年初
            let day = f.string(from: Date(timeIntervalSince1970: t))
            XCTAssertEqual(TodayProbe.utcMidnight(day), t, day)
            t += 86_400 * 7
        }
        XCTAssertEqual(TodayProbe.utcMidnight("2028-02-29"), try XCTUnwrap(f.date(from: "2028-02-29")).timeIntervalSince1970)
        XCTAssertNil(TodayProbe.utcMidnight("not-a-day"))
    }

    func testDayRangePrefilterMatchesSqlDay() throws {
        setenv("NOTIFHUB_DATA_DIR", dir.path, 1)
        let store = try XCTUnwrap(Store())
        let now = nowUnix()
        for h in stride(from: -72, through: 72, by: 1) {
            XCTAssertTrue(store.db.run("INSERT INTO events (ts,source,bundle,canon,app,title,body,rec_id,dedup_key) VALUES (?,?,?,?,?,?,?,?,?)",
                                       [now + Double(h) * 3600, "fixture", "fixture", "fixture", "Fixture", "T", "B", h, "h\(h)"]))
        }
        for offset in -2...2 {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = Clock.tz
            let day = f.string(from: Date(timeIntervalSince1970: now + Double(offset) * 86_400))
            var expected: [Int64] = []
            store.db.query("SELECT id FROM events WHERE \(Clock.sqlDay("ts")) = ? ORDER BY ts DESC", [day]) { expected.append($0.int(0)) }
            let got = store.feed(date: day, muteFilter: { _, _ in false }).rows.map(\.id)
            XCTAssertEqual(got, expected, day)
            XCTAssertFalse(expected.isEmpty, day)
        }
    }

    @MainActor
    func testModelReloadsOnlyOnWritesAndBadgeOnlyOnUnreadChange() throws {
        setenv("NOTIFHUB_DATA_DIR", dir.path, 1)
        setenv("NOTIFHUB_CONFIG", dir.appendingPathComponent("rules.json").path, 1)
        let writer = try XCTUnwrap(Store())   // 模拟 daemon：一直开着的写连接
        func insert(_ key: String, recID: Int?) {
            XCTAssertTrue(writer.db.run("INSERT INTO events (ts,source,bundle,canon,app,title,body,rec_id,dedup_key) VALUES (?,?,?,?,?,?,?,?,?)",
                                        [nowUnix(), "fixture", "fixture", "fixture", "Fixture", "T", "B", recID, key]))
        }
        insert("one", recID: 1)

        let model = TodayModel(startAutomatically: true, eventReloadGap: 0.2)
        var badgeChanges = 0
        let sub = model.badge.objectWillChange.sink { badgeChanges += 1 }
        defer { sub.cancel() }

        waitFor("首次读取") { model.badge.unread == 1 && !model.loading }
        settle(1.0)
        let loadsAfterStart = model.loadCount
        let badgeAfterStart = badgeChanges

        settle(1.5)
        XCTAssertEqual(model.loadCount, loadsAfterStart, "空闲时不该重读")

        XCTAssertTrue(writer.db.run("INSERT INTO state(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", ["fixture.watermark", "1"]))
        settle(2.0)
        XCTAssertEqual(model.loadCount, loadsAfterStart, "与今天无关的写入不该重读")

        insert("two", recID: 2)
        waitFor("写入后徽标更新") { model.badge.unread == 2 }
        XCTAssertGreaterThan(badgeChanges, badgeAfterStart)

        settle(1.0)
        let loads = model.loadCount
        let badgeBefore = badgeChanges
        XCTAssertTrue(writer.db.run("INSERT INTO notes(ts,date,text) VALUES(?,?,?)", [nowUnix(), Recap.today(), "note"]))
        waitFor("随手记写入后重读") { model.loadCount > loads && model.snap.notes == 1 }
        settle(0.5)
        XCTAssertEqual(badgeChanges, badgeBefore, "未读数没变，菜单栏不该重绘")
        XCTAssertEqual(model.badge.unread, 2)
    }

    @MainActor
    func testEventReloadsAreSpacedByGapAndNothingIsLost() throws {
        setenv("NOTIFHUB_DATA_DIR", dir.path, 1)
        setenv("NOTIFHUB_CONFIG", dir.appendingPathComponent("rules.json").path, 1)
        let writer = try XCTUnwrap(Store())
        func insert(_ key: String) {
            XCTAssertTrue(writer.db.run("INSERT INTO events (ts,source,bundle,canon,app,title,body,rec_id,dedup_key) VALUES (?,?,?,?,?,?,?,?,?)",
                                        [nowUnix(), "fixture", "fixture", "fixture", "Fixture", "T", "B", 1, key]))
        }
        insert("a")
        let model = TodayModel(startAutomatically: true, eventReloadGap: 4)
        waitFor("首次读取") { model.badge.unread == 1 && !model.loading }
        settle(1.0)

        insert("b")
        waitFor("第一条立即读到") { model.badge.unread == 2 }
        let afterFirst = model.loadCount

        settle(0.3)
        insert("c")
        settle(0.3)
        insert("d")
        settle(2.0)
        XCTAssertEqual(model.loadCount, afterFirst, "间隔内不该再重读")
        XCTAssertEqual(model.badge.unread, 2)
        waitFor("间隔到了补读，合并成一次", timeout: 6) { model.badge.unread == 4 }
        settle(1.5)
        XCTAssertEqual(model.loadCount, afterFirst + 1, "两条写入合并成一次重读")

        insert("e")
        model.refresh()
        waitFor("手动刷新立即生效") { model.badge.unread == 5 }
    }

    func testNextDayStartUsesGivenTimeZone() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T15:59:30Z"))
        let next = try XCTUnwrap(TodayModel.nextDayStart(after: now, in: tz))
        XCTAssertEqual(next, try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-25T16:00:01Z")))
    }
}
