import CryptoKit
import EventKit
import Foundation
import Observation


enum ReminderAuth: Equatable {
    case notDetermined
    case denied(String)
    case fullAccess
}

struct ReminderListInfo: Hashable, Identifiable {
    let id: String          // calendarIdentifier；设备 AppStorage 只存它
    let title: String
}

struct ReminderRow: Hashable, Identifiable {
    let id: String          // calendarItemIdentifier
    let title: String
    let notes: String?
    let url: URL?
    let listID: String
    let listName: String
    let due: DateComponents?
    let completed: Bool
    let completionDate: Date?

    var notihubKey: String? { ReminderMarker.key(url: url, notes: notes) }
    var addedByNotihub: Bool { notihubKey != nil }

    func dueDate(in calendar: Calendar) -> Date? {
        guard let due, due.year != nil, due.month != nil, due.day != nil else { return nil }
        var cal = calendar
        if let tz = due.timeZone { cal.timeZone = tz }
        var parts = due
        parts.calendar = nil
        parts.timeZone = nil
        return cal.date(from: parts)
    }

    var isDateOnly: Bool { due != nil && due?.hour == nil }
}

struct ReminderDraft: Equatable {
    let key: String
    let title: String
    let notes: String
    let url: URL
    let due: DateComponents?
    let alarm: Date?        // 到点提醒（仅有时刻的项）
    let listID: String
}

enum ReminderQuery: Equatable {
    case incomplete(start: Date?, end: Date?)
    case completed(start: Date, end: Date)
}

protocol ReminderStore: AnyObject {
    func authorization() -> ReminderAuth
    func requestFullAccess() async throws -> Bool
    func lists() -> [ReminderListInfo]
    func defaultList() -> ReminderListInfo?
    func fetch(_ query: ReminderQuery, listIDs: [String]?) async throws -> [ReminderRow]
    @discardableResult func save(_ draft: ReminderDraft) throws -> ReminderRow
    func remove(id: String) throws
}


enum ReminderMarker {
    static let scheme = "notihub"
    static let notePrefix = "notihub:agenda/"

    static func url(_ key: String) -> URL { URL(string: "\(scheme)://agenda/\(key)")! }
    static func noteLine(_ key: String) -> String { notePrefix + key }

    static func key(url: URL?, notes: String?) -> String? {
        if let url, url.scheme == scheme, url.host == "agenda" {
            let key = url.lastPathComponent
            if !key.isEmpty, key != "/" { return key }
        }
        let last = notes?.split(separator: "\n", omittingEmptySubsequences: true).last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let last, last.hasPrefix(notePrefix) {
            let key = String(last.dropFirst(notePrefix.count))
            return key.isEmpty ? nil : key
        }
        return nil
    }
}

enum ReminderPlan {
    static func key(for agenda: Agenda) -> String {
        let due = agenda.dueTS.map { String(format: "%.0f", $0) } ?? ""
        let raw = [agenda.kind, agenda.title, agenda.srcDate ?? "", due].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static func notes(for agenda: Agenda, key: String) -> String {
        let lines: [String?] = [agenda.note, agenda.evidence.map { "原文：\($0)" }, agenda.who.map { "来源：\($0)" },
                                agenda.srcDate.map { "抽自 \($0) 的复盘" }]
        let body = lines.compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (body + [ReminderMarker.noteLine(key)]).joined(separator: "\n")
    }

    static func make(agenda: Agenda, timezone: TimeZone, list: ReminderListInfo) -> ReminderDraft {
        let key = key(for: agenda)
        var due: DateComponents?
        var alarm: Date?
        if let at = agenda.due {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timezone
            if agenda.allDay {
                due = cal.dateComponents([.year, .month, .day], from: at)
            } else {
                var parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                parts.timeZone = timezone
                due = parts
                alarm = at
            }
        }
        return ReminderDraft(key: key, title: agenda.title, notes: notes(for: agenda, key: key),
                             url: ReminderMarker.url(key), due: due, alarm: alarm, listID: list.id)
    }
}


enum ReminderListChoice {
    static func resolve(savedID: String?, lists: [ReminderListInfo], default fallback: ReminderListInfo?)
        -> (list: ReminderListInfo?, notice: String?) {
        if let savedID, !savedID.isEmpty {
            if let hit = lists.first(where: { $0.id == savedID }) { return (hit, nil) }
            let target = fallback ?? lists.first
            return (target, target.map { "之前选的列表已不存在，改用「\($0.title)」" } ?? "之前选的列表已不存在")
        }
        return (fallback ?? lists.first, nil)
    }
}


enum ReminderDedup {
    static let completedWindow: TimeInterval = 30 * 86_400

