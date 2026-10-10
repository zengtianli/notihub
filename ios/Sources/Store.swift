import Foundation
import Observation

@Observable @MainActor
final class Store {
    var open: [Agenda] = []
    var openError: FeedError?
    var openAt: Date?
    var index: [IndexDay] = []
    var indexError: FeedError?
    var indexAt: Date?
    var lastSync: Date?
    var cloudTimezone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    var days: [String: FeedDay] = [:]
    var dayError: [String: FeedError] = [:]
    var dayAt: [String: Date] = [:]
    var loading = false
    @ObservationIgnored private let api: API
    @ObservationIgnored private var dayRevision: [String: Int] = [:]
    @ObservationIgnored private var dayRequests: [String: Task<(value: FeedDay?, error: FeedError?, cachedAt: Date?), Never>] = [:]

    init(api: API = .shared) {
        self.api = api
        #if DEBUG
        if DemoData.enabled { DemoData.load(into: self); return }
        #endif
        if let (value, at) = api.cache.load("/api/index", as: FeedIndex.self, api: api) {
            applyIndex(value); indexAt = at
        }
        if let (value, at) = api.cache.load("/api/open", as: FeedOpen.self, api: api) {
            open = value.items.sorted { $0.sortKey < $1.sortKey }; openAt = at
        }
    }

    nonisolated static let dayTZ = TimeZone(identifier: "Asia/Shanghai") ?? .current
    nonisolated static func dayString(_ date: Date = Date(), timezone: TimeZone = dayTZ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static var today: String { dayString() }
    var displayToday: String { Self.dayString(timezone: cloudTimezone) }
    var dayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = cloudTimezone
        return calendar
    }
    var latestDate: String { index.first?.date ?? displayToday }
    var landingDate: String {
        index.first(where: { $0.date <= displayToday })?.date ?? displayToday
    }

    private func applyIndex(_ value: FeedIndex) {
        Remote.ui = value.ui?.value
        index = value.days
        cloudTimezone = TimeZone(identifier: value.timezone) ?? cloudTimezone
        lastSync = Date(timeIntervalSince1970: value.lastSync)
    }

    func refresh() async {
        #if DEBUG
        if DemoData.enabled { return }
        #endif
        guard !loading else { return }
        loading = true
        defer { loading = false }
        async let openResult = api.get("/api/open", as: FeedOpen.self)
        async let indexResult = api.get("/api/index", as: FeedIndex.self)
        let (ov, oe, oat) = await openResult
        let (iv, ie, iat) = await indexResult
        if let value = ov { open = value.items.sorted { $0.sortKey < $1.sortKey } }
        openError = oe; openAt = oat
        if let value = iv { applyIndex(value) }
        indexError = ie; indexAt = iat
    }

    @discardableResult
    func day(_ date: String, force: Bool = false) async -> FeedDay? {
        #if DEBUG
        if DemoData.enabled { return days[date] }
        #endif
        let path = "/api/day/" + date
        if days[date] == nil, let (value, at) = api.cache.load(path, as: FeedDay.self, api: api) {
            days[date] = value; dayAt[date] = at
        }
        if !force, let value = days[date], let at = dayAt[date],
           Date().timeIntervalSince(at) < 60, dayError[date] == nil { return value }
        let revision: Int
        let request: Task<(value: FeedDay?, error: FeedError?, cachedAt: Date?), Never>
        if !force, let running = dayRequests[date] {
            revision = dayRevision[date, default: 0]; request = running
        } else {
            dayRequests[date]?.cancel()
            revision = dayRevision[date, default: 0] + 1
            dayRevision[date] = revision
            request = Task { await api.get(path, as: FeedDay.self) }
            dayRequests[date] = request
        }
        let (value, error, at) = await request.value
        guard dayRevision[date] == revision else { return days[date] }
        dayRequests[date] = nil
        if let value { days[date] = value }
        if let at { dayAt[date] = at }
        dayError[date] = error
        return days[date]
    }

    func invalidateDays() {
        for date in Set(days.keys).union(dayRequests.keys) {
            dayRevision[date, default: 0] += 1
            dayRequests[date]?.cancel()
            dayRequests[date] = nil
            dayAt[date] = .distantPast
            api.cache.invalidate("/api/day/" + date)
        }
        api.cache.invalidate("/api/open")
        api.cache.invalidate("/api/index")
    }

    var overdue: [Agenda] { AgendaBuckets.overdue(open, calendar: dayCalendar) }
    var dueToday: [Agenda] { AgendaBuckets.dueToday(open, calendar: dayCalendar) }
    var undated: [Agenda] { AgendaBuckets.undated(open) }
    var upcoming: [Agenda] { AgendaBuckets.upcoming(open, calendar: dayCalendar) }
}
