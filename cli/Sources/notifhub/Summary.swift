import Foundation


enum LLM {

    private static let bridgeSource = #"""
    # notifhub → 总部 llm_client 的薄桥。stdin 收 job JSON，stdout 回一行结果 JSON。
    # 单一真源在 Sources/notifhub/Summary.swift 的 LLM.bridgeSource，本文件是它写出来的副本。
    import json, os, sys

    job = json.load(sys.stdin)
    try:
        client_dir = os.environ.get("NOTIHUB_LLM_CLIENT_DIR")
        if not client_dir:
            raise ValueError("Configure NOTIHUB_LLM_CLIENT_DIR or disable summary.enabled")
        sys.path.insert(0, os.path.expanduser(client_dir))
        from tools.llm_client import chat
        provider = os.environ.get("NOTIFHUB_LLM_PROVIDER")
        if provider not in (None, "claude", "codex"):
            raise ValueError("NOTIFHUB_LLM_PROVIDER must be claude or codex")
        text = chat(job["system"], job["message"], provider=provider,
                    timeout=job.get("timeout", 180),
                    origin={"component": "notifhub.collector", "entrypoint": "Summary.swift:LLM.bridgeSource",
                            "job": "com.notifhub.daemon/summarize", "run_id": "bridge-pid:%s" % os.getpid(),
                            "owner_session": {"status": "not_applicable"}})
    except Exception as e:
        sys.stdout.write(json.dumps({"ok": False, "error": "%s: %s" % (type(e).__name__, e)}))
        sys.exit(1)
    sys.stdout.write(json.dumps({"ok": True, "text": text}))
    """#

    static func findPython(_ configured: String) -> String? {
        var candidates = [configured, "/opt/homebrew/bin/python3",
                          
                          "/usr/local/bin/python3", "/usr/bin/python3"]
        candidates = candidates.filter { !$0.isEmpty }
        for p in candidates {
            guard FileManager.default.isExecutableFile(atPath: p) else { continue }
            let (rc, out) = notifhub.run(p, ["-c", "import sys;print(sys.version_info >= (3,10))"])
            if rc == 0, out.contains("True") { return p }
        }
        return nil
    }

    static func providerOverride(config: Config, environment: [String: String]) -> String? {
        if environment["NOTIFHUB_LLM_PROVIDER"] != nil { return nil }
        return ["claude", "codex"].contains(config.summary.provider) ? config.summary.provider : nil
    }

    enum LLMError: Error, CustomStringConvertible {
        case noPython, failed(String)
        var description: String {
            switch self {
            case .noPython:
                return "找不到 3.10+ 的 python3（总部 llm_client 要 3.10+ 的类型注解语法）。"
                     + "装一个或在配置里写 summary.python 指到具体解释器。"
            case .failed(let s): return s
            }
        }
    }

    static func chat(system: String, message: String, config: Config) throws -> String {
        guard let py = findPython(config.summary.python) else { throw LLMError.noPython }

        Paths.ensureDataDir()
        let bridge = Paths.dataDir.appendingPathComponent("llm_bridge.py")
        try? bridgeSource.write(to: bridge, atomically: true, encoding: .utf8)

        let job: [String: Any] = ["system": system, "message": message,
                                  "timeout": config.summary.timeoutSeconds]
        guard let jd = try? JSONSerialization.data(withJSONObject: job),
              let js = String(data: jd, encoding: .utf8) else {
            throw LLMError.failed("job 序列化失败")
        }

        let path = [Paths.home.appendingPathComponent(".local/bin").path,
                    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        var env = ["PATH": path]
        if let provider = providerOverride(config: config, environment: ProcessInfo.processInfo.environment) {
            env["NOTIFHUB_LLM_PROVIDER"] = provider
        }
        let (rc, out) = notifhub.run(py, [bridge.path], stdin: js, env: env, stderrToo: true)

        let line = out.split(separator: "\n").reversed().first { $0.hasPrefix("{\"ok\"") }
        guard let line,
              let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw LLMError.failed("LLM 桥没回可解析的结果 (rc=\(rc)):\n\(out.truncated(600))")
        }
        if obj["ok"] as? Bool == true, let text = obj["text"] as? String { return text }
        throw LLMError.failed("LLM 调用失败: \(obj["error"] as? String ?? "?")")
    }
}


enum Summarizer {

    static let systemPrompt = """
    你是使用者的私人复盘助理。输入是他某一天在 Mac 上收到的全部通知（微信 / 短信 / 钉钉 / 邮件 / iPhone 转发）\
    合并后的时间线，以及他自己写的随手记（标记为「随手记」）。
    标记为 [Claude Code] / [Codex] 的条目**不是通知**，是他本人发给 AI 编程助手的输入，冒号前是项目名；\
    它们说明他在那个项目上做了什么、卡在哪、还想做什么。输入末尾另附按会话日志算好的各项目用时。

