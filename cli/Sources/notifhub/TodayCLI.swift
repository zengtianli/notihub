import Foundation

enum TodayCLI {

    static func snapshotJSON(_ s: DaySnapshot, includeAll: Bool) -> [String: Any] {
        var o: [String: Any] = ["ok": s.problem == nil, "date": s.date, "unread": s.unread, "total": s.total,
                                "muted": s.muted, "notes": s.notes, "includeAll": includeAll,
                                "first": s.first ?? NSNull(), "last": s.last ?? NSNull()]
        if let p = s.problem { o["error"] = p }
        o["groups"] = s.groups.map { g -> [String: Any] in
            ["canon": g.canon, "app": g.app, "unread": g.unread, "count": g.rows.count,
             "rows": g.rows.map { r -> [String: Any] in
                 ["id": r.id, "ts": r.ts, "time": Recap.hhmm(r.ts), "who": r.who,
                  "text": r.redacted ? "" : r.text, "redacted": r.redacted, "unread": r.unread]
             }]
        }
        return o
    }

    static func today(_ args: [String]) -> Int32 {
        if let bad = args.first(where: { !["--all", "--json"].contains($0) }) {
            let msg = "today 不认识的参数：\(bad)（notihub today --help）"
            if args.contains("--json") { CLI.jsonUsageFail(msg) }
            Log.err(msg); return 64
        }
        let includeAll = args.contains("--all")
        let snap = Today.load(includeAll: includeAll, readOnly: true)
        if args.contains("--json") {
            CLI.printJSON(snapshotJSON(snap, includeAll: includeAll))
            if let p = snap.problem { Log.err("✗ \(p)") }
            return snap.problem == nil ? 0 : 1
        }
        if let p = snap.problem { Log.err("✗ \(p)"); return 1 }
        let span = snap.first.map { "\(Recap.hhmm($0)) → \(Recap.hhmm(snap.last ?? $0))" } ?? "—"
        print("\(snap.date) · 未读 \(snap.unread) · 通知 \(snap.total) 条 · \(span)"
              + (snap.muted > 0 ? " · 已折叠 \(snap.muted) 条噪音\(includeAll ? "" : "（--all 看全部）")" : "")
              + (snap.notes > 0 ? " · 随手记 \(snap.notes) 条" : ""))
        guard !snap.groups.isEmpty else { print("今天还没有记录到通知"); return 0 }
        for g in snap.groups {
            print("\n\(g.app)（\(g.canon)）\(g.rows.count) 条\(g.unread > 0 ? " · 未读 \(g.unread)" : "")")
            for r in g.rows {
                let text = r.redacted ? "〔已过保留期，正文已抹除〕" : r.text.replacingOccurrences(of: "\n", with: " ").truncated(60)
                print("  \(Recap.hhmm(r.ts)) #\(CLI.pad(String(r.id), 7))\(r.unread ? "·未读 " : "      ")\(r.who)：\(text)")
            }
        }
        print("\n标已读：notihub mark-read <id…> | --source <来源> | --all")
        return 0
    }

    static func select(ids: [Int64], all: Bool, source: String?, full: DaySnapshot, visible: DaySnapshot)
        -> (mark: [Int64], alreadyRead: [Int64], missing: [Int64]) {
        let rows = Dictionary(full.groups.flatMap(\.rows).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var mark: [Int64] = [], already: [Int64] = [], missing: [Int64] = []
        if all {
            mark = visible.groups.flatMap(\.rows).filter(\.unread).map(\.id)
        } else if let source {
            mark = full.groups.filter { matches($0, source) }.flatMap(\.rows).filter(\.unread).map(\.id)
        } else {
            for id in ids {
                guard let r = rows[id] else { missing.append(id); continue }
                if r.unread { mark.append(id) } else { already.append(id) }
            }
        }
        return (mark, already, missing)
    }

    static func matches(_ g: SourceGroup, _ source: String) -> Bool {
        let key = source.lowercased()
        return g.canon.lowercased() == key || g.app.lowercased() == key
    }

    static func markRead(_ args: [String]) -> Int32 {
        let asJSON = args.contains("--json"), dryRun = args.contains("--dry-run")
        let all = args.contains("--all"), includeMuted = args.contains("--include-muted")
        let source = CLI.strArg(args, "--source")
        var ids: [Int64] = []
        var skip = false
        for a in args {
            if skip { skip = false; continue }
            if a == "--source" { skip = true; continue }
            if ["--json", "--dry-run", "--all", "--include-muted"].contains(a) { continue }
            guard let id = Int64(a), id > 0 else {
                let msg = "mark-read 不认识的参数：\(a)（notihub mark-read --help）"
                if asJSON { CLI.jsonUsageFail(msg) }
                Log.err(msg); return 64
            }
            ids.append(id)
        }
        let modes = (all ? 1 : 0) + (source != nil ? 1 : 0) + (ids.isEmpty ? 0 : 1)
        guard modes == 1, (args.contains("--source") ? source != nil : true) else {
            let usage = "用法: notihub mark-read <事件id…> | --all [--include-muted] | --source <来源> [--dry-run] [--json]"
            if asJSON { CLI.jsonUsageFail(usage) }
            Log.err(usage)
            return 64
        }
        let full = Today.load(includeAll: true, readOnly: true)
        if let p = full.problem {
            if asJSON { CLI.printJSON(["ok": false, "error": p]) }
            Log.err("✗ \(p)"); return 1
        }
        if let source, !full.groups.contains(where: { Self.matches($0, source) }) {
            let known = full.groups.map(\.canon).joined(separator: " ")
            let msg = "今天（\(full.date)）的流水里没有来源 \(source)（今天有：\(known.isEmpty ? "无" : known)；按 today --json 的 groups[].canon 或 app 写）"
            if asJSON { CLI.printJSON(["ok": false, "date": full.date, "dryRun": dryRun, "ids": [Int64](), "marked": 0, "error": msg]) }
            Log.err("✗ \(msg)"); return 1
        }
        let visible = includeMuted ? full : Today.load(includeAll: false, readOnly: true)
        let pick = select(ids: ids, all: all, source: source, full: full, visible: visible)

        var marked = 0
        var writeError: String?
        if !dryRun && !pick.mark.isEmpty {
            do { marked = try Today.markRead(pick.mark) }
            catch { writeError = error.localizedDescription }
        }
        let ok = writeError == nil && pick.missing.isEmpty
        if asJSON {
            var o: [String: Any] = ["ok": ok, "date": full.date, "dryRun": dryRun, "ids": pick.mark,
                                    "marked": marked, "alreadyRead": pick.alreadyRead, "missing": pick.missing]
            if let e = writeError { o["error"] = e }
            else if !pick.missing.isEmpty { o["error"] = "这些 id 不在今天（\(full.date)）的流水里" }
            CLI.printJSON(o)
        } else if dryRun {
            print("（dry-run，未写入）会标已读 \(pick.mark.count) 条\(pick.mark.isEmpty ? "" : "：" + pick.mark.map { "#\($0)" }.joined(separator: " "))")
        } else if writeError == nil {
            print("已标已读 \(marked) 条（今天 \(full.date)）" + (pick.alreadyRead.isEmpty ? "" : " · 本来就已读 \(pick.alreadyRead.count) 条"))
        }
        for id in pick.missing { Log.err("#\(id) 不在今天（\(full.date)）的流水里") }
        if let e = writeError { Log.err("✗ 标已读失败：\(e)") }
        return ok ? 0 : 1
    }
}
