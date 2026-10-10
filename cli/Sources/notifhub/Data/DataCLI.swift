import Foundation

enum DataCLI {

    static func run(_ args: [String]) -> Int32 {
        let sub = args.first ?? "list"
        let rest = Array(args.dropFirst())
        switch sub {
        case "list": return list(json: rest.contains("--json"))
        case "export": return export(rest)
        case "people": return People.command(rest)
        case "selfcheck": return selfCheck(json: rest.contains("--json"))
        case "help", "-h", "--help": print(usage); return 0
        default:
            guard let d = DomainRegistry.domain(sub) else {
                Log.err("没有这个域:\(sub)\n\(usage)")
                return 64
            }
            if d.id == "messages" && rest.contains("--self-check") { return selfCheck(json: rest.contains("--json")) }
            return show(d, rest)
        }
    }

    static var usage: String {
        """
        notihub data list [--json]                     15 个域的状态与条数(含通讯录统计)
        notihub data <域> [--limit N] [--json|--csv] [--raw]
                                                       号码/邮箱默认打码,--raw 显示原文
        notihub data reminders [--date YYYY-MM-DD] [--limit N] [--json|--csv]
                                                       含完成时间；按天取当天到期未完成 + 当天完成（系统时区）
        notihub data export <域…|--all> --out <目录> [--csv|--json] [--mask] [--limit N]
        notihub data people who <词> | timeline <词> [--since D --until D --limit N --full] | stats
        notihub data selfcheck [--json]                信息正文解码对照(只报计数)
        域:\(DomainRegistry.all.map(\.id).joined(separator: " "))
        """
    }


    static func status(_ r: DomainResult) -> String {
        if r.isUsable { return "ok" }
        if r.failure != nil { return "broken" }
        switch r.verdict {
        case .notFound: return "missing"
        case .denied: return "denied"
        default: return "broken"
        }
    }
    static let statusName = ["ok": "可读", "missing": "缺源", "denied": "无权限", "broken": "损坏"]

    static func diagnose(_ d: DataDomain, _ r: DomainResult) -> String {
        let src = d.sources.map(\.display).joined(separator: " , ")
        switch (r.exitCode, r.verdict) {
        case (2, _):
            return "\(d.name):读不到,且侧信道探针(~/Library/Safari/History.db)也读不到 = 缺完全磁盘访问权限。\n"
                + "  系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 加入运行本命令的终端。\n"
                + "  (终端里跑用的是终端的授权;Notihub.app 的数据页要单独给 Notihub 授权)"
        case (_, .notFound):
            return "\(d.name):文件不存在 —— macOS 换了布局,或从没用过这个 App。探针可读,权限侧正常。\n  路径:\(src)"
        case (_, .denied):
            return "\(d.name):探针可读、只有本源读不动 = 该文件/目录的 mode 被改坏,与系统设置无关。\n  路径:\(src)"
        default:
            return "\(d.name):\(r.statusLabel)\n  路径:\(src)"
        }
    }


    static func list(json: Bool) -> Int32 {
        let results = DomainRegistry.all.map { Extractor.count($0) }
        var tally = ["ok": 0, "missing": 0, "denied": 0, "broken": 0]
        for r in results { tally[status(r), default: 0] += 1 }
        let book = contactStats()
        let redirected = ProcessInfo.processInfo.environment["NOTIHUB_DATA_HOME"].map { !$0.isEmpty } ?? false

        if json {
            let domains: [[String: Any]] = zip(DomainRegistry.all, results).map { d, r in
                var o: [String: Any] = ["id": d.id, "name": d.name, "status": status(r),
                                        "label": r.isUsable ? "可读" : r.statusLabel, "sources": r.resolvedCount]
                o["count"] = r.total ?? NSNull()
                if let n = r.note { o["note"] = n }
                return o
            }
            var obj: [String: Any] = ["ok": true, "domains": domains, "summary": tally, "fda_probe": ROSqlite.fdaGranted(),
                                      "home": redirected ? "NOTIHUB_DATA_HOME" : "~",
                                      "boundary": "终端授权不代表 Notihub.app;内容永不上云、不进总结"]
            obj["contacts"] = book.map { $0.json } ?? NSNull()
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return 0
        }
        print("notihub data list · 数据根 \(redirected ? "NOTIHUB_DATA_HOME(夹具)" : "~") · 只读快照,原库只被 read()\n")
        let icon = ["ok": "✅", "missing": "·", "denied": "⛔", "broken": "❌"]
        for (d, r) in zip(DomainRegistry.all, results) {
            let s = status(r)
            let right = s == "ok" ? "\(r.total ?? 0) 条" + (r.note.map { " · \($0)" } ?? "") : r.statusLabel
            print("  \(icon[s]!) " + CLI.pad(d.id, 17) + CLI.pad(d.name, 14) + right)
        }
        print("\n合计:可读 \(tally["ok"]!) · 缺源 \(tally["missing"]!) · 无权限 \(tally["denied"]!) · 损坏 \(tally["broken"]!)")
        if let b = book { print("通讯录:\(b.line)") }
        print("(终端里跑用的是终端的授权,不代表 Notihub.app;内容永不上云、不进总结)")
        return 0
    }