    你的任务：① 把这一天概括成他自己回头看会觉得有用的复盘；② 把里面**涉及时间节点的事**挑出来；\
    ③ 按项目说清他在 AI 助手里做了什么、还有什么没做完。

    只输出一个 JSON 对象。不要任何解释文字，不要 markdown 代码围栏，第一个字符就是 {。

    {
      "headline": "一句话说这天主要在忙什么，30 字以内",
      "points": ["3 到 6 条要点，写发生了什么、和谁、进展到哪。不要复述通知条数，不要空话套话"],
      "threads": [
        {"who": "人名或群名", "what": "这条线上发生了什么", "state": "进行中|已完结|等我回"}
      ],
      "work": [
        {"project": "项目名，照抄输入里冒号前的名字", "did": "这天做了什么，写成果不写过程，40 字以内",
         "pending": "从他的输入看还没做完、说了要做但没做、或卡住的事；看不出来就写空串，不许编", "state": "完成|进行中|卡住"}
      ],
      "agenda": [
        {
          "title": "要做的事 / 要去的场合，动词开头，20 字以内",
          "kind": "todo 或 event（要到场、有明确时刻的是 event，其余是 todo）",
          "when": "绝对时间，格式 2026-08-20T15:00；只知道日期不知道时刻就写 2026-08-20；完全没提时间写 null",
          "durationMinutes": 60,
          "who": "这事跟谁有关",
          "evidence": "原文里真实出现过的片段，40 字以内",
          "confidence": 0.0 到 1.0
        }
      ]
    }

    抽 agenda 的硬规矩：
    - 相对时间（明天 / 下周三 / 月底）按下面给的「今天是哪天」换算成绝对日期，别原样抄。
    - 只抽**要他本人去做或去到场**的事。广告、营销、验证码、系统通知、群里跟他无关的闲聊，一律不抽。
    - [Claude Code] / [Codex] 条目是他给 AI 下的指令，不抽进 agenda；没做完的写进 work 的 pending。
    - work 只列时间线里真出现过的项目，没有 AI 条目就给 []；points 和 threads 不必重复 AI 协作的细节。
    - evidence 必须是输入里真实出现过的片段，不许自己编、不许改写。核不上的宁可不抽。
    - 拿不准的给低 confidence（<0.5），但不要为了凑数硬抽。一件都没有就给空数组 []。
    """

    static func timeline(_ d: Recap.Day, maxChars: Int) throws -> String {
        var entries: [(prefix: String, body: String)] = []
        for it in d.items where !it.redacted {
            let range = it.endTs - it.ts > 60 ? "\(Recap.hhmm(it.ts))-\(Recap.hhmm(it.endTs))" : Recap.hhmm(it.ts)
            let body = it.lines.map { $0.replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: " / ")
            entries.append(("\(range) [\(it.app.truncated(20))] \(it.who.truncated(32)): ", body))
        }
        let notice = "以下覆盖全部 \(entries.count) 条可见合并记录及其中的随手记；长正文按条压缩，时间与来源保留。\n"
        var remaining = maxChars - notice.count - entries.reduce(0) { $0 + $1.prefix.count + 1 }
        guard remaining >= entries.count * 8 else {
            throw LLM.LLMError.failed("总结预算不足以覆盖全部 \(entries.count) 条记录，拒绝仅总结前半天")
        }
        var out = notice
        for (i, entry) in entries.enumerated() {
            let allowance = remaining / (entries.count - i)
            let excerpt = entry.body.count <= allowance ? entry.body
                : String(entry.body.prefix(max(0, allowance - 1))) + "…"
            out += entry.prefix + excerpt + "\n"
            remaining -= excerpt.count
        }
        return out
    }

    struct Outcome {
        var headline = ""
        var text = ""
        var added = 0
        var skipped = false
        var reason = ""
    }

    @discardableResult
    static func ensure(date: String, store: Store, config: Config,
                       force: Bool = false, extractAgenda: Bool = true,
                       quiet: Bool = false) throws -> Outcome {
        var o = Outcome()
        guard config.summary.enabled || force else {
            o.skipped = true; o.reason = "配置里 summary.enabled=false"; return o
        }

        let d = Recap.load(store: store, date: date, includeAll: false, config: config)
        let notes = store.notes(date: date)
        let unit = d.total + d.aiInputs + notes.count
        guard unit > 0 else { o.skipped = true; o.reason = "这天没有记录"; return o }

        if let old = store.summary(date: date), !force {
            let grew = unit - old.eventCount
            let age = nowUnix() - old.generatedAt
            if grew < config.summary.minNewEvents || age < Double(config.summary.minIntervalSeconds) {
                o.skipped = true
                o.headline = old.headline
                o.text = old.text
                o.reason = grew < config.summary.minNewEvents
                    ? "自上次总结只多了 \(grew) 条，不值得重算（--force 强制）"
                    : "上次总结才 \(Int(age / 60)) 分钟前（--force 强制）"
                return o
            }
        }

        let body = try timeline(d, maxChars: config.summary.maxChars)

        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = displayTZ
        let wf = DateFormatter(); wf.dateFormat = "EEEE"; wf.timeZone = displayTZ
        wf.locale = Locale(identifier: "zh_CN")
        let weekday = f.date(from: date).map { wf.string(from: $0) } ?? ""

        let message = """
        今天是 \(date)（\(weekday)）。所有相对时间都按这一天换算。

        时间线：
        \(body)
        \(d.work.map { "\n" + AIWork.summaryBlock($0) } ?? "")
        """

        if !quiet { print("正在总结 \(date)（\(d.items.count) 件事，\(body.count) 字）…") }
        let raw = try LLM.chat(system: systemPrompt, message: message, config: config)

        guard let obj = parseJSON(raw) else {
            throw LLM.LLMError.failed("LLM 回的不是 JSON，原文前 400 字：\n\(raw.truncated(400))")
        }

        o.headline = obj["headline"] as? String ?? ""
        let points = (obj["points"] as? [Any] ?? []).compactMap { $0 as? String }
        let threads = (obj["threads"] as? [[String: Any]] ?? [])

        var md = ""
        for p in points { md += "- \(p)\n" }
        if !threads.isEmpty {
            md += "\n**几条线：**\n"
            for t in threads {
                let who = t["who"] as? String ?? "?"
                let what = t["what"] as? String ?? ""
                let state = t["state"] as? String ?? ""
                md += "- \(who)：\(what)\(state.isEmpty ? "" : "（\(state)）")\n"
            }
        }
        md += workMarkdown(obj["work"] as? [[String: Any]] ?? [], day: d.work)
        o.text = md.trimmingCharacters(in: .whitespacesAndNewlines)
        store.saveSummary(date: date, eventCount: unit, headline: o.headline, text: o.text, raw: raw)

        if extractAgenda && config.summary.extractAgenda {
            store.clearLLMAgenda(date: date)
            for a in (obj["agenda"] as? [[String: Any]] ?? []) {
                guard let item = makeItem(a, srcDate: date, config: config) else { continue }
                if store.insertAgenda(item) != nil { o.added += 1 }
            }
        }
        return o
    }

    static func workMarkdown(_ items: [[String: Any]], day: AIWork.Day?) -> String {
        let minutes = Dictionary((day?.rows ?? []).map { ($0.project, $0.minutes) }, uniquingKeysWith: max)
        var lines = ""
        for w in items {
            let project = (w["project"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let did = (w["did"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !project.isEmpty, !did.isEmpty else { continue }
            let time = minutes[project].map { "（\(AIWork.fmtDuration($0))）" } ?? ""
            let state = (w["state"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let pending = (w["pending"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            lines += "- **\(project)**\(time)：\(did)\(state.isEmpty ? "" : "〔\(state)〕")"
                + (pending.isEmpty ? "" : "；**还没做：**\(pending)") + "\n"
        }
        return lines.isEmpty ? "" : "\n**AI 协作：**\n" + lines
    }

    static func makeItem(_ a: [String: Any], srcDate: String, config: Config) -> AgendaItem? {
        guard let title = (a["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        var item = AgendaItem(source: "llm", srcDate: srcDate, title: title)
        item.kind = (a["kind"] as? String) == "event" ? "event" : "todo"
        item.who = (a["who"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        item.evidence = (a["evidence"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        item.confidence = a["confidence"] as? Double ?? (a["confidence"] as? NSNumber)?.doubleValue

        if let whenStr = a["when"] as? String, !whenStr.isEmpty, whenStr.lowercased() != "null",
           let (ts, allDay) = WhenParser.parse(whenStr, defaultHour: config.apple.defaultDueHour) {
            item.dueTS = ts
            item.allDay = allDay
            if item.kind == "event" && !allDay {
                let mins = (a["durationMinutes"] as? Int)
                    ?? (a["durationMinutes"] as? NSNumber)?.intValue
                    ?? config.apple.defaultEventMinutes
                item.endTS = ts + Double(mins) * 60
            }
        } else if item.kind == "event" {
            item.kind = "todo"
        }
        return item
    }

    static func parseJSON(_ raw: String) -> [String: Any]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.split(separator: "\n").dropFirst().joined(separator: "\n")
            if let r = s.range(of: "```", options: .backwards) { s = String(s[s.startIndex..<r.lowerBound]) }
        }
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        let json = String(s[a...b])
        if let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] { return o }
        guard let fixed = repairBrackets(json) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(fixed.utf8))) as? [String: Any]
    }

    static func repairBrackets(_ json: String) -> String? {
        var out: [Character] = []
        var stack: [Character] = []        // '{' 或 '['
        var inStr = false, esc = false
        var lastStrStart = -1              // 最近一个字符串在 out 里的起始下标
        var changed = false

        for ch in json {
            if inStr {
                out.append(ch)
                if esc { esc = false }
                else if ch == "\\" { esc = true }
                else if ch == "\"" { inStr = false }
                continue
            }
            switch ch {
            case "\"":
                lastStrStart = out.count
                inStr = true
                out.append(ch)
            case "{", "[":
                stack.append(ch)
                out.append(ch)
            case "}", "]":
                if stack.isEmpty { return nil }
                stack.removeLast()
                out.append(ch)
            case ":":
                if stack.last == "[", lastStrStart >= 0 {
                    var i = lastStrStart
                    while i > 0, out[i - 1] == " " || out[i - 1] == "\n" { i -= 1 }
                    if i > 0, out[i - 1] == "," { i -= 1 }
                    out.insert("]", at: i)
                    stack.removeLast()
                    changed = true
                }
                out.append(ch)
            default:
                out.append(ch)
            }
        }
        if inStr { return nil }            // 字符串都没收尾 = 是被截断的，别猜
        while let top = stack.popLast() {  // 末尾没闭合的一并补上
            out.append(top == "{" ? "}" : "]")
            changed = true
        }
        return changed ? String(out) : nil
    }


    static func recentDates(store: Store, count: Int, through: String = Recap.today()) -> [String] {
        var dates: [String] = []
        store.db.query("""
            SELECT \(Clock.sqlDay("ts")) d FROM events
             WHERE \(Clock.sqlDay("ts")) <= ?
             GROUP BY d ORDER BY d DESC LIMIT ?
            """, [through, count]) { dates.append($0.str(0)) }
        return dates
    }

    static func failureMessage(date: String, error: Error) -> String {
        let detail = String(describing: error).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "；")
        return "\(date) 总结失败: \(detail)"
    }

    static func run(args: [String]) {
        guard let store = Store() else { exit(1) }
        let config = Config.load()
        if Instance.personalFeatures { AIWork.collect(store: store, config: config) }
        let force = args.contains("--force")
        let withAgenda = !args.contains("--no-agenda")

        var dates: [String] = args.filter { $0.count == 10 && $0.hasPrefix("20") }
        if dates.isEmpty {
            let n = CLI.intArg(args, "--days") ?? 1
            dates = recentDates(store: store, count: n)
            if dates.isEmpty { dates = [Recap.today()] }
        }

        var failed = false
        for date in dates {
            do {
                let o = try ensure(date: date, store: store, config: config,
                                   force: force, extractAgenda: withAgenda)
                if o.skipped && o.text.isEmpty {
                    print("\(date): 跳过 —— \(o.reason)")
                    continue
                }
                print("\n\(date) · \(o.headline)")
                print(String(repeating: "─", count: 58))
                print(o.text)
                if o.skipped {
                    print("\n（复用上次的总结：\(o.reason)）")
                } else if withAgenda {
                    print("\n抽出 \(o.added) 条时间节点"
                          + (o.added > 0 ? " → notihub agenda 看，notihub push <id> 推进苹果" : ""))
                }
            } catch {
                Log.err(failureMessage(date: date, error: error))
                failed = true
            }
        }
        if failed { exit(1) }
    }
}
