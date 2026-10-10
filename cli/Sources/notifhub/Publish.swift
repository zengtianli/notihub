import Foundation

enum Publish {

    static var host: String { Instance.current?.uploadHost ?? ProcessInfo.processInfo.environment["NOTIHUB_UPLOAD_HOST"] ?? "" }
    static var remoteDir: String { ProcessInfo.processInfo.environment["NOTIHUB_REMOTE_DIR"] ?? "." }
    static var siteURL: String { Instance.current?.siteURL ?? ProcessInfo.processInfo.environment["NOTIHUB_SITE_URL"] ?? "https://day.example.invalid" }

    static let maxLLMPerRun = 3

    struct Card {
        var date: String
        var total: Int
        var merged: Int
        var whos: [String]
        var headline: String
        var agendaOpen: Int
        var aiMinutes: Int?
    }

    static func wantsUpload(_ args: [String]) -> Bool {
        args.contains("--upload") && !args.contains("--no-upload") && !args.contains("--json-only")
    }

    static func run(args: [String]) {
        guard let store = Store() else { exit(1) }
        let config = Config.load()
        if Instance.personalFeatures {
            let t0 = nowUnix()
            let got = AIWork.collect(store: store, config: config)
            let secs = Int(nowUnix() - t0)
            if got.skipped {
                Log.write("publish: AI 收取跳过（另一个任务正在收）")
            } else if got.prompts + got.minutes > 0 || secs >= 5 {
                Log.write("publish: AI 输入 +\(got.prompts) 条 · 活跃分钟 +\(got.minutes) · 读 \(got.files) 个文件 \(got.bytes / 1024)KB · \(secs)s")
            }
        }
        let days = CLI.intArg(args, "--days") ?? 30
        let includeAll = args.contains("--all")
        let jsonOnly = args.contains("--json-only")
        let upload = wantsUpload(args)
        if upload && host.isEmpty { Log.err("Configure NOTIHUB_UPLOAD_HOST before --upload"); exit(2) }

        let outDir = CLI.strArg(args, "--out").map { URL(fileURLWithPath: $0.expandingTilde) }
            ?? Paths.dataDir.appendingPathComponent("site")
        let fm = FileManager.default
        try? fm.removeItem(at: outDir)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        var dates: [String] = []
        store.db.query("""
            SELECT \(Clock.sqlDay("ts")) d, COUNT(*)
              FROM events GROUP BY d ORDER BY d DESC LIMIT ?
            """, [days]) { dates.append($0.str(0)) }

        guard !dates.isEmpty else {
            Log.err("库里还没有任何事件，没什么可发的")
            exit(1)
        }

        let wantLLM = Instance.personalFeatures && !args.contains("--no-llm") && config.summary.enabled
        var llmCalls = 0
        if wantLLM {
            for d in dates {
                guard llmCalls < maxLLMPerRun else {
                    print("⚠ 本轮 LLM 调用已达上限 \(maxLLMPerRun) 次，剩下的天下次再补（或手动 notihub summarize <日期>）")
                    break
                }
                do {
                    let o = try Summarizer.ensure(date: d, store: store, config: config, quiet: true)
                    if !o.skipped { llmCalls += 1; Log.write("publish: 已总结 \(d)（抽出 \(o.added) 条时间节点）") }
                } catch {
                    Log.err("总结 \(d) 失败（继续发布，只是这天没有总结块）: \(error)")
                    Log.write("publish: 总结 \(d) 失败 \(error)")
                }
            }
        }

        var cards: [Card] = []
        var loaded: [Recap.Day] = []
        for d in dates {
            let day = Recap.load(store: store, date: d, includeAll: includeAll, config: config)
            if !jsonOnly {
                let html = Recap.renderHTML(day, config: config, backLink: "index.html")
                try? html.write(to: outDir.appendingPathComponent("\(d).html"), atomically: true, encoding: .utf8)
            }
            loaded.append(day)
            cards.append(Card(date: d, total: day.total, merged: day.items.count,
                              whos: day.whos.prefix(4).map(\.0),
                              headline: day.summary?.headline ?? "",
                              agendaOpen: day.agenda.filter { $0.status == "open" }.count,
                              aiMinutes: day.work?.wallMinutes))
        }

        if !jsonOnly { try? renderIndex(cards).write(to: outDir.appendingPathComponent("index.html"),
                                      atomically: true, encoding: .utf8) }

        do {
            try JSONFeed.emit(store: store, dates: dates, days: loaded,
                              index: cards.map { JSONFeed.IndexDay(
                                  date: $0.date, total: $0.total, merged: $0.merged,
                                  headline: $0.headline, agendaOpen: $0.agendaOpen, whos: $0.whos,
                                  aiMinutes: $0.aiMinutes) },
                              outDir: outDir)
        } catch {
            Log.err("JSON feed 生成失败：\(error)")
            exit(1)
        }
        print("已生成 \(dates.count) 天 → \(outDir.path)")

        if jsonOnly {
        } else if !Instance.personalFeatures {
            print("独立实例：不发布个人 handoff/未完成清单，不连接共用队列。")
        } else if Remain.emit(outDir: outDir, config: config) {
            print("已生成 remain 面（全树未完成 handoffs + 最近会话）")
        } else {
            print("⚠ remain 面生成失败，已放占位错误页（详见 notifhub.log）")
        }

        guard upload else {
            if !jsonOnly && !args.contains("--no-upload") {
                print("未上传（只在本机生成）。要 rsync 到 \(host):\(remoteDir) 请显式加 --upload。")
            }
            return
        }

        let allowShrink = args.contains("--shrink")
        if !allowShrink {
            let listing: (Int32, String)
            if Instance.current != nil {
                listing = notifhub.run("/usr/bin/rsync", ["--list-only", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=10", "\(host):./"], stderrToo: true, timeout: 30)
            } else {
                listing = notifhub.run("/usr/bin/ssh",
                ["-o", "ConnectTimeout=10", "-o", "BatchMode=yes", host,
                 "ls \(remoteDir)/20[0-9][0-9]-[0-9][0-9]-[0-9][0-9].json 2>/dev/null | wc -l"])
            }
            let (lrc, lout) = listing
            if lrc != 0 { Log.err("发布前远端检查失败：\(lout)"); exit(1) }
            let remote = Instance.current == nil ? (Int(lout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1)
                : lout.split(separator: "\n").filter { $0.range(of: #"\b\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil }.count
            if remote < 0 { Log.err("发布前远端计数无法解析，拒绝上传"); exit(1) }
            if remote > 0, dates.count < remote {
                Log.err("""
                ⛔ 拒绝发布：本轮只有 \(dates.count) 天，而站上已有 \(remote) 天。
                   rsync --delete 会把站上多出来的 \(remote - dates.count) 天删掉。
                   要么去掉 --days（默认 30 天），要么确实想删就加 --shrink。
                """)
                exit(1)
            }
        }

        let (rc, out) = notifhub.run("/usr/bin/rsync",
            ["-az", "--delete", "-e", "ssh -o ConnectTimeout=15",
             outDir.path + "/", "\(host):\(remoteDir)/"], stderrToo: true, timeout: 180)
        if rc == 0 {
            print("✅ 已发布 \(siteURL)")
            Log.write("publish: \(dates.count) 天已上传")
        } else {
            Log.err("rsync 失败 (rc=\(rc)): \(out)")
            Log.write("publish 失败 rc=\(rc)")
            exit(1)
        }
    }

    static func renderIndex(_ cards: [Card]) -> String {
        let items = cards.map { c in
            let line = c.headline.isEmpty
                ? "<div class=\"w\">\(c.whos.map { CLI.esc($0.truncated(10)) }.joined(separator: " · "))</div>"
                : "<div class=\"w hl\">\(CLI.esc(c.headline))</div>"
            let badge = c.agendaOpen > 0 ? "<span class=\"badge\">\(c.agendaOpen) 个时间节点</span>" : ""
            return """
            <a class="card" href="\(c.date).html">
              <div class="d">\(c.date)</div>
              <div class="n">\(c.total) 条 · \(c.merged) 件事\(badge)</div>
              \(line)
            </a>
            """
        }.joined()

        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="robots" content="noindex,nofollow">
        <title>通知复盘</title>
        <style>
        :root{--bg:#fdfcfa;--fg:#1f2328;--muted:#6b7280;--line:#e5e1da;--accent:#9a3412}
        *{box-sizing:border-box}
        body{margin:0;background:var(--bg);color:var(--fg);
             font:15px/1.6 -apple-system,"PingFang SC","Helvetica Neue",sans-serif;padding:32px 18px}
        .wrap{max-width:860px;margin:0 auto}
        h1{font-size:25px;margin:0 0 4px}
        .sub{color:var(--muted);font-size:13px;margin-bottom:24px}
        .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px}
        .card{display:block;border:1px solid var(--line);border-radius:10px;padding:14px 16px;
              background:#fff;text-decoration:none;color:inherit;transition:.15s}
        .card:hover{border-color:var(--accent);transform:translateY(-1px)}
        .d{font-size:17px;font-weight:600;letter-spacing:-.3px}
        .n{color:var(--accent);font-size:12px;margin:3px 0 6px}
        .w{color:var(--muted);font-size:12px;line-height:1.4;min-height:2.8em}
        .w.hl{color:#33383d;font-size:13px}
        .badge{display:inline-block;background:#f2ece4;color:#7c4a24;border-radius:4px;
               padding:0 5px;font-size:11px;margin-left:6px}
        footer{margin-top:36px;color:var(--muted);font-size:12px;border-top:1px solid var(--line);padding-top:12px}
        </style></head><body><div class="wrap">
        <h1>通知复盘</h1>
        <div class="sub">这台 Mac 上收到的每一条通知（微信 / 短信 / 钉钉 / 邮件 / iPhone 转发），
        按天成册 · 共 \(cards.count) 天 · 更新于 \(fmtTime(nowUnix())) ·
        \(Instance.personalFeatures ? "<a href=\"remain.html\">📌 未完成清单</a>" : "")</div>
        <div class="grid">\(items)</div>
        <footer>notifhub · 私有站，密码闸内。本机生成后 rsync，通知库本身不出本机。</footer>
        </div></body></html>
        """
    }
}
