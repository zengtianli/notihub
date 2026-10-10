#if DEBUG
import EventKit
import Foundation


enum ReminderSelfTest {
    private static var started = false

    @MainActor static func runIfRequested() {
        let requested = UserDefaults.standard.string(forKey: "reminderSelfTest") ?? ""
        let name = (requested as NSString).lastPathComponent
        guard !name.isEmpty, !started else { return }
        started = true
        Task { @MainActor in
            let report = await run()
            write(report, name: name)
            exit(0)
        }
    }


    private static let tzID = "Asia/Shanghai"

    @MainActor private final class Recorder {
        var checks: [String: Bool] = [:]
        var failures: [String] = []
        var extra: [String: Any] = [:]

        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            checks[name] = ok
            if !ok { failures.append(detail().isEmpty ? name : "\(name): \(detail())") }
        }

        func report() -> [String: Any] {
            var out = extra
            out["ok"] = failures.isEmpty && !checks.isEmpty && checks.values.allSatisfy { $0 }
            out["checks"] = checks
            out["failures"] = failures
            out["at"] = ISO8601DateFormatter().string(from: Date())
            out["environment"] = "iOS Simulator · Debug · synthetic data"
            if out["url_readback"] == nil { out["url_readback"] = false }
            if out["dedup_ms"] == nil { out["dedup_ms"] = -1 }
            if out["reminders_total_scanned"] == nil { out["reminders_total_scanned"] = 0 }
            return out
        }
    }

    @MainActor private static func run() async -> [String: Any] {
        let r = Recorder()

        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .fullAccess else {
            r.extra["reason"] = "authorizationStatus(for: .reminder) = \(status.rawValue)，不是 fullAccess"
            r.check("authorization_full_access", false, "status rawValue \(status.rawValue)")
            return r.report()
        }
        r.check("authorization_full_access", true)

        guard let shanghai = TimeZone(identifier: tzID) else {
            r.check("timezone", false, tzID)
            return r.report()
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = shanghai

        let writer = EKEventStore()
        let stamp = Int(Date().timeIntervalSince1970)
        let list = EKCalendar(for: .reminder, eventStore: writer)
        list.title = "Notihub-selftest-\(stamp)"
        guard let source = writer.defaultCalendarForNewReminders()?.source
            ?? writer.sources.first(where: { $0.sourceType == .local })
            ?? writer.sources.first(where: { !$0.calendars(for: .reminder).isEmpty }) else {
            r.check("temp_list_created", false, "找不到可建提醒列表的 source")
            return r.report()
        }
        list.source = source
        do {
            try writer.saveCalendar(list, commit: true)
            r.check("temp_list_created", true)
        } catch {
            r.check("temp_list_created", false, error.localizedDescription)
            return r.report()
        }
        let listID = list.calendarIdentifier
        r.extra["source_type"] = source.sourceType.rawValue

        await body(writer: writer, list: list, listID: listID, calendar: cal, timezone: shanghai, stamp: stamp, r: r)

        do {
            if let target = writer.calendar(withIdentifier: listID) {
                try writer.removeCalendar(target, commit: true)
            }
            let verify = EKEventStore()
            r.check("temp_list_removed", verify.calendar(withIdentifier: listID) == nil, "删除后仍能读到临时列表")
        } catch {
            r.check("temp_list_removed", false, error.localizedDescription)
        }
        return r.report()
    }

    @MainActor private static func body(writer: EKEventStore, list: EKCalendar, listID: String, calendar cal: Calendar,
                                        timezone: TimeZone, stamp: Int, r: Recorder) async {
        let base = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: Date()))!
        let timedAt = cal.date(bySettingHour: 9, minute: 30, second: 0, of: base)!
        let dayText: String = {
            let c = cal.dateComponents([.year, .month, .day], from: base)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }()
        func agenda(_ id: Int64, _ title: String, due: Date?, allDay: Bool) -> Agenda {
            Agenda(id: id, kind: "todo", title: "\(title)·\(stamp)", note: "合成自检备注",
                   dueTS: due?.timeIntervalSince1970, endTS: nil, allDay: allDay, who: "自检来源",
                   evidence: "合成原文", status: "open", source: "manual", srcDate: dayText, pushed: false)
        }
        let timed = agenda(900_001, "自检·有时刻", due: timedAt, allDay: false)
        let allDay = agenda(900_002, "自检·全天", due: base, allDay: true)
        let undated = agenda(900_003, "自检·无到期", due: nil, allDay: false)
        let info = ReminderListInfo(id: listID, title: list.title)
        let items = [("timed", timed), ("allday", allDay), ("undated", undated)]
        let drafts = items.map { ($0.0, $0.1, ReminderPlan.make(agenda: $0.1, timezone: timezone, list: info)) }

        let writeStore = EventKitReminderStore(eventStore: writer)
        var saveOK = true
        for (name, _, draft) in drafts {
            do { try writeStore.save(draft) } catch {
                saveOK = false
                r.check("save_\(name)", false, error.localizedDescription)
            }
        }
        r.check("save_all", saveOK, "写入失败")
        guard saveOK else { return }

        let reader = EKEventStore()
        let readStore = EventKitReminderStore(eventStore: reader)
        let rows: [ReminderRow]
        do {
            rows = try await readStore.fetch(.incomplete(start: nil, end: nil), listIDs: [listID])
        } catch {
            r.check("readback_fetch", false, error.localizedDescription)
            return
        }
        r.check("readback_count_3", rows.count == 3, "读回 \(rows.count) 条")
        let alarmCounts: [String: Int] = await withCheckedContinuation { continuation in
            let calendars = reader.calendars(for: .reminder).filter { $0.calendarIdentifier == listID }
            let predicate = reader.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil,
                                                                   calendars: calendars)
            reader.fetchReminders(matching: predicate) { reminders in
                var out: [String: Int] = [:]
                for r in reminders ?? [] { out[r.calendarItemIdentifier] = r.alarms?.count ?? 0 }
                continuation.resume(returning: out)
            }
        }

        var urlAll = true
        for (name, _, draft) in drafts {
            guard let row = rows.first(where: { $0.title == draft.title }) else {
                r.check("\(name)_found", false, "新实例读不到该条")
                urlAll = false
                continue
            }
            r.check("\(name)_title", row.title == draft.title)
            let lastLine = row.notes?.split(separator: "\n").last.map(String.init)
            r.check("\(name)_notes", row.notes == draft.notes && lastLine == ReminderMarker.noteLine(draft.key),
                  "notes 与计划不一致或末行无标记")
            r.check("\(name)_marker_key", row.notihubKey == draft.key, "标记键 \(row.notihubKey ?? "nil")")
            let due = row.due
            switch name {
            case "timed":
                let want = cal.dateComponents([.year, .month, .day, .hour, .minute], from: timedAt)
                let ok = due?.year == want.year && due?.month == want.month && due?.day == want.day
                    && due?.hour == want.hour && due?.minute == want.minute && due?.timeZone?.identifier == tzID
                r.check("timed_due", ok, "due=\(describe(due))")
                r.check("timed_alarm_1", alarmCounts[row.id] == 1, "alarms=\(alarmCounts[row.id] ?? -1)")
                r.check("timed_absolute_due", row.dueDate(in: Calendar(identifier: .gregorian)) == timedAt,
                      "绝对时刻不符")
            case "allday":
                let want = cal.dateComponents([.year, .month, .day], from: base)
                let ok = due?.year == want.year && due?.month == want.month && due?.day == want.day
                    && due?.hour == nil && due?.minute == nil && due?.timeZone == nil
                r.check("allday_due", ok, "due=\(describe(due))")
                r.check("allday_alarm_0", alarmCounts[row.id] == 0, "alarms=\(alarmCounts[row.id] ?? -1)")
            default:
                r.check("undated_due_nil", due == nil, "due=\(describe(due))")
                r.check("undated_alarm_0", alarmCounts[row.id] == 0, "alarms=\(alarmCounts[row.id] ?? -1)")
            }
            let urlBack = row.url == draft.url
            r.extra["url_\(name)"] = row.url?.absoluteString ?? "nil"
            if !urlBack { urlAll = false }
        }
        r.extra["url_readback"] = urlAll   // 如实记录；读不回不算失败，备注末行兜底。

        let dayState = await ReminderDay.fetch(date: dayText, calendar: cal, store: readStore)
        r.extra["day_date"] = dayText
        if case .loaded(let dayRows) = dayState {
            let mine = dayRows.filter { $0.listID == listID }
            let timedRow = mine.first { $0.title == timed.title }
            let allRow = mine.first { $0.title == allDay.title }
            r.check("day_loaded_contains_timed_allday", timedRow != nil && allRow != nil,
                  "临时列表当天行 \(mine.map(\.title))")
            r.check("day_added_by_notihub", timedRow?.addedByNotihub == true && allRow?.addedByNotihub == true)
            r.check("day_excludes_undated", !mine.contains { $0.title == undated.title })
        } else {
            r.check("day_loaded_contains_timed_allday", false, "ReminderDay 状态 \(dayState)")
        }

        let counter = CountingStore(readStore)
        let key = ReminderPlan.key(for: timed)
        let clock = ContinuousClock()
        var hit: ReminderRow?
        var dedupError: String?
        let elapsed = await clock.measure {
            do { hit = try await ReminderDedup.find(agenda: timed, key: key, store: counter, timezone: timezone) }
            catch { dedupError = error.localizedDescription }
        }
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        r.extra["dedup_ms"] = (ms * 100).rounded() / 100
        r.extra["reminders_total_scanned"] = counter.scanned
        r.check("dedup_hit_timed", hit?.listID == listID && hit?.notihubKey == key,
              dedupError ?? "未命中临时列表里的有时刻项")
        let missAgenda = agenda(900_004, "自检·不存在", due: timedAt, allDay: false)
        let miss = try? await ReminderDedup.find(agenda: missAgenda, key: ReminderPlan.key(for: missAgenda),
                                                 store: readStore, timezone: timezone)
        r.check("dedup_miss_other", miss == nil, "不存在的事项被误判重复")
    }

    private static func describe(_ due: DateComponents?) -> String {
        guard let due else { return "nil" }
        return "y\(due.year ?? -1) m\(due.month ?? -1) d\(due.day ?? -1) h\(due.hour.map(String.init) ?? "nil") "
            + "min\(due.minute.map(String.init) ?? "nil") tz\(due.timeZone?.identifier ?? "nil")"
    }

    private static func write(_ report: [String: Any], name: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            print("reminderSelfTest ok=\(report["ok"] ?? false) → \(url.path)")
        } catch {
            print("reminderSelfTest 写结果失败：\(error.localizedDescription)")
        }
    }
}

private final class CountingStore: ReminderStore {
    let inner: ReminderStore
    var scanned = 0
    init(_ inner: ReminderStore) { self.inner = inner }
    func authorization() -> ReminderAuth { inner.authorization() }
    func requestFullAccess() async throws -> Bool { try await inner.requestFullAccess() }
    func lists() -> [ReminderListInfo] { inner.lists() }
    func defaultList() -> ReminderListInfo? { inner.defaultList() }
    func fetch(_ query: ReminderQuery, listIDs: [String]?) async throws -> [ReminderRow] {
        let rows = try await inner.fetch(query, listIDs: listIDs)
        scanned += rows.count
        return rows
    }
    @discardableResult func save(_ draft: ReminderDraft) throws -> ReminderRow { try inner.save(draft) }
    func remove(id: String) throws { try inner.remove(id: id) }
}
#endif
