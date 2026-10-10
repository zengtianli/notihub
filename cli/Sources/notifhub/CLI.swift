import Foundation

enum CLI {


    static func tail(args: [String]) {
        guard let store = Store() else { exit(1) }
        let n = intArg(args, "-n") ?? 20
        let follow = args.contains("-f")
        var lastID: Int64 = 0

        func dump(since: Int64) -> Int64 {
            var maxID = since
            var rows: [String] = []
            store.db.query("""
                SELECT id, ts, app, COALESCE(title,''), COALESCE(body,''), source, redacted
                  FROM events WHERE id > ? ORDER BY id DESC LIMIT ?
                """, [since, since == 0 ? n : 100]) { r in
                maxID = max(maxID, r.int(0))
                let redacted = r.int(6) == 1
                let text = redacted ? "〔已过保留期，正文已抹除〕"
                                    : "\(r.str(3)) \(r.str(4))".trimmingCharacters(in: .whitespaces).truncated(70)
                rows.append("\(fmtTime(r.dbl(1)))  \(pad(r.str(2), 10)) \(text)")
            }
            rows.reversed().forEach { print($0) }
            return maxID
        }

        lastID = dump(since: 0)
        guard follow else { return }
        print("—— 跟随中，Ctrl-C 退出 ——")
        while true {
            Thread.sleep(forTimeInterval: 2)
            lastID = dump(since: lastID)
        }
    }


    static func search(args: [String]) {
        let asJSON = args.contains("--json")
        if asJSON {
            let p = parseStrict(args, cmd: "search", switches: ["--json"], options: ["--days", "--app"])
            if let e = p.error { jsonUsageFail(e) }
            if p.positional.isEmpty { jsonUsageFail("search 缺关键词（用法: notihub search <关键词> [--app wechat] [--days 30] [--json]）") }
            if let d = p.values["--days"], dayCount(d) == nil { jsonUsageFail("--days 要 1–36500 的整数，实得 \(d)") }
            if let a = p.values["--app"], a.trimmingCharacters(in: .whitespaces).isEmpty { jsonUsageFail("--app 不能为空") }
            do { runSearch(store: try Today.existingStore(readOnly: true), terms: p.positional,
                           days: p.values["--days"].flatMap(dayCount), app: p.values["--app"], asJSON: true) }
            catch { jsonFail(error.localizedDescription) }
            return
        }
        let valueFlags: Set<String> = ["--days", "--app", "--html", "-n"]
        var terms: [String] = []
        var skipNext = false
        for a in args {
            if skipNext { skipNext = false; continue }
            if valueFlags.contains(a) { skipNext = true; continue }
            if a.hasPrefix("-") { continue }
            terms.append(a)
        }
        guard !terms.isEmpty else {
            Log.err("用法: notihub search <关键词> [--app wechat] [--days 30] [--json]")
            exit(2)
        }
        guard let store = Store() else { exit(1) }
        runSearch(store: store, terms: terms, days: intArg(args, "--days"), app: strArg(args, "--app"), asJSON: false)
    }

