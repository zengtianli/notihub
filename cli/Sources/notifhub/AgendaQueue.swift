import Foundation

enum AgendaQueue {
    static let innerAPI = ProcessInfo.processInfo.environment["NOTIHUB_QUEUE_URL"] ?? "http://127.0.0.1:3000/api/admin/agenda-queue"
    static let maxAttempts = 3
    static let staleRunningMinutes = 20.0
    static let transportTimeout: TimeInterval = 40

    static func transportArguments(_ args: [String], host: String) -> [String] {
        let command = (["curl", "--fail", "--silent", "--show-error", "--max-time", "20"] + args)
            .map { shellQuote($0) }.joined(separator: " ")
        return ["-T", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
                "-o", "ControlMaster=no", "-o", "ControlPath=none", host, command]
    }
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    struct Job: Codable {
        let id: String
        let agendaId: Int64
        var kind: String
        var text: String?          // kind=note 的正文
        var to: String?            // kind=status 要标成什么
        var title: String
        var target: String        // auto | reminders | calendar
        var force: Bool
        var noAlarm: Bool
        var status: String        // pending | running | done | failed
        var requestedAt: String
        var updatedAt: String
        var attempts: Int
        var detail: String?

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            agendaId = try c.decode(Int64.self, forKey: .agendaId)
            kind = (try? c.decode(String.self, forKey: .kind)) ?? "push"
            text = try? c.decode(String.self, forKey: .text)
            to = try? c.decode(String.self, forKey: .to)
            title = (try? c.decode(String.self, forKey: .title)) ?? "agenda#\(agendaId)"
            target = (try? c.decode(String.self, forKey: .target)) ?? "auto"
            force = (try? c.decode(Bool.self, forKey: .force)) ?? false
            noAlarm = (try? c.decode(Bool.self, forKey: .noAlarm)) ?? false
            status = (try? c.decode(String.self, forKey: .status)) ?? "pending"
            requestedAt = (try? c.decode(String.self, forKey: .requestedAt)) ?? ""
            updatedAt = (try? c.decode(String.self, forKey: .updatedAt)) ?? ""
            attempts = (try? c.decode(Int.self, forKey: .attempts)) ?? 0
            detail = try? c.decode(String.self, forKey: .detail)
        }
    }

    struct QueueResponse: Codable { let items: [Job] }

    private static func vpsCurl(_ args: [String]) -> String? {
        guard !Publish.host.isEmpty else { Log.err("Configure NOTIHUB_UPLOAD_HOST to use the queue"); return nil }
        let (rc, out) = notifhub.run("/usr/bin/ssh",
                                     transportArguments(args, host: Publish.host),
                                     timeout: transportTimeout)
        guard rc == 0 else {
            Log.write("queue: ssh/curl 失败 rc=\(rc): \(out.prefix(200))"); Log.err("queue: ssh/curl 失败 rc=\(rc)")
            return nil
        }
        return out
    }

    @discardableResult
    private static func patch(_ id: String, status: String, attempts: Int, detail: String?) -> Bool {
        var body: [String: Any] = ["id": id, "status": status, "attempts": attempts]
        if let d = detail { body["detail"] = String(d.prefix(500)) }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else { return false }
        return vpsCurl(["-X", "PATCH", "-H", "Content-Type: application/json",
                        "-d", json, innerAPI]) != nil
    }

    static func minutesSince(_ iso: String) -> Double {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let d else { return .infinity }   // 时间戳读不出来 = 当它很旧，允许接管
        return Date().timeIntervalSince(d) / 60
    }

    static func claimable(_ items: [Job]) -> [Job] {
        items.filter { j in
            if j.status == "pending" { return j.attempts < maxAttempts }
            if j.status == "running" {
                return minutesSince(j.updatedAt) > staleRunningMinutes && j.attempts < maxAttempts
            }
            return false
        }
    }

    static func reallyAdded(_ out: String) -> Bool { out.contains("✓") }

    static func succeeded(kind: String, output: String) -> Bool {
        switch kind {
        case "note":   return output.contains("已记到")
        case "status": return output.contains("→ 完成") || output.contains("→ 丢弃")
        default:       return reallyAdded(output)
        }
    }

    static func argv(for job: Job) -> [String]? {
        switch job.kind {
        case "note":
            guard let t = job.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return ["note", t]
        case "status":
            let verb = (job.to == "dropped") ? "drop" : "done"
            return [verb, String(job.agendaId)]
        default:
            var a = ["push", String(job.agendaId)]
            if job.target != "auto" { a += ["--to", job.target] }
            if job.force { a.append("--force") }
            if job.noAlarm { a.append("--no-alarm") }
            return a
        }
    }

    static func hungHint(_ agendaId: Int64) -> String {
        let (rc, _) = notifhub.run("/usr/bin/osascript",
                                   ["-e", "tell application \"Reminders\" to return name of default list"],
                                   timeout: 15)
        if rc == 0 {
            return "push 挂住被强杀 —— 「提醒事项」应答正常，那多半是二进制重签后首次自动化"
                 + "授权的弹窗没人点：在 Mac 上手动跑一次 `notihub push \(agendaId)`，弹窗点允许"
        }
        return "push 挂住被强杀 —— 「提醒事项」App 没在应答（探针也超时，rc=\(rc)）："
             + "到 Mac 上退出 Reminders 再打开，然后在站上重点一次"
    }

    static func fetch() -> [Job]? {
        guard let raw = vpsCurl([innerAPI]),
              let data = raw.data(using: .utf8),
              let resp = try? JSONDecoder().decode(QueueResponse.self, from: data) else { return nil }
        return resp.items
    }

    @discardableResult
    static func poll(dryRun: Bool = false) -> Int {
        guard Instance.personalFeatures else { return 0 }
        guard let items = fetch() else {
            Log.write("queue: 拿不到队列，本轮跳过（不改任何单的状态）")
            return 0
        }
        let resp = QueueResponse(items: items)

        let claimable = claimable(resp.items)
        guard !claimable.isEmpty else { return 0 }

        var done = 0
        var touchedSite = false
        for job in claimable {
            let n = job.attempts + 1
            if dryRun {
                Log.write("queue[dry-run]: 会领 \(job.id) → \(job.kind) \(job.agendaId)「\(job.title)」")
                done += 1
                continue
            }
            guard patch(job.id, status: "running", attempts: n, detail: nil) else {
                Log.write("queue: 领取状态未获确认，本轮停止，不执行本机写入")
                break
            }

            guard let argv = argv(for: job) else {
                patch(job.id, status: "failed", attempts: n,
                      detail: "这单缺必要字段(kind=\(job.kind))，跑不了")
                Log.write("queue: \(job.id) 缺字段，判失败")
                continue
            }
            let (rc, out) = notifhub.run(Paths.installedBinary.path, argv, timeout: 90)
            let tail = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if rc == 0 && !succeeded(kind: job.kind, output: tail) {
                patch(job.id, status: "failed", attempts: n,
                      detail: "push 跑完了但一条都没写进去 —— 常见两种：这条已推过而单子没带 force，"
                              + "或者这个 id 库里没有。push 自己的输出："
                              + String(tail.prefix(200)))
                Log.write("queue: \(job.id) rc=0 却没有写入标记，判失败：\(tail.prefix(200))")
                continue
            }
            if rc == 0 {
                patch(job.id, status: "done", attempts: n, detail: tail)
                Log.write("queue: 已跑 \(job.id) \(job.kind) → agenda \(job.agendaId)「\(job.title)」")
                done += 1
                if job.kind == "note" || job.kind == "status" { touchedSite = true }
            } else {
                let hint = rc == -9 ? hungHint(job.agendaId) : tail
                patch(job.id, status: "failed", attempts: n, detail: "rc=\(rc) \(hint)")
                Log.write("queue: 推失败 \(job.id) → agenda \(job.agendaId) rc=\(rc): \(tail.prefix(200))"); Log.err("queue: push \(job.agendaId) 失败 rc=\(rc)")
            }
        }

        if touchedSite && !dryRun {
            let (prc, pout) = notifhub.run(Paths.installedBinary.path, resyncArguments(), stderrToo: true, timeout: 300)
            if prc == 0 {
                Log.write("queue: 内容有变，已跑一轮云同步")
            } else {
                Log.write("queue: 触发云同步失败 rc=\(prc)（单子本身是成功的，不改它的状态）：\(pout.prefix(200))")
                Log.err("queue: 触发云同步失败 rc=\(prc) —— 各端要等下一轮 5 分钟同步才看得到")
            }
        }
        return done
    }

    static func resyncArguments() -> [String] { ["sync"] }

    enum Mode: Equatable { case run(dryRun: Bool), list(json: Bool), invalid(String) }

    static func mode(_ args: [String]) -> Mode {
        let words = args.filter { !$0.hasPrefix("-") }
        let flags = args.filter { $0.hasPrefix("-") }
        switch words {
        case [], ["run"]:
            if let bad = flags.first(where: { !["--dry-run", "--once"].contains($0) }) {
                return .invalid("queue 不认识的参数：\(bad)（notihub queue --help）")
            }
            return .run(dryRun: flags.contains("--dry-run"))
        case ["list"]:
            if let bad = flags.first(where: { $0 != "--json" }) { return .invalid("queue list 不认识的参数：\(bad)") }
            return .list(json: flags.contains("--json"))
        default:
            return .invalid("用法: notihub queue [run] [--dry-run] | notihub queue list [--json]")
        }
    }

    static func cmd(_ args: [String]) -> Int32 {
        guard Instance.personalFeatures else { Log.err("独立实例未连接个人共用队列"); return 2 }
        switch mode(args) {
        case .invalid(let why):
            Log.err(why); return 64
        case .list(let json):
            return list(json: json)
        case .run(let dry):
            let n = poll(dryRun: dry)
            if n == 0 {
                print("队列里没有可领的单（或前置不满足，详见 \(Paths.log.path)）")
            } else {
                print("处理 \(n) 单\(dry ? "（dry-run，没真推）" : "")")
            }
            return 0
        }
    }

    static func list(json: Bool) -> Int32 {
        guard let items = fetch() else {
            let msg = "拿不到队列（ssh 到 VPS 或 VPS 上的队列服务不通，详见 \(Paths.log.path)）"
            if json { CLI.printJSON(["ok": false, "error": msg]) }
            Log.err("✗ \(msg)"); return 1
        }
        var counts: [String: Int] = [:]
        for j in items { counts[j.status, default: 0] += 1 }
        if json {
            let enc = JSONEncoder()
            let rows: [Any] = items.compactMap { j in
                (try? enc.encode(j)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            }
            CLI.printJSON(["ok": true, "counts": counts, "claimable": claimable(items).count, "items": rows])
            return 0
        }
        print("队列 \(items.count) 单：" + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
              + " · 现在可领 \(claimable(items).count)")
        for j in items.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let what = j.kind == "push" ? "push→\(j.target)" : j.kind
            print("  \(CLI.pad(j.status, 8))\(CLI.pad(what, 18))#\(CLI.pad(String(j.agendaId), 6))\(j.title.truncated(40))"
                  + (j.status == "failed" ? "\n      ↳ \((j.detail ?? "").truncated(120))" : ""))
        }
        return 0
    }
}
