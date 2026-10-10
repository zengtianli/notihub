import XCTest
import Foundation
@testable import DayDeckCore

private final class MockProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((MockProtocol) -> Void)?
    static var requests: [URLRequest] = []
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else { fail(URLError(.notConnectedToInternet)); return }
        handler(self)
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
    func reply(_ data: Data, status: Int = 200) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !stopped else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail(_ error: Error) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !stopped else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }
    static func configure(_ handler: @escaping (MockProtocol) -> Void) {
        lock.lock(); Self.handler = handler; requests = []; lock.unlock()
    }
    static var recorded: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
}

final class CloudContractTests: XCTestCase {
    private var api: API!
    private var session: URLSession!
    private var directory: URL!
    private let date = "2026-09-07"

    override func setUpWithError() throws {
        guard UserDefaults.standard.string(forKey: "gatepw")?.isEmpty != false else {
            throw NSError(domain: "CloudContractAcceptance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Run acceptance without a gatepw launch argument."])
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("daydeck-contract-\(UUID())")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
        api = API(session: session, cacheDirectory: directory)
        MockProtocol.configure { $0.fail(URLError(.notConnectedToInternet)) }
    }
    override func tearDownWithError() throws {
        session?.invalidateAndCancel()
        if let directory { try FileManager.default.removeItem(at: directory) }
    }
    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private func fixture(_ day: String = "2026-09-07", text: String = "cloud fixture") -> Data {
        json(["date": day, "total": 1, "muted": 0, "notes": 0,
              "byHour": Array(repeating: 0, count: 24), "apps": [["邮件", "1"]], "whos": [["sender", "1"]],
              "summary": ["headline": "Summary", "text": "**Kept markdown**", "generatedAt": 1788714000,
                          "html": "<p><strong>Kept markdown</strong></p>"],
              "agenda": [], "items": [["ts": 1788714000, "endTs": 1788714000, "app": "邮件", "who": "sender",
                                        "lines": ["first\nsecond"], "missed": false, "redacted": false]],
              "cloudNotes": [["id": 41, "text": text, "ts": 1788714000, "date": day]]])
    }
    private func body(_ request: URLRequest) -> [String: Any] {
        if let data = request.httpBody { return try! JSONSerialization.jsonObject(with: data) as! [String: Any] }
        guard let stream = request.httpBodyStream else { return [:] }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private func assertSuccess(_ result: Result<Void, FeedError>, file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(let error) = result { XCTFail("Unexpected failure: \(error)", file: file, line: line) }
    }
    private func assertFailure(_ result: Result<Void, FeedError>, file: StaticString = #filePath, line: UInt = #line) {
        if case .success = result { XCTFail("False success", file: file, line: line) }
    }

    func testProductionDecoderReadsCloudNotesAndSummary() throws {
        let day = try api.decode(fixture(), as: FeedDay.self, from: "mock").get()
        XCTAssertEqual(day.cloudNotes.first?.text, "cloud fixture")
        XCTAssertEqual(day.summary?.text, "**Kept markdown**")
        XCTAssertEqual(day.items.first?.lines, ["first\nsecond"])
    }

    func testNoteWireContractAndReceiptValidation() async {
        let receipt = json(["id": 41, "text": "new note", "date": date, "ts": 1788714000])
        MockProtocol.configure { protocolInstance in
            let request = protocolInstance.request
            XCTAssertEqual(request.url?.path, "/api/notes")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://day.example.invalid")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Notifhub-Request"), "1")
            let body = self.body(request)
            XCTAssertEqual(body["idempotencyKey"] as? String, "fixture-request-1")
            XCTAssertEqual(body["date"] as? String, self.date)
            XCTAssertEqual(body["text"] as? String, "new note")
            protocolInstance.reply(receipt)
        }
        assertSuccess(await Writer.note("new note", date: date, idempotencyKey: "fixture-request-1", api: api))
        for response in [
            json(["id": 41, "text": "wrong text", "date": date, "ts": 1788714000]),
            json(["id": 41, "text": "new note", "date": "2026-09-06", "ts": 1788714000]),
            json(["item": ["status": "pending"]])
        ] {
            MockProtocol.configure { $0.reply(response) }
            assertFailure(await Writer.note("new note", date: date, idempotencyKey: "fixture-request-1", api: api))
        }
        MockProtocol.configure { $0.reply(Data("{}".utf8), status: 500) }
        assertFailure(await Writer.note("new note", date: date, idempotencyKey: "fixture-request-1", api: api))
    }

    func testMarkUsesPatchAndRejectsMismatchedReceipt() async {
        MockProtocol.configure {
            XCTAssertEqual($0.request.httpMethod, "PATCH")
            XCTAssertEqual($0.request.url?.path, "/api/agenda/11")
            XCTAssertEqual($0.request.value(forHTTPHeaderField: "Origin"), "https://day.example.invalid")
            XCTAssertEqual($0.request.value(forHTTPHeaderField: "X-Notifhub-Request"), "1")
            XCTAssertEqual(self.body($0.request)["status"] as? String, "done")
            $0.reply(self.json(["id": 11, "status": "done"]))
        }
        assertSuccess(await Writer.mark(11, to: "done", title: "fixture", api: api))
        for receipt in [["id": 12, "status": "done"], ["id": 11, "status": "open"]] as [[String: Any]] {
            MockProtocol.configure { $0.reply(self.json(receipt)) }
            assertFailure(await Writer.mark(11, to: "done", title: "fixture", api: api))
        }
    }

    @MainActor
    func testWarmDayMakesNoRequestAndColdSwitchFetchesOnlyOneDay() async {
        api.cache.write(fixture(), for: "/api/day/" + date)
        let store = Store(api: api)
        let warm = await store.day(date)
        XCTAssertEqual(warm?.date, date)
        XCTAssertTrue(MockProtocol.recorded.isEmpty)
        MockProtocol.configure { $0.reply(self.fixture("2026-09-06")) }
        let cold = await store.day("2026-09-06")
        XCTAssertEqual(cold?.date, "2026-09-06")
        XCTAssertEqual(MockProtocol.recorded.map { $0.url!.path }, ["/api/day/2026-09-06"])
        _ = await store.day("2026-09-06")
        XCTAssertEqual(MockProtocol.recorded.count, 1)
    }

    func testBadJSONAndOfflineKeepLastReadableCacheAndTimestamp() async throws {
        let path = "/api/day/" + date
        api.cache.write(fixture(), for: path)
        let stamp = try XCTUnwrap(api.cache.stamp(path))
        MockProtocol.configure { $0.reply(Data("{\"wrong\":true}".utf8)) }
        let broken = await api.get(path, as: FeedDay.self)
        XCTAssertNotNil(broken.error)
        XCTAssertEqual(broken.value?.cloudNotes.first?.text, "cloud fixture")
        XCTAssertEqual(broken.cachedAt, stamp)
        XCTAssertEqual(api.cache.stamp(path), stamp)
        MockProtocol.configure { $0.fail(URLError(.notConnectedToInternet)) }
        let offline = await api.get(path, as: FeedDay.self)
        XCTAssertNotNil(offline.error)
        XCTAssertEqual(offline.value?.date, date)
        XCTAssertEqual(offline.cachedAt, stamp)
    }

    @MainActor
    func testStoreOfflineErrorIsVisibleAlongsideOldData() async throws {
        api.cache.write(fixture(), for: "/api/day/" + date)
        let stamp = try XCTUnwrap(api.cache.stamp("/api/day/" + date))
        let store = Store(api: api)
        _ = await store.day(date, force: true)
        XCTAssertEqual(store.days[date]?.cloudNotes.first?.text, "cloud fixture")
        XCTAssertNotNil(store.dayError[date])
        XCTAssertEqual(store.dayAt[date], stamp)
    }

    @MainActor
    func testForceCancelsOldRequestAndCannotOverwriteNewValueOrDisk() async throws {
        let started = expectation(description: "first request started")
        let responseLock = NSLock()
        var old: MockProtocol?
        var number = 0
        MockProtocol.configure { instance in
            responseLock.lock(); number += 1; let current = number
            if current == 1 { old = instance }; responseLock.unlock()
            if current == 1 { started.fulfill() } else { instance.reply(self.fixture(text: "new response")) }
        }
        let store = Store(api: api)
        let first = Task { await store.day(date, force: true) }
        await fulfillment(of: [started], timeout: 2)
        let newest = await store.day(date, force: true)
        XCTAssertEqual(newest?.cloudNotes.first?.text, "new response")
        old?.reply(fixture(text: "stale response"))
        _ = await first.value
        XCTAssertEqual(store.days[date]?.cloudNotes.first?.text, "new response")
        XCTAssertNil(store.dayError[date])
        XCTAssertEqual(api.cache.load("/api/day/" + date, as: FeedDay.self, api: api)?.0.cloudNotes.first?.text, "new response")
        XCTAssertEqual(MockProtocol.recorded.count, 2)
    }

    @MainActor
    func testIndexTimezoneAndFutureDateDoNotDisplaceToday() async {
        let timezone = TimeZone(identifier: "Pacific/Kiritimati")!
        let today = Store.dayString(timezone: timezone)
        let index: [String: Any] = [
            "generatedAt": 1788714000, "lastSync": 1788713999, "timezone": timezone.identifier,
            "days": ["2099-12-31", today, "2000-01-01"].map {
                ["date": $0, "total": 1, "merged": 1, "headline": "", "agendaOpen": 0, "whos": []] as [String: Any]
            }
        ]
        MockProtocol.configure {
            if $0.request.url?.path == "/api/index" { $0.reply(self.json(index)) }
            else { $0.reply(self.json(["generatedAt": 1788714000, "items": []])) }
        }
        let store = Store(api: api)
        await store.refresh()
        XCTAssertEqual(store.cloudTimezone.identifier, timezone.identifier)
        XCTAssertEqual(store.displayToday, today)
        XCTAssertEqual(store.landingDate, today)
        XCTAssertEqual(store.dayCalendar.timeZone, timezone)
        XCTAssertEqual(store.lastSync, Date(timeIntervalSince1970: 1788713999))
    }
}
