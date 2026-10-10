import XCTest
import Foundation
@testable import DayDeckCore

private final class PrivacyProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    static var recorded: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
    static func reset() { lock.lock(); requests = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let value: [String: Any]
        switch request.url?.path {
        case "/api/notes":
            value = ["id": 1, "text": "synthetic note", "date": "2001-01-01", "ts": 978307200]
        case "/api/agenda/42": value = ["id": 42, "status": "done"]
        case "/api/agenda-queue": value = ["item": ["status": "pending"]]
        default: value = ["ok": true]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PrivacyAcceptanceTests: XCTestCase {
    private var api: API!
    private var session: URLSession!
    private var directory: URL!
    private var argumentDomain: [String: Any] = [:]

    override func setUpWithError() throws {
        argumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        setDemo(false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("daydeck-privacy-\(UUID())")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrivacyProtocol.self]
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
        api = API(session: session, cacheDirectory: directory)
        PrivacyProtocol.reset()
    }
    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        UserDefaults.standard.setVolatileDomain(argumentDomain, forName: UserDefaults.argumentDomain)
        if let directory { try FileManager.default.removeItem(at: directory) }
    }
    private func setDemo(_ enabled: Bool) {
        var domain = argumentDomain
        domain["demo"] = enabled
        domain["gatepw"] = ""
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
    private func cacheSnapshot() throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            snapshot[file.lastPathComponent] = try Data(contentsOf: file)
        }
        return snapshot
    }
    private func assertSuccess(_ result: Result<Void, FeedError>, file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(let error) = result { XCTFail("Unexpected failure: \(error)", file: file, line: line) }
    }

    func testUntrustedDestinationsAreRejectedBeforeAnyRequest() async {
        for address in ["http://day.example.invalid/api/open", "https://example.invalid/api/open",
                        "https://day.example.invalid.example.invalid/api/open", "file:///tmp/private.json"] {
            let result = await api.fetch(URL(string: address)!)
            guard case .failure(.network) = result else { XCTFail("Untrusted destination accepted: \(address)"); continue }
        }
        XCTAssertTrue(PrivacyProtocol.recorded.isEmpty)
        let allowed = await api.fetch(URL(string: "https://day.example.invalid/api/open")!)
        if case .failure(let error) = allowed { XCTFail("Allowed HTTPS origin rejected: \(error)") }
        XCTAssertEqual(PrivacyProtocol.recorded.count, 1)
    }

    func testOnlyExplicitReminderExportUsesQueue() async {
        assertSuccess(await Writer.note("synthetic note", date: "2001-01-01", idempotencyKey: "privacy-fixture", api: api))
        assertSuccess(await Writer.mark(42, to: "done", title: "synthetic agenda", api: api))
        XCTAssertEqual(PrivacyProtocol.recorded.map { $0.url!.path }, ["/api/notes", "/api/agenda/42"])
        XCTAssertEqual(PrivacyProtocol.recorded.map { $0.httpMethod! }, ["POST", "PATCH"])
        XCTAssertFalse(PrivacyProtocol.recorded.contains { $0.url!.path == "/api/agenda-queue" })
        assertSuccess(await Writer.push(42, title: "synthetic agenda", api: api))
        XCTAssertEqual(PrivacyProtocol.recorded.map { $0.url!.path }, ["/api/notes", "/api/agenda/42", "/api/agenda-queue"])
        XCTAssertTrue(PrivacyProtocol.recorded.allSatisfy { $0.url?.scheme == "https" && $0.url?.host == "day.example.invalid" })
    }

    #if DEBUG
    @MainActor
    func testDemoDoesNotLoadPrivateCacheOrFetchDuringRefreshAndDateSwitch() async throws {
        let sentinel: [String: Any] = ["generatedAt": 1, "lastSync": 1, "timezone": "UTC", "days": [
            ["date": "2001-01-01", "total": 1, "merged": 1, "headline": "PRIVATE CACHE SENTINEL",
             "agendaOpen": 0, "whos": []] as [String: Any]
        ]]
        api.cache.write(try JSONSerialization.data(withJSONObject: sentinel), for: "/api/index")
        XCTAssertEqual(api.cache.load("/api/index", as: FeedIndex.self, api: api)?.0.days.first?.headline, "PRIVATE CACHE SENTINEL")
        let before = try cacheSnapshot()
        setDemo(true)
        let store = Store(api: api)
        XCTAssertFalse(store.index.isEmpty)
        XCTAssertFalse(store.index.contains { $0.headline == "PRIVATE CACHE SENTINEL" })
        XCTAssertEqual(store.open.first?.id, 901)
        await store.refresh()
        let shownDay = await store.day(store.latestDate, force: true)
        XCTAssertNotNil(shownDay?.summary?.headline)
        let absentDay = await store.day("2001-01-01", force: true)
        XCTAssertNil(absentDay)
        XCTAssertTrue(PrivacyProtocol.recorded.isEmpty)
        XCTAssertEqual(try cacheSnapshot(), before)
    }

    func testDemoRejectsAllWritesAndLoginWithoutNetworkOrCacheMutation() async throws {
        api.cache.write(Data("synthetic private cache".utf8), for: "/api/day/2001-01-01")
        let before = try cacheSnapshot()
        setDemo(true)
        let results = [
            await Writer.note("synthetic note", date: "2001-01-01", idempotencyKey: "demo-fixture", api: api),
            await Writer.mark(42, to: "done", title: "synthetic agenda", api: api),
            await Writer.push(42, title: "synthetic agenda", api: api)
        ]
        for result in results {
            guard case .failure(.demo) = result else { XCTFail("Demo write must return an explicit read-only error"); continue }
        }
        do {
            try await Gate.login(password: "synthetic-demo-password", session: session)
            XCTFail("Demo login must be refused")
        } catch let error as Gate.Failure {
            XCTAssertFalse(error.message.isEmpty)
        } catch { XCTFail("Expected a clear Gate failure, got \(error)") }
        XCTAssertTrue(PrivacyProtocol.recorded.isEmpty)
        XCTAssertEqual(try cacheSnapshot(), before)
    }
    #endif
}
