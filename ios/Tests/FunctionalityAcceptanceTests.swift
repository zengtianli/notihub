import XCTest
import Foundation
@testable import DayDeckCore

private final class FunctionalityProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        do {
            guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
            let data = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func configure(_ handler: @escaping (URLRequest) throws -> Data) {
        lock.lock(); defer { lock.unlock() }; Self.handler = handler
    }
}

final class FunctionalityAcceptanceTests: XCTestCase {
    private var api: API!
    private var session: URLSession!
    private var directory: URL!
    private let stamp = 1_788_714_000.0
    private let date = "2026-09-07"
    private let longSummary = String(repeating: "**合成摘要**：保留段落与中文。\n\n", count: 400) + "摘要末尾标记"
    private let longBody = String(repeating: "合成通知正文，第二行\n第三行。\n", count: 400) + "正文末尾标记"

    override func setUpWithError() throws {
        guard UserDefaults.standard.string(forKey: "gatepw")?.isEmpty != false else {
            throw NSError(domain: "FunctionalityAcceptance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Run acceptance without a gatepw launch argument."])
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notihub-functionality-\(UUID())")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FunctionalityProtocol.self]
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
        api = API(session: session, cacheDirectory: directory)
        FunctionalityProtocol.configure { _ in throw URLError(.unsupportedURL) }
    }
    override func tearDownWithError() throws {
        session?.invalidateAndCancel()
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, data.isEmpty {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func agenda(_ id: Int, due: Double? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "kind": "todo", "title": "合成待办 \(id)",
            "allDay": false, "status": "open", "source": "manual", "pushed": false]
        if let due { value["dueTS"] = due }
        return value
    }
    private func feed(_ day: String, notes: [[String: Any]] = []) throws -> Data {
        try json(["date": day, "total": 1, "muted": 0, "notes": notes.count,
            "byHour": Array(repeating: 0, count: 24), "apps": [["合成邮件", "1"]], "whos": [["合成联系人", "1"]],
            "summary": ["headline": "合成复盘", "text": longSummary, "generatedAt": stamp],
            "agenda": [], "items": [["ts": stamp, "endTs": stamp, "app": "合成邮件", "who": "合成联系人",
                "lines": [longBody], "missed": false, "redacted": false]], "cloudNotes": notes])
    }
    private func assertSuccess(_ result: Result<Void, FeedError>, file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(let error) = result { XCTFail("生产路径返回失败：\(error)", file: file, line: line) }
    }

    @MainActor
    func testTodayRefreshAndLongContentSurviveNetworkAndDisk() async throws {
        let today = Store.dayString()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Store.dayTZ
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: noon)!.timeIntervalSince1970
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: noon)!.timeIntervalSince1970
        var paths: [String] = []
        FunctionalityProtocol.configure { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let path = try XCTUnwrap(request.url?.path)
            paths.append(path)
            switch path {
            case "/api/index":
                return try self.json(["generatedAt": self.stamp, "lastSync": self.stamp, "timezone": "Asia/Shanghai",
                    "days": [["date": today, "total": 1, "merged": 1, "headline": "合成复盘", "agendaOpen": 4, "whos": []]]])
            case "/api/open":
                return try self.json(["generatedAt": self.stamp, "items": [self.agenda(4),
                    self.agenda(3, due: tomorrow), self.agenda(2, due: noon.timeIntervalSince1970), self.agenda(1, due: yesterday)]])
            case "/api/day/" + today: return try self.feed(today)
            default: throw URLError(.unsupportedURL)
            }
        }
        let store = Store(api: api)
        await store.refresh()
        XCTAssertNil(store.indexError); XCTAssertNil(store.openError)
        XCTAssertEqual(store.landingDate, today)
        XCTAssertEqual(store.open.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(store.overdue.map(\.id), [1])
        XCTAssertEqual(store.dueToday.map(\.id), [2])
        XCTAssertEqual(store.upcoming.map(\.id), [3])
        XCTAssertEqual(store.undated.map(\.id), [4])
        let fetchedDay = await store.day(today)
        let day = try XCTUnwrap(fetchedDay)
        XCTAssertEqual(day.summary?.text, longSummary)
        XCTAssertEqual(day.items.first?.lines, [longBody])
        XCTAssertNotNil(store.dayAt[today])
        let cached = try XCTUnwrap(api.cache.load("/api/day/" + today, as: FeedDay.self, api: api))
        XCTAssertEqual(cached.0.summary?.text, longSummary)
        XCTAssertEqual(cached.0.items.first?.lines, [longBody])
        XCTAssertEqual(Set(paths), Set(["/api/index", "/api/open", "/api/day/" + today]))
        XCTAssertEqual(paths.count, 3)
    }

