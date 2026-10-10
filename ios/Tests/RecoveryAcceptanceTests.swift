import XCTest
import Foundation
@testable import DayDeckCore

private final class RecoveryProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var response: (Data?, Int, URLError?) = (nil, 200, URLError(.notConnectedToInternet))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let (data, status, error) = Self.response
        Self.lock.unlock()
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func offline() {
        lock.lock(); defer { lock.unlock() }
        response = (nil, 200, URLError(.notConnectedToInternet))
    }
    static func reply(_ data: Data, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        response = (data, status, nil)
    }
}

final class RecoveryAcceptanceTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private var api: API!
    private let day = "2026-09-07"
    private var path: String { "/api/day/" + day }

    override func setUpWithError() throws {
        guard UserDefaults.standard.string(forKey: "gatepw")?.isEmpty != false else {
            throw NSError(domain: "RecoveryAcceptance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Run acceptance without a gatepw launch argument."])
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("daydeck-recovery-\(UUID())")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        api = API(session: session, cacheDirectory: directory)
        RecoveryProtocol.offline()
    }

    override func tearDownWithError() throws {
        session?.invalidateAndCancel()
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private func fixture(_ text: String) -> Data {
        json(["date": day, "total": 0, "muted": 0, "notes": 1,
              "byHour": Array(repeating: 0, count: 24), "apps": [], "whos": [],
              "agenda": [], "items": [],
              "cloudNotes": [["id": 1, "text": text, "ts": 1788714000, "date": day]]])
    }

    @MainActor
    func testCachedDaySurvivesOfflineAndBadJSONThenRecovers() async throws {
        api.cache.write(fixture("last readable note"), for: path)
        let oldDate = Date(timeIntervalSinceNow: -3600)
        let cacheFile = directory.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cacheFile.path)
        let oldStamp = try XCTUnwrap(api.cache.stamp(path))
        let oldBytes = try Data(contentsOf: cacheFile)
        let store = Store(api: api)

        _ = await store.day(day, force: true)
        XCTAssertEqual(store.days[day]?.cloudNotes.first?.text, "last readable note")
        XCTAssertEqual(store.dayAt[day], oldStamp)
        XCTAssertFalse(try XCTUnwrap(store.dayError[day]).whatToDo.isEmpty)
        XCTAssertEqual(try Data(contentsOf: cacheFile), oldBytes)

        RecoveryProtocol.reply(Data("{\"incompatible\":true}".utf8))
        _ = await store.day(day, force: true)
        XCTAssertEqual(store.days[day]?.cloudNotes.first?.text, "last readable note")
        guard case .decoding = store.dayError[day] else { return XCTFail("Bad JSON must report a decoding error") }
        XCTAssertEqual(store.dayAt[day], oldStamp)
        XCTAssertEqual(try Data(contentsOf: cacheFile), oldBytes)

        RecoveryProtocol.reply(fixture("recovered cloud note"))
        _ = await store.day(day)
        XCTAssertEqual(store.days[day]?.cloudNotes.first?.text, "recovered cloud note")
        XCTAssertNil(store.dayError[day])
        XCTAssertGreaterThan(try XCTUnwrap(store.dayAt[day]), oldStamp)
        XCTAssertGreaterThan(try XCTUnwrap(api.cache.stamp(path)), oldStamp)
        XCTAssertEqual(api.cache.load(path, as: FeedDay.self, api: api)?.0.cloudNotes.first?.text,
                       "recovered cloud note")
    }

    @MainActor
    func testColdOfflineDayBecomesReadableAfterRecovery() async throws {
        let store = Store(api: api)
        let unavailable = await store.day(day)
        XCTAssertNil(unavailable)
        XCTAssertNotNil(store.dayError[day])
        XCTAssertNil(store.dayAt[day])
        RecoveryProtocol.reply(fixture("first successful fetch"))
        let recovered = await store.day(day)
        XCTAssertEqual(recovered?.cloudNotes.first?.text, "first successful fetch")
        XCTAssertNil(store.dayError[day])
        XCTAssertNotNil(store.dayAt[day])
    }

    func testFailedWriteKeepsCacheUntilMatchingReceiptAndReadback() async throws {
        api.cache.write(fixture("before write"), for: path)
        let oldStamp = try XCTUnwrap(api.cache.stamp(path))
        let requestID = "recovery-acceptance-synthetic"
        let offline = await Writer.note("new note", date: day, idempotencyKey: requestID, api: api)
        guard case .failure = offline else { return XCTFail("Offline write reported success") }
        XCTAssertEqual(api.cache.stamp(path), oldStamp)

        RecoveryProtocol.reply(json(["id": 2, "text": "wrong note", "date": day, "ts": 1788714000]))
        let mismatched = await Writer.note("new note", date: day, idempotencyKey: requestID, api: api)
        guard case .failure = mismatched else { return XCTFail("Mismatched receipt reported success") }
        XCTAssertEqual(api.cache.stamp(path), oldStamp)
        XCTAssertEqual(api.cache.load(path, as: FeedDay.self, api: api)?.0.cloudNotes.first?.text, "before write")

        RecoveryProtocol.reply(json(["id": 2, "text": "new note", "date": day, "ts": 1788714000]))
        let saved = await Writer.note("new note", date: day, idempotencyKey: requestID, api: api)
        guard case .success = saved else { return XCTFail("Matching receipt failed") }
        XCTAssertLessThan(try XCTUnwrap(api.cache.stamp(path)), oldStamp)
        RecoveryProtocol.reply(fixture("new note"))
        let readback = await api.get(path, as: FeedDay.self)
        XCTAssertNil(readback.error)
        XCTAssertEqual(readback.value?.cloudNotes.first?.text, "new note")
        XCTAssertNotNil(readback.cachedAt)
    }
}