    static func find(agenda: Agenda, key: String, store: ReminderStore, timezone: TimeZone,
                     now: Date = Date()) async throws -> ReminderRow? {
        let open = try await store.fetch(.incomplete(start: nil, end: nil), listIDs: nil)
        let done = try await store.fetch(.completed(start: now.addingTimeInterval(-completedWindow), end: now), listIDs: nil)
        let rows = open + done
        if let hit = rows.first(where: { $0.notihubKey == key }) { return hit }
        guard agenda.pushed else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let title = agenda.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.first { row in
            guard row.title.trimmingCharacters(in: .whitespacesAndNewlines) == title else { return false }
            switch (agenda.due, row.dueDate(in: cal)) {
            case (nil, nil): return true
            case let (a?, b?): return cal.isDate(a, inSameDayAs: b)
            default: return false
            }
        }
    }
}


enum ReminderSectionState: Equatable {
    case notDetermined
    case denied(String)
    case empty
    case failed(String)
    case loaded([ReminderRow])
}

enum AddOutcome: Equatable {
    case added(String)
    case alreadyThere(String)
    case denied(String)
    case failed(String)

    var isAdded: Bool { if case .added = self { return true }; return false }
}

enum ReminderText {
    static let denied = "没有访问提醒事项的权限。可以在「设置 › Notihub › 提醒事项」里改为完全访问。"
    static let writeOnly = "只有「仅添加」权限，读不到提醒。可以在「设置 › Notihub › 提醒事项」里改为完全访问。"
    static let restricted = "这台设备限制了提醒事项访问（屏幕使用时间或设备管理）。"
    static let noList = "没有可写入的提醒事项列表。"
}


enum ReminderAdder {
    static func add(agenda: Agenda, store: ReminderStore, savedListID: String?, timezone: TimeZone,
                    force: Bool = false, now: Date = Date()) async -> (outcome: AddOutcome, notice: String?) {
        switch store.authorization() {
        case .denied(let reason): return (.denied(reason), nil)
        case .notDetermined:
            let granted = (try? await store.requestFullAccess()) ?? false
            guard granted, store.authorization() == .fullAccess else { return (.denied(ReminderText.denied), nil) }
        case .fullAccess: break
        }
        let choice = ReminderListChoice.resolve(savedID: savedListID, lists: store.lists(), default: store.defaultList())
        guard let list = choice.list else { return (.failed(ReminderText.noList), choice.notice) }
        let draft = ReminderPlan.make(agenda: agenda, timezone: timezone, list: list)
        do {
            if !force, let hit = try await ReminderDedup.find(agenda: agenda, key: draft.key, store: store,
                                                            timezone: timezone, now: now) {
                return (.alreadyThere(hit.listName), choice.notice)
            }
            let saved = try store.save(draft)
            return (.added(saved.listName), choice.notice)
        } catch {
            return (.failed("没有加入：\(error.localizedDescription)"), choice.notice)
        }
    }
}


enum ReminderDay {
    static func bounds(date: String, calendar: Calendar) -> (start: Date, end: Date)? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }

    static func fetch(date: String, calendar: Calendar, store: ReminderStore) async -> ReminderSectionState {
        switch store.authorization() {
        case .notDetermined: return .notDetermined
        case .denied(let reason): return .denied(reason)
        case .fullAccess: break
        }
        guard let (start, end) = bounds(date: date, calendar: calendar) else { return .failed("日期无效：\(date)") }
        do {
            let open = try await store.fetch(.incomplete(start: start.addingTimeInterval(-86_400),
                                                         end: end.addingTimeInterval(86_400)), listIDs: nil)
            let done = try await store.fetch(.completed(start: start, end: end), listIDs: nil)
            let day = calendar.dateComponents([.year, .month, .day], from: start)
            let dueToday = open.filter { row in
                guard !row.completed else { return false }
                if row.isDateOnly {
                    return row.due?.year == day.year && row.due?.month == day.month && row.due?.day == day.day
                }
                guard let at = row.dueDate(in: calendar) else { return false }
                return at >= start && at < end
            }
            let doneToday = done.filter { row in
                guard row.completed, let at = row.completionDate else { return false }
                return at >= start && at < end
            }
            var seen = Set<String>()
            let rows = (dueToday + doneToday).filter { seen.insert($0.id).inserted }
            if rows.isEmpty { return .empty }
            return .loaded(rows.sorted { sortKey($0, calendar) < sortKey($1, calendar) })
        } catch {
            return .failed("读取提醒事项失败：\(error.localizedDescription)")
        }
    }

    private static func sortKey(_ row: ReminderRow, _ calendar: Calendar) -> (Int, Double, String) {
        let at = row.completed ? row.completionDate : row.dueDate(in: calendar)
        return (row.completed ? 1 : 0, at?.timeIntervalSince1970 ?? .greatestFiniteMagnitude, row.title)
    }
}


