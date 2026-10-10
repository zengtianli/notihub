import Foundation

enum AgendaBuckets {
    static func overdue(_ open: [Agenda], calendar: Calendar, now: Date = Date()) -> [Agenda] {
        open.filter { ($0.dueTS ?? .infinity) < now.timeIntervalSince1970
            && !calendar.isDate($0.due ?? .distantFuture, inSameDayAs: now) }
    }

    static func dueToday(_ open: [Agenda], calendar: Calendar, now: Date = Date()) -> [Agenda] {
        open.filter { $0.due.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
    }

    static func undated(_ open: [Agenda]) -> [Agenda] {
        open.filter { $0.dueTS == nil }
    }

    static func upcoming(_ open: [Agenda], calendar: Calendar, now: Date = Date()) -> [Agenda] {
        open.filter { item in
            guard let due = item.due else { return false }
            return due > now && !calendar.isDate(due, inSameDayAs: now)
        }
    }
}
