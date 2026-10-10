import Foundation


struct AgendaItem {
    var id: Int64 = 0
    var createdAt: Double = nowUnix()
    var source: String = "manual"      // llm | manual
    var srcDate: String? = nil
    var kind: String = "todo"          // todo | event
    var title: String
    var note: String? = nil
    var dueTS: Double? = nil
    var endTS: Double? = nil
    var allDay: Bool = false
    var who: String? = nil
    var evidence: String? = nil
    var confidence: Double? = nil
    var status: String = "open"        // open | done | dropped
    var reminderID: String? = nil
    var calendarID: String? = nil
    var pushedAt: Double? = nil

    var dedupKey: String {
        let when = dueTS.map { String(Int($0 / 60)) } ?? "-"
        return "\(source)|\(srcDate ?? "-")|\(title)|\(when)".sha256()
    }

    var isPushed: Bool { (reminderID?.isEmpty == false) || (calendarID?.isEmpty == false) }

    var whenText: String? {
        guard let t = dueTS else { return nil }
        let f = DateFormatter()
        f.timeZone = displayTZ
        f.dateFormat = allDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        var s = f.string(from: Date(timeIntervalSince1970: t))
        if let e = endTS, !allDay {
            let g = DateFormatter(); g.timeZone = displayTZ; g.dateFormat = "HH:mm"
            s += "–" + g.string(from: Date(timeIntervalSince1970: e))
        }
        return s
    }
}


extension Store {

