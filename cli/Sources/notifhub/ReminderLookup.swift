import Foundation

enum LocalReminders {
    static let notePrefix = "notihub:agenda/"
    static let scope = "mac-readable-lists; excludes unsynced and iPhone-only lists"

    struct Failure: Error {
        let code: Int32
        let message: String
    }

    static func key(for agenda: [String: Any]) throws -> String {
        guard let kind = agenda["kind"] as? String, let title = agenda["title"] as? String else {
            throw CloudFailure("云端待办缺 kind 或 title，无法比对提醒事项", kind: .format)
        }
        var due = ""
        if let value = agenda["dueTS"], !(value is NSNull) {
            guard let n = value as? NSNumber, n.doubleValue.isFinite else {
                throw CloudFailure("云端待办 dueTS 不是有效时间戳", kind: .format)
            }
            due = String(format: "%.0f", n.doubleValue)
        }
        let raw = [kind, title, agenda["srcDate"] as? String ?? "", due].joined(separator: "|")
        return String(raw.sha256().prefix(16))
    }

    static func marker(in notes: String) -> String? {
        guard let last = notes.split(separator: "\n", omittingEmptySubsequences: true).last else { return nil }
        let line = last.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(notePrefix) else { return nil }
        let key = String(line.dropFirst(notePrefix.count))
        return key.isEmpty ? nil : key
    }

    static func addPresence(to payload: inout [String: Any]) throws {
        guard let items = payload["items"] as? [[String: Any]] else {
            throw CloudFailure("云端未完成清单缺 items 数组", kind: .format)
        }
        let wanted = try items.map { try key(for: $0) }
        let domain = DomainRegistry.reminders
        let read = Extractor.run(domain, limit: Int.max)
        guard read.isUsable else { throw Failure(code: read.exitCode, message: DataCLI.diagnose(domain, read)) }
        let keys = Set(read.rows.compactMap { marker(in: $0[5]) })
        payload["items"] = zip(items, wanted).map { item, key -> [String: Any] in
            var row = item
            row["reminderKey"] = key
            row["inReminders"] = keys.contains(key)
            return row
        }
        payload["reminderScope"] = scope
    }

    static func dayDomain(_ date: String) -> DataDomain? {
        guard Recap.validDate(date) else { return nil }
        let f = Extractor.timeFormatter("yyyy-MM-dd")
        guard let start = f.date(from: date) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Clock.tz
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        let a = Int64(start.timeIntervalSince1970 - appleEpoch)
        let b = Int64(end.timeIntervalSince1970 - appleEpoch)
        let base = DomainRegistry.reminders
        guard case .sqlite(let sql) = base.extraction else { return nil }
        let filter = "r.ZMARKEDFORDELETION = 0 AND ((COALESCE(r.ZCOMPLETED,0) <> 1 AND r.ZDUEDATE >= \(a) AND r.ZDUEDATE < \(b)) OR (r.ZCOMPLETED = 1 AND r.ZCOMPLETIONDATE >= \(a) AND r.ZCOMPLETIONDATE < \(b)))"
        return DataDomain(id: base.id, name: base.name, symbol: base.symbol, summary: base.summary,
                          sources: base.sources, extraction: .sqlite(sql.replacingOccurrences(of: "r.ZMARKEDFORDELETION = 0", with: filter)),
                          timestampColumns: base.timestampColumns, sensitiveColumns: base.sensitiveColumns,
                          mergeOrderColumn: base.mergeOrderColumn)
    }
}
