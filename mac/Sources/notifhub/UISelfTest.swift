import AppKit
import SwiftUI

@MainActor
enum UISelfTest {
    private static var demoDefaults: (defaults: UserDefaults, suite: String)?

    static func makeDemoCloudModel() -> CloudModel {
        let suite = "Notihub.LaneDemo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        demoDefaults = (defaults, suite)
        return fixtureCloud(defaults: defaults, session: fixtureSession())
    }

    static func makeDemoTodayModel() -> TodayModel { fixtureToday(UISelfTestStore()) }

    static func finishDemoSession() {
        if let demoDefaults { demoDefaults.defaults.removePersistentDomain(forName: demoDefaults.suite) }
        demoDefaults = nil
    }

    private static func fixtureSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UISelfTestProtocol.self]
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }

    private static func fixtureCloud(defaults: UserDefaults, session: URLSession) -> CloudModel {
        let connection = CloudConnection(id: "ui-self-test", url: URL(string: "https://fixture.invalid")!, token: "isolated-synthetic-value-not-a-credential")
        return CloudModel(client: CloudClient(connection: connection, session: session), defaults: defaults)
    }

    private static func fixtureToday(_ fixture: UISelfTestStore) -> TodayModel {
        TodayModel(startAutomatically: false, loader: { fixture.snapshot(includeAll: $0) },
                   writer: { fixture.markRead($0) },
                   recap: { _ in URL(string: "https://fixture.invalid")! }, opener: { _ in false })
    }

    static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let arguments = CommandLine.arguments
        guard let position = arguments.firstIndex(of: "--ui-self-test-output"),
              arguments.indices.contains(position + 1) else {
            throw CloudFailure("--ui-self-test-output <directory> is required")
        }
        let output = URL(fileURLWithPath: arguments[position + 1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "Notihub.UISelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let cloud = fixtureCloud(defaults: defaults, session: session)
        cloud.refresh(date: "2026-09-24")
        try wait("cloud refresh") { !cloud.loading }
        try check(cloud.problem == nil && cloud.day?.total == 2 && cloud.index?.days.count == 1, "cloud refresh populates real model")
        try check(cloud.opened.count == 1 && cloud.selectedDate == "2026-09-24", "cloud date and agenda counts")
        for section in ["timeline", "agenda", "notes"] {
            try snapshot(CloudWindowView(demoModel: cloud, section: section), width: 1100, height: 760,
                         to: output.appendingPathComponent("cloud-\(section).png"))
        }
        let previousRequests = UISelfTestProtocol.requestCount
        cloud.refresh()
        try wait("cloud refresh action") { !cloud.loading }
        try check(cloud.problem == nil && UISelfTestProtocol.requestCount >= previousRequests + 3,
                  "refresh action fetches index, agenda and day again")

        let fixture = UISelfTestStore()
        let today = fixtureToday(fixture)
        today.refresh()
        try wait("menu refresh") { !today.loading }
        try check(today.snap.total == 3 && today.snap.muted == 1 && today.snap.unread == 2 && today.badge.unread == 2,
                  "menu refresh and badge agree")
        try snapshot(TodayPanelView(model: today), width: 420, height: 640,
                     to: output.appendingPathComponent("menu-unread.png"))
        today.markAllRead()
        try wait("mark all read action") { !today.writing && !today.loading }
        try check(today.actionProblem == nil && today.snap.unread == 0 && today.badge.unread == 0,
                  "mark all read updates panel and badge")
        try check(fixture.writtenIDs == [1, 2], "mark all read uses the production writer path")
        try snapshot(TodayPanelView(model: today), width: 420, height: 640,
                     to: output.appendingPathComponent("menu-read.png"))
        today.includeAll = true
        try wait("include noise action") { !today.loading }
        try check(today.snap.groups.count == 2 && today.snap.total == 3, "noise toggle refreshes panel")
        let dataShots = try dataPage(cloud: cloud, output: output)
        try check(app.activationPolicy() == .prohibited && app.windows.allSatisfy { !$0.isVisible && !$0.isKeyWindow },
                  "all rendering stays offscreen")
        print("PASS native_ui: cloud timeline/agenda/notes and menu rendered; refresh, mark-read, noise toggle and window close passed; data page refresh, selection, focus, export list and permission banner passed; isolated fixtures; \(5 + dataShots) PNGs at \(output.path)")
    }

    private static func dataPage(cloud: CloudModel, output: URL) throws -> Int {
        let model = DataPageModel { domain, limit in
            DomainResult(domainID: domain.id, resolvedCount: 1, columns: ["示例名称", "记录"],
                         rows: (0..<min(3, limit)).map { ["虚构示例 \($0 + 1)", domain.name] })
        }
        let domains = model.domains
        try check(domains.count == 15 && Set(domains.map(\.id)).count == 15, "data registry has 15 unique domains")
        let window = { (name: String) in
            try snapshot(CloudWindowView(demoModel: cloud, section: "timeline", dataModel: model), width: 1200, height: 780,
                         to: output.appendingPathComponent("data-\(name).png"))
        }
        try window("initial")
        try check(model.results.isEmpty && !model.isScanning, "offscreen data page does not scan by itself")

        model.scanAll() // Same action as the page's 重新扫描 button and first entry.
        try check(model.scanning.count == domains.count, "data refresh marks every domain busy")
        try wait("data refresh") { !model.isScanning }
        try check(model.results.count == domains.count && model.results.values.allSatisfy { $0.rowCount == 3 && $0.isUsable },
                  "data refresh publishes fixture rows for every domain")
        model.selectAll()
        try check(model.selected.count == 15 && model.exportableSummary.rows == 45, "select all updates export summary")
        model.selectNone()
        try check(model.selected.isEmpty && model.exportableSummary.rows == 0, "select none clears export summary")
        model.toggle(domains[0])
        try check(model.selected == [domains[0].id], "checkbox action selects one domain")
        model.focus(on: domains[1])
        try check(model.focusedDomain?.id == domains[1].id, "row action changes preview domain")
        model.selectReadable()
        try check(model.selected.count == 15, "select readable uses refreshed results")
        try window("refreshed")
        try check(model.deniedDomains.isEmpty, "no permission banner without EPERM")

        model.results[domains[0].id] = DomainResult(domainID: domains[0].id, verdict: .denied)
        model.results[domains[2].id] = DomainResult(domainID: domains[2].id, verdict: .notFound)
        model.focus(on: domains[0])
        try check(model.deniedDomains.map(\.id) == [domains[0].id], "only EPERM domains drive the permission banner")
        try check(model.exportableSummary.domains == 13, "unreadable domains are excluded from export")
        try window("permission")

        var presented = true
        let binding = Binding(get: { presented }, set: { presented = $0 })
        let sheet = DataExportSheet(model: model, presented: binding)
        try check(!model.masked, "masking defaults to off")
        model.masked = true
        model.format = .json
        try snapshot(sheet, width: 620, height: 520, to: output.appendingPathComponent("data-export.png"))
        sheet.cancel() // Same action as the sheet's 取消 button; no synthetic Esc event.
        try check(!presented && !model.exporting && model.lastExport == nil, "cancel closes export list without writing")
        try check(model.masked && model.format == .json, "export options survive cancel")

        let files = ["initial", "refreshed", "permission"].map { output.appendingPathComponent("data-\($0).png") }
        let images = try files.map { try Data(contentsOf: $0) }
        try check(images[0] != images[1] && images[1] != images[2], "data page render changes with refresh and permission state")
        model.release()
        try check(model.results.isEmpty && model.selected.isEmpty && !model.isScanning, "leaving the data page releases results")
        return 4
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CloudFailure(message) }
    }

    private static func wait(_ action: String, until ready: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while !ready() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try check(ready(), "Timed out: \(action)")
    }

    private static func snapshot<V: View>(_ view: V, width: CGFloat, height: CGFloat, to url: URL) throws {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let host = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: "zh_CN")))
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        try check(!window.isVisible && !window.isKeyWindow, "render window became visible")
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CloudFailure("No UI bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CloudFailure("No PNG representation") }
        try check(bitmap.pixelsWide >= Int(width) && bitmap.pixelsHigh >= Int(height) && png.count > 4_000,
                  "rendered image is empty or too small")
        try png.write(to: url, options: .atomic)
        window.performClose(nil)
        try check(!window.isVisible && !window.isKeyWindow, "close left window visible")
    }
}

