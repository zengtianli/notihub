import Foundation

enum SyncSelfTest {

    static func run(_ ok: (Bool, String) -> Void, selfBin: String) {
        print("== 云同步（notihub sync）==")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notihub-sync-test-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data"), site = data.appendingPathComponent("site")
        try? fm.createDirectory(at: site, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        ok((try? CloudSync.parse([]).get()) == CloudSync.Options()
           && (try? CloudSync.parse(["--no-refresh", "--dry-run", "--json"]).get()) == CloudSync.Options(refresh: false, dryRun: true, json: true),
           "sync 合法参数解析不对")
        if case .failure(let f) = CloudSync.parse(["--upload"]) { ok(f.code == 64, "sync 不认识的参数应是 64，实得 \(f.code)") }
        else { ok(false, "sync 不认识的参数没被拒绝（打错字会真去上传）") }

        let nasty = "老王说 \"行\" \\ 然后\n\t走了\u{01}\u{1F}😀 \u{2028}"
        let back = (try? JSONSerialization.jsonObject(with: Data("[\(CloudSync.jsonString(nasty))]".utf8))) as? [String]
        ok(back == [nasty], "JSON 字符串转义往返不一致：\(String(describing: back))")

        let dbURL = data.appendingPathComponent("notif.db")
        let schema = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE events(id INTEGER PRIMARY KEY, ts REAL NOT NULL, title TEXT, rec_id INTEGER, dismissed_at REAL);
            CREATE TABLE notes(id INTEGER PRIMARY KEY, ts REAL NOT NULL, date TEXT NOT NULL, text TEXT NOT NULL);
            CREATE TABLE agenda(id INTEGER PRIMARY KEY, title TEXT NOT NULL, status TEXT NOT NULL, due_ts REAL);
            CREATE TABLE summaries(date TEXT PRIMARY KEY, generated_at REAL NOT NULL, event_count INTEGER NOT NULL, text TEXT NOT NULL);
            INSERT INTO events VALUES (1, 1760000000.0, '他说 "好"', 7, NULL), (2, 1760000001.5, '第二条\n换行', NULL, 1760000002.25);
            INSERT INTO notes VALUES (1, 1760000003.0, '2026-10-01', '随手记');
            INSERT INTO agenda VALUES (5, '交材料', 'open', NULL);
            INSERT INTO summaries VALUES ('2026-10-01', 1760000004.0, 2, '总结');
            """
        let seedURL = root.appendingPathComponent("seed.db")
        var (src, sout) = notifhub.run("/usr/bin/sqlite3", [seedURL.path, schema], stderrToo: true, timeout: 10)
        if src == 0 { (src, sout) = notifhub.run("/usr/bin/sqlite3", [seedURL.path, ".backup '\(dbURL.path)'"], stderrToo: true, timeout: 10) }
        ok(src == 0, "同步测试库建不起来：\(sout.prefix(160))")
        guard src == 0 else { return }
        ok(!fm.fileExists(atPath: dbURL.path + "-wal") && !fm.fileExists(atPath: dbURL.path + "-shm"), "测试前提不成立：WAL 旁路文件还在")
        let dump = try? CloudSync.dumpTables(database: dbURL)
        let text = dump.map { String(decoding: $0.json, as: UTF8.self) } ?? ""
        let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: [[String: Any]]]
        ok(dump?.counts == ["events": 2, "notes": 1, "agenda": 1, "summaries": 1] && Set(parsed?.keys.map { $0 } ?? []) == Set(CloudSync.tables),
           "表快照行数或表名不对：\(String(describing: dump?.counts))")
        ok(text.contains("\"id\":5,") && text.contains("\"ts\":1760000000.0,") && text.contains("\"rec_id\":null") && text.contains("\"event_count\":2,"),
           "表快照的数值形状不对（整数须无小数点、实数须带小数点、NULL 须为 null）：\(text.prefix(300))")
        ok(parsed?["events"]?.first?["title"] as? String == "他说 \"好\"" && parsed?["events"]?.last?["title"] as? String == "第二条\n换行",
           "表快照的正文往返不一致")
        ok((try? CloudSync.dumpTables(database: root.appendingPathComponent("nope.db"))) == nil, "库不存在时表快照应报错，不该给出空快照")

        func writeFeeds(stamp: Double, day: String) {
            try? #"{"generatedAt":\#(stamp),"days":[{"date":"2026-10-01","total":2}]}"#
                .write(to: site.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
            try? day.write(to: site.appendingPathComponent("2026-10-01.json"), atomically: true, encoding: .utf8)
        }
        func digest() -> String? {
            guard let d = dump, let f = try? CloudSync.loadFeeds(site: site) else { return nil }
            return try? CloudSync.contentDigest(instance: "personal", timezone: "Asia/Shanghai", tables: d.json, feeds: f)
        }
        writeFeeds(stamp: 1, day: #"{"date":"2026-10-01","items":[{"ts":1.5,"app":"微信","who":"甲","lines":["a"]}]}"#)
        let d1 = digest()
        writeFeeds(stamp: 2, day: #"{"items":[{"lines":["a"],"who":"甲","app":"微信","ts":1.5}],"date":"2026-10-01"}"#)
        let d2 = digest()
        writeFeeds(stamp: 2, day: #"{"date":"2026-10-01","items":[{"ts":1.5,"app":"微信","who":"甲","lines":["b"]}]}"#)
        let d3 = digest()
        ok(d1 != nil && d1 == d2, "只有生成时间或键顺序不同，指纹却变了（会每 5 分钟白传一次）")
        ok(d3 != nil && d1 != d3, "内容变了指纹没变（新内容传不上去）")
        try? #"{"generatedAt":1,"days":[{"date":"../../etc/passwd"}]}"#
            .write(to: site.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        ok((try? CloudSync.loadFeeds(site: site)) == nil, "index.json 里的非法日期（路径穿越）没被拒绝")
        writeFeeds(stamp: 3, day: #"{"date":"2026-10-01","items":[{"ts":1.5,"app":"微信","who":"甲","lines":["a"]}]}"#)

        let st = CloudSync.State(digest: "x", at: 1000)
        ok(CloudSync.unchanged(st, digest: "x", now: 1000 + CloudSync.heartbeatSeconds - 1)
           && !CloudSync.unchanged(st, digest: "x", now: 1000 + CloudSync.heartbeatSeconds)
           && !CloudSync.unchanged(st, digest: "y", now: 1001) && !CloudSync.unchanged(nil, digest: "x", now: 1001),
           "跳过规则不对（同指纹 30 分钟内跳过，其余都要传）")

        let token = "tok-" + String(repeating: "s", count: 40)
        let cfg = CloudSync.curlConfig(endpoint: "https://example.test/api/sync", token: token,
                                       body: URL(fileURLWithPath: "/tmp/b.json"), output: URL(fileURLWithPath: "/tmp/b.ack"))
        ok(!CloudSync.curlArguments.contains { $0.contains(token) || $0.contains("example.test") }
           && !CloudSync.curlArguments.contains("--location") && !CloudSync.curlArguments.contains("-L"),
           "curl 的 argv 里不许有凭据或地址，也不许跟重定向")
        ok(cfg.contains("url = \"https://example.test/api/sync\"") && cfg.contains("header = \"Authorization: Bearer \(token)\"")
           && cfg.contains("data-binary = \"@/tmp/b.json\"") && cfg.contains("output = \"/tmp/b.ack\""), "curl 配置不完整：\(cfg.replacingOccurrences(of: token, with: "<token>"))")

        let stateURL = root.appendingPathComponent("cloud-personal.state")
        var calls: [(endpoint: String, token: String, body: [String: Any]?)] = []
        var reply: (Int32, String) = (0, #"{"ok":true,"instance":"personal","counts":{"events":2,"notes":1,"agenda":1,"summaries":1}}"#)
        let stub: CloudSync.Transport = { endpoint, tok, file in
            let attrs = try? fm.attributesOfItem(atPath: file.path)
            let body = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
            calls.append((endpoint, tok, (attrs?[.posixPermissions] as? Int) == 0o600 ? body : nil))
            return reply
        }
        func once(now: Double, dryRun: Bool = false) -> Result<CloudSync.Outcome, CloudSync.Failure> {
            do {
                return .success(try CloudSync.perform(instance: "personal", endpoint: "https://example.test/api/sync", token: token,
                                                      database: dbURL, site: site, state: stateURL, dryRun: dryRun, now: now, transport: stub))
            } catch let f as CloudSync.Failure { return .failure(f) } catch { return .failure(CloudSync.Failure("\(error)")) }
        }
        let dry = try? once(now: 5000, dryRun: true).get()
        ok(dry?.action == .dryRun && calls.isEmpty && !fm.fileExists(atPath: stateURL.path) && (dry?.bytes ?? 0) > 0,
           "dry-run 不许上传、不许写状态：action=\(String(describing: dry?.action)) 调用 \(calls.count) 次")

        reply.1 = #"{"ok":true,"instance":"personal","counts":{"events":1,"notes":1,"agenda":1,"summaries":1}}"#
        if case .failure = once(now: 5000) { ok(calls.count == 1 && !fm.fileExists(atPath: stateURL.path), "回执行数对不上时不许记成已传") }
        else { ok(false, "回执行数对不上却被当成同步成功") }
        reply = (22, "curl: (22) The requested URL returned error: 422")
        if case .failure(let f) = once(now: 5000) { ok(f.code == 1 && !fm.fileExists(atPath: stateURL.path), "传输失败应退出 1 且不记状态") }
        else { ok(false, "传输失败却被当成同步成功") }

        reply = (0, #"{"ok":true,"instance":"personal","counts":{"events":2,"notes":1,"agenda":1,"summaries":1}}"#)
        calls = []
        let first = try? once(now: 5000).get()
        let sent = calls.first?.body
        let agendaID = ((sent?["tables"] as? [String: Any])?["agenda"] as? [[String: Any]])?.first?["id"]
        ok(first?.action == .uploaded && calls.count == 1 && calls.first?.endpoint == "https://example.test/api/sync" && calls.first?.token == token,
           "首轮应上传一次到 /api/sync：action=\(String(describing: first?.action)) 调用 \(calls.count) 次")
        ok(sent?["version"] as? Int == 1 && sent?["instance"] as? String == "personal" && sent?["generatedAt"] as? Double == 5000
           && (sent?["timezone"] as? String).map { TimeZone(identifier: $0) != nil } == true
           && Set((sent?["tables"] as? [String: Any])?.keys.map { $0 } ?? []) == Set(CloudSync.tables)
           && Set((sent?["feeds"] as? [String: Any])?.keys.map { $0 } ?? []) == ["index", "2026-10-01"]
           && agendaID is Int && !String(describing: sent).contains(token),
           "上传体形状不对（version/instance/generatedAt/timezone/四张表/index+各天；临时文件须 0600；凭据不许进正文）")
        let saved = CloudSync.readState(stateURL)
        let mode = (try? fm.attributesOfItem(atPath: stateURL.path))?[.posixPermissions] as? Int
        ok(saved?.digest == first?.digest && saved?.at == 5000 && mode == 0o600, "状态文件应记下指纹与时间且为 0600：\(String(describing: saved)) mode=\(String(describing: mode))")

        let second = try? once(now: 5000 + 300).get()
        ok(second?.action == .unchanged && calls.count == 1, "内容没变的下一轮不该再上传：action=\(String(describing: second?.action)) 调用 \(calls.count) 次")
        let beat = try? once(now: 5000 + CloudSync.heartbeatSeconds).get()
        ok(beat?.action == .uploaded && calls.count == 2, "到保底间隔应再传一次（「最后同步」要能证明作业在岗）")
        _ = notifhub.run("/usr/bin/sqlite3", [dbURL.path, "INSERT INTO events VALUES (3, 1760000009.0, '新来的', NULL, NULL)"], timeout: 10)
        reply.1 = #"{"ok":true,"instance":"personal","counts":{"events":3,"notes":1,"agenda":1,"summaries":1}}"#
        let third = try? once(now: 5000 + CloudSync.heartbeatSeconds + 60).get()
        ok(third?.action == .uploaded && calls.count == 3 && third?.counts["events"] == 3, "库里有新事件应立刻上传")
        _ = notifhub.run("/usr/bin/sqlite3", [dbURL.path, "DELETE FROM events"], timeout: 10)
        if case .failure = once(now: 9_000_000) { ok(calls.count == 3, "空事件库不许去覆盖云端（连请求都不该发）") }
        else { ok(false, "空事件库被传上了云端") }

        let cloud = root.appendingPathComponent("cloud-personal.json")
        try? #"{"id":"personal","url":"https://day.example.invalid","token":"\#(token)"}"#.write(to: cloud, atomically: true, encoding: .utf8)
        let env = ["NOTIFHUB_DATA_DIR": data.path, "NOTIHUB_CLOUD_CONFIG": cloud.path]
        let (irc, iout) = notifhub.run(selfBin, ["sync", "--no-refresh", "--json"], env: env, timeout: 20)
        ok(irc == 2 && AgentSelfTest.json(iout)?["ok"] as? Bool == false,
           "NOTIFHUB_DATA_DIR 隔离时 sync 必须拒绝上传（2），实得 rc=\(irc) \(iout.prefix(120))")
        ok(!fm.fileExists(atPath: root.appendingPathComponent("cloud-personal.lock").path), "被拒绝的 sync 不该走到加锁这一步")
        let (brc, bout) = notifhub.run(selfBin, ["sync", "--bogus", "--json"], env: env, timeout: 20)
        ok(brc == 64 && AgentSelfTest.json(bout)?["ok"] as? Bool == false && AgentSelfTest.json(bout)?["usageError"] as? Bool == true,
           "sync 打错参数应 ok:false、usageError、退出 64，实得 rc=\(brc) \(bout.prefix(120))")
        _ = notifhub.run("/usr/bin/sqlite3", [dbURL.path, "INSERT INTO events VALUES (9, 1760000010.0, '回来了', NULL, NULL)"], timeout: 10)
        let (drc, dout) = notifhub.run(selfBin, ["sync", "--dry-run", "--json"], env: env, timeout: 20)
        let dj = AgentSelfTest.json(dout)
        ok(drc == 0 && dj?["action"] as? String == "dry-run" && (dj?["counts"] as? [String: Int])?["events"] == 1 && dj?["days"] as? Int == 1,
           "sync --dry-run --json 应只报会传什么：rc=\(drc) \(dout.prefix(160))")
    }
}
