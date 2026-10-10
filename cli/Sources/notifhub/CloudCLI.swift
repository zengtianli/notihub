import Foundation

final class AsyncBox<T>: @unchecked Sendable { var value: Result<T, Error>? }
func blockingAwait<T>(_ op: @escaping () async throws -> T) -> Result<T, Error> {
    let box = AsyncBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.value = .success(try await op()) } catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return box.value ?? .failure(CloudFailure("内部错误：异步结果丢失", kind: .network))
}

enum CloudCLI {

    struct Plan {
        var sub: String
        var path = ""
        var limit: Int?
        var markID: Int64?
        var markStatus: String?
        var note: CloudNoteInput?
        var keyGenerated = false
        var withReminders = false
        var isWrite: Bool { sub == "mark" || sub == "note" }
        var described: [String: Any] {
            var d: [String: Any] = ["method": isWrite ? (sub == "mark" ? "PATCH" : "POST") : "GET",
                                    "path": "/native/api/" + path]
            if let s = markStatus { d["body"] = ["status": s] }
            if let n = note { d["body"] = ["text": n.text, "date": n.date, "idempotencyKey": n.idempotencyKey] }
            return d
        }
    }

    struct Outcome {
        var code: Int32 = 0
        var json: [String: Any] = ["ok": true]
        var text: [String] = []
    }

    static let subcommands = ["status", "days", "day", "open", "mark", "note"]


    static func parse(_ args: [String]) -> Result<Plan, CloudFailure> {
        let valueFlags: Set<String> = ["--limit", "--date", "--key"]
        var words: [String] = []
        var skip = false
        for a in args {
            if skip { skip = false; continue }
            if valueFlags.contains(a) { skip = true; continue }
            if a.hasPrefix("--") { continue }
            words.append(a)
        }
        guard let sub = words.first, subcommands.contains(sub) else {
            return .failure(.invalid("用法: notihub cloud status|days|day <日期>|open|mark <id> <状态>|note \"<正文>\"（notihub cloud --help）"))
        }
        let pos = Array(words.dropFirst())
        let known: Set<String> = valueFlags.union(["--json", "--dry-run"])
        if let bad = args.first(where: { $0.hasPrefix("--") && !known.contains($0) }) {
            return .failure(.invalid("cloud 不认识的参数：\(bad)"))
        }
        var plan = Plan(sub: sub)
        plan.withReminders = sub == "open" && args.contains("--json")
        switch sub {
        case "status", "open":
            guard pos.isEmpty else { return .failure(.invalid("cloud \(sub) 不带位置参数")) }
            plan.path = sub == "open" ? "open" : "index"
        case "days":
            guard pos.isEmpty else { return .failure(.invalid("cloud days 不带位置参数")) }
            if args.contains("--limit") {
                guard let n = CLI.intArg(args, "--limit"), n > 0 else { return .failure(.invalid("--limit 要正整数")) }
                plan.limit = n
            }
            plan.path = "index"
        case "day":
            guard pos.count == 1, Recap.validDate(pos[0]) else {
                return .failure(.invalid("用法: notihub cloud day <YYYY-MM-DD>（日期要真实存在）"))
            }
            plan.path = "day/" + pos[0]
        case "mark":
            guard pos.count == 2, let id = Int64(pos[0]), id > 0 else {
                return .failure(.invalid("用法: notihub cloud mark <id> open|done|dropped"))
            }
            guard CloudClient.statuses.contains(pos[1]) else {
                return .failure(.invalid("状态只能是 open / done / dropped，收到 \(pos[1])"))
            }
            plan.markID = id; plan.markStatus = pos[1]; plan.path = "agenda/\(id)"
        case "note":
            let text = pos.joined(separator: " ")
            let date = CLI.strArg(args, "--date") ?? Recap.today()
            let key = CLI.strArg(args, "--key")
            if args.contains("--date") && CLI.strArg(args, "--date") == nil { return .failure(.invalid("--date 要跟一个 YYYY-MM-DD")) }
            if args.contains("--key") && key == nil { return .failure(.invalid("--key 要跟一个幂等键")) }
            let input = CloudNoteInput(text: text, date: date, idempotencyKey: key ?? UUID().uuidString)
            do { try input.validate() } catch let e as CloudFailure { return .failure(e) } catch { return .failure(.invalid("\(error)")) }
            plan.note = input; plan.keyGenerated = key == nil; plan.path = "notes"
        default:
            return .failure(.invalid("未知子命令 \(sub)"))
        }
        return .success(plan)
    }


