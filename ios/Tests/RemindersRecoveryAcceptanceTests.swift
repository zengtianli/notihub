import XCTest
import Foundation
@testable import DayDeckCore

private final class ReminderOfflineProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

final class RemindersRecoveryAcceptanceTests: XCTestCase {
    private typealias F = ReminderFixture
    private var directory: URL!
    private var session: URLSession!
    private var api: API!

    override func setUpWithError() throws {
        guard UserDefaults.standard.string(forKey: "gatepw")?.isEmpty != false else {
            throw NSError(domain: "RemindersRecoveryAcceptance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Run acceptance without a gatepw launch argument."])
        }
        guard !UserDefaults.standard.bool(forKey: "demo") else {
            throw NSError(domain: "RemindersRecoveryAcceptance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Run acceptance without the demo launch argument."])
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("daydeck-reminders-recovery-\(UUID())")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReminderOfflineProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        api = API(session: session, cacheDirectory: directory)
    }

    override func tearDownWithError() throws {
        session?.invalidateAndCancel()
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private struct Boom: LocalizedError {
        let what: String
        var errorDescription: String? { "合成故障：\(what)" }
    }

    @MainActor
    func testCloudFailureWithoutCacheStillShowsTodaysReminders() async throws {
        let store = Store(api: api)
        let beforeRequests = ReminderOfflineProtocol.requests
        await store.refresh()
        XCTAssertGreaterThan(ReminderOfflineProtocol.requests, beforeRequests, "cloud refresh must really have failed")
        XCTAssertTrue(store.index.isEmpty)
        XCTAssertNotNil(store.indexError)
        XCTAssertNil(store.indexAt)
        let date = store.displayToday
        let dayFeed = await store.day(date)
        XCTAssertNil(dayFeed)
        XCTAssertNotNil(store.dayError[date])

        let calendar = store.dayCalendar
        let noon = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        XCTAssertEqual(Store.dayString(noon, timezone: store.cloudTimezone), date)
        let fake = ReminderTestStore()
        let row = fake.seed(title: "合成：云端挂了也要看到", due: F.zoned(noon, store.cloudTimezone))

        let state = await ReminderDay.fetch(date: date, calendar: calendar, store: fake)
        XCTAssertEqual(state, .loaded([row]))
        let model = RemindersModel(store: fake)
        await model.load(date: date, calendar: calendar)
        XCTAssertEqual(model.sections[date], .loaded([row]))
    }

    @MainActor
    func testSaveFailureIsFailedAndNeverShownAsAdded() async throws {
        let fake = ReminderTestStore()
        fake.saveError = Boom(what: "写入被拒")
        let agenda = F.agenda()
        let direct = await ReminderAdder.add(agenda: agenda, store: fake, savedListID: nil, timezone: F.cloud)
        guard case .failed(let reason) = direct.outcome else { return XCTFail("expected failed, got \(direct.outcome)") }
        XCTAssertTrue(reason.contains("合成故障：写入被拒"), reason)
        XCTAssertFalse(direct.outcome.isAdded)
        XCTAssertEqual(fake.saveCalls, 1)
        XCTAssertTrue(fake.rows.isEmpty)

        let model = RemindersModel(store: fake)
        let outcome = await model.add(agenda, savedListID: nil, timezone: F.cloud)
        XCTAssertFalse(outcome.isAdded)
        XCTAssertFalse(model.outcome(for: agenda)?.isAdded ?? false)
        guard case .failed = model.outcome(for: agenda) else { return XCTFail("model must keep the failure") }
        XCTAssertTrue(model.adding.isEmpty)

        fake.saveError = nil
        let retried = await model.add(agenda, savedListID: nil, timezone: F.cloud)
        XCTAssertEqual(retried, .added("合成收件箱"))
        XCTAssertEqual(fake.rows.count, 1)
    }

    @MainActor
    func testFetchFailureIsFailedNotEmptyAndRecovers() async throws {
        let fake = ReminderTestStore()
        let row = fake.seed(title: "合成：读回来的提醒", due: F.zoned(F.at("2026-09-08T09:00:00+08:00")))
        fake.fetchError = Boom(what: "读取中断")

        let state = await ReminderDay.fetch(date: "2026-09-08", calendar: F.cloudCalendar, store: fake)
        guard case .failed(let reason) = state else { return XCTFail("expected failed, got \(state)") }
        XCTAssertNotEqual(state, .empty)
        XCTAssertTrue(reason.contains("合成故障：读取中断"), reason)

        let model = RemindersModel(store: fake)
        await model.load(date: "2026-09-08", calendar: F.cloudCalendar)
        guard case .failed = model.sections["2026-09-08"] else { return XCTFail("model must show failed, not empty") }

        let add = await model.add(F.agenda(), savedListID: nil, timezone: F.cloud)
        guard case .failed = add else { return XCTFail("dedup read failure must be failed, got \(add)") }
        XCTAssertEqual(fake.saveCalls, 0)

        fake.fetchError = nil
        await model.load(date: "2026-09-08", calendar: F.cloudCalendar)
        XCTAssertEqual(model.sections["2026-09-08"], .loaded([row]))
    }
}
