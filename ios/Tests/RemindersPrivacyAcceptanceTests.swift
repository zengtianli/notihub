import XCTest
import Foundation
@testable import DayDeckCore

private final class ReminderPrivacyProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    static var recorded: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); requests = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class RemindersPrivacyAcceptanceTests: XCTestCase {
    private typealias F = ReminderFixture
    private var api: API!
    private var session: URLSession!
    private var directory: URL!
    private var argumentDomain: [String: Any] = [:]
    private let secretTitle = "合成隐私哨兵-提醒标题-7c1e"
    private let secretNote = "合成隐私哨兵-提醒备注-7c1e"

    override func setUpWithError() throws {
        argumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        setDemo(false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("daydeck-reminders-privacy-\(UUID())")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReminderPrivacyProtocol.self]
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
        api = API(session: session, cacheDirectory: directory)
        URLProtocol.registerClass(ReminderPrivacyProtocol.self)
        ReminderPrivacyProtocol.reset()
    }
    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(ReminderPrivacyProtocol.self)
        session.invalidateAndCancel()
        UserDefaults.standard.setVolatileDomain(argumentDomain, forName: UserDefaults.argumentDomain)
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
    private func setDemo(_ enabled: Bool) {
        var domain = argumentDomain
        domain["demo"] = enabled
        domain["gatepw"] = ""
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    private func defaultsText() -> String {
        var domains: [[String: Any]] = [UserDefaults.standard.dictionaryRepresentation()]
        for name in [Bundle.main.bundleIdentifier, "cyou.tianli.daydeck"].compactMap({ $0 }) {
            if let persistent = UserDefaults.standard.persistentDomain(forName: name) { domains.append(persistent) }
            if let suite = UserDefaults(suiteName: name) { domains.append(suite.dictionaryRepresentation()) }
        }
        return domains.map { "\($0)" }.joined(separator: "\n")
    }

    private func cacheFilesContaining(_ needle: String) throws -> [String] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var hits: [String] = []
        for case let file as URL in walker {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let data = try Data(contentsOf: file)
            if data.range(of: Data(needle.utf8)) != nil || file.lastPathComponent.contains(needle) {
                hits.append(file.lastPathComponent)
            }
        }
        return hits
    }

    @MainActor
    func testReadAndAddMakeNoRequestsAndLeaveNoTrace() async throws {
        let before = defaultsText()
        XCTAssertFalse(before.contains(secretTitle), "fixture must start clean")
        let cloudStore = Store(api: api)  // 生产 Store 与 API 共用这份隔离缓存目录
        let fake = ReminderTestStore(auth: .notDetermined, grantOnRequest: true)
        fake.seed(title: secretTitle, notes: secretNote, due: F.zoned(F.at("2026-09-08T09:00:00+08:00")))
        let model = RemindersModel(store: fake)

        await model.load(date: "2026-09-08", calendar: cloudStore.dayCalendar)
        await model.requestAccess()
        guard case .loaded(let rows) = model.sections["2026-09-08"] else { return XCTFail("expected loaded") }
        XCTAssertTrue(rows.contains { $0.title == secretTitle })

        let agenda = F.agenda(title: secretTitle + "-待办", note: secretNote)
        let added = await model.add(agenda, savedListID: nil, timezone: cloudStore.cloudTimezone)
        XCTAssertEqual(added, .added("合成收件箱"))
        let dup = await model.add(agenda, savedListID: nil, timezone: cloudStore.cloudTimezone)
        XCTAssertEqual(dup, .alreadyThere("合成收件箱"))
        _ = await ReminderAdder.add(agenda: F.agenda(title: secretTitle + "-强制", pushed: true), store: fake,
                                    savedListID: "list-work", timezone: cloudStore.cloudTimezone, force: true)
        await model.load(date: "2026-09-08", calendar: cloudStore.dayCalendar, force: true)

        XCTAssertTrue(ReminderPrivacyProtocol.recorded.isEmpty,
                      "reminder flow sent: \(ReminderPrivacyProtocol.recorded.compactMap { $0.url?.absoluteString })")
        XCTAssertEqual(try cacheFilesContaining(secretTitle), [])
        XCTAssertEqual(try cacheFilesContaining(secretNote), [])
        let after = defaultsText()
        XCTAssertFalse(after.contains(secretTitle))
        XCTAssertFalse(after.contains(secretNote))
        XCTAssertFalse(after.contains("notihub:agenda/"))

        _ = await api.fetch(URL(string: "https://day.example.invalid/api/open")!)
        _ = try? await URLSession.shared.data(from: URL(string: "https://example.invalid/probe")!)
        XCTAssertEqual(ReminderPrivacyProtocol.recorded.count, 2)
    }

    #if DEBUG
    @MainActor
    func testDemoFactoryReturnsFakeNotEventKit() throws {
        setDemo(true)
        XCTAssertTrue(DemoData.enabled)
        let demo = makeReminderStore()
        XCTAssertFalse(demo is EventKitReminderStore)
        XCTAssertTrue(demo is DemoReminderStore)
        XCTAssertFalse(demo is ReminderTestStore, "演示 fake 与测试 fake 不共用")
        setDemo(false)
        XCTAssertFalse(DemoData.enabled)
        XCTAssertTrue(makeReminderStore() is EventKitReminderStore)
        XCTAssertTrue(ReminderPrivacyProtocol.recorded.isEmpty)
    }
    #endif
}
