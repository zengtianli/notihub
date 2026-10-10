import Foundation


struct FeedRow: Identifiable, Hashable {
    let id: Int64
    let ts: Double
    let canon: String
    let app: String
    let who: String          // 标题位：微信是发信人、短信是号码、其他是通知标题
    let text: String
    let redacted: Bool       // 过了保留期，正文已被抹除
    var unread: Bool
}

struct SourceGroup: Identifiable, Equatable {
    var id: String { canon }
    let canon: String
    let app: String
    var rows: [FeedRow]
    var unread: Int { rows.reduce(0) { $0 + ($1.unread ? 1 : 0) } }
}

struct DaySnapshot: Equatable {
    var date: String
    var groups: [SourceGroup] = []
    var unread = 0
    var total = 0            // 只数通知，不含随手记（口径同 Recap.Day.total）
    var muted = 0            // 按 rules.json 的 muteInViews 折叠掉的噪音
    var notes = 0
    var first: Double?
    var last: Double?
    var problem: String?
}

extension Store {

    func feed(date: String, muteFilter: (String, String) -> Bool) -> (rows: [FeedRow], total: Int, muted: Int) {
        var rows: [FeedRow] = []
        var total = 0, muted = 0
        let range = Today.dayRange(date)
        let sql = """
            SELECT id, ts, canon, app, COALESCE(title,''), COALESCE(body,''), redacted, dismissed_at, rec_id
              FROM events
             WHERE ts >= ? AND ts < ? AND \(Clock.sqlDay("ts")) = ?
             ORDER BY ts DESC
            """
        db.query(sql, [range.lo, range.hi, date]) { r in
            total += 1
            let canon = r.str(2), app = r.str(3)
            if muteFilter(canon, app) { muted += 1; return }
            let title = r.str(4), body = r.str(5)
            rows.append(FeedRow(
                id: r.int(0),
                ts: r.dbl(1),
                canon: canon,
                app: app,
                who: title.isEmpty ? app : title,
                text: Recap.stripANSI(body.isEmpty ? title : body),
                redacted: r.int(6) == 1,
                unread: r.isNull(7) && !r.isNull(8)))
        }
        return (rows, total, muted)
    }

    @discardableResult
    func markRead(ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let holes = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let binds: [Any?] = [nowUnix()] + ids.map { $0 as Any? }
        guard db.run("UPDATE events SET dismissed_at=? WHERE id IN (\(holes)) AND dismissed_at IS NULL", binds)
        else { throw NSError(domain: "Notihub.Database", code: 1, userInfo: [NSLocalizedDescriptionKey: db.lastError]) }
        return db.changes
    }
}

enum Today {

    static func utcMidnight(_ day: String) -> Double? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        let m = p[1], d = p[2]
        let y = p[0] - (m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Double(era * 146_097 + doe - 719_468) * 86_400
    }

    static func dayRange(_ day: String, offsetMinutes: Int? = nil) -> (lo: Double, hi: Double) {
        let minutes = offsetMinutes ?? Clock.tz.secondsFromGMT(for: Date()) / 60
        let midnight = utcMidnight(day) ?? Date().timeIntervalSince1970
        let start = midnight - Double(minutes * 60)
        return (start - 86_400, start + 2 * 86_400)
    }

    static func existingStore(readOnly: Bool = false) throws -> Store {
        guard FileManager.default.fileExists(atPath: Paths.db.path) else {
            throw NSError(domain: "Notihub.Database", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "读不到 \(Paths.db.path)，请先运行 notihub install"])
        }
        guard let store = readOnly ? Store(readOnlyAt: Paths.db.path) : Store() else {
            throw NSError(domain: "Notihub.Database", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "打不开 \(Paths.db.path)（权限或库损坏）"])
        }
        return store
    }

    static func muteFilter(config: Config, includeAll: Bool) -> (String, String) -> Bool {
        let muteSet = includeAll ? Set<String>() : Set(config.muteInViews.map { $0.lowercased() })
        return { canon, app in
            if muteSet.isEmpty { return false }
            let tail = canon.split(separator: ".").last.map(String.init) ?? canon
            return muteSet.contains(canon.lowercased())
                || muteSet.contains(tail.lowercased())
                || muteSet.contains(app.lowercased())
        }
    }

    static func load(includeAll: Bool, readOnly: Bool = false) -> DaySnapshot {
        let date = Recap.today()
        var snap = DaySnapshot(date: date)

        guard FileManager.default.fileExists(atPath: Paths.db.path) else {
            snap.problem = "读不到 \(Paths.db.path)\n采集还没装：终端跑 notifhub install"
            return snap
        }
        let store: Store
        do { store = try existingStore(readOnly: readOnly) }
        catch { snap.problem = "打不开 \(Paths.db.path)（权限或库损坏）"; return snap }

        let config = Config.load()
        let (rows, total, mutedCount) = store.feed(date: date, muteFilter: muteFilter(config: config, includeAll: includeAll))
        snap.total = total
        snap.muted = mutedCount
        snap.unread = rows.reduce(0) { $0 + ($1.unread ? 1 : 0) }
        snap.notes = store.notes(date: date).count
        snap.first = rows.last?.ts
        snap.last = rows.first?.ts

        var order: [String] = []
        var byCanon: [String: SourceGroup] = [:]
        for r in rows {
            if byCanon[r.canon] == nil {
                order.append(r.canon)
                byCanon[r.canon] = SourceGroup(canon: r.canon, app: r.app, rows: [])
            }
            byCanon[r.canon]?.rows.append(r)
        }
        snap.groups = order.compactMap { byCanon[$0] }
            .sorted { a, b in
                if (a.unread > 0) != (b.unread > 0) { return a.unread > 0 }
                if a.unread != b.unread { return a.unread > b.unread }
                return a.rows.count > b.rows.count
            }
        return snap
    }

    @discardableResult
    static func markRead(_ ids: [Int64]) throws -> Int {
        let store = try existingStore()
        return try store.markRead(ids: ids)
    }
}