    static func perform(_ plan: Plan, client: CloudClient) async -> Outcome {
        var out = Outcome()
        do {
            switch plan.sub {
            case "status":
                async let idxData = client.raw("index")
                async let openData = client.raw("open")
                let idx = try object(try await idxData)
                let opn = try object(try await openData)
                let days = idx["days"] as? [[String: Any]] ?? []
                let lastSync = (idx["lastSync"] as? NSNumber)?.doubleValue ?? 0
                let age = lastSync > 0 ? Int(nowUnix() - lastSync) : -1
                let openCount = (opn["items"] as? [Any])?.count ?? 0
                out.json = ["ok": true, "instance": client.connection.id, "host": client.connection.url.host ?? "",
                            "lastSync": lastSync, "lastSyncAgeSeconds": age,
                            "timezone": idx["timezone"] as? String ?? "", "days": days.count,
                            "latestDay": days.first?["date"] as? String ?? NSNull(), "open": openCount]
                out.text = ["云端 \(client.connection.url.host ?? "") · 实例 \(client.connection.id)",
                            "最后同步 \(lastSync > 0 ? fmtTime(lastSync) : "从未")（\(age >= 0 ? "\(age) 秒前" : "—")）· 时区 \(idx["timezone"] as? String ?? "")",
                            "\(days.count) 天 · 最新 \(days.first?["date"] as? String ?? "—") · 未完成待办 \(openCount) 条",
                            "（同步作业每 5 分钟跑一次；内容没变时每 30 分钟保底上传，所以最后同步最长约 35 分钟前也正常）"]
            case "days":
                var idx = try object(try await client.raw(plan.path))
                var days = idx["days"] as? [[String: Any]] ?? []
                if let n = plan.limit { days = Array(days.prefix(n)); idx["days"] = days }
                idx["ok"] = true
                out.json = idx
                out.text = days.map { d in
                    let date = d["date"] as? String ?? "?"
                    let total = (d["total"] as? NSNumber)?.intValue ?? 0
                    let open = (d["agendaOpen"] as? NSNumber)?.intValue ?? 0
                    let head = (d["headline"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ""
                    return "\(date)  \(CLI.pad("\(total) 条", 8))\(open > 0 ? CLI.pad("未完成 \(open)", 10) : CLI.pad("", 10))\(head)"
                }
                if out.text.isEmpty { out.text = ["云端还没有任何一天"] }
            case "day":
                var day = try object(try await client.raw(plan.path))
                day["ok"] = true
                out.json = day
                out.text = dayText(day)
            case "open":
                var opn = try object(try await client.raw(plan.path))
                if plan.withReminders { try LocalReminders.addPresence(to: &opn) }
                opn["ok"] = true
                out.json = opn
                let items = opn["items"] as? [[String: Any]] ?? []
                out.text = items.map(agendaLine) + ["—— 云端未完成 \(items.count) 条（已套用各端的完成/丢弃）"]
            case "mark":
                guard let id = plan.markID, let status = plan.markStatus else { throw CloudFailure.invalid("缺 id 或状态") }
                let receipt = try await client.setStatus(id: id, status: status)
                out.json = ["ok": true, "id": id, "status": receipt.status]
                out.text = ["#\(id) → 云端状态 \(receipt.status)（主窗口 / 网页 / iPhone 刷新后可见；本机采集库未改）"]
            case "note":
                guard let input = plan.note else { throw CloudFailure.invalid("缺正文") }
                let saved = try await client.saveNote(input)
                out.json = ["ok": true, "id": saved.id, "date": input.date, "ts": saved.ts,
                            "idempotencyKey": input.idempotencyKey]
                out.text = ["云端随手记 #\(saved.id) 已存到 \(input.date)（幂等键 \(input.idempotencyKey)；失败重试请带 --key 这个值）"]
            default:
                throw CloudFailure.invalid("未知子命令 \(plan.sub)")
            }
        } catch let f as LocalReminders.Failure {
            out = Outcome(code: f.code, json: ["ok": false, "error": f.message, "errorCode": "reminders_unreadable"])
        } catch let f as CloudFailure {
            out = failure(f, plan: plan)
        } catch {
            out = failure(CloudFailure(error.localizedDescription, kind: .network), plan: plan)
        }
        return out
    }

    static func failure(_ f: CloudFailure, plan: Plan?) -> Outcome {
        var message = f.message
        if f.status == 404, let plan {
            if plan.sub == "day" { message = "云端没有这一天（还没同步，或那天没有任何记录）" }
            if plan.sub == "mark" { message = "云端没有这条待办（还没同步到云端，或 id 不对）" }
        }
        var json: [String: Any] = ["ok": false, "error": message]
        if f.kind == .invalid { json["usageError"] = true }   // 与其它命令的 --json 用法错误同形（顶层帮助写明）
        if let s = f.status { json["httpStatus"] = s }
        let code: Int32
        switch f.kind {
        case .notConfigured: code = 2
        case .invalid: code = 64
        default: code = 1
        }
        return Outcome(code: code, json: json, text: [])
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudFailure("云端数据格式不兼容（不是 JSON 对象）", kind: .format)
        }
        return obj
    }

    static func agendaLine(_ a: [String: Any]) -> String {
        let id = (a["id"] as? NSNumber)?.int64Value ?? 0
        let due = (a["dueTS"] as? NSNumber).map { fmtTime($0.doubleValue).dropLast(3) }.map(String.init) ?? "—"
        let status = a["status"] as? String ?? "?"
        let mark = status == "done" ? "✓" : status == "dropped" ? "✗" : "·"
        return "\(mark) #\(CLI.pad(String(id), 5))\(CLI.pad(due, 18))\(a["title"] as? String ?? "")"
    }

    static func dayText(_ d: [String: Any]) -> [String] {
        let items = d["items"] as? [[String: Any]] ?? []
        let agenda = d["agenda"] as? [[String: Any]] ?? []
        let notes = d["cloudNotes"] as? [[String: Any]] ?? []
        let open = agenda.filter { ($0["status"] as? String) == "open" }.count
        var lines = ["\(d["date"] as? String ?? "?") · \((d["total"] as? NSNumber)?.intValue ?? 0) 条通知 · 合并 \(items.count) 段"
                     + " · 待办 \(agenda.count)（未完成 \(open)）· 云端随手记 \(notes.count)"]
        if let s = d["summary"] as? [String: Any] {
            if let h = s["headline"] as? String, !h.isEmpty { lines.append("〖\(h)〗") }
            if let t = s["text"] as? String { lines.append(t) }
        } else {
            lines.append("（这天还没有总结）")
        }
        if !agenda.isEmpty { lines.append(""); lines += agenda.map(agendaLine) }
        if !notes.isEmpty {
            lines.append("")
            for n in notes {
                let ts = (n["ts"] as? NSNumber)?.doubleValue ?? 0
                lines.append("\(Recap.hhmm(ts))  随手记  \((n["text"] as? String ?? "").truncated(80))")
            }
        }
        if !items.isEmpty { lines.append("") }
        for it in items {
            let ts = (it["ts"] as? NSNumber)?.doubleValue ?? 0
            let first = (it["lines"] as? [String])?.first ?? ""
            let redacted = (it["redacted"] as? Bool) == true
            lines.append("\(Recap.hhmm(ts))  \(CLI.pad(it["app"] as? String ?? "", 8))\(it["who"] as? String ?? "")："
                         + (redacted ? "〔已过保留期，正文已抹除〕" : first.truncated(70)))
        }
        return lines
    }


    static func run(_ args: [String]) -> Int32 {
        let asJSON = args.contains("--json")
        let plan: Plan
        switch parse(args) {
        case .success(let p): plan = p
        case .failure(let f): return emit(failure(f, plan: nil), json: asJSON)
        }
        let client: CloudClient
        do { client = CloudClient(connection: try CloudConnection.load()) }
        catch let f as CloudFailure { return emit(failure(f, plan: plan), json: asJSON) }
        catch { return emit(failure(CloudFailure(error.localizedDescription, kind: .notConfigured), plan: plan), json: asJSON) }

        if plan.isWrite && args.contains("--dry-run") {
            var out = Outcome()
            out.json = ["ok": true, "dryRun": true, "host": client.connection.url.host ?? "", "request": plan.described]
            out.text = ["（dry-run，未发送）\(plan.described["method"]!) https://\(client.connection.url.host ?? "")\(plan.described["path"]!)"]
            if let n = plan.note {
                out.text.append("  日期 \(n.date) · \(n.text.count) 字 · 幂等键 \(n.idempotencyKey)\(plan.keyGenerated ? "（新生成；真写时同样会新生成，要复用请带 --key）" : "")")
            }
            if let s = plan.markStatus { out.text.append("  状态 → \(s)") }
            return emit(out, json: asJSON)
        }
        switch blockingAwait({ await perform(plan, client: client) }) {
        case .success(let out): return emit(out, json: asJSON)
        case .failure(let e): return emit(failure(CloudFailure(e.localizedDescription, kind: .network), plan: plan), json: asJSON)
        }
    }

    @discardableResult
    static func emit(_ out: Outcome, json: Bool) -> Int32 {
        if json {
            CLI.printJSON(out.json)
        } else {
            out.text.forEach { print($0) }
        }
        if out.code != 0, let e = out.json["error"] as? String { Log.err("✗ \(e)") }
        return out.code
    }
}

enum CloudStatusSync {
    enum Outcome: Equatable {
        case updated, notSynced, skipped(String), failed(String)
        var label: String {
            switch self {
            case .updated: return "updated"
            case .notSynced: return "not-synced"
            case .skipped: return "skipped"
            case .failed: return "failed"
            }
        }
        var ok: Bool { if case .failed = self { return false }; return true }
    }

    static func connect() -> (CloudClient?, String?) {
        do { return (CloudClient(connection: try CloudConnection.load()), nil) }
        catch { return (nil, error.localizedDescription) }
    }

    static func apply(_ client: CloudClient, id: Int64, status: String) -> Outcome {
        switch blockingAwait({ try await client.setStatus(id: id, status: status) }) {
        case .success: return .updated
        case .failure(let e):
            if let f = e as? CloudFailure, f.status == 404 { return .notSynced }
            return .failed(e.localizedDescription)
        }
    }
}
