import Foundation


struct WatchDigest: Codable, Equatable {
    struct Count: Codable, Equatable, Hashable {
        let name: String
        let count: Int
    }

    struct Item: Codable, Equatable, Identifiable {
        let ts: Double
        let app: String
        let who: String
        let line: String
        let missed: Bool
        var id: String { "\(ts)-\(app)-\(who)" }
    }

    let date: String          // 摘要的是哪一天（yyyy-MM-dd，云端时区）—— 早上 notifhub 还没发布今天时是最近一天
    let timezone: String      // 云端时区：判「是不是今天」、显示时刻都按它
    let total: Int            // 原始通知条数
    let events: Int           // 合并后的件数
    let muted: Int            // 折叠的噪音
    let unread: Int           // 至今没点开的件数（FeedItem.missed）
    let notes: Int            // 随手记条数
    let headline: String      // LLM 一句话；没总结时是空串
    let apps: [Count]         // 按 App 计数，最多 5 个
    let whos: [Count]         // 聊得最多，最多 3 个
    let top: [Item]           // 未读在前、再按时间倒序，最多 6 条
    let dueToday: Int
    let overdue: Int
    let lastSync: Double?     // 云端最后一次同步（Mac 采集）的时刻
    var ui: Lenient<FeedUI>? = nil

    static let contextKey = "digest"
    static let topLimit = 6
    static let lineLimit = 80

    static let carriedCopy: Set<String> = ["today.group.today", "today.group.overdue", "watch.day_stale",
                                           "watch.sync_at", "watch.sync_never", "watch.no_apps",
                                           "watch.no_items", "watch.not_today"]
    static let carriedLimits: Set<String> = ["stale_seconds"]
    static let carriedCopyLimit = 80

    static func carried(_ ui: FeedUI?) -> Lenient<FeedUI>? {
        guard let ui else { return nil }
        let copy = (ui.copy ?? [:]).filter {
            carriedCopy.contains($0.key) && !$0.value.isEmpty && $0.value.count <= carriedCopyLimit
        }
        let limits = (ui.limits ?? [:]).filter { carriedLimits.contains($0.key) && $0.value.isFinite }
        if copy.isEmpty && limits.isEmpty { return nil }
        return Lenient(FeedUI(copy: copy.isEmpty ? nil : copy, limits: limits.isEmpty ? nil : limits))
    }

    static var staleAfter: TimeInterval { Remote.seconds("stale_seconds", 3 * 3600, in: 600...86_400) }

    static func make(day: FeedDay, open: [Agenda], timezone: TimeZone, lastSync: Date?,
                     ui: FeedUI? = nil, now: Date = Date()) -> WatchDigest {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let picked = day.items.sorted { a, b in
            a.missed != b.missed ? a.missed : a.ts > b.ts
        }.prefix(topLimit)
        return WatchDigest(
            date: day.date, timezone: timezone.identifier,
            total: day.total, events: day.items.count, muted: day.muted,
            unread: day.items.filter(\.missed).count,
            notes: day.notes + day.cloudNotes.count,
            headline: day.summary?.headline ?? "",
            apps: counts(day.apps, limit: 5), whos: counts(day.whos, limit: 3),
            top: picked.map { item in
                Item(ts: item.ts, app: item.app, who: item.who, line: firstLine(item), missed: item.missed)
            },
            dueToday: AgendaBuckets.dueToday(open, calendar: calendar, now: now).count,
            overdue: AgendaBuckets.overdue(open, calendar: calendar, now: now).count,
            lastSync: lastSync?.timeIntervalSince1970,
            ui: carried(ui))
    }

    private static func counts(_ rows: [[String]], limit: Int) -> [Count] {
        Array(rows.compactMap { row in
            guard row.count == 2, let n = Int(row[1]) else { return nil }
            return Count(name: row[0], count: n)
        }.prefix(limit))
    }

    private static func firstLine(_ item: FeedItem) -> String {
        if item.redacted { return T("watch.redacted", "正文已按保留期抹除") }
        let line = item.lines.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        return line.count > lineLimit ? String(line.prefix(lineLimit)) + "…" : line
    }

    var cloudTimeZone: TimeZone { TimeZone(identifier: timezone) ?? .current }

    func isToday(_ now: Date = Date()) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = cloudTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now) == date
    }

    func isOlder(than other: WatchDigest) -> Bool {
        (date, lastSync ?? 0) < (other.date, other.lastSync ?? 0)
    }
}