    @MainActor
    func testNoteReceiptInvalidatesCacheThenReadsBackCommittedText() async throws {
        let noteText = "合成随手记\n保存后必须完整回读"
        var notes: [[String: Any]] = []
        var reads = 0
        FunctionalityProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/day/" + self.date):
                reads += 1
                return try self.feed(self.date, notes: notes)
            case ("POST", "/api/notes"):
                let body = try self.body(request)
                XCTAssertEqual(body["text"] as? String, noteText)
                XCTAssertEqual(body["date"] as? String, self.date)
                XCTAssertEqual(body["idempotencyKey"] as? String, "acceptance-note-1")
                let note: [String: Any] = ["id": 41, "text": noteText, "date": self.date, "ts": self.stamp]
                notes = [note]
                return try self.json(note)
            default: throw URLError(.unsupportedURL)
            }
        }
        let store = Store(api: api)
        _ = await store.day(date)
        XCTAssertEqual(store.days[date]?.cloudNotes.count, 0)
        assertSuccess(await Writer.note(noteText, date: date, idempotencyKey: "acceptance-note-1", api: api))
        let invalidatedStamp = try XCTUnwrap(api.cache.stamp("/api/day/" + date))
        XCTAssertGreaterThan(Date().timeIntervalSince(invalidatedStamp), 60)
        store.invalidateDays()
        let saved = await store.day(date)
        XCTAssertEqual(saved?.cloudNotes.first?.text, noteText)
        XCTAssertEqual(reads, 2)
        let reopened = Store(api: api)
        let warm = await reopened.day(date)
        XCTAssertEqual(warm?.cloudNotes.first?.text, noteText)
        XCTAssertEqual(reads, 2, "重开应读取刚保存的缓存")
    }

    @MainActor
    func testAgendaStatusReadbackAndReminderQueueContract() async throws {
        var pending = true
        var queueCount = 0
        FunctionalityProtocol.configure { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/open"):
                return try self.json(["generatedAt": self.stamp, "items": pending ? [self.agenda(11)] : []])
            case ("GET", "/api/index"):
                return try self.json(["generatedAt": self.stamp, "lastSync": self.stamp, "timezone": "Asia/Shanghai", "days": []])
            case ("PATCH", "/api/agenda/11"):
                XCTAssertEqual(try self.body(request)["status"] as? String, "done")
                pending = false
                return try self.json(["id": 11, "status": "done"])
            case ("POST", "/api/agenda-queue"):
                let body = try self.body(request)
                XCTAssertEqual(body["kind"] as? String, "push")
                XCTAssertEqual(body["agendaId"] as? Int, 11)
                XCTAssertEqual(body["title"] as? String, "合成待办 11")
                XCTAssertEqual(body["force"] as? Bool, true)
                queueCount += 1
                return try self.json(["item": ["id": "synthetic-queue-1", "status": "pending"]])
            default: throw URLError(.unsupportedURL)
            }
        }
        let store = Store(api: api)
        await store.refresh()
        XCTAssertEqual(store.open.map(\.id), [11])
        assertSuccess(await Writer.push(11, title: "合成待办 11", api: api))
        XCTAssertEqual(queueCount, 1)
        XCTAssertTrue(pending, "推提醒只排队，不把云端待办标完成")
        assertSuccess(await Writer.mark(11, to: "done", title: "合成待办 11", api: api))
        store.invalidateDays()
        await store.refresh()
        XCTAssertNil(store.openError)
        XCTAssertTrue(store.open.isEmpty)
        let reopened = Store(api: api)
        XCTAssertTrue(reopened.open.isEmpty)
    }
}