@Observable @MainActor
final class RemindersModel {
    var sections: [String: ReminderSectionState] = [:]
    var auth: ReminderAuth
    var lists: [ReminderListInfo] = []
    var defaultList: ReminderListInfo?
    var outcomes: [String: AddOutcome] = [:]
    var notices: [String: String] = [:]
    var adding: Set<String> = []

    @ObservationIgnored let store: ReminderStore
    @ObservationIgnored private var visibleDate: String?
    @ObservationIgnored private var calendar = Calendar(identifier: .gregorian)
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(store: ReminderStore) {
        self.store = store
        self.auth = store.authorization()
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.storeChanged() }
        }
    }

    func refreshAuth() {
        auth = store.authorization()
        if auth == .fullAccess {
            lists = store.lists()
            defaultList = store.defaultList()
        }
    }

    func requestAccess() async {
        _ = try? await store.requestFullAccess()
        refreshAuth()
        if let visibleDate { await load(date: visibleDate, calendar: calendar, force: true) }
    }

    func load(date: String, calendar: Calendar, force: Bool = false) async {
        visibleDate = date
        self.calendar = calendar
        auth = store.authorization()
        if !force, let cached = sections[date], case .loaded = cached { return }
        sections[date] = await ReminderDay.fetch(date: date, calendar: calendar, store: store)
    }

    func add(_ agenda: Agenda, savedListID: String?, timezone: TimeZone, force: Bool = false) async -> AddOutcome {
        let key = ReminderPlan.key(for: agenda)
        adding.insert(key)
        defer { adding.remove(key) }
        let result = await ReminderAdder.add(agenda: agenda, store: store, savedListID: savedListID,
                                             timezone: timezone, force: force)
        outcomes[key] = result.outcome
        notices[key] = result.notice
        refreshAuth()
        return result.outcome
    }

    func outcome(for agenda: Agenda) -> AddOutcome? { outcomes[ReminderPlan.key(for: agenda)] }

    private func storeChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.sections = [:]
            if let date = self.visibleDate { await self.load(date: date, calendar: self.calendar, force: true) }
        }
    }
}


final class EventKitReminderStore: ReminderStore {
    static let shared = EventKitReminderStore()
    let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) { self.eventStore = eventStore }

    func authorization() -> ReminderAuth {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .fullAccess
        case .notDetermined: return .notDetermined
        case .writeOnly: return .denied(ReminderText.writeOnly)
        case .restricted: return .denied(ReminderText.restricted)
        default: return .denied(ReminderText.denied)
        }
    }

    func requestFullAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToReminders()
    }

    func lists() -> [ReminderListInfo] {
        eventStore.calendars(for: .reminder).filter(\.allowsContentModifications)
            .map { ReminderListInfo(id: $0.calendarIdentifier, title: $0.title) }
    }

    func defaultList() -> ReminderListInfo? {
        eventStore.defaultCalendarForNewReminders().map { ReminderListInfo(id: $0.calendarIdentifier, title: $0.title) }
    }

    func fetch(_ query: ReminderQuery, listIDs: [String]?) async throws -> [ReminderRow] {
        let calendars = listIDs.map { ids in eventStore.calendars(for: .reminder).filter { ids.contains($0.calendarIdentifier) } }
        let predicate: NSPredicate
        switch query {
        case let .incomplete(start, end):
            predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: calendars)
        case let .completed(start, end):
            predicate = eventStore.predicateForCompletedReminders(withCompletionDateStarting: start, ending: end, calendars: calendars)
        }
        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.row))
            }
        }
    }

    @discardableResult
    func save(_ draft: ReminderDraft) throws -> ReminderRow {
        guard let calendar = eventStore.calendar(withIdentifier: draft.listID) else {
            throw NSError(domain: "Notihub.Reminders", code: 1, userInfo: [NSLocalizedDescriptionKey: "目标列表不存在"])
        }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.url = draft.url
        reminder.dueDateComponents = draft.due
        if let alarm = draft.alarm { reminder.addAlarm(EKAlarm(absoluteDate: alarm)) }
        try eventStore.save(reminder, commit: true)
        return Self.row(reminder)
    }

    func remove(id: String) throws {
        guard let item = eventStore.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try eventStore.remove(item, commit: true)
    }

    static func row(_ reminder: EKReminder) -> ReminderRow {
        ReminderRow(id: reminder.calendarItemIdentifier, title: reminder.title ?? "", notes: reminder.notes,
                    url: reminder.url, listID: reminder.calendar?.calendarIdentifier ?? "",
                    listName: reminder.calendar?.title ?? "", due: reminder.dueDateComponents,
                    completed: reminder.isCompleted, completionDate: reminder.completionDate)
    }
}

@MainActor func makeReminderStore() -> ReminderStore {
    #if DEBUG
    if DemoData.enabled { return DemoData.reminderStore() }
    #endif
    return EventKitReminderStore.shared
}
