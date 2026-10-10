#if DEBUG
import Foundation


enum DemoData {
    static var enabled: Bool { DemoFeed.enabled }

    @MainActor static func load(into store: Store) {
        let feed = DemoFeed.make()
        store.open = feed.open.sorted { $0.sortKey < $1.sortKey }
        store.index = feed.index
        store.cloudTimezone = feed.timezone
        store.days = [feed.day.date: feed.day]
        store.dayAt = [feed.day.date: feed.now]
        store.openAt = feed.now
        store.indexAt = feed.now
        store.lastSync = feed.lastSync
    }

    @MainActor static func reminderStore() -> ReminderStore { DemoReminderStore() }
}

final class DemoReminderStore: ReminderStore {
    private let tz = TimeZone(identifier: "Asia/Shanghai") ?? .current
    private let list = ReminderListInfo(id: "demo-list", title: "提醒")
    private let work = ReminderListInfo(id: "demo-work", title: "工作")
    private var rows: [ReminderRow] = []

    init() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let now = Date()
        func due(_ hour: Int?) -> DateComponents {
            var parts = cal.dateComponents([.year, .month, .day], from: now)
            if let hour { parts.hour = hour; parts.minute = 0; parts.timeZone = tz }
            return parts
        }
        rows = [
            ReminderRow(id: "demo-r1", title: "回复房东续租条款", notes: "抽自今天的复盘\nnotihub:agenda/demo0000000001",
                        url: ReminderMarker.url("demo0000000001"), listID: list.id, listName: list.title,
                        due: due(20), completed: false, completionDate: nil),
            ReminderRow(id: "demo-r2", title: "取快递（东门快递柜）", notes: nil, url: nil, listID: list.id,
                        listName: list.title, due: due(nil), completed: false, completionDate: nil),
            ReminderRow(id: "demo-r3", title: "提交评审纪要", notes: nil, url: nil, listID: work.id,
                        listName: work.title, due: due(11), completed: true,
                        completionDate: cal.startOfDay(for: now).addingTimeInterval(11.5 * 3600)),
        ]
    }

    func authorization() -> ReminderAuth { .fullAccess }
    func requestFullAccess() async throws -> Bool { true }
    func lists() -> [ReminderListInfo] { [list, work] }
    func defaultList() -> ReminderListInfo? { list }
    func fetch(_ query: ReminderQuery, listIDs: [String]?) async throws -> [ReminderRow] {
        switch query {
        case .incomplete: return rows.filter { !$0.completed }
        case .completed: return rows.filter(\.completed)
        }
    }
    func save(_ draft: ReminderDraft) throws -> ReminderRow {
        let name = [list, work].first { $0.id == draft.listID }?.title ?? list.title
        let row = ReminderRow(id: "demo-\(rows.count + 1)", title: draft.title, notes: draft.notes, url: draft.url,
                              listID: draft.listID, listName: name, due: draft.due, completed: false, completionDate: nil)
        rows.append(row)
        return row
    }
    func remove(id: String) throws { rows.removeAll { $0.id == id } }
}
#endif