private final class UISelfTestStore: @unchecked Sendable {
    private let lock = NSLock()
    private var read: Set<Int64> = []
    var writtenIDs: [Int64] { lock.lock(); defer { lock.unlock() }; return read.sorted() }
    func markRead(_ ids: [Int64]) { lock.lock(); defer { lock.unlock() }; read.formUnion(ids) }
    func snapshot(includeAll: Bool) -> DaySnapshot {
        lock.lock(); defer { lock.unlock() }
        let rows = (1...2).map { id in
            FeedRow(id: Int64(id), ts: 1_790_208_000 - Double(id * 60), canon: "fixture.calendar", app: "日历（虚构）",
                    who: "界面验收示例 \(id)", text: "固定测试内容，不含个人通知。", redacted: false, unread: !read.contains(Int64(id)))
        }
        var groups = [SourceGroup(canon: "fixture.calendar", app: "日历（虚构）", rows: rows)]
        if includeAll {
            let noise = FeedRow(id: 3, ts: 1_790_208_000, canon: "fixture.noise", app: "折叠示例（虚构）",
                                who: "固定折叠示例", text: "这条通知用于测试展开噪音。", redacted: false, unread: false)
            groups.append(SourceGroup(canon: "fixture.noise", app: "折叠示例（虚构）", rows: [noise]))
        }
        return DaySnapshot(date: "2026-09-24", groups: groups, unread: rows.filter(\.unread).count,
                           total: 3, muted: includeAll ? 0 : 1)
    }
}

private final class UISelfTestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "fixture.invalid", request.httpMethod == "GET" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        let body: String
        switch url.path {
        case "/native/api/index":
            body = #"{"days":[{"date":"2026-09-24","total":2,"headline":"界面验收（虚构）","agendaOpen":1}],"lastSync":1790208000,"timezone":"Asia/Shanghai"}"#
        case "/native/api/open":
            body = #"{"items":[{"id":1,"title":"验收待办（虚构）","status":"open"}]}"#
        case "/native/api/day/2026-09-24":
            body = #"{"date":"2026-09-24","total":2,"items":[{"ts":1790208000,"app":"日历","who":"验收通知（虚构）","lines":["固定示例，不含个人数据。"],"redacted":false},{"ts":1790207900,"app":"提醒事项","who":"读书计划（虚构）","lines":["今晚读书二十分钟。"],"redacted":false}],"summary":{"headline":"界面验收（虚构）","text":"两个固定示例用于原生界面验收。"},"agenda":[{"id":1,"title":"验收待办（虚构）","status":"open"}],"cloudNotes":[{"id":1,"text":"验收笔记（虚构）","ts":1790208000}]}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
