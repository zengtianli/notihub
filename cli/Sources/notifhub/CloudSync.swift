import Foundation
import SQLite3
import CryptoKit

enum CloudSync {

    static let tables = ["events", "notes", "agenda", "summaries"]
    static let heartbeatSeconds: Double = 1800
    static let refreshArguments = ["publish", "--no-upload", "--no-llm", "--json-only"]

    struct Failure: Error {
        let message: String
        let code: Int32
        init(_ message: String, code: Int32 = 1) { self.message = message; self.code = code }
    }

    struct Options: Equatable {
        var refresh = true
        var dryRun = false
        var json = false
    }

    static func parse(_ args: [String]) -> Result<Options, Failure> {
        var o = Options()
        for a in args {
            switch a {
            case "--no-refresh": o.refresh = false
            case "--dry-run": o.dryRun = true
            case "--json": o.json = true
            default: return .failure(Failure("不认识的参数：\(a)（用法见 notihub sync --help）", code: 64))
            }
        }
        return .success(o)
    }


    static func appendJSONString(_ s: String, to out: inout [UInt8]) {
        out.append(0x22)
        for b in s.utf8 {
            switch b {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])
            case 0x09: out.append(contentsOf: [0x5C, 0x74])
            case 0..<0x20: out.append(contentsOf: Array(String(format: "\\u%04x", b).utf8))
            default: out.append(b)
            }
        }
        out.append(0x22)
    }

    static func jsonString(_ s: String) -> String {
        var out: [UInt8] = []
        appendJSONString(s, to: &out)
        return String(decoding: out, as: UTF8.self)
    }

    static func dumpTables(database: URL) throws -> (json: [UInt8], counts: [String: Int]) {
        func connect(_ flags: Int32) -> OpaquePointer? {
            var h: OpaquePointer?
            if sqlite3_open_v2(database.path, &h, flags, nil) == SQLITE_OK, let h {
                sqlite3_busy_timeout(h, 5000)
                if sqlite3_exec(h, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK { return h }
            }
            sqlite3_close(h)
            return nil
        }
        guard FileManager.default.fileExists(atPath: database.path) else { throw Failure("采集库不存在：\(database.path)") }
        var handle = connect(SQLITE_OPEN_READONLY)
        if handle == nil, let h = connect(SQLITE_OPEN_READWRITE) {
            sqlite3_exec(h, "PRAGMA query_only=ON", nil, nil, nil)
            handle = h
        }
        guard let db = handle else { throw Failure("打不开采集库 \(database.path)（损坏、不是 SQLite 文件或无权限）") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw Failure("采集库读事务开不了：\(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }

        var out: [UInt8] = [0x7B]
        var counts: [String: Int] = [:]
        for (ti, name) in tables.enumerated() {
            if ti > 0 { out.append(0x2C) }
            appendJSONString(name, to: &out)
            out.append(contentsOf: [0x3A, 0x5B])
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT * FROM \(name)", -1, &stmt, nil) == SQLITE_OK else {
                throw Failure("读不了表 \(name)：\(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            let columns = sqlite3_column_count(stmt)
            var keys: [[UInt8]] = []
            for c in 0..<columns {
                var k: [UInt8] = []
                appendJSONString(String(cString: sqlite3_column_name(stmt, c)), to: &k)
                k.append(0x3A)
                keys.append(k)
            }
            var rows = 0
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                if rows > 0 { out.append(0x2C) }
                out.append(0x7B)
                for c in 0..<columns {
                    if c > 0 { out.append(0x2C) }
                    out.append(contentsOf: keys[Int(c)])
                    switch sqlite3_column_type(stmt, c) {
                    case SQLITE_NULL:
                        out.append(contentsOf: Array("null".utf8))
                    case SQLITE_INTEGER:
                        out.append(contentsOf: Array(String(sqlite3_column_int64(stmt, c)).utf8))
                    case SQLITE_FLOAT:
                        let d = sqlite3_column_double(stmt, c)
                        guard d.isFinite else { throw Failure("表 \(name) 里有非有限实数，JSON 表示不了") }
                        out.append(contentsOf: Array("\(d)".utf8))
                    case SQLITE_TEXT:
                        let n = Int(sqlite3_column_bytes(stmt, c))
                        if n > 0, let p = sqlite3_column_text(stmt, c) {
                            appendJSONString(String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self), to: &out)
                        } else {
                            out.append(contentsOf: [0x22, 0x22])
                        }
                    default:
                        throw Failure("表 \(name) 里有二进制列，同步协议只收文本与数字")
                    }
                }
                out.append(0x7D)
                rows += 1
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else {
                throw Failure("读表 \(name) 中断：\(String(cString: sqlite3_errmsg(db)))")
            }
            out.append(0x5D)
            counts[name] = rows
        }
        out.append(0x7D)
        return (out, counts)
    }


    struct Feeds {
        var index: Data
        var days: [(date: String, data: Data)]
    }

    static func loadFeeds(site: URL) throws -> Feeds {
        let indexURL = site.appendingPathComponent("index.json")
        guard let index = try? Data(contentsOf: indexURL),
              let object = (try? JSONSerialization.jsonObject(with: index)) as? [String: Any],
              let list = object["days"] as? [[String: Any]] else {
            throw Failure("读不出 \(indexURL.path)（先跑 notihub publish --json-only，或去掉 --no-refresh）")
        }
        var days: [(date: String, data: Data)] = []
        for entry in list {
            guard let date = entry["date"] as? String, Recap.validDate(date) else {
                throw Failure("index.json 里的日期无效：\(entry["date"] ?? "缺")")
            }
            guard let data = try? Data(contentsOf: site.appendingPathComponent(date + ".json")),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw Failure("读不出 \(date).json")
            }
            days.append((date, data))
        }
        return Feeds(index: index, days: days)
    }

    static func contentDigest(instance: String, timezone: String, tables: [UInt8], feeds: Feeds) throws -> String {
        func canonical(_ data: Data, dropping key: String? = nil) throws -> Data {
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw Failure("feed 不是 JSON 对象，算不出指纹")
            }
            if let key { object.removeValue(forKey: key) }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        var hash = SHA256()
        func add(_ data: Data) {
            hash.update(data: Data("\(data.count):".utf8))
            hash.update(data: data)
        }
        add(Data("notihub-sync-1".utf8))
        add(Data(instance.utf8))
        add(Data(timezone.utf8))
        add(Data(tables))
        add(try canonical(feeds.index, dropping: "generatedAt"))
        for day in feeds.days {
            add(Data(day.date.utf8))
            add(try canonical(day.data))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func payload(instance: String, generatedAt: Double, timezone: String, tables: [UInt8], feeds: Feeds) -> Data {
        var out: [UInt8] = Array("{\"version\":1,\"instance\":".utf8)
        appendJSONString(instance, to: &out)
        out.append(contentsOf: Array(",\"generatedAt\":\(generatedAt),\"timezone\":".utf8))
        appendJSONString(timezone, to: &out)
        out.append(contentsOf: Array(",\"tables\":".utf8))
        out.append(contentsOf: tables)
        out.append(contentsOf: Array(",\"feeds\":{\"index\":".utf8))
        out.append(contentsOf: feeds.index)
        for day in feeds.days {
            out.append(0x2C)
            appendJSONString(day.date, to: &out)
            out.append(0x3A)
            out.append(contentsOf: day.data)
        }
        out.append(contentsOf: [0x7D, 0x7D])
        return Data(out)
    }


    struct State: Equatable {
        var digest: String
        var at: Double
    }

    static func readState(_ url: URL) -> State? {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let digest = object["digest"] as? String, let at = object["at"] as? Double else { return nil }
        return State(digest: digest, at: at)
    }

    static func writeState(_ state: State, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["digest": state.digest, "at": state.at])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func unchanged(_ state: State?, digest: String, now: Double) -> Bool {
        guard let state else { return false }
        return state.digest == digest && now - state.at < heartbeatSeconds
    }


    typealias Transport = (_ endpoint: String, _ token: String, _ body: URL) -> (Int32, String)

    static let curlArguments = ["--config", "-", "--silent", "--show-error", "--fail-with-body", "--max-time", "90"]

    static func curlConfig(endpoint: String, token: String, body: URL, output: URL) -> String {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return ["url = " + quoted(endpoint),
                "header = " + quoted("Authorization: Bearer " + token),
                "header = \"Content-Type: application/json\"",
                "data-binary = " + quoted("@" + body.path),
                "output = " + quoted(output.path)].joined(separator: "\n")
    }

    static func curlTransport(endpoint: String, token: String, body: URL) -> (Int32, String) {
        let output = body.deletingPathExtension().appendingPathExtension("ack")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: output) }
        let (rc, errors) = notifhub.run("/usr/bin/curl", curlArguments,
                                        stdin: curlConfig(endpoint: endpoint, token: token, body: body, output: output),
                                        stderrToo: true, timeout: 100)
        let response = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        if rc != 0 {
            return (rc, (errors.trimmingCharacters(in: .whitespacesAndNewlines) + " " + String(response.prefix(500)))
                        .trimmingCharacters(in: .whitespaces))
        }
        return (0, response)
    }

    static func acknowledged(_ response: String, instance: String, counts: [String: Int]) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any],
              object["ok"] as? Bool == true, object["instance"] as? String == instance,
              let got = object["counts"] as? [String: Int] else { return false }
        return got == counts
    }


    enum Action: String { case uploaded, unchanged, dryRun = "dry-run", busy }

    struct Outcome {
        var action: Action
        var counts: [String: Int] = [:]
        var days = 0
        var bytes = 0
        var digest = ""
    }

    struct Snapshot {
        var body: Data
        var counts: [String: Int]
        var days: Int
        var digest: String
    }

    static func snapshot(instance: String, database: URL, site: URL, now: Double) throws -> Snapshot {
        guard let timezone = Clock.systemTZName else { throw Failure("解不出系统时区（/etc/localtime）") }
        let (tableJSON, counts) = try dumpTables(database: database)
        guard (counts["events"] ?? 0) > 0 else { throw Failure("采集库里一条事件都没有，拒绝用空库覆盖云端") }
        let feeds = try loadFeeds(site: site)
        let digest = try contentDigest(instance: instance, timezone: timezone, tables: tableJSON, feeds: feeds)
        return Snapshot(body: payload(instance: instance, generatedAt: now, timezone: timezone, tables: tableJSON, feeds: feeds),
                        counts: counts, days: feeds.days.count, digest: digest)
    }

    static func perform(instance: String, endpoint: String?, token: String?, database: URL, site: URL,
                        state stateURL: URL?, dryRun: Bool, now: Double = nowUnix(),
                        transport: Transport = curlTransport) throws -> Outcome {
        let snap = try snapshot(instance: instance, database: database, site: site, now: now)
        var outcome = Outcome(action: .unchanged, counts: snap.counts, days: snap.days, bytes: snap.body.count, digest: snap.digest)
        if !dryRun, let stateURL, unchanged(readState(stateURL), digest: snap.digest, now: now) { return outcome }
        let body = snap.body, counts = snap.counts, digest = snap.digest
        if dryRun { outcome.action = .dryRun; return outcome }
        guard let endpoint, let token else { throw Failure("尚未连接云端", code: 2) }

        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notihub-sync-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: file.path, contents: body, attributes: [.posixPermissions: 0o600]) else {
            throw Failure("写不了临时上传文件 \(file.path)")
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let (rc, response) = transport(endpoint, token, file)
        guard rc == 0 else { throw Failure("云同步上传失败（curl rc=\(rc)）：\(response.prefix(600))") }
        guard acknowledged(response, instance: instance, counts: counts) else {
            throw Failure("云端回执与本机快照对不上：\(response.prefix(300))")
        }
        if let stateURL { try writeState(State(digest: digest, at: now), to: stateURL) }
        outcome.action = .uploaded
        return outcome
    }


    static func describe(_ counts: [String: Int]) -> String {
        tables.map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: " · ")
    }

    private static func emit(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
    }

    static func run(_ args: [String]) -> Int32 {
        let options: Options
        switch parse(args) {
        case .success(let o): options = o
        case .failure(let f):
            if args.contains("--json") { emit(["ok": false, "error": f.message, "usageError": true]) } else { Log.err(f.message) }
            return f.code
        }
        func fail(_ f: Failure) -> Int32 {
            if options.json { emit(["ok": false, "error": f.message]) } else { Log.err("sync: " + f.message) }
            if !options.dryRun { Log.write("sync 失败：\(f.message.prefix(300))") }
            return f.code
        }
        let instance = Instance.current?.id ?? "personal"
        let site = Paths.dataDir.appendingPathComponent("site")
        do {
            if options.dryRun {
                let o = try perform(instance: instance, endpoint: nil, token: nil, database: Paths.db, site: site,
                                    state: nil, dryRun: true)
                if options.json {
                    emit(["ok": true, "action": o.action.rawValue, "instance": instance, "counts": o.counts,
                          "days": o.days, "bytes": o.bytes, "digest": o.digest])
                } else {
                    print("dry-run：会上传 \(describe(o.counts)) · \(o.days) 天 · \(o.bytes / 1024)KB（未刷新、未上传、未写状态）")
                }
                return 0
            }
            guard ProcessInfo.processInfo.environment["NOTIFHUB_DATA_DIR"] == nil else {
                throw Failure("数据目录已被 NOTIFHUB_DATA_DIR 改到隔离位置：云同步是整库替换，拒绝把隔离库传上云端（只看会传什么用 --dry-run）。", code: 2)
            }
            let connection: CloudConnection
            do { connection = try CloudConnection.load() }
            catch { throw Failure(error.localizedDescription, code: 2) }
            guard let configURL = CloudConnection.configURL else { throw Failure("尚未连接云端", code: 2) }
            if let recorded = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL))) as? [String: Any])?["database"] as? String,
               URL(fileURLWithPath: (recorded as NSString).expandingTildeInPath).standardizedFileURL.path != Paths.db.standardizedFileURL.path {
                throw Failure("云端配置登记的数据库（\(recorded)）与当前实例的采集库（\(Paths.db.path)）不是同一个，拒绝上传。", code: 2)
            }
            let base = connection.url.absoluteString
            let endpoint = (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/api/sync"

            let lockURL = configURL.deletingPathExtension().appendingPathExtension("lock")
            let fd = open(lockURL.path, O_WRONLY | O_CREAT, 0o600)
            guard fd >= 0 else { throw Failure("锁文件打不开：\(lockURL.path)") }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if options.json { emit(["ok": true, "action": Action.busy.rawValue, "instance": instance]) }
                else { print("另一轮云同步正在跑，本轮跳过") }
                return 0
            }

            if options.refresh {
                guard let binary = Paths.selfExecutable?.path else { throw Failure("找不到自己的可执行文件，无法刷新 JSON") }
                let (rc, out) = notifhub.run(binary, refreshArguments, stderrToo: true, timeout: 180)
                guard rc == 0 else { throw Failure("刷新本机 JSON 失败（publish rc=\(rc)）：\(out.suffix(400))") }
            }
            let o = try perform(instance: instance, endpoint: endpoint, token: connection.token, database: Paths.db,
                                site: site, state: configURL.deletingPathExtension().appendingPathExtension("state"),
                                dryRun: false)
            if options.json {
                emit(["ok": true, "action": o.action.rawValue, "instance": instance, "counts": o.counts,
                      "days": o.days, "bytes": o.bytes, "digest": o.digest])
            } else if o.action == .uploaded {
                print("云端已同步：\(base) · \(describe(o.counts)) · \(o.days) 天 · \(o.bytes / 1024)KB")
            } else {
                print("内容自上次上传以来没有变化，本轮不上传")
            }
            if o.action == .uploaded { Log.write("sync: 已上传 \(describe(o.counts))") }
            return 0
        } catch let f as Failure {
            return fail(f)
        } catch {
            return fail(Failure("\(error)"))
        }
    }
}
