import Foundation

enum JobsSelfTest {

    static func run(_ ok: (Bool, String) -> Void, selfBin: String) {
        print("== 后台任务调度（采集器内，子进程）==")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notihub-jobs-test-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let receipt = root.appendingPathComponent("jobs.json")
        func sh(_ name: String, _ script: String, interval: TimeInterval = 100, timeout: TimeInterval = 50,
                legacy: String? = nil, out: Bool = false) -> Jobs.Spec {
            Jobs.Spec(name: name, executable: "/bin/sh", arguments: ["-c", script], interval: interval, timeout: timeout,
                      stdoutPath: out ? root.appendingPathComponent("\(name).log").path : nil,
                      stderrPath: root.appendingPathComponent("\(name).err").path, legacyLabel: legacy)
        }
        func wait(_ limit: Double = 5, until done: () -> Bool) {
            let end = Date().addingTimeInterval(limit)
            while !done() && Date() < end { usleep(50_000) }
        }
        func show(_ s: Jobs.Scheduler, _ name: String) -> String { String(describing: s.states[name]?.json as NSDictionary?) }
        func state(_ s: Jobs.Scheduler, _ name: String) -> Jobs.TaskState { s.states[name] ?? Jobs.TaskState() }
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

        var loaded: Set<String> = []
        let s1 = Jobs.Scheduler(specs: [sh("bad", "echo 第一行 >&2; echo boom line >&2; exit 3"),
                                        sh("good", "echo fine; exit 0", out: true)],
                                receiptURL: receipt, legacyLoaded: { loaded.contains($0) }, killGrace: 1, stagger: 3, now: t0)
        let wake1 = s1.tick(now: t0)
        ok(s1.states["bad"]?.state == "running" && s1.states["good"]?.state != "running",
           "一次 tick 应只拉起一条任务")
        ok(abs(wake1.timeIntervalSince(t0) - 3) < 0.01, "还有到期任务时应隔 stagger 秒再来")
        s1.tick(now: at(3))
        wait { s1.tick(now: at(4)); return s1.running.isEmpty }
        let bad = s1.states["bad"] ?? Jobs.TaskState(), good = s1.states["good"] ?? Jobs.TaskState()
        ok(bad.lastExit == 3 && bad.consecutiveFailures == 1 && bad.lastError == "boom line" && bad.state == "idle",
           "失败任务应记退出码 3、连续失败 1、stderr 最后一行")
        ok(good.lastExit == 0 && good.consecutiveFailures == 0 && good.lastError == nil && good.lastSuccessAt != nil,
           "另一条任务不该受影响")
        ok(bad.nextDueAt == at(100) && good.nextDueAt == at(103), "下次到期应从各自开始时间算")
        ok(Jobs.status(bad, now: at(5)) == "failing" && Jobs.status(good, now: at(5)) == "ok",
           "判读应是 failing / ok，实得")
        ok((try? String(contentsOf: root.appendingPathComponent("good.log"), encoding: .utf8)) == "fine\n",
           "子进程 stdout 应追加进它自己的日志文件")

        let diagnostic = "LLM 调用失败: ConnectionError: 未获得结果：\n- codex [timeout]：连接路由发现超时\n"
            + "- claude [timeout]：总预算用完，未启动\n额度恢复后自动重试。"
        let failure = Summarizer.failureMessage(date: "2026-10-08", error: LLM.LLMError.failed(diagnostic))
        let errorLog = root.appendingPathComponent("summary-diagnostic.err")
        try? "旧轮次错误\n".write(to: errorLog, atomically: true, encoding: .utf8)
        let errorOffset = Jobs.fileSize(errorLog.path)
        if let fh = FileHandle(forWritingAtPath: errorLog.path) {
            fh.seekToEndOfFile(); fh.write(Data((failure + "\n").utf8)); try? fh.close()
        }
        let reported = Jobs.lastLine(of: errorLog.path, from: errorOffset) ?? ""
        ok(reported.contains("codex [timeout]") && reported.contains("连接路由发现超时")
           && !reported.contains("旧轮次错误") && !failure.contains("\n"),
           "总结回执丢失真实错误、只保留恢复建议：\(reported)")

        let raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: receipt))) as? [String: Any] ?? [:]
        let badJSON = (raw["tasks"] as? [String: Any])?["bad"] as? [String: Any] ?? [:]
        let goodJSON = (raw["tasks"] as? [String: Any])?["good"] as? [String: Any] ?? [:]
        let keys = ["command", "interval", "timeout", "state", "state_reason", "pid", "runs", "last_started_at", "last_finished_at",
                    "last_exit", "last_error", "last_success_at", "consecutive_failures", "next_due_at", "log", "err"]
        ok(raw["schema"] as? Int == 1 && (raw["updated_at"] as? String).flatMap(Jobs.parseStamp) != nil
           && raw["order"] as? [String] == ["bad", "good"] && raw["version"] as? String == VERSION,
           "回执顶层应有 schema=1 / updated_at / order / version")
        ok(keys.allSatisfy { badJSON[$0] != nil } && keys.allSatisfy { goodJSON[$0] != nil },
           "回执每条任务的字段必须齐全（空值是 null）：缺")
        ok(badJSON["last_exit"] as? Int == 3 && badJSON["consecutive_failures"] as? Int == 1 && badJSON["last_error"] as? String == "boom line"
           && goodJSON["last_error"] is NSNull && badJSON["last_started_at"] as? String == Jobs.stamp(t0),
           "回执里的失败事实不对")
        let mode = ((try? fm.attributesOfItem(atPath: receipt.path))?[.posixPermissions] as? NSNumber)?.intValue
        let strays = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.contains(".tmp-") }
        ok(mode == 0o600 && strays.isEmpty, "回执应是 0600 且不留临时文件：mode= 残留")

        let flag = root.appendingPathComponent("flaky-ok").path
        let s3 = Jobs.Scheduler(specs: [sh("flaky", "[ -f '\(flag)' ] || { echo 还不行 >&2; exit 1; }")],
                                receiptURL: root.appendingPathComponent("flaky.json"), legacyLoaded: { _ in false }, now: t0)
        for round in 0..<2 {
            s3.tick(now: at(Double(round) * 100))
            wait { s3.tick(now: at(Double(round) * 100 + 1)); return s3.running.isEmpty }
        }
        ok(s3.states["flaky"]?.consecutiveFailures == 2 && s3.states["flaky"]?.runs == 2,
           "连续两轮失败应累加到 2：\(show(s3, "flaky"))")
        fm.createFile(atPath: flag, contents: nil)
        s3.tick(now: at(200))
        wait { s3.tick(now: at(201)); return s3.running.isEmpty }
        ok(s3.states["flaky"]?.consecutiveFailures == 0 && s3.states["flaky"]?.lastError == nil && s3.states["flaky"]?.lastExit == 0,
           "成功一轮后连续失败应清零、错误应清掉：\(show(s3, "flaky"))")

        let s4 = Jobs.Scheduler(specs: [sh("slow", "sleep 1", interval: 10, timeout: 100_000)],
                                receiptURL: root.appendingPathComponent("slow.json"), legacyLoaded: { _ in false }, now: t0)
        s4.tick(now: t0)
        let firstPID = s4.states["slow"]?.pid
        s4.tick(now: at(11)); s4.tick(now: at(25)); s4.tick(now: at(500))     // 早过了到期时间，但上一轮还在跑
        ok(s4.states["slow"]?.runs == 1 && s4.states["slow"]?.pid == firstPID && s4.running.count == 1,
           "上一轮还在跑时不许再起一轮")
        wait { s4.tick(now: at(501)); return s4.running.isEmpty }
        ok(s4.states["slow"]?.runs == 1 && s4.states["slow"]?.nextDueAt == at(511),
           "一轮跑过了间隔，结束后不该紧接着再跑")
        s4.tick(now: at(10_000))
        ok(s4.states["slow"]?.runs == 2 && s4.states["slow"]?.nextDueAt == at(10_010),
           "错过多轮应只补一轮")
        wait { s4.tick(now: at(10_001)); return s4.running.isEmpty }
        ok(s4.states["slow"]?.runs == 2, "补跑结束后不该再补第二轮")

        let childPID = root.appendingPathComponent("child.pid").path, stubborn = root.appendingPathComponent("stubborn.pid").path
        let s5 = Jobs.Scheduler(specs: [sh("hang", "sleep 300 & echo $! > '\(childPID)'; wait", timeout: 5),
                                        sh("deaf", "trap '' TERM; sleep 300 & echo $! > '\(stubborn)'; wait", timeout: 5),
                                        sh("quick", "exit 0")],
                                receiptURL: root.appendingPathComponent("timeout.json"), legacyLoaded: { _ in false },
                                killGrace: 2, stagger: 1, now: t0)
        s5.tick(now: t0); s5.tick(now: at(1)); s5.tick(now: at(2))
        func pidIn(_ path: String) -> pid_t { pid_t((try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }
        wait { pidIn(childPID) > 0 && pidIn(stubborn) > 0 }
        let grand = pidIn(childPID), grandDeaf = pidIn(stubborn)
        ok(grand > 0 && Jobs.alive(grand) && grandDeaf > 0 && Jobs.alive(grandDeaf), "测试前提：孙进程应已起来")
        s5.tick(now: at(4))
        ok(s5.running["hang"] != nil && s5.running["hang"]?.termSentAt == nil, "没到超时不该动它")
        s5.tick(now: at(6))                                   // hang 起于 0、deaf 起于 1：两条都过了 5 秒 → SIGTERM 整组
        wait { s5.tick(now: at(7)); return s5.running["hang"] == nil }
        let hang = s5.states["hang"] ?? Jobs.TaskState()
        ok(hang.lastExit == -SIGTERM && hang.consecutiveFailures == 1 && (hang.lastError ?? "").contains("超时 5 秒"),
           "超时应记 SIGTERM（-15）与超时原因")
        wait { !Jobs.alive(grand) }
        ok(!Jobs.alive(grand), "超时后孙进程  还活着（没按进程组收）")
        ok(s5.running["deaf"] != nil, "不听 SIGTERM 的那条在宽限期内应还在")
        s5.tick(now: at(9))                                   // SIGTERM 发于 6，宽限 2 秒 → SIGKILL
        wait { s5.tick(now: at(10)); return s5.running["deaf"] == nil }
        let deaf = s5.states["deaf"] ?? Jobs.TaskState()
        ok(deaf.lastExit == -SIGKILL && (deaf.lastError ?? "").contains("超时"), "不听 SIGTERM 的应被 SIGKILL（-9）")
        wait { !Jobs.alive(grandDeaf) }
        ok(!Jobs.alive(grandDeaf), "SIGKILL 后孙进程  还活着")
        ok(s5.states["quick"]?.lastExit == 0 && s5.states["quick"]?.consecutiveFailures == 0, "别的任务超时不该影响 quick：\(show(s5, "quick"))")

        loaded = ["com.test.legacy", "com.test.hourly"]
        let hourlyLog = root.appendingPathComponent("hourly.log")
        fm.createFile(atPath: hourlyLog.path, contents: Data("上一轮\n".utf8))
        try? fm.setAttributes([.modificationDate: at(-600)], ofItemAtPath: hourlyLog.path)   // 旧作业 10 分钟前跑过
        let s6 = Jobs.Scheduler(specs: [sh("guarded", "exit 0", interval: 60, legacy: "com.test.legacy"),
                                        sh("hourly", "exit 0", interval: 3600, legacy: "com.test.hourly", out: true)],
                                receiptURL: root.appendingPathComponent("legacy.json"), legacyLoaded: { loaded.contains($0) }, now: t0)
        s6.tick(now: t0); s6.tick(now: at(60)); s6.tick(now: at(120))
        ok(s6.states["guarded"]?.runs == 0 && s6.states["guarded"]?.state == "deferred" && s6.running.isEmpty
           && s6.states["hourly"]?.state == "deferred" && s6.states["hourly"]?.runs == 0,
           "旧作业还加载着时不许调度：\(show(s6, "guarded"))")
        ok(Jobs.status(s6.states["guarded"] ?? Jobs.TaskState(), now: at(121)) == "deferred"
           && (s6.states["guarded"]?.stateReason ?? "").contains("com.test.legacy"),
           "deferred 应写明是哪个旧作业、且不算失败")
        loaded = []
        s6.tick(now: at(180))
        wait { s6.tick(now: at(181)); return s6.running.isEmpty && s6.states["guarded"]?.runs == 1 }
        ok(s6.states["guarded"]?.runs == 1 && s6.states["guarded"]?.lastExit == 0 && s6.states["guarded"]?.state == "idle",
           "旧作业卸掉后应自动接手：\(show(s6, "guarded"))")
        ok(s6.states["hourly"]?.runs == 0 && s6.states["hourly"]?.state == "idle" && s6.states["hourly"]?.nextDueAt == at(3000),
           "接手每小时任务时应等到「上次日志写入 + 间隔」，不当场多跑一轮：\(show(s6, "hourly"))")
        ok(Jobs.status(s6.states["hourly"] ?? Jobs.TaskState(), now: at(200)) == "pending", "接手后未到期应是 pending")
        loaded = ["com.test.legacy"]                           // 回滚：旧作业又加载回来 → 立刻让路
        s6.tick(now: at(240))
        ok(s6.states["guarded"]?.runs == 1 && s6.states["guarded"]?.state == "deferred", "旧作业加载回来后应让路：\(show(s6, "guarded"))")

        let s7 = Jobs.Scheduler(specs: [sh("good", "exit 0"), sh("bad", "exit 3")], receiptURL: receipt,
                                legacyLoaded: { _ in false }, now: at(50))
        s7.tick(now: at(50))
        ok(s7.running.isEmpty && s7.states["good"]?.runs == 1 && s7.states["bad"]?.consecutiveFailures == 1,
           "重启后没到期不该跑，失败计数应保留：\(show(s7, "good"))")
        var ghost = Jobs.TaskState()
        ghost.state = "running"; ghost.pid = 1; ghost.lastStartedAt = at(0); ghost.runs = 4; ghost.nextDueAt = at(100)
        let ghostReceipt = root.appendingPathComponent("ghost.json")
        Jobs.writeReceipt(Jobs.Receipt(updatedAt: at(1), daemonPID: 1, version: VERSION, tasks: [("orphan", ghost)]), to: ghostReceipt)
        let s8 = Jobs.Scheduler(specs: [sh("orphan", "exit 0")], receiptURL: ghostReceipt, legacyLoaded: { _ in false }, now: at(20))
        ok(s8.states["orphan"]?.state == "idle" && s8.states["orphan"]?.nextDueAt == at(20) && s8.running.isEmpty
           && (s8.states["orphan"]?.lastError ?? "").contains("结果未知") && s8.states["orphan"]?.consecutiveFailures == 0,
           "重启时在跑的那轮（pid 1 不是本程序）应记结果未知并安排补跑：\(show(s8, "orphan"))")

        var st = Jobs.TaskState()
        st.interval = 300; st.timeout = 600; st.lastStartedAt = at(0); st.nextDueAt = at(300)
        ok(Jobs.status(st, now: at(400)) == "ok" && Jobs.status(st, now: at(601)) == "overdue",
           "到期后超过一个间隔没跑应是 overdue")
        st.state = "running"
        ok(Jobs.status(st, now: at(100)) == "running" && Jobs.status(st, now: at(700)) == "overdue", "超时再过一分钟还在 running 应是 overdue")
        st.state = "disabled"
        ok(Jobs.status(st, now: at(99_999)) == "disabled" && !Jobs.isBad("deferred") && !Jobs.isBad("pending") && Jobs.isBad("failing") && Jobs.isBad("overdue"),
           "disabled / deferred / pending 不算坏")
        func jobs(_ dir: URL, _ args: [String] = ["--json"]) -> (Int32, [String: Any]) {
            let (rc, out) = notifhub.run(selfBin, ["jobs"] + args, env: ["NOTIFHUB_DATA_DIR": dir.path])
            return (rc, AgentSelfTest.json(out) ?? [:])
        }
        let empty = root.appendingPathComponent("empty"), live = root.appendingPathComponent("live")
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        try? fm.createDirectory(at: live, withIntermediateDirectories: true)
        let (rcMissing, jMissing) = jobs(empty)
        ok(rcMissing == 1 && jMissing["ok"] as? Bool == false, "读不到回执应退出 1、ok:false：rc")
        var fine = Jobs.TaskState()
        fine.interval = 300; fine.timeout = 600; fine.lastStartedAt = Date(); fine.lastFinishedAt = Date(); fine.lastExit = 0
        fine.lastSuccessAt = Date(); fine.nextDueAt = Date().addingTimeInterval(200); fine.runs = 3
        Jobs.writeReceipt(Jobs.Receipt(updatedAt: Date(), daemonPID: 1, version: VERSION, tasks: [("sync", fine)]), to: live.appendingPathComponent("jobs.json"))
        let (rcFine, jFine) = jobs(live)
        ok(rcFine == 0 && jFine["ok"] as? Bool == true && ((jFine["tasks"] as? [String: Any])?["sync"] as? [String: Any])?["status"] as? String == "ok"
           && (jFine["failing"] as? [String]) == [], "全部正常应退出 0：rc")
        fine.consecutiveFailures = 2; fine.lastExit = 1; fine.lastError = "curl: (7) 连不上"
        Jobs.writeReceipt(Jobs.Receipt(updatedAt: Date(), daemonPID: 1, version: VERSION, tasks: [("sync", fine)]), to: live.appendingPathComponent("jobs.json"))
        let (rcBad, jBad) = jobs(live)
        ok(rcBad == 1 && jBad["ok"] as? Bool == false && jBad["failing"] as? [String] == ["sync"],
           "有任务在失败应退出 1 并点名")
        ok(jobs(live, []).0 == 1 && jobs(live, ["--bogus"]).0 == 64, "文本模式同样退出 1；不认识的参数退出 64")

        var cfg = Config()
        let data = URL(fileURLWithPath: "/tmp/notihub-jobs-data")
        func specs(personal: Bool = true, cloud: Bool = true, isolated: Bool = false) -> [Jobs.Spec] {
            Jobs.specs(config: cfg, binary: "/A.app/Contents/Resources/bin/notihub", dataDir: data,
                       labelPrefix: personal ? "com.notifhub" : "com.notifhub.acme", personal: personal, cloudConfigured: cloud, isolated: isolated)
        }
        let all = specs()
        ok(all.map(\.name) == ["queue", "sync", "summarize"] && all.allSatisfy(\.enabled)
           && all.map { Int($0.interval) } == [60, 300, 3600]
           && all.map(\.arguments) == [["queue"], ["sync"], ["summarize", "--days", "2"]]
           && all.map { $0.legacyLabel ?? "" } == ["com.notifhub.queue", "com.notifhub.publish", "com.notifhub.summarize"],
           "个人实例应调度 queue/sync/summarize（60/300/3600 秒）并对应三个旧作业")
        ok(all[0].stdoutPath == nil && all[0].stderrPath == "/tmp/notihub-jobs-data/queue.err"
           && all[1].stdoutPath == "/tmp/notihub-jobs-data/cloud-sync.log" && all[1].stderrPath == "/tmp/notihub-jobs-data/cloud-sync.err"
           && all[2].stdoutPath == "/tmp/notihub-jobs-data/summary.log" && all[2].stderrPath == "/tmp/notihub-jobs-data/summary.err",
           "每条任务应继续写它原来的日志文件")
        ok(specs(isolated: true).allSatisfy { !$0.enabled },
           "NOTIFHUB_DATA_DIR 隔离时一条都不许调度（验收沙盒里的采集器会真去领单、真调 LLM）")
        let inst = specs(personal: false)
        ok(inst.filter(\.enabled).map(\.name) == ["sync"] && inst[1].legacyLabel == "com.notifhub.acme.publish",
           "独立实例应只调度 sync")
        ok(!specs(cloud: false)[1].enabled && specs(cloud: false)[0].enabled, "没有云同步配置时不调度 sync")
        cfg.jobs.disabled = ["summarize"]; cfg.jobs.syncSeconds = 5
        ok(specs().filter(\.enabled).map(\.name) == ["queue", "sync"] && specs()[1].interval == 30,
           "jobs.disabled 应停用指定任务；间隔下限 30 秒")
        cfg.jobs.enabled = false
        ok(specs().allSatisfy { !$0.enabled }, "jobs.enabled=false 应全部停用")
        cfg = Config(); cfg.summary.enabled = false
        ok(!specs()[2].enabled, "summary.enabled=false 时不调度总结")
        let disabled = Jobs.Scheduler(specs: specs(isolated: true), receiptURL: root.appendingPathComponent("off.json"),
                                      legacyLoaded: { _ in false }, now: t0)
        disabled.tick(now: t0)
        ok(disabled.running.isEmpty && disabled.states.values.allSatisfy { $0.state == "disabled" && $0.runs == 0 && $0.nextDueAt == nil },
           "停用的任务不该被拉起，回执里是 disabled")

        let old = try? JSONDecoder().decode(Config.self, from: Data(#"{"summary":{"enabled":true},"muteInViews":["mine"]}"#.utf8))
        ok(old?.jobs.enabled == true && old?.jobs.syncSeconds == 300 && old?.summary.provider == "" && old?.muteInViews == ["mine"],
           "没有 jobs 块的旧配置应回落默认值且不丢别的键")
        let part = try? JSONDecoder().decode(Config.self, from: Data(#"{"jobs":{"disabled":["queue"]},"summary":{"provider":"codex"}}"#.utf8))
        ok(part?.jobs.disabled == ["queue"] && part?.jobs.enabled == true && part?.summary.provider == "codex", "jobs 块缺键应逐项回落默认")
        var pc = Config(); pc.summary.provider = "codex"
        ok(LLM.providerOverride(config: pc, environment: [:]) == "codex"
           && LLM.providerOverride(config: pc, environment: ["NOTIFHUB_LLM_PROVIDER": "claude"]) == nil
           && LLM.providerOverride(config: Config(), environment: [:]) == nil,
           "summary.provider 应注入桥；环境里已给时不覆盖；没配时不注入")
        pc.summary.provider = "gpt"
        ok(LLM.providerOverride(config: pc, environment: [:]) == nil, "不认识的 provider 不该传给桥")
    }
}
