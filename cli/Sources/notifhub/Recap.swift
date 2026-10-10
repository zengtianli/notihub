import Foundation

enum Recap {

    struct Item {
        var ts: Double
        var endTs: Double
        var canon: String
        var app: String
        var who: String          // 标题位：微信是发信人、短信是号码、其他是通知标题
        var lines: [String]      // 合并进来的正文
        var redacted: Bool
        var missed: Bool         // 至今没点开
    }

    struct Day {
        var date: String
        var items: [Item]
        var total: Int           // 合并前的原始条数（**只数通知，不含随手记和 AI 输入**）
        var muted: Int           // 被折叠的噪音条数
        var notes: Int = 0       // 自己写的随手记条数
        var apps: [(String, Int)]
        var whos: [(String, Int)]
        var byHour: [Int]
        var first: Double?
        var last: Double?
        var summary: Store.SummaryRow? = nil
        var agenda: [AgendaItem] = []
        var aiInputs: Int = 0    // 本人在 Claude Code / Codex 里的输入条数（也在 items 里）
        var work: AIWork.Day? = nil
    }

    static let noteApp = "随手记"
    static let noteCanon = "note:self"

    static func load(store: Store, date: String, includeAll: Bool, config: Config) -> Day {
        var items: [Item] = []
        var total = 0, mutedCount = 0, aiInputs = 0
        var apps: [String: Int] = [:], whos: [String: Int] = [:]
        var byHour = [Int](repeating: 0, count: 24)
        var first: Double?, last: Double?

        let muteSet = includeAll ? Set<String>() : Set(config.muteInViews.map { $0.lowercased() })
        func muted(_ canon: String, _ app: String) -> Bool {
            if muteSet.isEmpty { return false }
            let last = canon.split(separator: ".").last.map(String.init) ?? canon
            return muteSet.contains(canon.lowercased())
                || muteSet.contains(last.lowercased())
                || muteSet.contains(app.lowercased())
        }
        struct Raw {
            var ts: Double; var canon: String; var app: String; var who: String
            var line: String; var redacted: Bool; var missed: Bool
        }
        var raws: [Raw] = []

        let sql = """
            SELECT ts, canon, app, COALESCE(title,''), COALESCE(body,''), redacted, dismissed_at, rec_id
              FROM events
             WHERE \(Clock.sqlDay("ts")) = ?
             ORDER BY ts
            """
        store.db.query(sql, [date]) { r in
            let ts = r.dbl(0), canon = r.str(1), app = r.str(2)
            let title = r.str(3), body = r.str(4)
            if AIWork.canons.contains(canon) { aiInputs += 1 } else { total += 1 }
            if muted(canon, app) { mutedCount += 1; return }
            raws.append(Raw(ts: ts, canon: canon, app: app,
                            who: title.isEmpty ? app : title,
                            line: stripANSI(body.isEmpty ? title : body),
                            redacted: r.int(5) == 1,
                            missed: r.isNull(6) && !r.isNull(7)))
        }

        let noteRows = store.notes(date: date)
        for n in noteRows {
            raws.append(Raw(ts: n.ts, canon: noteCanon, app: noteApp, who: "我",
                            line: n.text, redacted: false, missed: false))
        }
        raws.sort { $0.ts < $1.ts }

        var cal = Calendar.current; cal.timeZone = displayTZ
        for r in raws {
            apps[r.app, default: 0] += 1
            if !AIWork.canons.contains(r.canon) { whos[r.who, default: 0] += 1 }
            let h = cal.component(.hour, from: Date(timeIntervalSince1970: r.ts))
            if h >= 0 && h < 24 { byHour[h] += 1 }
            if first == nil { first = r.ts }
            last = r.ts

            if var prev = items.last, prev.canon == r.canon, prev.who == r.who,
               r.ts - prev.endTs <= 900 {
                prev.lines.append(r.line)
                prev.endTs = r.ts
                prev.missed = prev.missed || r.missed
                items[items.count - 1] = prev
            } else {
                items.append(Item(ts: r.ts, endTs: r.ts, canon: r.canon, app: r.app, who: r.who,
                                  lines: [r.line], redacted: r.redacted, missed: r.missed))
            }
        }

        return Day(date: date, items: items, total: total, muted: mutedCount,
                   notes: noteRows.count,
                   apps: apps.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) },
                   whos: whos.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(12).map { ($0.key, $0.value) },
                   byHour: byHour, first: first, last: last,
                   summary: store.summary(date: date),
                   agenda: store.agendaForDay(date),
                   aiInputs: aiInputs,
                   work: AIWork.day(store: store, date: date, config: config))
    }

    static let ansiRegex = try! NSRegularExpression(pattern: "\u{001B}?\\[[0-9;]*m", options: [])
    static func stripANSI(_ s: String) -> String {
        ansiRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    static func renderLine(_ text: String, mail: Bool) -> String {
        guard mail else { return CLI.esc(text) }
        let regex = try! NSRegularExpression(pattern: #"https?://[^\s<>\"\)。，；！？\p{Han}]+"#)
        var output = "", start = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            output += CLI.esc(String(text[start..<range.lowerBound]))
            let address = String(text[range])
            let label = URL(string: address)?.host ?? "打开链接"
            output += "<a href=\"\(CLI.esc(address))\" rel=\"noreferrer noopener\">\(CLI.esc(label))</a>"
            start = range.upperBound
        }
        return output + CLI.esc(String(text[start...]))
    }

    static func mdLite(_ s: String) -> String {
        var out = ""
        var inList = false
        for rawLine in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let isBullet = line.hasPrefix("- ") || line.hasPrefix("* ")
            let content = bold(CLI.esc(isBullet ? String(line.dropFirst(2)) : line))
            if isBullet {
                if !inList { out += "<ul>"; inList = true }
                out += "<li>\(content)</li>"
            } else {
                if inList { out += "</ul>"; inList = false }
                out += "<p>\(content)</p>"
            }
        }
        if inList { out += "</ul>" }
        return out
    }

    private static let boldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    private static func bold(_ s: String) -> String {
        boldRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                           withTemplate: "<strong>$1</strong>")
    }

    static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = displayTZ
        return f.string(from: Date())
    }

    static func validDate(_ s: String) -> Bool {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = displayTZ; f.isLenient = false
        return f.date(from: s).map { f.string(from: $0) == s } ?? false
    }

    static func hhmm(_ ts: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = displayTZ
        return f.string(from: Date(timeIntervalSince1970: ts))
    }


    static func run(args: [String]) {
        let includeAll = args.contains("--all")

        if args.contains("--json") {
            let p = CLI.parseStrict(args, cmd: "day", switches: ["--json", "--all"])
            if let e = p.error { CLI.jsonUsageFail(e) }
            guard p.positional.count <= 1 else { CLI.jsonUsageFail("day 只收一个日期，实得 \(p.positional.joined(separator: " "))") }
            let date = p.positional.first ?? today()
            guard validDate(date) else { CLI.jsonUsageFail("日期无效：\(date)（要 YYYY-MM-DD，如 \(today())）") }
            let store: Store
            do { store = try Today.existingStore(readOnly: true) }
            catch {
                CLI.printJSON(["ok": false, "date": date, "error": error.localizedDescription])
                Log.err("✗ \(error.localizedDescription)"); exit(1)
            }
            let d = load(store: store, date: date, includeAll: includeAll, config: Config.load())
            guard let data = try? JSONFeed.enc.encode(JSONFeed.day(d)),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                CLI.printJSON(["ok": false, "date": date, "error": "编码失败"]); exit(1)
            }
            obj["ok"] = true
            obj["source"] = "local"
            obj["includeAll"] = includeAll
            CLI.printJSON(obj)
            return
        }

        var positional: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--html", i + 1 < args.count, !args[i + 1].hasPrefix("-") { i += 2; continue }
            if !a.hasPrefix("-") { positional.append(a) }
            i += 1
        }
        let date = positional.first ?? today()
        guard positional.count <= 1, validDate(date) else {
            Log.err("日期无效：\(positional.joined(separator: " "))（要一个 YYYY-MM-DD，如 \(today())）"); exit(2)
        }

        guard let store = Store() else { exit(1) }
        let config = Config.load()
        if Instance.personalFeatures { AIWork.collect(store: store, config: config) }
        let d = load(store: store, date: date, includeAll: includeAll, config: config)

        if args.contains("--html") {
            let path = CLI.strArg(args, "--html")
                ?? Paths.dataDir.appendingPathComponent("day-\(date).html").path
            do { try renderHTML(d, config: config).write(toFile: path, atomically: true, encoding: .utf8) }
            catch { Log.err("写不进 \(path)：\(error.localizedDescription)"); exit(1) }
            print("已生成 \(path)")
            if !args.contains("--no-open") { _ = notifhub.run("/usr/bin/open", [path]) }
            return
        }

        guard !d.items.isEmpty || d.work != nil else {
            print("\(date) 没有记录\(d.muted > 0 ? "（\(d.muted) 条被折叠，加 --all 看全部）" : "")")
            return
        }

        let span = (d.first.map(hhmm) ?? "") + " → " + (d.last.map(hhmm) ?? "")
        print("\(date) · \(d.total) 条 · \(d.apps.count) 个来源 · \(span)"
              + (d.notes > 0 ? " · 随手记 \(d.notes) 条" : "")
              + (d.aiInputs > 0 ? " · AI 输入 \(d.aiInputs) 条" : "")
              + (d.muted > 0 ? " · 已折叠 \(d.muted) 条噪音（--all 看全部）" : ""))
        if let w = d.work {
            print("\nAI 协作用时 \(AIWork.fmtDuration(w.wallMinutes))（全天去重；间隔 ≤\(w.idleMinutes) 分钟算连续）")
            for r in w.rows {
                let tools = r.byTool.map { "\($0.0) \(AIWork.fmtDuration($0.1))" }.joined(separator: " · ")
                let span = r.first > 0 ? "\(hhmm(r.first))–\(hhmm(r.last))" : "—"
                print("  \(CLI.pad(AIWork.fmtDuration(r.minutes), 7))\(CLI.pad(r.project, 34))\(CLI.pad(span, 13))输入 \(r.prompts)  \(tools)")
            }
        }

        if let s = d.summary {
            print("")
            if !s.headline.isEmpty { print("〖\(s.headline)〗") }
            print(s.text)
            print("（\(fmtTime(s.generatedAt)) 生成 · notihub summarize \(date) --force 重来）")
        } else {
            print("（还没总结这天：notihub summarize \(date)）")
        }
        print("")

        var lastHour = -1
        var cal = Calendar.current; cal.timeZone = displayTZ
        for it in d.items {
            let h = cal.component(.hour, from: Date(timeIntervalSince1970: it.ts))
            if h != lastHour {
                print("── \(String(format: "%02d", h)):00 " + String(repeating: "─", count: 46))
                lastHour = h
            }
            let range = it.endTs - it.ts > 60 ? "\(hhmm(it.ts))-\(hhmm(it.endTs))" : hhmm(it.ts)
            let flag = it.missed ? " ·未读" : ""
            print("\(CLI.pad(range, 12))\(CLI.pad(it.app, 8))\(it.who)\(flag)")
            if it.redacted {
                print("            〔已过保留期，正文已抹除〕")
            } else {
                for line in it.lines.prefix(8) {
                    print("            \(line.replacingOccurrences(of: "\n", with: " ").truncated(78))")
                }
                if it.lines.count > 8 { print("            …还有 \(it.lines.count - 8) 条") }
            }
        }

        if !d.agenda.isEmpty {
            print("\n这天相关的时间节点：")
            for a in d.agenda {
                let mark = a.status == "done" ? "✓" : (a.status == "dropped" ? "✗" : "·")
                print("  \(mark) #\(CLI.pad(String(a.id), 4)) \(CLI.pad(a.whenText ?? "—", 18))"
                      + "\(a.kind == "event" ? "日程" : "待办") \(a.title)"
                      + (a.isPushed ? " ⇢已推" : ""))
            }
            print("  推进苹果提醒/日历: notihub push <id>")
        }

        print("\n最活跃的来源：")
        for (w, c) in d.whos.prefix(8) { print("  \(CLI.pad(w, 22)) \(c)") }
    }


    static func renderHTML(_ d: Day, config: Config, backLink: String? = nil) -> String {
        let maxHour = max(1, d.byHour.max() ?? 1)
        var cal = Calendar.current; cal.timeZone = displayTZ

        var rows = ""
        var lastHour = -1
        for it in d.items {
            let h = cal.component(.hour, from: Date(timeIntervalSince1970: it.ts))
            if h != lastHour {
                rows += "<div class=\"hourmark\">\(String(format: "%02d", h)):00</div>"
                lastHour = h
            }
            let range = it.endTs - it.ts > 60 ? "\(hhmm(it.ts))–\(hhmm(it.endTs))" : hhmm(it.ts)
            let body = it.redacted
                ? "<div class=\"line muted\">〔已过保留期，正文已抹除〕</div>"
                : it.lines.map { "<div class=\"line\">\(renderLine($0, mail: it.canon == "mail" || it.app == "邮件"))</div>" }.joined()
            rows += """
            <div class="item\(it.canon == noteCanon ? " note" : AIWork.canons.contains(it.canon) ? " ai" : "")">
              <div class="t">\(range)</div>
              <div class="c">
                <div class="head"><span class="app">\(CLI.esc(it.app))</span>
                  <span class="who">\(CLI.esc(it.who))</span>
                  \(it.missed ? "<span class=\"missed\">未读</span>" : "")
                  \(it.lines.count > 1 ? "<span class=\"n\">\(it.lines.count) 条</span>" : "")</div>
                \(body)
              </div>
            </div>
            """
        }

        let hourBars = (0..<24).map { h in
            "<div class=\"hbar\" title=\"\(h):00 · \(d.byHour[h]) 条\"><span style=\"height:\(d.byHour[h] * 100 / maxHour)%\"></span><label>\(h)</label></div>"
        }.joined()

        let summaryBlock: String
        if let s = d.summary {
            summaryBlock = """
            <section class="sum">
              <div class="sumhead">\(s.headline.isEmpty ? "这一天" : CLI.esc(s.headline))</div>
              \(mdLite(s.text))
              <div class="sumfoot">\(fmtTime(s.generatedAt)) 生成</div>
            </section>
            """
        } else {
            summaryBlock = "<section class=\"sum empty\">这天还没生成总结（本机跑 <code>notihub summarize \(d.date)</code>）</section>"
        }

        let agendaBlock: String
        if d.agenda.isEmpty {
            agendaBlock = ""
        } else {
            let lis = d.agenda.map { a -> String in
                let cls = a.status == "done" ? " done" : (a.status == "dropped" ? " dropped" : "")
                let when = a.whenText.map { "<span class=\"when\">\(CLI.esc($0))</span>" } ?? "<span class=\"when none\">没定时间</span>"
                let src = a.source == "manual" ? "<span class=\"tag me\">我加的</span>"
                                               : "<span class=\"tag\">从通知里抽的</span>"
                let ev = a.evidence.map { "<div class=\"ev\">\(a.who.map { CLI.esc($0) + "：" } ?? "")\(CLI.esc($0))</div>" } ?? ""
                let dests = [(a.reminderID?.isEmpty == false) ? "提醒事项" : nil,
                             (a.calendarID?.isEmpty == false) ? "日历" : nil].compactMap { $0 }
                let pstat = "<span class=\"pstat\(dests.isEmpty ? "" : " tag ok")\" data-for=\"\(a.id)\">"
                          + (dests.isEmpty ? "" : "已进" + dests.joined(separator: "+")) + "</span>"
                let btn = { (to: String, label: String, cls: String) -> String in
                    "<button class=\"push\(cls)\" data-id=\"\(a.id)\" data-to=\"\(to)\""
                    + " data-title=\"\(CLI.esc(a.title))\">\(label)</button>"
                }
                let act = a.status != "open" || !Instance.personalFeatures ? "" :
                    btn("reminders", "⏰ 存进提醒事项", "")
                    + (a.kind == "event" && a.dueTS != nil ? btn("calendar", "📅 日历", " alt") : "")
                return """
                <li class="\(a.kind)\(cls)">\(when)
                  <span class="ttl">\(CLI.esc(a.title))</span>
                  \(src)\(pstat)\(act)\(ev)</li>
                """
            }.joined()
            agendaBlock = "<h2>时间节点</h2><ul class=\"agenda\">\(lis)</ul>"
        }

        let workBlock: String
        if let w = d.work {
            let maxM = max(1, w.rows.map(\.minutes).max() ?? 1)
            let rows = w.rows.map { r -> String in
                let tools = r.byTool.map { "\($0.0) \(AIWork.fmtDuration($0.1))" }.joined(separator: " · ")
                let span = r.first > 0 ? "\(hhmm(r.first))–\(hhmm(r.last))" : "—"
                return "<tr><td>\(CLI.esc(r.project))<div class=\"wbar\"><span style=\"width:\(r.minutes * 100 / maxM)%\"></span></div></td>"
                    + "<td data-sort=\"\(r.minutes)\">\(AIWork.fmtDuration(r.minutes))</td>"
                    + "<td data-sort=\"\(r.prompts)\">\(r.prompts)</td><td>\(span)</td><td>\(CLI.esc(tools))</td></tr>"
            }.joined()
            workBlock = """
            <h2>AI 协作用时 · \(AIWork.fmtDuration(w.wallMinutes))</h2>
            <p class="sub">按 Claude Code / Codex 会话日志计：间隔 ≤\(w.idleMinutes) 分钟算连续；各项目分别计，合计已去掉并行重叠。</p>
            <table><thead><tr><th>项目</th><th>用时</th><th>输入</th><th>时段</th><th>工具</th></tr></thead><tbody>\(rows)</tbody></table>
            """
        } else { workBlock = "" }

        let appRows = d.apps.map { "<tr><td>\(CLI.esc($0.0))</td><td data-sort=\"\($0.1)\">\($0.1)</td></tr>" }.joined()
        let whoRows = d.whos.map { "<tr><td>\(CLI.esc($0.0))</td><td data-sort=\"\($0.1)\">\($0.1)</td></tr>" }.joined()
        let span = (d.first.map(hhmm) ?? "-") + " → " + (d.last.map(hhmm) ?? "-")

        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(d.date) 复盘</title>
        <style>
        :root{--bg:#fdfcfa;--fg:#1f2328;--muted:#6b7280;--line:#e5e1da;--accent:#9a3412;--bar:#c2703a}
        *{box-sizing:border-box}
        body{margin:0;background:var(--bg);color:var(--fg);
             font:15px/1.6 -apple-system,"PingFang SC","Helvetica Neue",sans-serif;padding:30px 18px}
        .wrap{max-width:860px;margin:0 auto}
        h1{font-size:25px;margin:0 0 4px}
        h2{font-size:16px;margin:30px 0 10px;color:var(--accent)}
        .sub{color:var(--muted);font-size:13px;margin-bottom:20px}
        .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:10px;margin:18px 0}
        .card{border:1px solid var(--line);border-radius:10px;padding:12px 14px;background:#fff}
        .card b{display:block;font-size:23px;font-weight:600;letter-spacing:-.5px}
        .card span{color:var(--muted);font-size:12px}
        .hours{display:flex;gap:3px;align-items:flex-end;height:96px;padding:8px 0;border-bottom:1px solid var(--line);margin-bottom:6px}
        .hbar{flex:1;display:flex;flex-direction:column;justify-content:flex-end;align-items:center;height:100%}
        .hbar span{width:100%;background:var(--bar);border-radius:3px 3px 0 0;min-height:2px}
        .hbar label{font-size:10px;color:var(--muted);margin-top:3px}
        .back{display:inline-block;color:var(--accent);text-decoration:none;font-size:13px;margin-bottom:10px}
        .back:hover{text-decoration:underline}
        .hourmark{margin:22px 0 8px;color:var(--accent);font-size:12px;font-weight:600;
                  border-top:1px solid var(--line);padding-top:8px}
        .item{display:flex;gap:12px;margin:0 0 12px}
        .t{flex:0 0 84px;color:var(--muted);font-size:12px;padding-top:3px;font-variant-numeric:tabular-nums}
        .c{flex:1;min-width:0;border-left:2px solid var(--line);padding-left:12px}
        .head{margin-bottom:2px}
        .app{display:inline-block;background:#f2ece4;color:#7c4a24;border-radius:4px;
             padding:1px 6px;font-size:11px;margin-right:6px}
        .who{font-weight:600}
        .missed{color:#9a3412;font-size:11px;border:1px solid #e7c3ab;border-radius:4px;padding:0 5px;margin-left:6px}
        .n{color:var(--muted);font-size:11px;margin-left:6px}
        .line{color:#33383d;font-size:14px;word-break:break-word;white-space:pre-wrap;margin:1px 0}
        .line a{color:var(--accent);overflow-wrap:anywhere}
        .line.muted{color:var(--muted);font-style:italic}
        .item.note .c{border-left-color:var(--accent)}
        .item.note .app{background:#e7f0e4;color:#39602c}
        .item.ai .c{border-left-color:#8fb4d4}
        .item.ai .app{background:#e2ecf7;color:#28527a}
        .sum{border:1px solid var(--line);border-left:3px solid var(--accent);border-radius:10px;
             background:#fffdf9;padding:16px 18px;margin:18px 0}
        .sum.empty{color:var(--muted);font-size:13px;border-left-color:var(--line)}
        .sum code{background:#f2ece4;border-radius:4px;padding:1px 5px;font-size:12px}
        .sumhead{font-size:17px;font-weight:600;margin-bottom:8px;letter-spacing:-.2px}
        .sum ul{margin:6px 0;padding-left:20px}
        .sum li{margin:3px 0}
        .sum p{margin:8px 0 2px}
        .sumfoot{color:var(--muted);font-size:11px;margin-top:10px}
        ul.agenda{list-style:none;margin:0;padding:0}
        ul.agenda li{border:1px solid var(--line);border-radius:8px;background:#fff;
                     padding:9px 12px;margin-bottom:8px}
        ul.agenda li.event{border-left:3px solid var(--bar)}
        ul.agenda li.todo{border-left:3px solid #94a3b8}
        ul.agenda li.done .ttl,ul.agenda li.dropped .ttl{text-decoration:line-through;color:var(--muted)}
        .when{display:inline-block;font-variant-numeric:tabular-nums;color:var(--accent);
              font-size:12px;margin-right:8px}
        .when.none{color:var(--muted)}
        .ttl{font-weight:600}
        .tag{display:inline-block;background:#f2ece4;color:#7c4a24;border-radius:4px;
             padding:1px 6px;font-size:11px;margin-left:6px}
        .tag.me{background:#e7f0e4;color:#39602c}
        .tag.ok{background:#e2ecf7;color:#28527a}
        .tag.bad{background:#fbeceb;color:#a03123}
        .pstat:empty{display:none}
        button.push{margin-left:8px;font:inherit;font-size:11.5px;padding:2px 9px;
                    border:1px solid #b9cfe4;background:#eef5fb;color:#28527a;
                    border-radius:5px;cursor:pointer;vertical-align:1px}
        button.push:hover{background:#dfeaf6;border-color:#8fb4d4}
        button.push:disabled{cursor:default;opacity:.5}
        button.push.alt{margin-left:4px;background:#f4f1ea;border-color:#d9d0c2;color:#7c4a24}
        button.push.alt:hover{background:#ece6da;border-color:#c3b7a4}
        .ev{color:var(--muted);font-size:12px;margin-top:4px}
        .wbar{height:4px;background:#f2ece4;border-radius:2px;margin-top:4px}
        .wbar span{display:block;height:100%;background:var(--bar);border-radius:2px}
        table{width:100%;border-collapse:collapse;background:#fff;border:1px solid var(--line);border-radius:8px;overflow:hidden}
        th,td{padding:7px 12px;text-align:left;border-bottom:1px solid var(--line);font-size:14px}
        th{background:#f6f3ee;cursor:pointer;user-select:none;font-weight:600}
        th::after{content:" ⇅";color:#bbb;font-size:11px}
        tr:last-child td{border-bottom:none}
        .cols{display:grid;grid-template-columns:1fr 1fr;gap:16px}
        @media(max-width:620px){.cols{grid-template-columns:1fr}}
        footer{margin-top:34px;color:var(--muted);font-size:12px;border-top:1px solid var(--line);padding-top:12px}
        </style></head><body><div class="wrap">
        \(backLink.map { "<a class=\"back\" href=\"\($0)\">← 全部日期</a>" } ?? "")
        <h1>\(d.date) · 这一天发生了什么</h1>
        <div class="sub">\(d.total) 条通知 · \(d.apps.count) 个来源 · \(span)\(d.notes > 0 ? " · 随手记 \(d.notes) 条" : "")\(d.aiInputs > 0 ? " · AI 输入 \(d.aiInputs) 条" : "")\(d.muted > 0 ? " · 已折叠 \(d.muted) 条噪音" : "") · 生成于 \(fmtTime(nowUnix()))</div>

        \(summaryBlock)

        <div class="cards">
          <div class="card"><b>\(d.total)</b><span>通知总数</span></div>
          <div class="card"><b>\(d.items.count)</b><span>合并后的「事」</span></div>
          <div class="card"><b>\(d.whos.count)</b><span>联系人/来源</span></div>
          <div class="card"><b>\(d.items.filter(\.missed).count)</b><span>至今没点开</span></div>
        </div>

        <div class="hours">\(hourBars)</div>

        \(agendaBlock)

        \(workBlock)

        <h2>时间线</h2>
        \(rows.isEmpty ? "<p class=\"muted\">这一天没有记录。</p>" : rows)

        <h2>分布</h2>
        <div class="cols">
          <table><thead><tr><th>来源 App</th><th>条数</th></tr></thead><tbody>\(appRows)</tbody></table>
          <table><thead><tr><th>联系人/标题</th><th>条数</th></tr></thead><tbody>\(whoRows)</tbody></table>
        </div>

        <footer>notifhub · 通知即日志：微信 / 短信 / 钉钉 / 邮件 / iPhone 转发全部实时入库。
        本页只读不提醒。</footer>
        </div>
        <script>
        const DEST = t => t === 'calendar' ? '日历' : '提醒事项';
        const stat = id => document.querySelector('.pstat[data-for="'+id+'"]');
        function say(id, cls, text, tip){
          const s = stat(id); if(!s) return;
          s.className = 'pstat ' + cls; s.textContent = text; s.title = tip || '';
        }
        async function syncState(){
          let items = [];
          try{
            const r = await fetch('/api/agenda-queue', {cache:'no-store'});
            if(!r.ok) return;                    // 拿不到就别动按钮,保持可点
            items = (await r.json()).items || [];
          }catch(e){ return; }
          const byKey = new Map(), byId = new Map();
          for(const it of items){                // 队列按时间排,后面的覆盖前面的
            byKey.set(it.agendaId + '|' + (it.target||'auto'), it);
            byId.set(String(it.agendaId), it);
          }
          document.querySelectorAll('button.push').forEach(b=>{
            const it = byKey.get(Number(b.dataset.id) + '|' + b.dataset.to);
            b.disabled = !!it && (it.status === 'pending' || it.status === 'running');
          });
          document.querySelectorAll('.pstat').forEach(s=>{
            const it = byId.get(s.dataset.for); if(!it) return;
            const d = DEST(it.target);
            if(it.status==='done')        say(it.agendaId,'tag ok','✓ 已加进'+d, it.detail);
            else if(it.status==='failed') say(it.agendaId,'tag bad','✗ 没加成，可再点一次', it.detail);
            else                          say(it.agendaId,'tag','排队中…等 Mac 领单');
          });
        }
        syncState();
        setInterval(syncState, 15000);   // 点完不用刷新,15 秒内自己收敛成「✓ 已加进…」

        document.querySelectorAll('button.push').forEach(b=>{
          b.addEventListener('click', async ()=>{
            if(b.disabled) return;
            b.disabled = true;
            say(b.dataset.id, 'tag', '下单中…');
            try{
              const r = await fetch('/api/agenda-queue', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({agendaId: Number(b.dataset.id), title: b.dataset.title,
                                      target: b.dataset.to, force: true})
              });
              const j = await r.json().catch(()=>({}));
              if(!r.ok) throw new Error(j.error || ('HTTP '+r.status));
              say(b.dataset.id, 'tag', j.deduped ? '已在队列里…' : '排队中…等 Mac 领单');
              setTimeout(syncState, 3000);   // 3 秒后开始收敛成「✓ 已加进提醒事项」
            }catch(e){
              b.disabled = false;
              say(b.dataset.id, 'tag bad', '下单失败：' + e.message);
            }
          });
        });
        document.querySelectorAll('table').forEach(t=>{
          t.querySelectorAll('th').forEach((th,i)=>{
            let asc=false;
            th.addEventListener('click',()=>{
              const tb=t.tBodies[0], rows=[...tb.rows];
              rows.sort((a,b)=>{
                const av=a.cells[i]?.dataset.sort??a.cells[i]?.innerText??'';
                const bv=b.cells[i]?.dataset.sort??b.cells[i]?.innerText??'';
                const an=parseFloat(av), bn=parseFloat(bv);
                if(!isNaN(an)&&!isNaN(bn)) return asc?an-bn:bn-an;
                return asc?String(av).localeCompare(bv,'zh'):String(bv).localeCompare(av,'zh');
              });
              asc=!asc; rows.forEach(r=>tb.appendChild(r));
            });
          });
        });
        </script></body></html>
        """
    }
}