    struct ContactStats {
        var records = 0, sources = 0, people = 0, withPhone = 0, withEmail = 0
        static let basis = "AddressBook 各来源 SQLite 合并,按「姓名|公司」去重;有电话/邮箱 = 去重组内任一条有"
        var line: String {
            "\(records) 条记录(\(sources) 个来源)· 去重后 \(people) 人 · 有电话 \(withPhone) · 有邮箱 \(withEmail)\n  口径:\(ContactStats.basis)"
        }
        var json: [String: Any] {
            ["records": records, "sources": sources, "people": people,
             "with_phone": withPhone, "with_email": withEmail, "basis": ContactStats.basis]
        }
    }

    static func contactStats() -> ContactStats? {
        guard case .sqlite(let sql) = DomainRegistry.contacts.extraction else { return nil }
        let srcs = DomainRegistry.contacts.sources.flatMap { $0.resolve() }
        guard let first = srcs.first, ROSqlite.triage(first).isOK,
              let t = try? ROSqlite.query(sources: srcs, sql: sql.replacingOccurrences(of: "{LIMIT}", with: "-1"))
        else { return nil }
        var groups: [String: (phone: Bool, email: Bool)] = [:]
        for r in t.rows where r.count >= 5 {
            let k = r[0] + "|" + r[1]
            let g = groups[k] ?? (false, false)
            groups[k] = (g.phone || !r[3].isEmpty, g.email || !r[4].isEmpty)
        }
        return ContactStats(records: t.rows.count, sources: srcs.count, people: groups.count,
                            withPhone: groups.values.filter(\.phone).count,
                            withEmail: groups.values.filter(\.email).count)
    }


    static func show(_ domain: DataDomain, _ args: [String]) -> Int32 {
        var d = domain
        var reminderLimit: Int?
        if d.id == "reminders" {
            let p = CLI.parseStrict(args, cmd: "data reminders", switches: ["--json", "--csv", "--raw"], options: ["--limit", "--date"])
            var error = p.error
            if !p.positional.isEmpty { error = "data reminders 不带位置参数" }
            if args.contains("--json") && args.contains("--csv") { error = "--json 与 --csv 不能同时使用" }
            if let n = p.values["--limit"], Int(n).map({ $0 > 0 }) != true { error = "--limit 要正整数" }
            if let date = p.values["--date"] {
                if let filtered = LocalReminders.dayDomain(date) { d = filtered }
                else { error = "日期无效：\(date)（要真实存在的 YYYY-MM-DD）" }
            }
            if let error {
                if args.contains("--json") { CLI.printJSON(["ok": false, "error": error, "usageError": true]) }
                Log.err(error); return 64
            }
            reminderLimit = p.values["--limit"].flatMap(Int.init) ?? (p.values["--date"] != nil ? Int.max : 20)
        }
        let limit = reminderLimit ?? max(1, CLI.intArg(args, "--limit") ?? 20)
        let raw = args.contains("--raw")
        let r = Extractor.run(d, limit: limit)
        guard r.isUsable else {
            let reason = diagnose(d, r)
            if d.id == "reminders" && args.contains("--json") { CLI.printJSON(["ok": false, "error": reason, "errorCode": "reminders_unreadable"]) }
            Log.err(reason); return r.exitCode
        }
        if let n = r.note { Log.err("[note] \(n)") }
        let rows = raw ? r.rows : Masker.applyAddr(r.rows, columns: d.sensitiveColumns)

        if args.contains("--json") {
            print(Exporter.json(columns: r.columns, rows: rows))
        } else if args.contains("--csv") {
            print(Exporter.csv(columns: r.columns, rows: rows), terminator: "")
        } else {
            guard !rows.isEmpty else { print("(\(d.name):库可读,0 条 —— 数据源为空,不是失败)"); return 0 }
            print(r.columns.joined(separator: "\t"))
            for row in rows {
                print(row.map { cell in
                    let one = cell.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                    return one.count > 80 ? String(one.prefix(80)) + "…" : one
                }.joined(separator: "\t"))
            }
        }
        let masked = !raw && !d.sensitiveColumns.isEmpty
        Log.err("(\(d.name) \(rows.count) 条\(r.truncated ? ",已到上限 \(limit),--limit 调大" : "")"
                + (masked ? ";号码/邮箱已打码,--raw 显示原文" : "") + ")")
        return 0
    }


