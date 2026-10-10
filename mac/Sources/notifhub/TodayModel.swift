import AppKit
import Foundation
import SwiftUI


@MainActor
final class MenuBadge: ObservableObject {
    @Published fileprivate(set) var unread = 0
}

@MainActor
final class TodayModel: ObservableObject {

    static let shared: TodayModel = {
        guard CommandLine.arguments.contains("--demo") else { return TodayModel() }
        let model = UISelfTest.makeDemoTodayModel()
        model.refresh() // Same worker/publish path; no database watcher or production reader.
        return model
    }()

    let badge = MenuBadge()

    @Published private(set) var snap = DaySnapshot(date: Recap.today())
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var actionProblem: String?
    @Published private(set) var writing = false
    @Published private(set) var openingRecap = false
    @Published var includeAll = false {
        didSet { refresh() }
    }

    var dbPath: String { Paths.db.path }

    private var busy = false
    private var revision = 0
    private let worker = DispatchQueue(label: "cyou.tianli.notifhubbar.data", qos: .userInitiated)
    private let loader: (Bool) -> DaySnapshot
    private let writer: ([Int64]) throws -> Void
    private let recap: (Bool) throws -> URL
    private let opener: (URL) -> Bool
    private var watcher: DataWatcher?
    private var fallback: Timer?
    private var dayTimer: Timer?
    private var systemObservers: [NSObjectProtocol] = []
    private let probeState = ProbeState()
    private(set) var loadCount = 0

    private final class ProbeState: @unchecked Sendable {
        var enabled = false
        var eventReloadGap: TimeInterval = 60
        var lastEventReload: DispatchTime?
        var reloadScheduled = false
        var dbPath = ""
        var rulesURL = URL(fileURLWithPath: "/")
        var loaded: DayFingerprint?
        let probe = TodayProbe()
        func current() -> DayFingerprint? { probe.fingerprint(dbPath: dbPath, rulesURL: rulesURL) }
    }

    init(startAutomatically: Bool = true,
         loader: @escaping (Bool) -> DaySnapshot = TodayModel.load,
         writer: @escaping ([Int64]) throws -> Void = TodayModel.writeRead,
         recap: @escaping (Bool) throws -> URL = { _ in TodayModel.onlineRecapURL },
         opener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         eventReloadGap: TimeInterval = 60) {
        self.loader = loader
        self.writer = writer
        self.recap = recap
        self.opener = opener
        guard startAutomatically else { return }
        let dbPath = Paths.db.path, rulesURL = Paths.configFile, state = probeState
        worker.async {
            state.dbPath = dbPath
            state.rulesURL = rulesURL
            state.eventReloadGap = eventReloadGap
            state.enabled = true
        }
        refresh()
        startWatching()
        scheduleDayRollover()
        let wake = NSWorkspace.shared.notificationCenter
        let local = NotificationCenter.default
        let react: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.dataMayHaveChanged(resetTimeZone: true)
                self?.scheduleDayRollover()
            }
        }
        systemObservers = [
            wake.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: react),
            local.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: react),
            local.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: react),
        ]
    }

    func refresh() {
        revision += 1
        startRefresh()
    }

    nonisolated func dataMayHaveChanged(resetTimeZone: Bool = false) {
        let state = probeState
        let worker = self.worker
        worker.async { [weak self] in
            if resetTimeZone { state.probe.resetTimeZone() }
            guard state.enabled, !state.reloadScheduled else { return }
            if let now = state.current(), now == state.loaded { return }
            var wait = 0.0
            if let last = state.lastEventReload {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1e9
                wait = max(0, state.eventReloadGap - elapsed)
            }
            state.reloadScheduled = true
            worker.asyncAfter(deadline: .now() + wait) {
                state.reloadScheduled = false
                state.lastEventReload = .now()
                DispatchQueue.main.async { self?.refresh() }
            }
        }
    }

    private func startWatching() {
        watcher = nil
        let dirs = [Paths.dataDir, Paths.configFile.deletingLastPathComponent()]
        let files = [Paths.db, URL(fileURLWithPath: Paths.db.path + "-wal"), Paths.configFile]
        watcher = DataWatcher(dirs: dirs, files: files, onChange: { [weak self] in
            self?.dataMayHaveChanged()
        }, onLost: { [weak self] in
            Task { @MainActor in
                self?.startWatching()
                self?.dataMayHaveChanged()
            }
        })
        if watcher != nil {
            fallback?.invalidate()
            fallback = nil
        } else if fallback == nil {
            fallback = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.startWatching()
                    self.dataMayHaveChanged()
                }
            }
        }
    }

    nonisolated static func nextDayStart(after date: Date, in tz: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        guard let start = calendar.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                            matchingPolicy: .nextTime) else { return nil }
        return start.addingTimeInterval(1)
    }

    private func scheduleDayRollover() {
        dayTimer?.invalidate()
        guard let fire = Self.nextDayStart(after: Date(), in: Clock.tz) else { return }
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dataMayHaveChanged()
                self?.scheduleDayRollover()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        dayTimer = timer
    }

    private func startRefresh() {
        guard !busy else { return }
        busy = true
        loading = true
        let requestedRevision = revision
        let includeAll = self.includeAll
        let loader = self.loader
        let state = probeState
        worker.async {
            if state.enabled { state.loaded = state.current() }
            let snapshot = loader(includeAll)
            DispatchQueue.main.async {
                self.busy = false
                guard requestedRevision == self.revision else {
                    self.startRefresh()
                    return
                }
                self.loadCount += 1
                if snapshot != self.snap { self.snap = snapshot }
                if self.badge.unread != snapshot.unread { self.badge.unread = snapshot.unread }
                self.refreshedAt = snapshot.problem == nil ? Date() : nil
                self.loading = false
            }
        }
    }

    func markRead(_ rows: [FeedRow]) {
        let ids = rows.filter(\.unread).map(\.id)
        guard !ids.isEmpty, !writing else { return }
        writing = true
        actionProblem = nil
        revision += 1
        let writer = self.writer
        worker.async {
            var problem: String?
            do { try writer(ids) }
            catch { problem = "标已读失败：\(error.localizedDescription)" }
            let result = problem
            DispatchQueue.main.async {
                self.writing = false
                self.actionProblem = result
                self.refresh()
            }
        }
    }

    func markAllRead() {
        markRead(snap.groups.flatMap(\.rows))
    }

    nonisolated static var onlineRecapURL: URL { URL(string: Publish.siteURL)! }

    func openFullRecap() {
        guard !openingRecap else { return }
        openingRecap = true
        actionProblem = nil
        let includeAll = self.includeAll
        let recap = self.recap
        worker.async {
            let result = Result { try recap(includeAll) }
            DispatchQueue.main.async {
                self.openingRecap = false
                switch result {
                case .success(let url):
                    if !self.opener(url) { self.actionProblem = "无法打开完整复盘：\(url.absoluteString)" }
                case .failure(let error):
                    self.actionProblem = "完整复盘失败：\(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated static func writeRead(_ ids: [Int64]) throws {
        try Today.markRead(ids)
    }

    nonisolated static func renderRecap(_ includeAll: Bool) throws -> URL {
        let store = try Today.existingStore()
        let date = Recap.today()
        let config = Config.load()
        let day = Recap.load(store: store, date: date, includeAll: includeAll, config: config)
        let url = Paths.dataDir.appendingPathComponent("day-\(date).html")
        try Recap.renderHTML(day, config: config).write(to: url, atomically: true, encoding: .utf8)
        return url
    }


    nonisolated static func load(includeAll: Bool) -> DaySnapshot {
        Today.load(includeAll: includeAll)
    }
}
