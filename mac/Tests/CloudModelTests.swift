import XCTest
@testable import notifhub

private final class CloudStub: URLProtocol {
    static var respond: (URLRequest) -> (Int, String, Double) = { _ in (500, "{}", 0) }
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body, delay) = Self.respond(request)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: status,
                                                                     httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    override func stopLoading() { pending?.cancel() }
}

final class CloudModelTests: XCTestCase {
    private let connection = CloudConnection(id: "test", url: URL(string: "https://test.example.com")!, token: String(repeating: "x", count: 40))
    private let index = #"{"days":[{"date":"2026-09-07","total":1,"agendaOpen":0}],"lastSync":1,"timezone":"Asia/Shanghai"}"#
    private func day(_ date: String) -> String {
        "{\"date\":\"\(date)\",\"total\":1,\"items\":[{\"ts\":1,\"app\":\"Mail\",\"who\":\"Sender\",\"lines\":[\"First paragraph\",\"Second paragraph\"],\"redacted\":false}],\"agenda\":[],\"cloudNotes\":[]}"
    }
    private func client() -> CloudClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CloudStub.self]
        let session = URLSession(configuration: cfg)
        addTeardownBlock { session.invalidateAndCancel() }
        return CloudClient(connection: connection, session: session)
    }
    private func defaults() -> UserDefaults {
        let suite = "CloudModelTests." + UUID().uuidString
        let result = UserDefaults(suiteName: suite)!
        addTeardownBlock { result.removePersistentDomain(forName: suite) }
        return result
    }
    @MainActor private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Cloud operation did not finish")
    }

    func testRejectsWrongInstanceAndInsecureOrigin() throws {
        XCTAssertNoThrow(try connection.validate(expectedID: "test", expectedURL: connection.url))
        XCTAssertThrowsError(try connection.validate(expectedID: "another-user", expectedURL: connection.url))
        XCTAssertThrowsError(try connection.validate(expectedID: "test", expectedURL: URL(string: "https://another.example.com")!))
        for value in ["http://test.example.com", "https://test.example.com/extra", "https://user:pass@test.example.com", "https://test.example.com?token=x"] {
            let invalid = CloudConnection(id: "test", url: URL(string: value)!, token: connection.token)
            XCTAssertThrowsError(try invalid.validate(expectedID: "test", expectedURL: connection.url))
        }
    }

    func testFutureCalendarDateDoesNotReplaceTodayInCloudTimezone() throws {
        let data = Data(#"{"days":[{"date":"2026-09-09","total":1,"agendaOpen":0},{"date":"2026-09-08","total":227,"agendaOpen":0}],"lastSync":1,"timezone":"Asia/Shanghai"}"#.utf8)
        let value = try JSONDecoder().decode(CloudIndex.self, from: data)
        let now = ISO8601DateFormatter().date(from: "2026-09-07T17:00:00Z")!
        XCTAssertEqual(value.initialDate(now: now), "2026-09-08")
    }

    func testNativeRequestUsesCredentialOnlyInHeaderAndKeepsParagraphs() async throws {
        let expected = day("2026-09-07")
        CloudStub.respond = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://test.example.com/native/api/day/2026-09-07")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.connection.token)
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Notifhub-Proxy"))
            return (200, expected, 0)
        }
        let value: CloudDay = try await client().request("day/2026-09-07")
        XCTAssertNil(value.summary)
        XCTAssertEqual(value.items.first?.lines, ["First paragraph", "Second paragraph"])
    }

    func testHTTPFailuresAreVisibleInsteadOfDecodedAsEmptyData() async {
        for code in [401, 302, 503] {
            CloudStub.respond = { _ in (code, "<html>Login</html>", 0) }
            do { let _: CloudIndex = try await client().request("index"); XCTFail("Unexpected success") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    @MainActor func testFailedNoteRetainsDraftAcrossModelRestartThenSuccessfulSaveClearsIt() async throws {
        let pref = defaults()
        var fail = true
        CloudStub.respond = { request in
            switch request.url!.lastPathComponent {
            case "index": return (200, self.index, 0)
            case "open": return (200, #"{"items":[]}"#, 0)
            case "notes":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Notifhub-Request"), "1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
                return (fail ? 503 : 200, #"{"id":1,"text":"A durable draft","ts":1}"#, 0)
            default: return (200, self.day("2026-09-07"), 0)
            }
        }
        let first = CloudModel(client: client(), defaults: pref)
        first.refresh()
        try await waitFor { !first.loading }
        first.beginNote(); first.draft = "A durable draft"
        let failed = await first.saveNote()
        XCTAssertFalse(failed)
        XCTAssertEqual(first.draft, "A durable draft")
        XCTAssertNotNil(first.writeProblem)
        let next = CloudModel(client: client(), defaults: pref)
        next.refresh()
        try await waitFor { !next.loading }
        next.beginNote()
        XCTAssertEqual(next.draft, "A durable draft")
        XCTAssertEqual(next.draftDate, "2026-09-07")
        fail = false
        let saved = await next.saveNote()
        XCTAssertTrue(saved)
        XCTAssertEqual(next.draft, "")
        try await waitFor { !next.loading }
        let final = CloudModel(client: client(), defaults: pref)
        final.beginNote()
        XCTAssertEqual(final.draft, "")
    }

    @MainActor func testTaskStatusWriteReportsFailureAndReloadsCloudOnSuccess() async throws {
        var fail = true
        var changed = false
        CloudStub.respond = { request in
            let tail = request.url!.lastPathComponent
            if request.httpMethod == "PATCH" {
                XCTAssertEqual(request.url?.path, "/native/api/agenda/11")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Notifhub-Request"), "1")
                if !fail { changed = true }
                return (fail ? 503 : 200, #"{"status":"done"}"#, 0)
            }
            if tail == "index" { return (200, self.index, 0) }
            if tail == "open" { return (200, changed ? #"{"items":[]}"# : #"{"items":[{"id":11,"title":"A task","status":"open"}]}"#, 0) }
            return (200, self.day(tail), 0)
        }
        let model = CloudModel(client: client(), defaults: defaults())
        model.refresh()
        try await waitFor { !model.loading }
        let item = try XCTUnwrap(model.opened.first)
        await model.setStatus(item, status: "done")
        XCTAssertNotNil(model.writeProblem)
        XCTAssertEqual(model.opened.count, 1)
        fail = false
        await model.setStatus(item, status: "done")
        try await waitFor { !model.loading }
        XCTAssertNil(model.writeProblem)
        XCTAssertTrue(model.opened.isEmpty)
    }

    @MainActor func testDateNavigationOnlyFetchesOneDayAndWarmReturnIsImmediate() async throws {
        var requests: [String] = []
        CloudStub.respond = { request in
            let tail = request.url!.lastPathComponent
            requests.append(tail)
            if tail == "index" { return (200, self.index, 0) }
            if tail == "open" { return (200, #"{"items":[]}"#, 0) }
            return (200, self.day(tail), 0.1)
        }
        let model = CloudModel(client: client(), defaults: defaults())
        model.refresh()
        try await waitFor { !model.loading }
        requests.removeAll()
        model.select(date: "2026-09-06")
        try await waitFor { !model.loading }
        XCTAssertEqual(requests, ["2026-09-06"])
        requests.removeAll()
        model.select(date: "2026-09-07")
        XCTAssertEqual(model.day?.date, "2026-09-07")
        XCTAssertFalse(model.loading)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor func testSlowOldDateDoesNotOverwriteNewSelection() async throws {
        var oldStarted = false
        CloudStub.respond = { request in
            let tail = request.url!.lastPathComponent
            if tail == "index" { return (200, self.index, 0) }
            if tail == "open" { return (200, #"{"items":[]}"#, 0) }
            if tail == "2026-09-06" { oldStarted = true; return (200, self.day(tail), 0.2) }
            return (200, self.day(tail), 0)
        }
        let model = CloudModel(client: client(), defaults: defaults())
        model.select(date: "2026-09-06")
        try await waitFor { oldStarted }
        model.select(date: "2026-09-07")
        try await waitFor { !model.loading }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.selectedDate, "2026-09-07")
        XCTAssertEqual(model.day?.date, "2026-09-07")
    }


    override func tearDown() {
        Remote.ui = nil
        super.tearDown()
    }

    private func index(ui: String) -> String {
        #"{"days":[{"date":"2026-09-07","total":1,"agendaOpen":0}],"lastSync":1,"timezone":"Asia/Shanghai","ui":\#(ui)}"#
    }

    private let builtin: [(String, String)] = [
        ("mac.loading", "正在读取云端记录…"),
        ("mac.empty.none_title", "还没有云端记录"),
        ("mac.empty.none_detail", "首次同步完成后，你的每日记录会出现在这里。"),
        ("mac.empty.timeline_title", "没有匹配的记录"),
        ("mac.empty.timeline_detail", "当天暂无可展示的通知。"),
        ("mac.empty.search_detail", "试试其他关键词。"),
        ("mac.empty.agenda_title", "这里都处理好了"),
        ("mac.empty.agenda_search_title", "没有匹配的待办"),
        ("mac.empty.agenda_detail", "没有待办事项。"),
        ("mac.empty.agenda_search_detail", "没有符合关键词的待办。"),
        ("mac.empty.notes_title", "留下一点想法"),
        ("mac.empty.notes_detail", "点击右上角「随手记」，内容会保存到云端。"),
        ("mac.note.hint", "记下想法，回头在任何设备上继续。"),
        ("mac.note.draft_kept", "草稿自动保留在本机"),
        ("mac.redacted", "正文已按保留策略清理"),
        ("mac.notice.note_saved", "随手记已保存到云端"),
        ("mac.notice.done", "待办已完成"),
        ("mac.notice.reopened", "待办已重新打开"),
    ]

    private func assertBuiltinEverywhere(file: StaticString = #filePath, line: UInt = #line) {
        for (key, text) in builtin { XCTAssertEqual(T(key, text), text, key, file: file, line: line) }
        XCTAssertEqual(T("mac.sync_at", "同步于 {time}", ["time": "10-06 09:00"]), "同步于 10-06 09:00", file: file, line: line)
        XCTAssertEqual(CloudCopy.connection(problem: true, connected: true), "连接需要重试", file: file, line: line)
        XCTAssertEqual(CloudCopy.connection(problem: false, connected: false), "尚未连接", file: file, line: line)
        XCTAssertEqual(CloudCopy.connection(problem: false, connected: true), "云端已连接", file: file, line: line)
        for failure in [CloudFailure("云端凭据无效，请检查当前实例的连接配置。", kind: .http, status: 401),
                        CloudFailure("云端原生接口尚未就绪，连接被重定向。", kind: .http, status: 302),
                        CloudFailure("云端请求失败（HTTP 503），请稍后重试。", kind: .http, status: 503),
                        CloudFailure("云端连不上：超时", kind: .network),
                        CloudFailure("云端数据格式不兼容，请刷新或更新应用。", kind: .format),
                        CloudFailure.notConfigured("尚未连接云端。请先安装此实例的云端同步配置。")] {
            XCTAssertEqual(CloudCopy.problem(failure), failure.message, file: file, line: line)
        }
    }


    @MainActor func testBackendCopyReplacesBuiltinTextOnNextIndexAndIsDroppedWhenRemoved() async throws {
        var ui: String? = #"{"copy":{"mac.empty.none_title":"云端还是空的","mac.notice.done":"已划掉","mac.sync_at":"上次同步 {time}","mac.error.http":"服务器在忙（{code}）","mac.error.unauthorized":"口令过期了"},"vocab":{"conn.ok":{"label":"已连上"}},"order":[],"limits":{}}"#
        var status = 200
        CloudStub.respond = { request in
            let tail = request.url!.lastPathComponent
            if request.httpMethod == "PATCH" { return (200, #"{"status":"done"}"#, 0) }
            if tail == "index" { return (status, ui.map(self.index(ui:)) ?? self.index, 0) }
            if tail == "open" { return (200, #"{"items":[{"id":11,"title":"A task","status":"open"}]}"#, 0) }
            return (200, self.day(tail), 0)
        }
        let model = CloudModel(client: client(), defaults: defaults())
        assertBuiltinEverywhere()
        model.refresh()
        try await waitFor { !model.loading }
        XCTAssertEqual(model.index?.days.count, 1)
        XCTAssertEqual(T("mac.empty.none_title", "还没有云端记录"), "云端还是空的")
        XCTAssertEqual(T("mac.sync_at", "同步于 {time}", ["time": "10-06 09:00"]), "上次同步 10-06 09:00")
        XCTAssertEqual(CloudCopy.connection(problem: false, connected: true), "已连上")
        XCTAssertEqual(CloudCopy.connection(problem: false, connected: false), "尚未连接")   // 没写的状态仍是自带的
        XCTAssertEqual(T("mac.loading", "正在读取云端记录…"), "正在读取云端记录…")            // 没写的键仍是自带的
        await model.setStatus(try XCTUnwrap(model.opened.first), status: "done")
        XCTAssertEqual(model.notice, "已划掉")
        try await waitFor { !model.loading }
        status = 503
        model.refresh()
        try await waitFor { !model.loading }
        XCTAssertEqual(model.problem, "服务器在忙（503）")
        status = 401
        model.refresh()
        try await waitFor { !model.loading }
        XCTAssertEqual(model.problem, "口令过期了")
        status = 200; ui = nil
        model.refresh()
        try await waitFor { !model.loading }
        XCTAssertNil(model.problem)
        assertBuiltinEverywhere()
    }

    @MainActor func testBrokenCopyFallsBackWholeAndLeavesDataIntact() async throws {
        for broken in [#""oops""#, "7", "[]", #"{"copy":["a","b"]}"#, #"{"copy":{"mac.loading":5}}"#, #"{"vocab":{"conn.ok":"plain"}}"#] {
            Remote.ui = FeedUI(copy: ["mac.loading": "上一轮留下的"])
            CloudStub.respond = { request in
                let tail = request.url!.lastPathComponent
                if tail == "index" { return (200, self.index(ui: broken), 0) }
                if tail == "open" { return (200, #"{"items":[{"id":11,"title":"A task","status":"open"}]}"#, 0) }
                return (200, self.day(tail), 0)
            }
            let model = CloudModel(client: client(), defaults: defaults())
            model.refresh()
            try await waitFor { !model.loading }
            XCTAssertNil(model.problem, broken)
            XCTAssertEqual(model.index?.days.first?.date, "2026-09-07", broken)
            XCTAssertEqual(model.opened.count, 1, broken)
            XCTAssertEqual(model.day?.items.count, 1, broken)
            XCTAssertNil(Remote.ui, broken)
            assertBuiltinEverywhere()
        }
        for empty in ["null", #"{"copy":{},"vocab":{},"order":[],"limits":{}}"#] {
            CloudStub.respond = { request in
                let tail = request.url!.lastPathComponent
                if tail == "index" { return (200, self.index(ui: empty), 0) }
                if tail == "open" { return (200, #"{"items":[]}"#, 0) }
                return (200, self.day(tail), 0)
            }
            let model = CloudModel(client: client(), defaults: defaults())
            model.refresh()
            try await waitFor { !model.loading }
            XCTAssertEqual(model.index?.days.count, 1, empty)
            assertBuiltinEverywhere()
        }
    }

    func testIndexWithAndWithoutCopyDecodesForOldAndNewClients() async throws {
        let withUI = index(ui: #"{"copy":{"mac.loading":"读取中"},"vocab":{},"order":[],"limits":{}}"#)
        CloudStub.respond = { _ in (200, withUI, 0) }
        let old: CloudIndex = try await client().request("index")
        XCTAssertEqual(old.days.first?.date, "2026-09-07")
        XCTAssertEqual(old.timezone, "Asia/Shanghai")
        let plain = index
        CloudStub.respond = { _ in (200, plain, 0) }
        let new: CloudIndexFeed = try await client().request("index")
        XCTAssertEqual(new.index.days.count, 1)
        XCTAssertNil(new.ui)
    }
}
