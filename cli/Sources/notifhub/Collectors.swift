import Foundation
import SQLite3


enum PlistKit {
    static func parse(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func unarchive(fileAt url: URL) -> Any? {
        let (rc, xml) = run("/usr/bin/plutil", ["-convert", "xml1", "-o", "-", url.path])
        guard rc == 0, let data = xml.data(using: .utf8),
              let raw = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let objects = raw["$objects"] as? [Any]
        else { return nil }

        func uid(_ o: Any) -> Int? {
            guard let d = o as? [String: Any], let n = d["CF$UID"] as? Int, d.count == 1 else { return nil }
            return n
        }
        func resolve(_ o: Any, _ depth: Int = 0) -> Any {
            if depth > 16 { return "<deep>" }
            if let i = uid(o) {
                guard i >= 0 && i < objects.count else { return NSNull() }
                return resolve(objects[i], depth + 1)
            }
            if let d = o as? [String: Any] {
                if let keys = d["NS.keys"] as? [Any], let vals = d["NS.objects"] as? [Any] {
                    var out: [String: Any] = [:]
                    for (k, v) in zip(keys, vals) {
                        out["\(resolve(k, depth + 1))"] = resolve(v, depth + 1)
                    }
                    return out
                }
                if let objs = d["NS.objects"] as? [Any] {
                    return objs.map { resolve($0, depth + 1) }
                }
                var out: [String: Any] = [:]
                for (k, v) in d where k != "$class" { out[k] = resolve(v, depth + 1) }
                return out
            }
            if let a = o as? [Any] { return a.map { resolve($0, depth + 1) } }
            return o
        }
        guard let top = raw["$top"] else { return nil }
        return resolve(top)
    }
}


protocol Collector {
    var name: String { get }
    func collect(_ store: Store) -> [Event]
    func health() -> (Bool, String)
}

enum Sources {
    static func all() -> [Collector] {
        [UsernotedCollector(), RemoteCollector(), MessagesCollector(), MailCollector()]
    }
    static let nonFatal: Set<String> = ["mail"]
}


final class UsernotedCollector: Collector {
    let name = "usernoted"
    private let wmKey = "wm.usernoted.rec_id"

    func health() -> (Bool, String) {
        guard FileManager.default.isReadableFile(atPath: Paths.usernotedDB.path) else {
            return (false, "通知库不可读（缺全磁盘访问？）")
        }
        guard let db = DB(path: Paths.usernotedDB.path, readOnly: true) else {
            return (false, "通知库打不开")
        }
        var n = 0
        db.query("SELECT COUNT(*) FROM record") { n = Int($0.int(0)) }
        return (true, "当前队列 \(n) 条")
    }

    func collect(_ store: Store) -> [Event] {
        guard let db = DB(path: Paths.usernotedDB.path, readOnly: true) else { return [] }
        let last = Int64(store.watermark(wmKey) ?? "") ?? -1
        var maxSeen = last
        var out: [Event] = []

        let sql = """
            SELECT r.rec_id, a.identifier, r.data, r.delivered_date
              FROM record r JOIN app a ON r.app_id = a.app_id
             WHERE r.rec_id > ?
             ORDER BY r.rec_id LIMIT 500
            """
        db.query(sql, [last]) { row in
            let recID = row.int(0)
            maxSeen = max(maxSeen, recID)
            let bundle = row.str(1)
            let blob = row.data(2)
            let delivered = row.dbl(3)
            guard let plist = PlistKit.parse(blob) else { return }
            let req = plist["req"] as? [String: Any] ?? [:]
            let title = req["titl"] as? String ?? ""
            let subtitle = req["subt"] as? String ?? ""
            let body = req["body"] as? String ?? ""
            if title.isEmpty && body.isEmpty { return }  // 纯角标/静默推送，不入库
            let ts = delivered > 0 ? appleToUnix(delivered)
                                   : appleToUnix((plist["date"] as? Double) ?? 0)
            out.append(Event(ts: ts > 1e9 ? ts : nowUnix(), source: name,
                             bundle: bundle, app: BundleMap.displayName(bundle),
                             title: title, subtitle: subtitle, body: body,
                             extID: "\(recID)", recID: recID))
        }
        if maxSeen > last { store.setWatermark(wmKey, "\(maxSeen)") }
        return out
    }

    static func liveRecIDs() -> Set<Int64> {
        guard let db = DB(path: Paths.usernotedDB.path, readOnly: true) else { return [] }
        var s = Set<Int64>()
        db.query("SELECT rec_id FROM record") { s.insert($0.int(0)) }
        return s
    }
}


final class RemoteCollector: Collector {
    let name = "remote"

    func health() -> (Bool, String) {
        let files = Self.plistFiles()
        if files.isEmpty { return (false, "Remote 容器下没有 DeliveredNotifications.plist") }
        return (true, "\(files.count) 个活跃容器")
    }

