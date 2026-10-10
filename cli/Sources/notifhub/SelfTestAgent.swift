import Foundation

final class SelfTestCloudStub: URLProtocol {
    struct Seen { let method: String; let path: String; let headers: [String: String]; let body: Data? }
    private static let lock = NSLock()
    private static var _handler: ((String, String, Data?) -> (Int, String))?
    private static var _seen: [Seen] = []
    static func reset(_ handler: @escaping (String, String, Data?) -> (Int, String)) {
        lock.lock(); _handler = handler; _seen = []; lock.unlock()
    }
    static var seen: [Seen] { lock.lock(); defer { lock.unlock() }; return _seen }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            body = data
        }
        let method = request.httpMethod ?? "GET", path = request.url?.path ?? ""
        Self.lock.lock()
        Self._seen.append(Seen(method: method, path: path, headers: request.allHTTPHeaderFields ?? [:], body: body))
        let handler = Self._handler
        Self.lock.unlock()
        let (code, text) = handler?(method, path, body) ?? (500, "{}")
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum AgentSelfTest {

    static func withEnv<T>(_ vars: [String: String?], _ body: () -> T) -> T {
        var prev: [String: String?] = [:]
        for (k, v) in vars {
            prev[k] = ProcessInfo.processInfo.environment[k]
            if let v { setenv(k, v, 1) } else { unsetenv(k) }
        }
        defer { for (k, v) in prev { if let v { setenv(k, v, 1) } else { unsetenv(k) } } }
        return body()
    }

    static func json(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    static func run(_ ok: (Bool, String) -> Void, selfBin: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notihub-agent-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data"), conf = root.appendingPathComponent("rules.json")
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? #"{"rules":[{"name":"otp","enabled":true,"apps":[],"keywords":[],"actions":[],"stop":true}],"bark":{"enabled":false},"summary":{"enabled":false},"ai":{"enabled":false},"apple":{},"muteInViews":["scripteditor2"]}"#
            .write(to: conf, atomically: true, encoding: .utf8)
        let sandbox: [String: String] = ["NOTIFHUB_DATA_DIR": data.path, "NOTIFHUB_CONFIG": conf.path,
                                         "NOTIHUB_CLOUD_CONFIG": root.appendingPathComponent("no-cloud.json").path]
        func sh(_ args: [String]) -> (Int32, String) { notifhub.run(selfBin, args, env: sandbox, timeout: 30) }
        func shErr(_ args: [String]) -> (Int32, String) { notifhub.run(selfBin, args, env: sandbox, stderrToo: true, timeout: 30) }

        print("== 帮助不执行（每个子命令 --help / -h）==")
        var probe = sandbox; probe["NOTIHUB_HELP_PROBE"] = "1"
        var notIntercepted: [String] = []
        for cmd in Help.usages.keys.sorted() {
            for flag in ["--help", "-h"] {
                let (rc, out) = notifhub.run(selfBin, [cmd, flag], env: probe, timeout: 10)
                if rc != 0 || out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notIntercepted.append("\(cmd) \(flag) rc=\(rc)") }
            }
        }
        ok(notIntercepted.isEmpty, "这些子命令的帮助没被截住（会真去执行）：\(notIntercepted)")
        for extra in [["queue", "list", "--help"], ["data", "export", "--help"], ["cloud", "mark", "1", "done", "-h"]] {
            let (rc, _) = notifhub.run(selfBin, extra, env: probe, timeout: 10)
            ok(rc == 0, "\(extra.joined(separator: " ")) 应只打印用法、退出 0，实得 rc=\(rc)")
        }
        let (urc, _) = sh(["frobnicate"])
        ok(urc == 64, "未知命令应退出 64，实得 \(urc)")
        let (ujrc, ujout) = sh(["frobnicate", "--json"])
        ok(ujrc == 64 && json(ujout)?["ok"] as? Bool == false && json(ujout)?["usageError"] as? Bool == true,
           "未知命令加 --json 应在 stdout 输出 ok:false、usageError 并退出 64，实得 rc=\(ujrc) \(ujout.prefix(120))")
        let (hrc, hout) = sh(["help", "cloud"])
        ok(hrc == 0 && hout.contains("cloud mark"), "help <命令> 应打印该命令用法")
        let (unrc, _) = sh(["uninstall"])
        ok(unrc == 64, "uninstall 不带 --yes 必须拒绝（64），实得 \(unrc)")
        ok(Set(Help.usages.keys).isSuperset(of: ["day", "recap", "today", "mark-read", "cloud", "done", "drop", "reopen",
                                                   "queue", "instance", "summarize", "sum", "todo", "agenda"]),
           "帮助清单缺命令：\(Set(["today", "mark-read", "cloud", "reopen", "queue", "instance"]).subtracting(Help.usages.keys))")

        let appURL = URL(fileURLWithPath: "/x/A.app")
        func resolved(_ bundle: URL?, _ info: [String: Any]?, _ exists: Bool = true) -> String? {
            try? LifecycleRelay.target(appBundle: bundle, info: { _ in info }, executable: { _ in exists }).get().path
        }
        ok(resolved(appURL, [LifecycleRelay.capabilityKey: 1, "CFBundleExecutable": "Main"]) == "/x/A.app/Contents/MacOS/Main", "主程序路径应取 Info.plist 的 CFBundleExecutable")
        ok(resolved(nil, nil) == nil && resolved(appURL, nil) == nil && resolved(appURL, ["CFBundleExecutable": "Main"]) == nil
           && resolved(appURL, [LifecycleRelay.capabilityKey: 1, "CFBundleExecutable": "../Main"]) == nil
           && resolved(appURL, [LifecycleRelay.capabilityKey: 1, "CFBundleExecutable": "Main"], false) == nil,
           "没有 App、读不到 Info.plist、没有能力键、可执行名带路径、主程序不存在都不该转调")
        ok(LifecycleRelay.timeout(for: ["update", "install", "--yes", "--json"]) == LifecycleRelay.installTimeout
           && LifecycleRelay.timeout(for: ["update", "--json", "install", "--yes"]) == LifecycleRelay.installTimeout
           && LifecycleRelay.installTimeout >= 30 + 330 + 20 + 330,
           "update install 的转调时限要盖过共用层自己的等待（30+330+20+330 秒）")
        ok([["update", "install", "--dry-run"], ["update", "install", "--yes", "--help"], ["update", "check", "--json"],
            ["config", "import", "install", "--yes"], ["config", "status"], ["update"]]
            .allSatisfy { LifecycleRelay.timeout(for: $0) == LifecycleRelay.timeout },
           "只有 update install 的实际执行放长时限，预演、帮助与其它命令仍是 60 秒")

        print("== 只读命令不建库 ==")
        let dbPath = data.appendingPathComponent("notif.db").path
        for args in [["today", "--json"], ["day", "--json"], ["stats", "--json"], ["mark-read", "--all", "--dry-run", "--json"],
                     ["agenda", "--json"], ["search", "验收", "--json"], ["done", "1", "--dry-run", "--json"]] {
            let (rc, out) = sh(args)
            ok(rc == 1 && json(out)?["ok"] as? Bool == false, "\(args.joined(separator: " ")) 在库不存在时应输出 ok:false 并退出 1，实得 rc=\(rc)")
        }
        let (statusRC, statusOut) = sh(["status", "--json"])
        let statusObj = json(statusOut)
        ok(statusRC == 1 && statusObj?["ok"] as? Bool == false && statusObj?["version"] as? String == VERSION
           && !((statusObj?["checks"] as? [[String: Any]]) ?? []).isEmpty && statusObj?["fullDiskAccess"] is Bool,
           "status --json 在库不存在时应 ok:false、退出 1 且带 version / checks / fullDiskAccess，实得 rc=\(statusRC) \(statusOut.prefix(160))")
        ok((statusObj?["error"] as? String)?.contains("致命检查未通过") == true && statusObj?["errorCode"] as? String == "fatal_checks"
           && (statusObj?["fatal"] as? Int ?? 0) > 0,
           "status --json 有致命项时应带 error（字符串）与 errorCode=fatal_checks，实得 \(statusOut.prefix(160))")
        let (sbrc, sbout) = sh(["status", "--bogus", "--json"])
        ok(sbrc == 64 && json(sbout)?["ok"] as? Bool == false && json(sbout)?["usageError"] as? Bool == true,
           "status 错参应 ok:false、usageError、退出 64，实得 rc=\(sbrc)")
        ok(sh(["status", "--bogus"]).0 == 64, "status 文本模式错参也应退出 64")
        for args in [["cloud", "status", "--bogus", "--json"], ["cloud", "day", "2026-02-30", "--json"], ["cloud", "--json"]] {
            let (crc, cout) = sh(args)
            ok(crc == 64 && json(cout)?["ok"] as? Bool == false && json(cout)?["usageError"] as? Bool == true,
               "\(args.joined(separator: " ")) 应 ok:false、usageError、退出 64，实得 rc=\(crc) \(cout.prefix(120))")
        }
        for word in ["读命令", "写命令", "--json 输出形状", "退出码", "仅在窗口中", "status", "today", "mark-read", "cloud status",
                     "cloud days", "cloud day", "cloud open", "cloud mark", "cloud note", "data list", "data export",
                     "push", "queue", "jobs", "doctor", "instance show",
                     "进入「本机数据」页", "分段切换", "「知道了」", "收起键盘", "云端站点链接", "访问密码登录", "提醒事项授权",
                     "分区切换", "打不开时的提示", "手表主页上下翻页",
                     "config export", "config import", "config sync", "打开「配置与同步…」窗口", "update install --yes",
                     "开关下面那句同步状态", "state: handed_off"] {
            ok(Help.main.contains(word), "顶层帮助缺「\(word)」（sop.agent_cli 的对照与 Chapter 的 agent_cli 检查读它）")
        }
        for line in Help.lifecycleReads + Help.lifecycleWrites {
            ok(Help.main.contains("\n" + line + "\n"), "顶层帮助里这一行要原样列在行首：\(line.prefix(30))")
        }
        ok(Help.usages["config"] == nil && Help.usages["update"] == nil, "config / update 的用法由共用命令层回答，不该另抄一份进 Help.usages")
        for stale in ["升级到新版 / 下载新版", "命令不做静默安装", "由运行中的 App 持有"] {
            ok(!Help.main.contains(stale), "顶层帮助还留着过时的说法「\(stale)」：升级与同步状态那句话都已有命令")
        }
        ok(!FileManager.default.fileExists(atPath: dbPath), "只读命令凭空建出了库 —— 会把「采集没跑」显示成「今天很安静」")

        print("== 今日流水与标已读（与菜单栏共用 Today）==")
        let (src, _) = sh(["stats"])   // 文本 stats 沿用 Store()：在隔离目录里建库（验收脚本也靠它）
        ok(src == 0 && FileManager.default.fileExists(atPath: dbPath), "隔离库没建起来")
        let now = nowUnix()
        let today = Recap.today()
        let seed = """
            INSERT INTO events(ts,source,bundle,canon,app,title,body,rec_id,dismissed_at,dedup_key) VALUES
            (\(now - 60),'usernoted','com.tencent.xinwechat','wechat','微信','甲','未读一',101,NULL,'agent-1'),
            (\(now - 50),'usernoted','com.tencent.xinwechat','wechat','微信','甲','未读二',102,NULL,'agent-2'),
            (\(now - 40),'usernoted','com.alibaba.dingtalkmac','dingtalk','钉钉','群','已读',103,\(now - 30),'agent-3'),
            (\(now - 20),'usernoted','com.apple.scripteditor2','com.apple.scripteditor2','scripteditor2','脚本','噪音',104,NULL,'agent-4');
            """
        let (qrc, qout) = notifhub.run("/usr/bin/sqlite3", [dbPath, seed], stderrToo: true, timeout: 10)
        ok(qrc == 0, "种子数据写不进隔离库：\(qout.prefix(120))")
        var ids: [Int64] = []
        if let s = Store(readOnlyAt: dbPath) {
            s.db.query("SELECT id FROM events WHERE dedup_key LIKE 'agent-%' ORDER BY dedup_key") { ids.append($0.int(0)) }
        }
        ok(ids.count == 4, "种子行数不对：\(ids.count)")
        guard ids.count == 4 else { return }
        let env: [String: String?] = ["NOTIFHUB_DATA_DIR": data.path, "NOTIFHUB_CONFIG": conf.path]
        let (visible, full) = withEnv(env) { (Today.load(includeAll: false, readOnly: true), Today.load(includeAll: true, readOnly: true)) }
        ok(visible.problem == nil && visible.date == today && visible.total == 4 && visible.muted == 1 && visible.unread == 2,
           "今日快照口径不对：total=\(visible.total) muted=\(visible.muted) unread=\(visible.unread) problem=\(visible.problem ?? "-")")
        ok(full.unread == 3 && full.muted == 0, "--all 应连折叠的噪音一起算：unread=\(full.unread) muted=\(full.muted)")
        let pick = TodayCLI.select(ids: [ids[0], ids[2], 999_999], all: false, source: nil, full: full, visible: visible)
        ok(pick.mark == [ids[0]] && pick.alreadyRead == [ids[2]] && pick.missing == [999_999],
           "按 id 选行不对：mark=\(pick.mark) already=\(pick.alreadyRead) missing=\(pick.missing)")
        ok(Set(TodayCLI.select(ids: [], all: true, source: nil, full: full, visible: visible).mark) == [ids[0], ids[1]],
           "--all 默认不该含折叠的噪音")
        ok(Set(TodayCLI.select(ids: [], all: true, source: nil, full: full, visible: full).mark) == [ids[0], ids[1], ids[3]],
           "--all --include-muted 应含噪音")
        ok(Set(TodayCLI.select(ids: [], all: false, source: "微信", full: full, visible: visible).mark) == [ids[0], ids[1]],
           "--source 应按来源（canon 或 app 名）选未读")

        let (trc, tout) = sh(["today", "--json"])
        let tj = json(tout)
        ok(trc == 0 && tj?["unread"] as? Int == 2 && (tj?["groups"] as? [Any])?.count == 2,
           "today --json 应与菜单栏同口径（未读 2、两组），实得 rc=\(trc) \(tout.prefix(120))")
        let (drc, dout) = sh(["mark-read", "--all", "--dry-run", "--json"])
        let dj = json(dout)
        ok(drc == 0 && (dj?["ids"] as? [Any])?.count == 2 && dj?["marked"] as? Int == 0, "mark-read --dry-run 应只报会标哪些：\(dout.prefix(160))")
        let (mrc, mout) = sh(["mark-read", String(ids[0]), "--json"])
        ok(mrc == 0 && json(mout)?["marked"] as? Int == 1, "mark-read <id> 应写 1 行：rc=\(mrc) \(mout.prefix(160))")
        let (xrc, _) = sh(["mark-read", "999999"])
        ok(xrc == 1, "不在今天流水里的 id 应退出 1，实得 \(xrc)")
        let (src2, sout2) = sh(["mark-read", "--source", "wechat"])
        ok(src2 == 0 && sout2.contains("已标已读 1 条"), "按来源标已读应只剩 1 条未读可标：\(sout2.prefix(120))")
        let after = withEnv(env) { Today.load(includeAll: false, readOnly: true) }
        ok(after.unread == 0, "标完后未读应为 0，实得 \(after.unread)")

        let stamp: (String) -> String = { p in
            let a = try? FileManager.default.attributesOfItem(atPath: p)
            return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((a?[.size] as? Int) ?? -1)"
        }
        let s0 = [dbPath, dbPath + "-wal"].map(stamp)
        let (jrc, jout) = sh(["day", today, "--json"])
        let jd = json(jout)
        ok(jrc == 0 && jd?["ok"] as? Bool == true && jd?["total"] as? Int == 4 && jd?["items"] is [Any] && jd?["agenda"] is [Any],
           "day --json 应输出 FeedDay + ok：rc=\(jrc) \(jout.prefix(160))")
        let (stj, stout) = sh(["stats", "--days", "1", "--json"])
        ok(stj == 0 && json(stout)?["total"] as? Int == 4, "stats --json 总数不对：\(stout.prefix(120))")
        ok([dbPath, dbPath + "-wal"].map(stamp) == s0, "day/stats --json 动了库文件（读命令不许写）")
        let (like, likeOut) = sh(["search", "未读", "--json"])
        ok(like == 0 && (try? JSONSerialization.jsonObject(with: Data(likeOut.utf8))) is [Any],
           "短查询的 search --json 必须是纯 JSON（降级提示走 stderr）：\(likeOut.prefix(120))")

        print("== --json 参数严格 ==")
        for args in [["day", "yesterday", "--json"], ["day", "2026-02-30", "--json"], ["day", today, "--bogus", "--json"],
                     ["agenda", "--bogus", "--json"], ["agenda", "--date", "2026-13-40", "--json"], ["agenda", "extra", "--json"],
                     ["stats", "--days", "-3", "--json"], ["stats", "--days", "abc", "--json"], ["stats", "--html", "--json"],
                     ["search", "--json"], ["search", "未读", "--days", "0", "--json"], ["search", "未读", "--bogus", "--json"],
                     ["search", "未读", "--app", "--json"], ["today", "--bogus", "--json"], ["mark-read", "--json"],
                     ["done", "--json"]] {
            let (rc, out) = sh(args)
            let j = json(out)
            ok(rc == 64 && j?["ok"] as? Bool == false && (j?["error"] as? String ?? "").isEmpty == false,
               "\(args.joined(separator: " ")) 应输出 ok:false 并退出 64，实得 rc=\(rc) \(out.prefix(120))")
        }
        let (dtrc, _) = sh(["day", "yesterday"])
        ok(dtrc == 2, "文本 day 收到非日期的位置参数应报日期无效（2），不该悄悄显示今天，实得 \(dtrc)")
        let (agrc, agout) = sh(["agenda", "--all", "--json"])
        ok(agrc == 0 && (try? JSONSerialization.jsonObject(with: Data(agout.utf8))) is [Any], "agenda --json 合法参数应仍输出数组")
        let (nsrc, nsout) = sh(["mark-read", "--source", "nosuchapp", "--json"])
        ok(nsrc == 1 && json(nsout)?["ok"] as? Bool == false, "--source 对不上今天任何来源应 ok:false、退出 1：rc=\(nsrc) \(nsout.prefix(120))")
        let s1 = [dbPath, dbPath + "-wal"].map { p -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: p)
            return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((a?[.size] as? Int) ?? -1)"
        }
        let (asrc, _) = sh(["agenda", "--json"]); let (ssrc, _) = sh(["search", "未读一", "--json"])
        let s2 = [dbPath, dbPath + "-wal"].map { p -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: p)
            return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\((a?[.size] as? Int) ?? -1)"
        }
        ok(asrc == 0 && ssrc == 0 && s1 == s2, "agenda / search --json 动了库文件（读命令不许写）：rc=\(asrc)/\(ssrc)")
        let (isrc, isout) = sh(["instance", "show"])
        ok(isrc == 0 && json(isout)?["ok"] as? Bool == true, "instance show 应带 ok:true")

        ok(!Publish.wantsUpload([]) && !Publish.wantsUpload(["--no-llm", "--days", "3"]),
           "裸 publish 不许上传（rsync --delete 到 VPS 是对外写入，要显式 --upload）")
        ok(Publish.wantsUpload(["--upload"]) && !Publish.wantsUpload(["--upload", "--json-only"])
           && !Publish.wantsUpload(["--upload", "--no-upload"]), "--upload 才传；--json-only / --no-upload 一律不传")

        print("== done / drop / reopen（本机 + 云端覆盖）==")
        let (arc, aout) = sh(["add", "验收待办（虚构）"])
        let aid = aout.split(separator: " ").first.map { String($0.dropFirst()) } ?? ""
        ok(arc == 0 && Int64(aid) != nil, "add 没给出 id：\(aout.prefix(80))")
        let (dnrc, dnout) = sh(["done", aid, "--json"])
        let dnr = (json(dnout)?["results"] as? [[String: Any]])?.first
        ok(dnrc == 0 && dnr?["status"] as? String == "done" && dnr?["cloud"] as? String == "skipped",
           "done --json 应本机成功、隔离目录下云端跳过：rc=\(dnrc) \(dnout.prefix(200))")
        let (rorc, roout) = sh(["reopen", aid])
        ok(rorc == 0 && roout.contains("→ 重新打开"), "reopen 应把状态改回 open：\(roout.prefix(120))")
        let (dprc, dpout) = sh(["drop", aid, "--dry-run"])
        ok(dprc == 0 && dpout.contains("dry-run"), "drop --dry-run 应只报计划")
        var st = ""
        if let s = Store(readOnlyAt: dbPath) { s.db.query("SELECT status FROM agenda WHERE id=?", [Int64(aid) ?? 0]) { st = $0.str(0) } }
        ok(st == "open", "reopen 之后 / dry-run 不写：库里状态应为 open，实得 \(st)")
        let (misrc, misout) = shErr(["done", "999999"])
        ok(misrc == 1 && misout.contains("#999999 不存在"), "不存在的 id 应退出 1 并说明：rc=\(misrc)")
        let (badrc, _) = sh(["done", "abc"])
        ok(badrc == 2, "done 非数字参数应是用法错误 2，实得 \(badrc)")
        ok(AgendaQueue.succeeded(kind: "status", output: "#5 → 完成：x · 云端已同步"), "接单器应仍认 done 的输出行")

        print("== 云端：连接规则与请求形状（桩）==")
        let sandboxURL = withEnv(["NOTIFHUB_DATA_DIR": data.path, "NOTIHUB_CLOUD_CONFIG": nil]) { CloudConnection.configURL }
        ok(sandboxURL == nil, "NOTIFHUB_DATA_DIR 指向隔离目录时不许拿真实凭据连云端")
        let explicitURL = withEnv(["NOTIFHUB_DATA_DIR": data.path, "NOTIHUB_CLOUD_CONFIG": "/tmp/x.json"]) { CloudConnection.configURL }
        ok(explicitURL?.path == "/tmp/x.json", "显式 NOTIHUB_CLOUD_CONFIG 应被采用")
        let token = String(repeating: "t", count: 40)
        let conn = CloudConnection(id: "personal", url: URL(string: "https://day.example.invalid")!, token: token)
        ok((try? conn.validate(expectedID: "personal", expectedURL: URL(string: "https://other.example.invalid")!)) == nil,
           "域名不符的云端配置必须拒绝")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SelfTestCloudStub.self]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        let client = CloudClient(connection: conn, session: session)
        func perform(_ args: [String]) -> CloudCLI.Outcome {
            switch CloudCLI.parse(args) {
            case .failure(let f): return CloudCLI.failure(f, plan: nil)
            case .success(let plan):
                return (try? blockingAwait({ await CloudCLI.perform(plan, client: client) }).get()) ?? CloudCLI.Outcome(code: 99)
            }
        }
        SelfTestCloudStub.reset { method, path, _ in
            switch (method, path) {
            case ("GET", "/native/api/index"): return (200, #"{"days":[{"date":"2026-09-29","total":3,"merged":2,"headline":"","agendaOpen":1,"whos":["甲"]}],"lastSync":\#(Int(now) - 100),"timezone":"Asia/Shanghai","generatedAt":1}"#)
            case ("GET", "/native/api/open"): return (200, #"{"generatedAt":1,"items":[{"id":7,"title":"x","status":"open"}]}"#)
            case ("GET", "/native/api/day/2026-09-29"): return (200, #"{"date":"2026-09-29","total":3,"items":[],"agenda":[],"cloudNotes":[],"extraField":1}"#)
            case ("PATCH", "/native/api/agenda/7"): return (200, #"{"id":7,"status":"done"}"#)
            case ("PATCH", "/native/api/agenda/8"): return (200, #"{"id":8,"status":"open"}"#)
            case ("PATCH", "/native/api/agenda/9"): return (404, #"{"detail":"待办不存在"}"#)
            case ("POST", "/native/api/notes"): return (200, #"{"id":42,"request_key":"k","date":"2026-09-29","ts":1,"text":"t"}"#)
            default: return (500, "{}")
            }
        }
        let status = perform(["status", "--json"])
        let statusText = String(decoding: (try? JSONSerialization.data(withJSONObject: status.json)) ?? Data(), as: UTF8.self)
        ok(status.code == 0 && status.json["days"] as? Int == 1 && status.json["open"] as? Int == 1
           && (status.json["lastSyncAgeSeconds"] as? Int ?? -1) >= 100, "cloud status 计数不对：\(statusText.prefix(200))")
        ok(!statusText.contains(token), "cloud status 输出里出现了凭据")
        let day = perform(["day", "2026-09-29", "--json"])
        ok(day.code == 0 && day.json["extraField"] as? Int == 1 && day.json["ok"] as? Bool == true,
           "cloud day --json 应原样转出服务端字段（不经有损结构体）")
        let mark = perform(["mark", "7", "done"])
        let patch = SelfTestCloudStub.seen.last { $0.method == "PATCH" }
        ok(mark.code == 0 && patch?.path == "/native/api/agenda/7"
           && patch?.headers["X-Notifhub-Request"] == "1" && patch?.headers["Content-Type"] == "application/json"
           && patch?.headers["Authorization"] == "Bearer " + token
           && patch?.body.flatMap { json(String(decoding: $0, as: UTF8.self)) }?["status"] as? String == "done",
           "cloud mark 的请求形状与主窗口不一致：\(String(describing: patch))")
        ok(perform(["mark", "8", "done"]).code == 1, "回执状态与请求不符时必须失败（实际没改成却报成功）")
        let gone = perform(["mark", "9", "dropped"])
        ok(gone.code == 1 && (gone.json["error"] as? String ?? "").contains("没有这条待办"), "云端 404 应说清是还没同步")
        ok(perform(["mark", "7", "finished"]).code == 64, "非法状态应是用法错误 64")
        let note = perform(["note", "验收", "笔记", "--date", "2026-09-29", "--key", "selftest-key-0001"])
        let post = SelfTestCloudStub.seen.last { $0.method == "POST" }
        let postBody = post?.body.flatMap { json(String(decoding: $0, as: UTF8.self)) }
        ok(note.code == 0 && note.json["id"] as? Int64 == 42 && postBody?["text"] as? String == "验收 笔记"
           && postBody?["idempotencyKey"] as? String == "selftest-key-0001" && postBody?["date"] as? String == "2026-09-29",
           "cloud note 的请求体不对：\(String(describing: postBody))")
        SelfTestCloudStub.reset { _, _, _ in (409, #"{"detail":"重复请求的内容不一致"}"#) }
        let conflict = perform(["note", "另一段", "--key", "selftest-key-0001"])
        ok(conflict.code == 1 && conflict.json["httpStatus"] as? Int == 409, "幂等键冲突（409）必须报失败")
        SelfTestCloudStub.reset { _, path, _ in path.hasSuffix("/11") ? (200, #"{"id":11,"status":"done"}"#) : path.hasSuffix("/12") ? (404, "{}") : (503, "{}") }
        ok(CloudStatusSync.apply(client, id: 11, status: "done") == .updated, "云端覆盖写成功应为 updated")
        ok(CloudStatusSync.apply(client, id: 12, status: "done") == .notSynced, "云端还没有这条应为 not-synced（不算失败）")
        let failed13: Bool
        if case .failed = CloudStatusSync.apply(client, id: 13, status: "done") { failed13 = true } else { failed13 = false }
        ok(failed13, "云端 503 应为 failed（done/drop 要据此退出 1）")
        let dry = CloudCLI.parse(["note", "x", "--date", "2026-09-29"])
        if case .success(let p) = dry { ok(p.keyGenerated && p.isWrite && p.note?.idempotencyKey.count == 36, "note 不给 --key 应新生成幂等键") }
        else { ok(false, "cloud note 合法参数被拒") }

        print("== 队列参数与云同步触发 ==")
        ok(AgendaQueue.mode([]) == .run(dryRun: false) && AgendaQueue.mode(["run", "--dry-run"]) == .run(dryRun: true),
           "裸 queue / queue run 应是接单器（launchd plist 就这么调）")
        ok(AgendaQueue.mode(["list", "--json"]) == .list(json: true), "queue list --json 应是只读查看")
        let rejected = [["lsit"], ["--frobnicate"], ["list", "--dry-run"], ["run", "extra"]].filter {
            if case .invalid = AgendaQueue.mode($0) { return false }; return true
        }
        ok(rejected.isEmpty, "这些 queue 参数没被拒绝，会落到接单器：\(rejected)")
        let resync = AgendaQueue.resyncArguments()
        ok(resync == ["sync"],
           "内容有变应直接跑一轮 sync（com.notifhub.publish 作业已退役，kickstart 它只会失败），实得 \(resync)")

        print("== rules init 不覆盖 ==")
        let custom = root.appendingPathComponent("custom-rules.json")
        try? #"{"muteInViews":["mine"]}"#.write(to: custom, atomically: true, encoding: .utf8)
        let (r1, r2): (Int32, Int32) = withEnv(["NOTIFHUB_CONFIG": custom.path]) {
            (Config.initDefault(force: false), Config.initDefault(force: true))
        }
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix("custom-rules.json.bak-") }
        let backupText = backups.first.flatMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) } ?? ""
        ok(r1 == 1, "已有配置时 rules init 应拒绝（1），实得 \(r1)")
        ok(r2 == 0 && backupText.contains("mine"), "rules init --force 应先备份旧配置再覆盖：rc=\(r2) 备份 \(backups.count) 个")
    }
}
