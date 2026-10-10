import Foundation
@testable import DayDeckCore

final class ReminderTestStore: ReminderStore {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var auth: ReminderAuth
    var grantOnRequest: Bool
    var requestError: Error?
    var fetchError: Error?
    var saveError: Error?
    var dropURLOnSave = false
    private(set) var allLists: [ReminderListInfo]
    var defaultListID: String?
    private(set) var rows: [ReminderRow] = []

    private(set) var requestCalls = 0
    private(set) var fetchCalls: [ReminderQuery] = []
    private(set) var saveCalls = 0
    private(set) var savedDrafts: [ReminderDraft] = []
    private var serial = 0

    init(auth: ReminderAuth = .fullAccess, grantOnRequest: Bool = true,
         lists: [ReminderListInfo] = [ReminderListInfo(id: "list-inbox", title: "合成收件箱"),
                                      ReminderListInfo(id: "list-work", title: "合成工作")],
         defaultListID: String? = "list-inbox") {
        self.auth = auth
        self.grantOnRequest = grantOnRequest
        self.allLists = lists
        self.defaultListID = defaultListID
    }


    func deleteList(id: String) {
        allLists.removeAll { $0.id == id }
        rows.removeAll { $0.listID == id }
        if defaultListID == id { defaultListID = allLists.first?.id }
    }

    @discardableResult
    func seed(title: String, notes: String? = nil, url: URL? = nil, listID: String? = nil,
              due: DateComponents? = nil, completedAt: Date? = nil) -> ReminderRow {
        let list = allLists.first { $0.id == (listID ?? defaultListID) } ?? allLists[0]
        serial += 1
        let row = ReminderRow(id: "fake-\(serial)", title: title, notes: notes, url: url, listID: list.id,
                              listName: list.title, due: due, completed: completedAt != nil, completionDate: completedAt)
        rows.append(row)
        return row
    }

    static func absoluteDue(_ due: DateComponents?) -> Date? {
        guard let due, let y = due.year, let m = due.month, let d = due.day else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = due.timeZone ?? NSTimeZone.default
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: due.hour ?? 0, minute: due.minute ?? 0,
                                             second: due.second ?? 0))
    }


    func authorization() -> ReminderAuth { auth }

    func requestFullAccess() async throws -> Bool {
        requestCalls += 1
        if let requestError { throw requestError }
        guard auth == .notDetermined else { return auth == .fullAccess }
        auth = grantOnRequest ? .fullAccess : .denied(ReminderText.denied)
        return grantOnRequest
    }

    func lists() -> [ReminderListInfo] { auth == .fullAccess ? allLists : [] }

    func defaultList() -> ReminderListInfo? {
        guard auth == .fullAccess else { return nil }
        return allLists.first { $0.id == defaultListID }
    }

    func fetch(_ query: ReminderQuery, listIDs: [String]?) async throws -> [ReminderRow] {
        fetchCalls.append(query)
        if let fetchError { throw fetchError }
        guard auth == .fullAccess else { return [] }
        let scoped = rows.filter { listIDs?.contains($0.listID) ?? true }
        func inRange(_ at: Date, _ start: Date?, _ end: Date?) -> Bool {
            (start.map { at >= $0 } ?? true) && (end.map { at < $0 } ?? true)
        }
        switch query {
        case let .incomplete(start, end):
            return scoped.filter { row in
                guard !row.completed else { return false }
                if start == nil && end == nil { return true }
                guard let at = Self.absoluteDue(row.due) else { return false }
                return inRange(at, start, end)
            }
        case let .completed(start, end):
            return scoped.filter { row in
                guard row.completed, let at = row.completionDate else { return false }
                return inRange(at, start, end)
            }
        }
    }

    @discardableResult
    func save(_ draft: ReminderDraft) throws -> ReminderRow {
        saveCalls += 1
        if let saveError { throw saveError }
        guard auth == .fullAccess else { throw Failure(message: "fake: 未授权写入") }
        guard let list = allLists.first(where: { $0.id == draft.listID }) else {
            throw Failure(message: "fake: 目标列表不存在")
        }
        savedDrafts.append(draft)
        serial += 1
        let row = ReminderRow(id: "fake-\(serial)", title: draft.title, notes: draft.notes,
                              url: dropURLOnSave ? nil : draft.url, listID: list.id, listName: list.title,
                              due: draft.due, completed: false, completionDate: nil)
        rows.append(row)
        return row
    }

    func remove(id: String) throws { rows.removeAll { $0.id == id } }
}

enum ReminderFixture {
    static let cloud = TimeZone(identifier: "Asia/Shanghai")!

    static func at(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { fatalError("bad fixture date \(iso)") }
        return date
    }

    static var cloudCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = cloud
        return cal
    }

    static func zoned(_ date: Date, _ tz: TimeZone = cloud) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        parts.timeZone = tz
        return parts
    }

    static func agenda(id: Int64 = 101, kind: String = "todo", title: String = "合成待办：交季度材料",
                       note: String? = "带上合成复印件", dueTS: Double? = at("2026-09-08T14:30:00+08:00").timeIntervalSince1970,
                       endTS: Double? = nil, allDay: Bool = false, who: String? = "合成联系人",
                       evidence: String? = "合成原文：周二下午交材料", srcDate: String? = "2026-09-07",
                       pushed: Bool = false) -> Agenda {
        Agenda(id: id, kind: kind, title: title, note: note, dueTS: dueTS, endTS: endTS, allDay: allDay, who: who,
               evidence: evidence, status: "open", source: "llm", srcDate: srcDate, pushed: pushed)
    }
}