    static func plistFiles() -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.remoteRoot,
                                                     includingPropertiesForKeys: nil) else { return [] }
        return dirs.map { $0.appendingPathComponent("DeliveredNotifications.plist") }
                   .filter { fm.fileExists(atPath: $0.path) }
    }

    func collect(_ store: Store) -> [Event] {
        var out: [Event] = []
        for f in Self.plistFiles() {
            let key = "wm.remote." + f.deletingLastPathComponent().lastPathComponent
            let mtime = (try? FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as? Date)??.timeIntervalSince1970 ?? 0
            if let seen = Double(store.watermark(key) ?? ""), seen >= mtime { continue }

            defer { store.setWatermark(key, "\(mtime)") }
            guard let root = PlistKit.unarchive(fileAt: f) else { continue }
            var entries: [[String: Any]] = []
            if let d = root as? [String: Any] {
                if let list = d["root"] as? [Any] {
                    entries = list.compactMap { $0 as? [String: Any] }
                } else { entries = [d] }
            } else if let list = root as? [Any] {
                entries = list.compactMap { $0 as? [String: Any] }
            }

            for e in entries {
                let title = e["AppNotificationTitle"] as? String ?? ""
                let body = e["AppNotificationMessage"] as? String ?? ""
                if title.isEmpty && body.isEmpty { continue }
                let bundle = (e["CommunicationContextBundleIdentifier"] as? String)
                          ?? (e["SBSPushStoreNotificationSectionKey"] as? String) ?? "unknown"
                var ts = nowUnix()
                if let d = e["AppNotificationCreationDate"] as? [String: Any],
                   let t = d["NS.time"] as? Double { ts = appleToUnix(t) }
                let sender = ((e["CommunicationContextSender"] as? [String: Any])?["displayName"] as? String) ?? ""
                out.append(Event(ts: ts, source: name, bundle: bundle,
                                 app: BundleMap.displayName(bundle),
                                 title: title, subtitle: sender, body: body,
                                 extID: e["AppNotificationIdentifier"] as? String ?? "", recID: nil))
            }
        }
        return out
    }
}


final class MessagesCollector: Collector {
    let name = "messages"
    private let wmKey = "wm.messages.rowid"

    func health() -> (Bool, String) {
        guard let db = DB(path: Paths.chatDB.path, readOnly: true) else {
            return (false, "chat.db 打不开（缺全磁盘访问？）")
        }
        var n: Int64 = 0
        db.query("SELECT COALESCE(MAX(ROWID),0) FROM message") { n = $0.int(0) }
        return (true, "最大 ROWID=\(n)")
    }

    func collect(_ store: Store) -> [Event] {
        guard let db = DB(path: Paths.chatDB.path, readOnly: true) else { return [] }
        var last = Int64(store.watermark(wmKey) ?? "") ?? -1
        if last < 0 {
            var maxID: Int64 = 0
            db.query("SELECT COALESCE(MAX(ROWID),0) FROM message") { maxID = $0.int(0) }
            store.setWatermark(wmKey, "\(maxID)")
            Log.write("messages: 基线设为 ROWID=\(maxID)")
            return []
        }
        var out: [Event] = []
        var maxSeen = last
        let sql = """
            SELECT m.ROWID, m.text, m.attributedBody, m.date, COALESCE(h.id,'')
              FROM message m LEFT JOIN handle h ON m.handle_id = h.ROWID
             WHERE m.ROWID > ? AND m.is_from_me = 0
             ORDER BY m.ROWID LIMIT 200
            """
        db.query(sql, [last]) { row in
            let rid = row.int(0)
            maxSeen = max(maxSeen, rid)
            var text = row.str(1)
            if text.isEmpty {
                text = Self.scrapeAttributedBody(row.data(2))
            }
            guard !text.isEmpty else { return }
            let sender = row.str(4)
            out.append(Event(ts: appleToUnix(row.dbl(3)), source: self.name,
                             bundle: "com.apple.MobileSMS", app: "信息",
                             title: sender.isEmpty ? "信息" : sender,
                             subtitle: "", body: text,
                             extID: "\(rid)", recID: nil))
        }
        if maxSeen > last { store.setWatermark(wmKey, "\(maxSeen)"); last = maxSeen }
        return out
    }

    static func scrapeAttributedBody(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var best = ""
        var cur = [UInt8]()
        func flush() {
            if cur.count >= 4, let s = String(bytes: cur, encoding: .utf8), s.count > best.count {
                best = s
            }
            cur.removeAll(keepingCapacity: true)
        }
        for b in data {
            if b >= 0x20 || b >= 0x80 { cur.append(b) } else { flush() }
        }
        flush()
        return best.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