    static func runSearch(store: Store, terms: [String], days: Int?, app: String?, asJSON: Bool) {
        let q = terms.joined(separator: " ")

        var sql: String
        var binds: [Any?] = []
        let tooShortForTrigram = q.count < 3
        if tooShortForTrigram && store.ftsEnabled {
            let notice = "（『\(q)』不足 3 字，trigram 索引用不上，已自动改用 LIKE 扫描）"
            if asJSON { Log.err(notice) } else { print(notice) }
        }
        if store.ftsEnabled && !tooShortForTrigram {
            sql = """
                SELECT e.id, e.ts, e.app, COALESCE(e.title,''), COALESCE(e.body,''), e.source, e.canon
                  FROM events e JOIN events_fts ON events_fts.rowid = e.id
                 WHERE events_fts MATCH ?
                """
            binds.append("\"\(q.replacingOccurrences(of: "\"", with: ""))\"")
        } else {
            sql = """
                SELECT id, ts, app, COALESCE(title,''), COALESCE(body,''), source, canon
                  FROM events e
                 WHERE (title LIKE ? OR body LIKE ? OR app LIKE ?)
                """
            binds.append(contentsOf: ["%\(q)%", "%\(q)%", "%\(q)%"])
        }
        if let d = days { sql += " AND e.ts > ?"; binds.append(nowUnix() - Double(d) * 86400) }
        if let a = app { sql += " AND e.canon = ?"; binds.append(a) }
        sql += " ORDER BY e.ts DESC LIMIT 100"

        var out: [[String: Any]] = []
        store.db.query(sql, binds) { r in
            out.append(["id": r.int(0), "ts": r.dbl(1), "app": r.str(2),
                        "title": r.str(3), "body": r.str(4), "source": r.str(5)])
        }
        if asJSON {
            let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        } else if out.isEmpty {
            print("没有命中。\(store.ftsEnabled ? "" : "（注意：FTS5 不可用，当前是 LIKE 扫描）")")
        } else {
            for r in out {
                let t = fmtTime(r["ts"] as! Double)
                let text = "\(r["title"]!) \(r["body"]!)".trimmingCharacters(in: .whitespaces)
                print("\(t)  \(pad(r["app"] as! String, 10)) \(text.truncated(80))")
            }
            print("—— \(out.count) 条\(store.ftsEnabled ? "" : "（LIKE 降级模式）")")
        }
    }


    struct Stats {
        var days: Int
        var total: Int
        var byApp: [(String, Int)]
        var byHour: [Int]
        var byDay: [(String, Int)]
        var actions: [(String, Int)]
        var renotified: Int
        var unreadOpen: Int
    }

    static func gather(store: Store, days: Int) -> Stats {
        let since = nowUnix() - Double(days) * 86400
        var total = 0
        store.db.query("SELECT COUNT(*) FROM events WHERE ts > ?", [since]) { total = Int($0.int(0)) }

        var byApp: [(String, Int)] = []
        store.db.query("""
            SELECT app, COUNT(*) c FROM events WHERE ts > ? GROUP BY canon ORDER BY c DESC LIMIT 15
            """, [since]) { byApp.append(($0.str(0), Int($0.int(1)))) }

        var byHour = [Int](repeating: 0, count: 24)
        store.db.query("""
            SELECT \(Clock.sqlHour("ts")) h, COUNT(*)
              FROM events WHERE ts > ? GROUP BY h
            """, [since]) { r in
            let h = Int(r.int(0)); if h >= 0 && h < 24 { byHour[h] = Int(r.int(1)) }
        }

        var byDay: [(String, Int)] = []
        store.db.query("""
            SELECT \(Clock.sqlDay("ts")) d, COUNT(*) FROM events WHERE ts > ?
             GROUP BY d ORDER BY d
            """, [since]) { byDay.append(($0.str(0), Int($0.int(1)))) }

        var actions: [(String, Int)] = []
        store.db.query("""
            SELECT rule || '/' || action, COUNT(*) c FROM actions WHERE ts > ?
             GROUP BY 1 ORDER BY c DESC LIMIT 10
            """, [since]) { actions.append(($0.str(0), Int($0.int(1)))) }

        var reno = 0, open = 0
        store.db.query("SELECT COUNT(*) FROM events WHERE renotified=1 AND ts > ?", [since]) { reno = Int($0.int(0)) }
        store.db.query("SELECT COUNT(*) FROM events WHERE rec_id IS NOT NULL AND dismissed_at IS NULL AND ts > ?", [since]) { open = Int($0.int(0)) }

        return Stats(days: days, total: total, byApp: byApp, byHour: byHour,
                     byDay: byDay, actions: actions, renotified: reno, unreadOpen: open)
    }

    static func stats(args: [String]) {
        let days = intArg(args, "--days") ?? 7
        if args.contains("--json") {
            let p = parseStrict(args, cmd: "stats", switches: ["--json"], options: ["--days"])
            if let e = p.error { jsonUsageFail(e) }
            if let x = p.positional.first { jsonUsageFail("stats --json 不认识的参数：\(x)（notihub stats --help）") }
            if let d = p.values["--days"], dayCount(d) == nil { jsonUsageFail("--days 要 1–36500 的整数，实得 \(d)") }
            let store: Store
            do { store = try Today.existingStore(readOnly: true) }
            catch { jsonFail(error.localizedDescription) }
            printJSON(statsJSON(gather(store: store, days: p.values["--days"].flatMap(dayCount) ?? 7)))
            return
        }
        guard let store = Store() else { exit(1) }
        let s = gather(store: store, days: days)

        if args.contains("--html") {
            let path = strArg(args, "--html") ?? Paths.dataDir.appendingPathComponent("stats.html").path
            let html = renderHTML(s)
            do { try html.write(toFile: path, atomically: true, encoding: .utf8) }
            catch { Log.err("写不进 \(path)：\(error.localizedDescription)"); exit(1) }
            print("已生成 \(path)")
            if !args.contains("--no-open") { _ = run("/usr/bin/open", [path]) }
            return
        }

        print("近 \(days) 天：\(s.total) 条通知，未点开 \(s.unreadOpen) 条，二次提醒 \(s.renotified) 次")
        print("\n按 app：")
        for (a, c) in s.byApp {
            let bar = String(repeating: "█", count: max(1, c * 30 / max(1, s.byApp.first?.1 ?? 1)))
            print("  \(pad(a, 12)) \(pad("\(c)", 5)) \(bar)")
        }
        print("\n按小时：")
        let peak = max(1, s.byHour.max() ?? 1)
        for h in 0..<24 where s.byHour[h] > 0 {
            print("  \(pad("\(h):00", 6)) \(pad("\(s.byHour[h])", 5)) \(String(repeating: "▇", count: max(1, s.byHour[h] * 24 / peak)))")
        }
        if !s.actions.isEmpty {
            print("\n规则动作：")
            for (a, c) in s.actions { print("  \(pad(a, 22)) \(c)") }
        }
    }


    struct DoctorCheck {
        enum Level: String { case ok, warn, fail, info }
        var name: String
        var level: Level
        var detail: String
        var fatal = false
        var sub = false
        var chain = false
        var external = false
        var source = false

        var json: [String: Any] {
            ["name": name, "level": level.rawValue, "ok": level != .fail, "fatal": fatal, "detail": detail,
             "group": external ? "online" : "local"]
        }
    }

    static func doctorChecks(online: Bool) -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        func add(_ name: String, _ level: DoctorCheck.Level, _ detail: String, fatal: Bool = false,
                 sub: Bool = false, chain: Bool = false, external: Bool = false, source: Bool = false) {
            out.append(DoctorCheck(name: name, level: level, detail: detail, fatal: fatal, sub: sub,
                                   chain: chain, external: external, source: source))
        }

        for c in Sources.all() {
            let (ok, detail) = c.health()
            let nonFatal = Sources.nonFatal.contains(c.name)
            add("源 \(c.name)", ok ? .ok : (nonFatal ? .warn : .fail), detail, fatal: !ok && !nonFatal, source: !ok && !nonFatal)
        }

        let store = Store(readOnlyAt: Paths.db.path)
        if let store {
            var n = 0, a = 0
            store.db.query("SELECT COUNT(*) FROM events") { n = Int($0.int(0)) }
            store.db.query("SELECT COUNT(*) FROM actions") { a = Int($0.int(0)) }
            add("库", .ok, "\(n) 条事件 / \(a) 条动作 · \(Paths.db.path)")
            add("全文检索", store.ftsEnabled ? .ok : .warn, store.ftsEnabled ? "FTS5 trigram 可用" : "不可用，search 降级 LIKE")
            let perm = ((try? FileManager.default.attributesOfItem(atPath: Paths.db.path)[.posixPermissions]) as? Int) ?? 0
            let permOK = perm & 0o077 == 0
            add("库权限", permOK ? .ok : .fail, String(format: "%o", perm) + (permOK ? "" : " ← 应为 600，正文含聊天内容"))
        } else if !FileManager.default.fileExists(atPath: Paths.db.path) {
            add("库", .fail, "不存在 \(Paths.db.path) —— 采集还没跑过（notihub install）或数据目录不对", fatal: true)
        } else {
            add("库", .fail, "打不开 \(Paths.db.path)（权限或库损坏）", fatal: true)
        }

        let cfg = Config.load()
        let cfgExists = FileManager.default.fileExists(atPath: Paths.configFile.path)
        add("配置", cfgExists ? .ok : .warn, cfgExists ? Paths.configFile.path : "未创建，用内置默认值（跑 notihub install 生成）")
        add("", .info, "规则 \(cfg.rules.count) 条 · 保留期 \(cfg.retentionDays) 天 · 复盘折叠 \(cfg.muteInViews.joined(separator: ","))", sub: true)
        add("", .info, "Bark \(cfg.resolveBarkKey() != nil ? "key 已解析（来源: \(cfg.bark.key != nil ? "配置" : "keyFile/env")）" : "无 key，bark 动作会静默失败")", sub: true)

        let tzNow = Clock.tz
        let offH = Double(tzNow.secondsFromGMT(for: Date())) / 3600
        let tzOK = Clock.resolvedFromSystem
        add("划天时区", tzOK ? .ok : .fail,
            "\(tzNow.identifier) (UTC\(offH >= 0 ? "+" : "")\(String(format: "%g", offH))) · 现在是 \(Recap.today()) \(Recap.hhmm(nowUnix()))"
            + (tzOK ? "  ← 系统时区 /etc/localtime" : " ← 解不出系统时区，已退化到 TimeZone.current（会跟着 TZ 跑）"), fatal: !tzOK)
        let tzEnv = ProcessInfo.processInfo.environment["TZ"] ?? "(未设)"
        add("", .info, "TZ 环境变量 \(tzEnv) —— 只表示人在哪，不是时间口径，别去「修」它", sub: true)
        if let probe = store?.db ?? DB(path: ":memory:") {
            var sqlDay = ""
            probe.query("SELECT \(Clock.sqlDay("?"))", [nowUnix()]) { sqlDay = $0.str(0) }
            let same = sqlDay == Recap.today()
            add("Swift 与 SQLite", same ? .ok : .fail, "同一把尺子（\(Recap.today()) / \(sqlDay)）", fatal: !same, sub: true)
        }
        for p in [Paths.launchAgent, Paths.publishAgent, Paths.queueAgent] {
            guard let txt = try? String(contentsOf: p, encoding: .utf8) else { continue }
            let hasTZ = txt.contains("<key>TZ</key>")
            let fix = p == Paths.launchAgent ? "重跑 notihub install 清掉" : "这是已退役的旧作业，卸载并移走即可"
            add(p.lastPathComponent, hasTZ ? .warn : .ok, hasTZ ? "写了 TZ —— 会冻住口径，\(fix)" : "没写 TZ，作业跟系统时区", sub: true)
        }

        if cfg.summary.enabled {
            let py = LLM.findPython(cfg.summary.python)
            let claudeBin = ["\(Paths.home.path)/.local/bin/claude", "/opt/homebrew/bin/claude",
                             "/usr/local/bin/claude"].first { FileManager.default.isExecutableFile(atPath: $0) }
            let ok = py != nil && claudeBin != nil
            add("日报总结", ok ? .ok : .warn,
                py == nil ? "找不到 3.10+ 的 python3（配 summary.python）"
                : claudeBin == nil ? "找不到 claude CLI（总部 llm_client 靠它，无需 API key）"
                : "\(py!.replacingOccurrences(of: Paths.home.path, with: "~")) + claude 订阅通路就绪")
            var nSum = 0
            store?.db.query("SELECT COUNT(*) FROM summaries") { nSum = Int($0.int(0)) }
            add("", .info, "已总结 \(nSum) 天 · 重算闸: 距上次 ≥\(cfg.summary.minIntervalSeconds / 3600)h 且新增 ≥\(cfg.summary.minNewEvents) 条", sub: true)
        } else {
            add("日报总结", .warn, "配置里关掉了（summary.enabled=false），通知正文不出本机")
        }

        if online && Instance.personalFeatures {
            if FileManager.default.fileExists(atPath: Remain.scanner) {
                if let rpy = LLM.findPython(cfg.summary.python) {
                    let (rrc, rout) = run(rpy, [Remain.scanner, "--selfcheck"], stderrToo: true, timeout: 30)
                    add("remain 面", rrc == 0 ? .ok : .warn,
                        rrc == 0 ? rout.trimmingCharacters(in: .whitespacesAndNewlines)
                        : "selfcheck rc=\(rrc)（publish 会放占位错误页，不拦发布）: \(rout.suffix(120))", external: true)
                } else {
                    add("remain 面", .warn, "找不到 3.10+ 的 python3（扫描器跑不了）", external: true)
                }
            } else {
                add("remain 面", .warn, "总部扫描器不存在：\(Remain.scanner)", external: true)
            }
        }

        if !cfg.ai.enabled {
            add("AI 协作", .warn, "配置里关掉了（ai.enabled=false）")
        } else if Instance.personalFeatures {
            let r = AIWork.Roots.standard
            let fm = FileManager.default
            let srcs: [(String, Bool)] = [
                ("Claude 输入", fm.isReadableFile(atPath: r.claudeHistory.path)),
                ("Claude 会话", fm.fileExists(atPath: r.claudeProjects.path)),
                ("Codex 输入", fm.isReadableFile(atPath: r.codexHistory.path)),
                ("Codex 会话", r.codexSessions.contains { fm.fileExists(atPath: $0.path) }),
            ]
            var nIn = 0, last = 0.0
            store?.db.query("SELECT COUNT(*) FROM events WHERE canon IN ('claude','codex') AND \(Clock.sqlDay("ts")) = ?",
                            [Recap.today()]) { nIn = Int($0.int(0)) }
            if let s = store?.watermark("ai.lastCollect") { last = Double(s) ?? 0 }
            let today = store.flatMap { AIWork.day(store: $0, date: Recap.today(), config: cfg) }
            add("AI 协作", srcs.allSatisfy(\.1) ? .ok : .warn,
                srcs.map { "\($0.0)\($0.1 ? "✓" : "✗")" }.joined(separator: " ")
                + " · 今天输入 \(nIn) 条 · 用时 \(AIWork.fmtDuration(today?.wallMinutes ?? 0))"
                + " · 上次收取 \(last > 0 ? fmtTime(last) : "从未（publish/day 时收取）")")
            add("", .info, "私密目录只计时不收正文：\(cfg.ai.privatePaths.joined(separator: ", "))", sub: true)
        }

        var nOpen = 0, nPushed = 0
        store?.db.query("SELECT COUNT(*) FROM agenda WHERE status='open'") { nOpen = Int($0.int(0)) }
        store?.db.query("""
            SELECT COUNT(*) FROM agenda
             WHERE reminder_id IS NOT NULL AND reminder_id<>'' OR calendar_id IS NOT NULL AND calendar_id<>''
            """) { nPushed = Int($0.int(0)) }
        if online {
            let (rcR, defList) = run("/usr/bin/osascript",
                                     ["-e", "tell application \"Reminders\" to return name of default list"])
            let listOK = rcR == 0 && !defList.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            add("苹果导出", listOK ? .ok : .warn, "提醒事项列表 "
                + (listOK ? "「\(cfg.apple.remindersList.isEmpty ? defList.trimmingCharacters(in: .whitespacesAndNewlines) : cfg.apple.remindersList)」" : "拿不到（第一次跑会弹「自动化」授权，同意后重跑）")
                + " · 日历 \(cfg.apple.calendarName.isEmpty ? "未指定（push 时 --cal 一次即记住）" : "「\(cfg.apple.calendarName)」")", external: true)
        }
        add("待办", .info, "本机 \(nOpen) 条未完成 · \(nPushed) 条已进苹果 · 只有你敲 push 才会推，没有自动推送", sub: online)

        let daemonRT = daemonRuntime()
        add("launchd", daemonRT != nil ? .ok : .warn, daemonRT != nil ? "\(Installer.label) 已加载" : "未加载（跑 notihub install）")
        if let prog = daemonRT?.program {
            let inApp = prog.contains(".app/Contents/Resources/bin/")
            add("采集程序", inApp ? .ok : .warn, prog + (inApp ? "" : "  ← 不在 Notihub.app 里（旧装法），重跑 notihub install 切到 App"))
        } else {
            add("采集程序", .warn, "读不到（launchctl print \(Installer.guiDomain)/\(Installer.label) 没给出 program）")
        }
        let inAppNow = daemonRT?.program?.contains(".app/Contents/Resources/bin/") == true
        add("", .info, inAppNow ? "采集器在 Notihub.app 里 —— 移动或删除 Notihub.app 就会停止采集"
                                : "切到 App 后采集器在 Notihub.app 里 —— 届时移动或删除 Notihub.app 就会停止采集", sub: true)

        var rssMB: Int? = nil
        if let pid = daemonRT?.pid {
            let (prc, pout) = run("/bin/ps", ["-o", "rss=", "-p", String(pid)])
            if prc == 0, let kb = Int(pout.trimmingCharacters(in: .whitespacesAndNewlines)) { rssMB = kb / 1024 }
        } else {
            let (_, ps) = run("/bin/ps", ["-axo", "pid,rss,args"])
            if let line = ps.split(separator: "\n").first(where: {
                ($0.contains("/notihub daemon") || $0.contains("/notifhub daemon")) && !$0.contains("grep") }) {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                rssMB = parts.count > 1 ? (Int(parts[1]) ?? 0) / 1024 : 0
            }
        }
        if let rss = rssMB {
            add("常驻进程", .ok, "在跑\(daemonRT?.pid.map { " pid=\($0)" } ?? "")，常驻内存 \(rss) MB")
        } else {
            add("常驻进程", .warn, "没在跑")
        }

        let isolated = ProcessInfo.processInfo.environment["NOTIFHUB_DATA_DIR"] != nil
        let receipt = isolated ? nil : Jobs.readReceipt(Jobs.receiptURL)
        if isolated {
            add("后台任务", .info, "数据目录被 NOTIFHUB_DATA_DIR 隔离，采集器不调度任务")
        } else if let receipt {
            let now = Date()
            let rows = receipt.tasks.map { ($0.name, $0.state, Jobs.status($0.state, now: now)) }
            let bad = rows.filter { Jobs.isBad($0.2) }
            add("后台任务", bad.isEmpty ? .ok : .fail,
                bad.isEmpty ? rows.map { "\($0.0) \($0.2)" }.joined(separator: " · ") + "  ← notihub jobs 看详情"
                            : "\(bad.map(\.0).joined(separator: "、")) 在失败或逾期  ← notihub jobs", fatal: !bad.isEmpty)
            for (name, state, status) in bad {
                add(name, .fail, "\(status) · 连续失败 \(state.consecutiveFailures) 次 · \(state.lastError ?? "到期后没有运行（调度器停了？）")", sub: true)
            }
        } else {
            add("后台任务", daemonRT != nil ? .fail : .warn,
                "读不到回执 \(Jobs.receiptURL.path)（采集器没在跑，或在跑的版本早于 1.5.0）", fatal: daemonRT != nil)
        }

        var dOK = 0, dMissing = 0, dDenied = 0, dOther = 0
        for d in DomainRegistry.all {
            switch Extractor.verdict(d) {
            case .ok: dOK += 1
            case .notFound: dMissing += 1
            case .denied: dDenied += 1
            case .failed: dOther += 1
            }
        }
        add("本机数据", dDenied == 0 && dOther == 0 ? .ok : .warn,
            "\(DomainRegistry.all.count) 域（只读）：可读 \(dOK) · 缺源 \(dMissing) · 无权限 \(dDenied)"
            + (dOther > 0 ? " · 其它 \(dOther)" : "") + "  ← notihub data list 看条数")
        add("", .info, "终端里跑用的是终端的授权，不代表 Notihub.app（数据页要单独给 App 授权）；数据页内容永不上云、不进总结", sub: true)

        guard Instance.personalFeatures else { return out }
        let qState = isolated ? nil : receipt?.tasks.first { $0.name == "queue" }?.state
        let qStatus = qState.map { Jobs.status($0, now: Date()) }
        let qOK = qStatus.map { !Jobs.isBad($0) && $0 != "disabled" } ?? false
        add("接单器在岗", qOK ? .ok : .fail,
            qStatus.map { "queue 任务 \($0)" + (qState?.lastError.map { "：\($0)" } ?? "")
                          + ($0 == "deferred" ? "（由旧作业 \(Installer.queueLabel) 运行）" : "") }
                ?? (isolated ? "数据目录被隔离，采集器不调度任务" : "回执里没有 queue 任务 —— 采集器没在跑或版本早于 1.5.0"),
            fatal: !qOK, sub: true, chain: true)

        if online {
            let (src, _) = notifhub.run("/usr/bin/ssh",
                ["-o", "ConnectTimeout=8", "-o", "BatchMode=yes", Publish.host, "true"])
            add("ssh 到 VPS", src == 0 ? .ok : .fail, src == 0 ? "通" : "不通（rc=\(src)）—— 按钮点了会一直排队没人领",
                fatal: src != 0, sub: true, chain: true, external: true)
            if src == 0 {
                let (crc, cout) = notifhub.run("/usr/bin/ssh",
                    ["-o", "ConnectTimeout=8", "-o", "BatchMode=yes", Publish.host,
                     "curl -s -o /dev/null -w '%{http_code}' --max-time 10 \(AgendaQueue.innerAPI)"])
                let code = cout.trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = crc == 0 && code == "200"
                add("队列 API 回环", ok ? .ok : .fail, ok ? "200" : "返回 \(code.isEmpty ? "空" : code) —— 检查 VPS 上 Next 服务起没起",
                    fatal: !ok, sub: true, chain: true, external: true)
                let (nrc, nout) = notifhub.run("/usr/bin/ssh",
                    ["-o", "ConnectTimeout=8", "-o", "BatchMode=yes", Publish.host,
                     "f=$(readlink -f /etc/nginx/sites-enabled/day.example.invalid 2>/dev/null); "
                     + "[ -n \"$f\" ] && grep -c 'location = /api/agenda-queue' \"$f\" || echo 0"])
                let cnt = Int(nout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                let nok = nrc == 0 && cnt > 0
                add("线上 nginx", nok ? .ok : .fail, "有下单口的 location" + (nok ? "" : " —— 配置没生效（多半装到了 sites-enabled 不指向的文件），按钮会 405。修：bash nginx/deploy.sh"),
                    fatal: !nok, sub: true, chain: true, external: true)
            }
        }

        let hasOsa = FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript")
        add("osascript", hasOsa ? .ok : .fail, "在（push 靠它写提醒事项/日历）", fatal: !hasOsa, sub: true, chain: true)

        if online && hasOsa {
            let (prc, _) = notifhub.run("/usr/bin/osascript",
                                        ["-e", "tell application \"Reminders\" to return name of default list"],
                                        timeout: 15)
            let alive = prc == 0
            add("提醒事项应答", alive ? .ok : .fail, "15s 探针"
                + (alive ? "" : " —— 按钮点了会 90s 超时。两种原因：授权弹窗没人点"
                           + "（手动跑一次 `notihub push <id>` 点允许），"
                           + "或 Reminders.app 卡住了（退出它再打开）"),
                fatal: !alive, sub: true, chain: true, external: true)
        }
        return out
    }

    static let doctorNotCovered = [
        "后台任务只看回执里每条任务的上次结果与是否逾期（notihub jobs），不验证下一轮会不会成功",
        "新通知会不会真被抓到 → notihub selftest --live（发一条真通知再回查库）",
        "LLM 真调得通不通 → notihub summarize <日期>（这里只查了 python/claude 在不在）",
        "remain 面只验扫描器 selfcheck 通不通，不验站上那份新不新",
        "AI 协作只验日志在不在、今天收到多少；Claude/Codex 改了日志格式时这里仍是绿的",
        "写不写得进提醒/日历 → notihub push <id> --dry-run 看路由，真写才知道授权过没",
        "按钮那条链只验「六个环都在」，不验真下过一单 → notihub queue list 看失败原因",
        "本机数据只做文件级分诊，不验库结构与条数 → notihub data list；也不代表 Notihub.app 的授权（App 用 --data-probe 回读）",
        "时区只验「这台机器现在算出来的天对不对」，不验换尺子之前生成的日报总结（notihub summarize <日期> --force 重算）",
        "云端是否在同步、各端看到什么 → notihub cloud status",
    ]

    static func status(args: [String]) -> Int32 {
        let json = args.contains("--json")
        if let bad = args.first(where: { $0 != "--json" }) {
            let msg = "status 不认识的参数：\(bad)（notihub status --help）"
            if json { jsonUsageFail(msg) }
            Log.err(msg); return 64
        }
        let checks = doctorChecks(online: false)
        let fatal = checks.filter(\.fatal).count
        var app: [String: Any] = [:]
        if let bundle = Paths.appBundle {
            app["path"] = bundle.path
            if let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) {
                app["version"] = info["CFBundleShortVersionString"] as? String ?? ""
                app["build"] = info["CFBundleVersion"] as? String ?? ""
                app["cliCommit"] = info["NotihubCLICommit"] as? String ?? ""
            }
        }
        let sources = checks.filter { $0.name.hasPrefix("源 ") }
        let access = !sources.contains { $0.source }
        if json {
            var out: [String: Any] = ["ok": fatal == 0, "version": VERSION, "app": app.isEmpty ? NSNull() : app,
                                      "data": Paths.db.path, "config": Paths.configFile.path,
                                      "fullDiskAccess": access, "fatal": fatal, "checks": checks.map(\.json)]
            if fatal > 0 {
                out["error"] = "\(fatal) 项致命检查未通过：" + checks.filter(\.fatal).map(\.name).joined(separator: "、")
                out["errorCode"] = "fatal_checks"
            }
            printJSON(out)
            return fatal == 0 ? 0 : 1
        }
        print("notihub \(VERSION)" + (app["version"].map { " · Notihub.app \($0) (\(app["build"] ?? ""))" } ?? " · 不在 Notihub.app 里"))
        print("数据 \(Paths.db.path)\n配置 \(Paths.configFile.path)")
        print("完全磁盘访问（采集源可读）：\(access ? "到位" : "缺 —— 见 notihub doctor --offline")")
        for c in checks where !c.sub && !c.chain && c.level != .info {
            print("  " + (c.level == .ok ? "✅" : c.level == .warn ? "⚠️ " : "❌") + " " + pad(c.name, 11) + " " + c.detail)
        }
        print(fatal == 0 ? "本机状态正常（联网与「提醒事项」那几环用 notihub doctor；后台任务用 notihub jobs；云端用 notihub cloud status）。"
                         : "❌ \(fatal) 项没过（notihub doctor --offline 看全部）。")
        return fatal == 0 ? 0 : 1
    }

    @discardableResult
    static func doctor(online: Bool = true, json: Bool = false) -> Int32 {
        let checks = doctorChecks(online: online)
        let fatal = checks.filter(\.fatal).count
        let srcFatal = checks.filter(\.source).count
        if json {
            printJSON(["ok": fatal == 0, "mode": online ? "full" : "offline", "fatal": fatal,
                       "checks": checks.map(\.json),
                       "skipped": online ? [] : ["remain 面", "苹果导出（AppleScript）", "ssh 到 VPS", "队列 API 回环", "线上 nginx", "提醒事项应答"],
                       "notCovered": doctorNotCovered])
            return fatal == 0 ? 0 : 1
        }
        print("notihub doctor\(online ? "" : " --offline（只查本机：不 ssh、不问提醒事项、不跑 remain 扫描器）")")
        print("")
        var chainHeader = false
        for c in checks {
            if c.chain && !chainHeader {
                print("\n  站上「⏰ 存进提醒事项」按钮 → 本机执行：")
                chainHeader = true
            }
            let icon: String
            switch c.level {
            case .ok: icon = "✅"
            case .warn: icon = "⚠️ "
            case .fail: icon = "❌"
            case .info: icon = ""
            }
            if c.sub || c.chain {
                let label = c.name.isEmpty ? "" : "\(c.name) "
                print("     · " + (icon.isEmpty ? "" : icon + " ") + label + c.detail)
            } else {
                print("  " + (icon.isEmpty ? "  " : icon) + " " + pad(c.name, 11) + " " + c.detail)
            }
        }
        if fatal == 0 {
            print(online ? "\n全部就绪。" : "\n本机检查全部就绪（--offline：没查联网与「提醒事项」那几环）。")
        } else {
            print("\n❌ \(fatal) 项没过。")
            if srcFatal > 0 {
                print("   其中 \(srcFatal) 个采集源不可读 —— 多半是没给全磁盘访问：")
                print("   系统设置 → 隐私与安全性 → 完全磁盘访问 → 把 \(Paths.installedBinary.path) 加进去")
                print("   （TCC 认的是实际执行的二进制本体，不是调它的终端，也不是 ~/.local/bin 下的软链）")
                print("   注意：在终端里跑 doctor 用的是终端的授权；daemon 的真实权限以 launchd 下的探针为准")
            }
        }
        print("\n覆盖边界：doctor 只验「读得到 + 在岗 + 依赖找得着」。不覆盖：")
        for line in doctorNotCovered { print("  · " + line) }
        return fatal == 0 ? 0 : 1
    }


    static func doctorSources(json: Bool) -> Int32 {
        var rows: [[String: Any]] = []
        var allOK = true
        for c in Sources.all() {
            let (ok, detail) = c.health()
            if !ok { allOK = false }
            rows.append(["name": c.name, "ok": ok, "detail": detail])
        }
        let bin = Paths.selfExecutable?.path ?? CommandLine.arguments[0]
        if json {
            let obj: [String: Any] = ["ok": allOK, "sources": rows, "binary": bin, "pid": Int(getpid())]
            if let data = try? JSONSerialization.data(withJSONObject: obj,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                print(String(decoding: data, as: UTF8.self))
            }
        } else {
            print("notihub doctor --sources · \(bin) · pid \(getpid())")
            for r in rows {
                print("  \((r["ok"] as? Bool) == true ? "✅" : "❌") \(pad(r["name"] as? String ?? "", 11)) \(r["detail"] as? String ?? "")")
            }
            print(allOK ? "全部可读。" : "有来源读不到 —— 多半是这个二进制还没拿到完全磁盘访问。")
        }
        return allOK ? 0 : 1
    }

    static func daemonRuntime() -> (program: String?, pid: Int?)? {
        let (rc, out) = run("/bin/launchctl", ["print", "\(Installer.guiDomain)/\(Installer.label)"], timeout: 10)
        guard rc == 0 else { return nil }
        var program: String?, pid: Int?
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if program == nil, line.hasPrefix("program = ") { program = String(line.dropFirst("program = ".count)) }
            if pid == nil, line.hasPrefix("pid = ") { pid = Int(line.dropFirst("pid = ".count)) }
        }
        return (program, pid)
    }

    static func statsJSON(_ s: Stats) -> [String: Any] {
        ["ok": true, "days": s.days, "total": s.total, "unreadOpen": s.unreadOpen, "renotified": s.renotified,
         "byApp": s.byApp.map { ["app": $0.0, "count": $0.1] },
         "byHour": s.byHour,
         "byDay": s.byDay.map { ["date": $0.0, "count": $0.1] },
         "actions": s.actions.map { ["action": $0.0, "count": $0.1] }]
    }


    static func printJSON(_ obj: Any) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { print(#"{"ok":false,"error":"内部错误：结果无法序列化为 JSON"}"#); return }
        print(String(decoding: data, as: UTF8.self))
    }


    static func parseStrict(_ args: [String], cmd: String, switches: Set<String>, options: Set<String> = [])
        -> (positional: [String], values: [String: String], error: String?) {
        var pos: [String] = [], vals: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if switches.contains(a) { i += 1; continue }
            if options.contains(a) {
                guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                    return (pos, vals, "\(a) 缺值（notihub \(cmd) --help）")
                }
                vals[a] = args[i + 1]; i += 2; continue
            }
            if a.hasPrefix("-") && a.count > 1 {
                return (pos, vals, "\(cmd) --json 不认识的参数：\(a)（notihub \(cmd) --help）")
            }
            pos.append(a); i += 1
        }
        return (pos, vals, nil)
    }

    static func dayCount(_ s: String) -> Int? {
        guard let n = Int(s), (1...36_500).contains(n) else { return nil }
        return n
    }

    static func jsonUsageFail(_ message: String) -> Never {
        printJSON(["ok": false, "error": message, "usageError": true]); Log.err("✗ \(message)"); exit(64)
    }

    static func jsonFail(_ message: String) -> Never {
        printJSON(["ok": false, "error": message]); Log.err("✗ \(message)"); exit(1)
    }

    static func pad(_ s: String, _ n: Int) -> String {
        var w = 0
        for ch in s.unicodeScalars { w += ch.value > 0x2000 ? 2 : 1 }
        return s + String(repeating: " ", count: max(1, n - w))
    }

    static func intArg(_ args: [String], _ flag: String) -> Int? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    static func strArg(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count,
              !args[i + 1].hasPrefix("-") else { return nil }
        return args[i + 1]
    }
}