    @discardableResult
    func insertAgenda(_ a: AgendaItem) -> Int64? {
        let ok = db.run("""
            INSERT OR IGNORE INTO agenda
              (created_at,source,src_date,kind,title,note,due_ts,end_ts,all_day,who,
               evidence,confidence,status,dedup_key)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [a.createdAt, a.source, a.srcDate, a.kind, a.title, a.note, a.dueTS, a.endTS,
                  a.allDay, a.who, a.evidence, a.confidence, a.status, a.dedupKey])
        guard ok, db.changes > 0 else { return nil }
        return db.lastInsertID
    }

    private static let agendaCols = """
        id,created_at,source,COALESCE(src_date,''),kind,title,COALESCE(note,''),
        due_ts,end_ts,all_day,COALESCE(who,''),COALESCE(evidence,''),confidence,status,
        COALESCE(reminder_id,''),COALESCE(calendar_id,''),pushed_at
        """

    private func readAgenda(_ r: DB.Row) -> AgendaItem {
        AgendaItem(id: r.int(0), createdAt: r.dbl(1), source: r.str(2),
                   srcDate: r.str(3).isEmpty ? nil : r.str(3),
                   kind: r.str(4), title: r.str(5),
                   note: r.str(6).isEmpty ? nil : r.str(6),
                   dueTS: r.isNull(7) ? nil : r.dbl(7),
                   endTS: r.isNull(8) ? nil : r.dbl(8),
                   allDay: r.int(9) == 1,
                   who: r.str(10).isEmpty ? nil : r.str(10),
                   evidence: r.str(11).isEmpty ? nil : r.str(11),
                   confidence: r.isNull(12) ? nil : r.dbl(12),
                   status: r.str(13),
                   reminderID: r.str(14).isEmpty ? nil : r.str(14),
                   calendarID: r.str(15).isEmpty ? nil : r.str(15),
                   pushedAt: r.isNull(16) ? nil : r.dbl(16))
    }

    func agenda(where clause: String = "1=1", _ binds: [Any?] = [],
                order: String = "COALESCE(due_ts, created_at) ASC, id ASC") -> [AgendaItem] {
        var out: [AgendaItem] = []
        db.query("SELECT \(Store.agendaCols) FROM agenda WHERE \(clause) ORDER BY \(order)", binds) {
            out.append(self.readAgenda($0))
        }
        return out
    }

    func agendaItem(id: Int64) -> AgendaItem? { agenda(where: "id=?", [id]).first }

    func agendaForDay(_ date: String) -> [AgendaItem] {
        agenda(where: """
            status <> 'dropped' AND (
              src_date = ?
              OR (due_ts IS NOT NULL AND \(Clock.sqlDay("due_ts")) = ?)
            )
            """, [date, date])
    }

    func setAgendaStatus(_ id: Int64, _ status: String) -> Bool {
        db.run("UPDATE agenda SET status=? WHERE id=?", [status, id]) && db.changes > 0
    }

    func setAgendaPushed(_ id: Int64, reminderID: String?, calendarID: String?) {
        db.run("""
            UPDATE agenda
               SET reminder_id = COALESCE(NULLIF(?,''), reminder_id),
                   calendar_id = COALESCE(NULLIF(?,''), calendar_id),
                   pushed_at   = ?
             WHERE id=?
            """, [reminderID ?? "", calendarID ?? "", nowUnix(), id])
    }

    @discardableResult
    func clearLLMAgenda(date: String) -> Int {
        db.run("""
            DELETE FROM agenda
             WHERE source='llm' AND src_date=? AND status='open'
               AND (reminder_id IS NULL OR reminder_id='')
               AND (calendar_id IS NULL OR calendar_id='')
            """, [date])
        return db.changes
    }


    @discardableResult
    func insertNote(text: String, ts: Double, date: String) -> Int64? {
        guard db.run("INSERT INTO notes(ts,date,text) VALUES(?,?,?)", [ts, date, text]) else { return nil }
        return db.lastInsertID
    }

    func notes(date: String) -> [(id: Int64, ts: Double, text: String)] {
        var out: [(Int64, Double, String)] = []
        db.query("SELECT id,ts,text FROM notes WHERE date=? ORDER BY ts", [date]) {
            out.append(($0.int(0), $0.dbl(1), $0.str(2)))
        }
        return out
    }

    @discardableResult
    func deleteNote(id: Int64) -> Bool {
        db.run("DELETE FROM notes WHERE id=?", [id]) && db.changes > 0
    }


    struct SummaryRow {
        var date: String
        var generatedAt: Double
        var eventCount: Int
        var headline: String
        var text: String
    }

    func summary(date: String) -> SummaryRow? {
        var out: SummaryRow?
        db.query("""
            SELECT date,generated_at,event_count,COALESCE(headline,''),text
              FROM summaries WHERE date=?
            """, [date]) {
            out = SummaryRow(date: $0.str(0), generatedAt: $0.dbl(1), eventCount: Int($0.int(2)),
                             headline: $0.str(3), text: $0.str(4))
        }
        return out
    }

    func saveSummary(date: String, eventCount: Int, headline: String, text: String, raw: String) {
        db.run("""
            INSERT INTO summaries(date,generated_at,event_count,headline,text,raw)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(date) DO UPDATE SET
              generated_at=excluded.generated_at, event_count=excluded.event_count,
              headline=excluded.headline, text=excluded.text, raw=excluded.raw
            """, [date, nowUnix(), eventCount, headline, text, raw])
    }
}


enum WhenParser {

    static func parse(_ raw: String, now: Date = Date(), defaultHour: Int = 9) -> (ts: Double, allDay: Bool)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = displayTZ

        if let m = firstMatch("^\\+(\\d+)\\s*([hmdw小时天分周])", s) {
            let n = Double(m[1]) ?? 0
            let unit = m[2]
            let mult: Double
            switch unit {
            case "h", "小", "时": mult = 3600
            case "m", "分":      mult = 60
            case "d", "天":      mult = 86400
            case "w", "周":      mult = 604800
            default:            mult = 3600
            }
            return (now.timeIntervalSince1970 + n * mult, false)
        }

        let (hour, minute, hadTime, rest) = extractTime(s)

        var base: DateComponents? = nil

        if let m = firstMatch("(\\d{4})[-/年.](\\d{1,2})[-/月.](\\d{1,2})", rest) {
            base = DateComponents(year: Int(m[1]), month: Int(m[2]), day: Int(m[3]))
        } else if let m = firstMatch("(?<!\\d)(\\d{1,2})[-/月.](\\d{1,2})[日号]?(?!\\d)", rest) {
            let nowC = cal.dateComponents([.year], from: now)
            base = DateComponents(year: nowC.year, month: Int(m[1]), day: Int(m[2]))
        }

        if base == nil {
            let dayWords: [(String, Int)] = [("大后天", 3), ("后天", 2), ("明天", 1), ("明日", 1),
                                             ("今天", 0), ("今日", 0), ("昨天", -1), ("tomorrow", 1),
                                             ("today", 0)]
            for (w, off) in dayWords where rest.contains(w) {
                let d = cal.date(byAdding: .day, value: off, to: now)!
                base = cal.dateComponents([.year, .month, .day], from: d)
                break
            }
        }

        if base == nil {
            let names = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7,
                         "日": 1, "天": 1, "七": 1]
            if let m = firstMatch("(?:周|星期|礼拜)([一二三四五六日天七])", rest),
               let target = names[m[1]] {
                let todayWD = cal.component(.weekday, from: now)
                func offsetFromMonday(_ wd: Int) -> Int { (wd - 2 + 7) % 7 }

                let delta: Int
                let weekJump = (rest.contains("下下周") || rest.contains("下下星期") || rest.contains("下下礼拜")) ? 2
                             : (rest.contains("下周") || rest.contains("下星期") || rest.contains("下礼拜")) ? 1
                             : (rest.contains("本周") || rest.contains("这周") || rest.contains("这星期")) ? 0
                             : -1
                if weekJump >= 0 {
                    delta = weekJump * 7 + offsetFromMonday(target) - offsetFromMonday(todayWD)
                } else {
                    var d = (target - todayWD + 7) % 7
                    if d == 0 {
                        let todayAt = cal.date(bySettingHour: hadTime ? hour : defaultHour,
                                               minute: hadTime ? minute : 0, second: 0, of: now)!
                        if todayAt <= now { d = 7 }
                    }
                    delta = d
                }
                let d = cal.date(byAdding: .day, value: delta, to: now)!
                base = cal.dateComponents([.year, .month, .day], from: d)
            }
        }

        if base == nil {
            guard hadTime else { return nil }
            var c = cal.dateComponents([.year, .month, .day], from: now)
            c.hour = hour; c.minute = minute; c.second = 0
            guard var d = cal.date(from: c) else { return nil }
            if d <= now { d = cal.date(byAdding: .day, value: 1, to: d)! }
            return (d.timeIntervalSince1970, false)
        }

        var c = base!
        c.hour = hadTime ? hour : defaultHour
        c.minute = hadTime ? minute : 0
        c.second = 0
        guard let d = cal.date(from: c) else { return nil }
        return (d.timeIntervalSince1970, !hadTime)
    }

    private static func extractTime(_ s: String) -> (Int, Int, Bool, String) {
        var text = s
        var pm = false, am = false
        for w in ["下午", "傍晚", "晚上", "夜里", "中午"] where text.contains(w) {
            pm = true; text = text.replacingOccurrences(of: w, with: " ")
        }
        for w in ["上午", "早上", "凌晨", "早晨"] where text.contains(w) {
            am = true; text = text.replacingOccurrences(of: w, with: " ")
        }
        if let m = firstMatch("(?i)\\b(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)\\b", text) {
            var h = Int(m[1]) ?? 0
            let mi = Int(m[2]) ?? 0
            if m[3].lowercased() == "pm" && h < 12 { h += 12 }
            if m[3].lowercased() == "am" && h == 12 { h = 0 }
            return (h, mi, true, remove(m[0], from: text))
        }
        if let m = firstMatch("(?<!\\d)(\\d{1,2})[:：](\\d{2})(?!\\d)", text) {
            var h = Int(m[1]) ?? 0
            if pm && h < 12 { h += 12 }
            if am && h == 12 { h = 0 }
            return (h, Int(m[2]) ?? 0, true, remove(m[0], from: text))
        }
        if let m = firstMatch("(?<!\\d)(\\d{1,2})\\s*[点时](半|\\d{1,2}分?)?", text) {
            var h = Int(m[1]) ?? 0
            var mi = 0
            if m[2] == "半" { mi = 30 }
            else if !m[2].isEmpty { mi = Int(m[2].replacingOccurrences(of: "分", with: "")) ?? 0 }
            if pm && h < 12 { h += 12 }
            if am && h == 12 { h = 0 }
            return (h, mi, true, remove(m[0], from: text))
        }
        return (0, 0, false, text)
    }

    private static func remove(_ sub: String, from s: String) -> String {
        guard let r = s.range(of: sub) else { return s }
        return s.replacingCharacters(in: r, with: " ")
    }

    private static func firstMatch(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}


enum AgendaCLI {

    static func add(args: [String]) {
        guard let store = Store() else { exit(1) }
        let cfg = Config.load()
        let valueFlags: Set<String> = ["--due", "--at", "--kind", "--note", "--dur", "--who", "--to", "--list", "--cal"]
        var words: [String] = []
        var skip = false
        for a in args {
            if skip { skip = false; continue }
            if valueFlags.contains(a) { skip = true; continue }
            if a.hasPrefix("--") { continue }
            words.append(a)
        }
        let title = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            Log.err("要加点什么？用法: notihub add \"周三下午跟老王对一下方案\" --due \"周三 15:00\"")
            exit(2)
        }

        var item = AgendaItem(source: "manual", title: title)
        item.note = CLI.strArg(args, "--note")
        item.who = CLI.strArg(args, "--who")

        let dueRaw = CLI.strArg(args, "--due") ?? CLI.strArg(args, "--at")
        if let dueRaw {
            guard let (ts, allDay) = WhenParser.parse(dueRaw, defaultHour: cfg.apple.defaultDueHour) else {
                Log.err("看不懂时间「\(dueRaw)」。能认的写法：2026-08-20 15:00 / 明天 15:00 / 周三下午3点 / +2h / 15:30")
                exit(2)
            }
            item.dueTS = ts
            item.allDay = allDay
        }

        item.kind = CLI.strArg(args, "--kind") ?? ((item.dueTS != nil && !item.allDay) ? "event" : "todo")
        if item.kind == "event", let due = item.dueTS, !item.allDay {
            let mins = CLI.intArg(args, "--dur") ?? cfg.apple.defaultEventMinutes
            item.endTS = due + Double(mins) * 60
        }
        item.srcDate = item.dueTS.map(dayString) ?? Recap.today()

        guard let id = store.insertAgenda(item) else {
            print("已经有一条一模一样的了，没重复加")
            return
        }
        var saved = item; saved.id = id
        print("#\(id) \(saved.kind == "event" ? "日程" : "待办")：\(saved.title)"
              + (saved.whenText.map { " · \($0)" } ?? " · 没定时间"))

        if args.contains("--push") {
            AppleExport.push(items: [saved], args: args, store: store, config: cfg)
        } else {
            print("推到苹果：notihub push \(id)")
        }
    }

    static func note(args: [String]) {
        guard let store = Store() else { exit(1) }
        let valueFlags: Set<String> = ["--date", "--at"]
        var words: [String] = []
        var skip = false
        for a in args {
            if skip { skip = false; continue }
            if valueFlags.contains(a) { skip = true; continue }
            if a.hasPrefix("--") { continue }
            words.append(a)
        }
        let text = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            Log.err("用法: notihub note \"下午和老王聊了方案，他倾向 B\"")
            exit(2)
        }
        var ts = nowUnix()
        if let at = CLI.strArg(args, "--at"), let (t, _) = WhenParser.parse(at) { ts = t }
        let date = CLI.strArg(args, "--date") ?? dayString(ts)
        guard let id = store.insertNote(text: text, ts: ts, date: date) else {
            Log.err("写入失败"); exit(1)
        }
        print("#\(id) 已记到 \(date) \(Recap.hhmm(ts))：\(text.truncated(60))")
    }

    static func list(args: [String]) {
        let asJSON = args.contains("--json")
        let store: Store
        if asJSON {
            let p = CLI.parseStrict(args, cmd: "agenda", switches: ["--json", "--all", "--overdue"], options: ["--date"])
            if let e = p.error { CLI.jsonUsageFail(e) }
            if let x = p.positional.first { CLI.jsonUsageFail("agenda --json 不认识的参数：\(x)（notihub agenda --help）") }
            if let d = p.values["--date"], !Recap.validDate(d) { CLI.jsonUsageFail("日期无效：\(d)（要 YYYY-MM-DD）") }
            do { store = try Today.existingStore(readOnly: true) }
            catch { CLI.jsonFail(error.localizedDescription) }
        } else {
            guard let s = Store() else { exit(1) }
            store = s
        }
        var clause = "status='open'"
        var binds: [Any?] = []
        if args.contains("--all") { clause = "1=1" }
        if let d = CLI.strArg(args, "--date") {
            clause += " AND (src_date=? OR \(Clock.sqlDay("due_ts"))=?)"
            binds += [d, d]
        }
        if args.contains("--overdue") {
            clause += " AND due_ts IS NOT NULL AND due_ts < ?"
            binds.append(nowUnix())
        }
        let items = store.agenda(where: clause, binds)

        if asJSON {
            let objs: [[String: Any]] = items.map { a in
                var o: [String: Any] = ["id": a.id, "kind": a.kind, "title": a.title,
                                        "status": a.status, "source": a.source]
                if let t = a.dueTS { o["due"] = a.whenText ?? ""; o["due_ts"] = t }
                if let n = a.note { o["note"] = n }
                if let w = a.who { o["who"] = w }
                if let e = a.evidence { o["evidence"] = e }
                if let c = a.confidence { o["confidence"] = c }
                if a.isPushed { o["pushed"] = true }
                return o
            }
            if let d = try? JSONSerialization.data(withJSONObject: objs, options: [.prettyPrinted, .withoutEscapingSlashes]) {
                print(String(data: d, encoding: .utf8)!)
            }
            return
        }

        guard !items.isEmpty else { print("没有待办。加一条: notihub add \"...\" --due \"明天 15:00\""); return }
        let now = nowUnix()
        for a in items {
            let mark: String
            switch a.status {
            case "done":    mark = "✓"
            case "dropped": mark = "✗"
            default:        mark = (a.dueTS.map { $0 < now } ?? false) ? "!" : "·"
            }
            let when = a.whenText ?? "—"
            let tag = a.kind == "event" ? "日程" : "待办"
            let pushed = a.isPushed ? " ⇢已推" : ""
            print("\(mark) #\(CLI.pad(String(a.id), 4)) \(CLI.pad(when, 18)) \(tag) \(a.title)\(pushed)")
            if let e = a.evidence, !e.isEmpty {
                print("       ↳ \(a.who.map { $0 + "：" } ?? "")\(e.truncated(72))")
            }
        }
        print("\n完成: notihub done <id> · 删掉: notihub drop <id> · 推到苹果: notihub push <id>")
    }

    static func setStatus(args: [String], status: String) -> Int32 {
        let verb = status == "done" ? "done" : status == "dropped" ? "drop" : "reopen"
        let known: Set<String> = ["--local-only", "--json", "--dry-run"]
        var ids: [Int64] = []
        for a in args {
            if known.contains(a) { continue }
            guard let id = Int64(a) else { ids = []; break }
            ids.append(id)
        }
        guard !ids.isEmpty else {
            let usage = "用法: notihub \(verb) <id> [id...] [--local-only] [--dry-run] [--json]"
            if args.contains("--json") { CLI.jsonUsageFail(usage) }
            Log.err(usage); return 2
        }
        let asJSON = args.contains("--json"), dryRun = args.contains("--dry-run")
        let localOnly = args.contains("--local-only")
        let store: Store
        do { store = try Today.existingStore(readOnly: dryRun) }
        catch {
            if asJSON { CLI.printJSON(["ok": false, "status": status, "dryRun": dryRun, "error": error.localizedDescription]) }
            Log.err("✗ \(error.localizedDescription)"); return 1
        }
        let label = status == "done" ? "完成" : status == "dropped" ? "丢弃" : "重新打开"
        func say(_ line: String) { if asJSON { Log.err(line) } else { print(line) } }

        var cloud: CloudClient?
        var cloudSkip: String? = localOnly ? "--local-only" : nil
        var results: [[String: Any]] = []
        var failed = false
        for id in ids {
            guard let item = store.agendaItem(id: id) else {
                say("#\(id) 不存在")
                results.append(["id": id, "ok": false, "error": "本机没有这条待办"]); failed = true
                continue
            }
            if dryRun {
                say("（dry-run）#\(id) \(item.status) → \(status)：\(item.title)"
                      + (localOnly ? "（只改本机）" : "（本机 + 云端覆盖）"))
                results.append(["id": id, "ok": true, "from": item.status, "to": status, "dryRun": true])
                continue
            }
            guard store.setAgendaStatus(id, status) else {
                say("#\(id) 改不动")
                results.append(["id": id, "ok": false, "error": "本机改不动"]); failed = true
                continue
            }
            var extra = ""
            var r: [String: Any] = ["id": id, "ok": true, "status": status, "local": "updated"]
            if status == "done", let rid = item.reminderID, !rid.isEmpty {
                let ticked = AppleExport.completeReminder(id: rid)
                extra += ticked ? " · 提醒事项已勾掉" : " · 提醒事项没勾上（自己去点一下）"
                r["reminder"] = ticked ? "completed" : "failed"
            }
            if cloud == nil && cloudSkip == nil {
                let (c, why) = CloudStatusSync.connect()
                cloud = c; cloudSkip = why
            }
            let outcome: CloudStatusSync.Outcome = cloud.map { CloudStatusSync.apply($0, id: id, status: status) }
                ?? .skipped(cloudSkip ?? "")
            r["cloud"] = outcome.label
            switch outcome {
            case .updated:   extra += " · 云端已同步"
            case .notSynced: extra += " · 云端还没有这条（随下次同步上去）"
            case .skipped(let why): if !localOnly { r["cloudNote"] = why }
            case .failed(let why):
                extra += " · 云端没改成：\(why)"
                r["ok"] = false; r["error"] = "本机已改，云端写入失败：\(why)"; failed = true
            }
            say("#\(id) → \(label)：\(item.title)\(extra)")
            results.append(r)
        }
        return finish(results: results, failed: failed, json: asJSON)
    }

    private static func finish(results: [[String: Any]], failed: Bool, json: Bool) -> Int32 {
        if json { CLI.printJSON(["ok": !failed, "results": results]) }
        return failed ? 1 : 0
    }
}

func dayString(_ ts: Double) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = displayTZ
    return f.string(from: Date(timeIntervalSince1970: ts))
}