    static func export(_ args: [String]) -> Int32 {
        var ids: [String] = [], out: String?, format = ExportFormat.csv, masked = false, all = false
        var limit = 100_000
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--all": all = true
            case "--out": out = i + 1 < args.count ? args[i + 1] : nil; i += 1
            case "--json": format = .json
            case "--csv": format = .csv
            case "--mask": masked = true
            case "--limit": limit = max(1, Int(i + 1 < args.count ? args[i + 1] : "") ?? limit); i += 1
            case let a where a.hasPrefix("-"): Log.err("未知参数 \(a)\n\(usage)"); return 64
            case let a: ids.append(a)
            }
            i += 1
        }
        guard let outDir = out else { Log.err("缺 --out <目录>\n\(usage)"); return 64 }
        let unknown = ids.filter { DomainRegistry.domain($0) == nil }
        guard unknown.isEmpty else { Log.err("没有这些域:\(unknown.joined(separator: " "))"); return 64 }
        let domains = all ? DomainRegistry.all : ids.compactMap(DomainRegistry.domain)
        guard !domains.isEmpty else { Log.err("要导出哪些域?给域名或 --all"); return 64 }

        var results: [String: DomainResult] = [:]
        for d in domains { results[d.id] = Extractor.run(d, limit: limit) }
        let root = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let o = try Exporter.export(domains: domains, results: results, format: format, masked: masked, to: root)
            print("已导出到 \(o.directory)")
            for f in o.files { print("  ✅ \(f.name)  \(f.rows) 条") }
            for s in o.skipped { print("  ·  \(s.domain):\(s.reason)") }
            print("  说明:\(o.directory)/导出说明.md")
        } catch {
            Log.err("导出失败:\(error.localizedDescription)"); return 1
        }
        let codes = results.values.map(\.exitCode)
        if codes.contains(1) { return 1 }
        return codes.contains(2) ? 2 : 0
    }


    static func selfCheck(json: Bool) -> Int32 {
        let d = DomainRegistry.messages
        var probe = DomainResult(domainID: d.id)
        let srcs = d.sources.flatMap { $0.resolve() }
        probe.resolvedCount = srcs.count
        probe.verdict = srcs.first.map(ROSqlite.triage) ?? (ROSqlite.fdaDenied() ? .denied : .notFound)
        guard probe.isUsable else { Log.err(diagnose(d, probe)); return probe.exitCode }
        do {
            let c = try IMessageBody.selfCheck(sources: srcs)
            if json {
                let o: [String: Any] = ["compared": c.compared, "matched": c.matched, "invisible_only": c.invisibleOnly,
                                        "mismatched": c.mismatched, "recovered": c.recovered,
                                        "with_body": c.withBody, "pass": c.passed]
                if let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
            } else {
                print("信息正文解码对照:对照 \(c.compared) 条(text 与 attributedBody 双有)· 逐字一致 \(c.matched) 条 · "
                      + "仅差不可见字符 \(c.invisibleOnly) 条(U+FFFD/U+200E/U+200F)· 其它不一致 \(c.mismatched) 条 · "
                      + "补回 \(c.recovered) 条(text 为空、只在 attributedBody 里)· 有正文共 \(c.withBody) 条 · "
                      + (c.passed ? "PASS" : "FAIL"))
            }
            if c.compared == 0 { Log.err("[fail] 对照样本为 0 条,无法自检") }
            return c.passed ? 0 : 1
        } catch {
            Log.err("[fail] \(error.localizedDescription)"); return 1
        }
    }
}
