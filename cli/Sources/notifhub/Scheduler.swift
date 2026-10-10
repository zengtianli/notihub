import Foundation

enum Jobs {

    static let schema = 1
    static var receiptURL: URL { Paths.dataDir.appendingPathComponent("jobs.json") }


    struct Spec {
        let name: String
        var executable: String
        var arguments: [String]
        var interval: TimeInterval
        var timeout: TimeInterval
        var stdoutPath: String?
        var stderrPath: String
        var legacyLabel: String?
        var enabled: Bool = true
        var disabledReason: String?
        var environment: [String: String] = [:]
    }

    static func specs(config: Config, binary: String, dataDir: URL, labelPrefix: String, personal: Bool,
                      cloudConfigured: Bool, isolated: Bool) -> [Spec] {
        let cfg = config.jobs
        func path(_ name: String) -> String { dataDir.appendingPathComponent(name).path }
        func make(_ name: String, _ args: [String], seconds: Int, timeout: TimeInterval, out: String?, err: String,
                  legacy: String, applicable: Bool, why: String) -> Spec {
            var s = Spec(name: name, executable: binary, arguments: args, interval: TimeInterval(max(30, seconds)),
                         timeout: timeout, stdoutPath: out.map(path), stderrPath: path(err),
                         legacyLabel: "\(labelPrefix).\(legacy)")
            if isolated {
                s.enabled = false; s.disabledReason = "数据目录被 NOTIFHUB_DATA_DIR 隔离，不调度任何任务"
            } else if !cfg.enabled {
                s.enabled = false; s.disabledReason = "rules.json 的 jobs.enabled=false"
            } else if cfg.disabled.contains(name) {
                s.enabled = false; s.disabledReason = "rules.json 的 jobs.disabled 里列了 \(name)"
            } else if !applicable {
                s.enabled = false; s.disabledReason = why
            }
            return s
        }
        return [
            make("queue", ["queue"], seconds: cfg.queueSeconds, timeout: 600, out: nil, err: "queue.err",
                 legacy: "queue", applicable: personal, why: "独立实例未连接个人共用队列"),
            make("sync", ["sync"], seconds: cfg.syncSeconds, timeout: 600, out: "cloud-sync.log", err: "cloud-sync.err",
                 legacy: "publish", applicable: cloudConfigured, why: "尚未连接云端（没有云同步配置）"),
            make("summarize", ["summarize", "--days", "2"], seconds: cfg.summarizeSeconds, timeout: 1800,
                 out: "summary.log", err: "summary.err", legacy: "summarize",
                 applicable: personal && config.summary.enabled,
                 why: personal ? "rules.json 的 summary.enabled=false" : "独立实例没有配置总结通路"),
        ]
    }

    static func liveSpecs(config: Config = Config.load()) -> [Spec] {
        let env = ProcessInfo.processInfo.environment
        let cloud = CloudConnection.configURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return specs(config: config, binary: Paths.selfExecutable?.path ?? Paths.installedBinary.path,
                     dataDir: Paths.dataDir, labelPrefix: Installer.labelPrefix, personal: Instance.personalFeatures,
                     cloudConfigured: cloud, isolated: env["NOTIFHUB_DATA_DIR"] != nil)
    }

    static func launchdLoaded(_ label: String) -> Bool {
        run("/bin/launchctl", ["print", "\(Installer.guiDomain)/\(label)"], timeout: 10).0 == 0
    }


    struct TaskState: Equatable {
        var command: [String] = []
        var interval = 0
        var timeout = 0
        var state = "idle"
        var stateReason: String?
        var pid: Int32?
        var runs = 0
        var lastStartedAt: Date?
        var lastFinishedAt: Date?
        var lastExit: Int32?
        var lastError: String?
        var lastSuccessAt: Date?
        var consecutiveFailures = 0
        var nextDueAt: Date?
        var log: String?
        var err: String?

        var json: [String: Any] {
            func opt(_ v: Any?) -> Any { v ?? NSNull() }
            return [
                "command": command, "interval": interval, "timeout": timeout,
                "state": state, "state_reason": opt(stateReason), "pid": opt(pid.map { Int($0) }), "runs": runs,
                "last_started_at": opt(lastStartedAt.map(Jobs.stamp)), "last_finished_at": opt(lastFinishedAt.map(Jobs.stamp)),
                "last_exit": opt(lastExit.map { Int($0) }), "last_error": opt(lastError),
                "last_success_at": opt(lastSuccessAt.map(Jobs.stamp)),
                "consecutive_failures": consecutiveFailures, "next_due_at": opt(nextDueAt.map(Jobs.stamp)),
                "log": opt(log), "err": opt(err),
            ]
        }

        init() {}
        init(json j: [String: Any]) {
            func date(_ k: String) -> Date? { (j[k] as? String).flatMap(Jobs.parseStamp) }
            command = j["command"] as? [String] ?? []
            interval = j["interval"] as? Int ?? 0
            timeout = j["timeout"] as? Int ?? 0
            state = j["state"] as? String ?? "idle"
            stateReason = j["state_reason"] as? String
            pid = (j["pid"] as? Int).map(Int32.init)
            runs = j["runs"] as? Int ?? 0
            lastStartedAt = date("last_started_at")
            lastFinishedAt = date("last_finished_at")
            lastExit = (j["last_exit"] as? Int).map(Int32.init)
            lastError = j["last_error"] as? String
            lastSuccessAt = date("last_success_at")
            consecutiveFailures = j["consecutive_failures"] as? Int ?? 0
            nextDueAt = date("next_due_at")
            log = j["log"] as? String
            err = j["err"] as? String
        }
    }

    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        f.timeZone = Clock.tz
        return f
    }
    static func stamp(_ d: Date) -> String { formatter().string(from: d) }
    static func parseStamp(_ s: String) -> Date? { formatter().date(from: s) }

    struct Receipt {
        var updatedAt: Date
        var daemonPID: Int32
        var version: String
        var tasks: [(name: String, state: TaskState)]
    }

    static func readReceipt(_ url: URL) -> Receipt? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["schema"] as? Int == schema,
              let updated = (obj["updated_at"] as? String).flatMap(parseStamp),
              let tasks = obj["tasks"] as? [String: Any] else { return nil }
        let order = obj["order"] as? [String] ?? tasks.keys.sorted()
        return Receipt(updatedAt: updated, daemonPID: Int32(obj["daemon_pid"] as? Int ?? 0),
                       version: obj["version"] as? String ?? "",
                       tasks: order.compactMap { n in (tasks[n] as? [String: Any]).map { (n, TaskState(json: $0)) } })
    }

    static func writeReceipt(_ r: Receipt, to url: URL) {
        var tasks: [String: Any] = [:]
        for (n, s) in r.tasks { tasks[n] = s.json }
        let obj: [String: Any] = ["schema": schema, "updated_at": stamp(r.updatedAt), "daemon_pid": Int(r.daemonPID),
                                  "version": r.version, "order": r.tasks.map(\.name), "tasks": tasks]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }


    static func status(_ s: TaskState, now: Date) -> String {
        if s.state == "disabled" { return "disabled" }
        if s.state == "deferred" { return "deferred" }
        if s.state == "running" {
            if let t = s.lastStartedAt, now.timeIntervalSince(t) > Double(s.timeout) + 60 { return "overdue" }
            return s.consecutiveFailures > 0 ? "failing" : "running"
        }
        if s.consecutiveFailures > 0 { return "failing" }
        if let due = s.nextDueAt, now.timeIntervalSince(due) > max(120, Double(s.interval)) { return "overdue" }
        if s.nextDueAt == nil { return "overdue" }
        return s.lastStartedAt == nil ? "pending" : "ok"
    }

    static func isBad(_ status: String) -> Bool { status == "failing" || status == "overdue" }


    static func spawn(_ spec: Spec) -> (pid: pid_t, errno: Int32) {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        let append = O_WRONLY | O_CREAT | O_APPEND
        posix_spawn_file_actions_addopen(&actions, 1, spec.stdoutPath ?? "/dev/null", append, 0o644)
        posix_spawn_file_actions_addopen(&actions, 2, spec.stderrPath, append, 0o644)

        var env = ProcessInfo.processInfo.environment
        for (k, v) in spec.environment { env[k] = v }
        let argv: [UnsafeMutablePointer<CChar>?] = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { free(p) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, spec.executable, &actions, &attr, argv, envp)
        return rc == 0 ? (pid, 0) : (0, rc)
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func lastLine(of path: String, from offset: UInt64) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let end = fh.seekToEndOfFile()
        guard end > offset else { return nil }
        fh.seek(toFileOffset: max(offset, end > 4096 ? end - 4096 : 0))
        let text = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return line.map { $0.truncated(200) }
    }

    static func fileSize(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64) ?? 0
    }


    final class Scheduler {
        struct Running {
            let pid: pid_t
            let started: Date
            let errOffset: UInt64
            let adopted: Bool
            var termSentAt: Date?
            var killSent = false
        }

        private(set) var specs: [Spec]
        private(set) var states: [String: TaskState] = [:]
        private(set) var running: [String: Running] = [:]
        let receiptURL: URL
        let legacyLoaded: (String) -> Bool
        let killGrace: TimeInterval
        let stagger: TimeInterval
        private var dirty = false

        init(specs: [Spec], receiptURL: URL, legacyLoaded: @escaping (String) -> Bool,
             killGrace: TimeInterval = 5, stagger: TimeInterval = 3, now: Date = Date()) {
            self.specs = specs
            self.receiptURL = receiptURL
            self.legacyLoaded = legacyLoaded
            self.killGrace = killGrace
            self.stagger = stagger
            if let old = Jobs.readReceipt(receiptURL) {
                for (name, state) in old.tasks { states[name] = state }
            }
            for spec in specs { restore(spec, now: now) }
            dirty = true
        }

        private func restore(_ spec: Spec, now: Date) {
            var s = states[spec.name] ?? TaskState()
            if s.state == "running", let pid = s.pid, let started = s.lastStartedAt {
                if Jobs.alive(pid), Jobs.executablePath(of: pid) == spec.executable {
                    running[spec.name] = Running(pid: pid, started: started, errOffset: Jobs.fileSize(spec.stderrPath), adopted: true)
                } else {
                    s.state = "idle"; s.pid = nil
                    s.lastFinishedAt = now; s.lastExit = nil
                    s.lastError = "采集器重启时这一轮正在跑，结果未知；已安排补跑"
                    s.nextDueAt = now
                    Log.write("jobs: \(spec.name) 上一轮在采集器重启时中断，安排补跑")
                }
            } else if s.state == "running" {
                s.state = "idle"; s.pid = nil
            }
            states[spec.name] = s
        }

        func update(specs new: [Spec]) { specs = new; dirty = true }

        var runningPIDs: [pid_t] { running.values.filter { !$0.adopted }.map(\.pid) }

        private func seed(_ spec: Spec, now: Date) -> Date {
            if let p = spec.stdoutPath,
               let m = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
               m <= now, m.addingTimeInterval(spec.interval) > now {
                return m.addingTimeInterval(spec.interval)
            }
            return now
        }

        @discardableResult
        func tick(now: Date = Date()) -> Date {
            reap(now: now)
            enforceTimeouts(now: now)
            var launched = false
            var moreDue = false
            for spec in specs {
                var s = states[spec.name] ?? TaskState()
                s.command = [URL(fileURLWithPath: spec.executable).lastPathComponent] + spec.arguments
                s.interval = Int(spec.interval); s.timeout = Int(spec.timeout)
                s.log = spec.stdoutPath; s.err = spec.stderrPath
                defer { if states[spec.name] != s { states[spec.name] = s; dirty = true } }
                if running[spec.name] != nil { continue }               // 不重入
                guard spec.enabled else {
                    s.state = "disabled"; s.stateReason = spec.disabledReason; s.nextDueAt = nil; s.pid = nil
                    continue
                }
                if s.state == "disabled" { s.state = "idle"; s.stateReason = nil }
                let fresh = s.nextDueAt == nil
                if fresh { s.nextDueAt = now }
                guard let due = s.nextDueAt, due <= now else { continue }
                if let legacy = spec.legacyLabel, legacyLoaded(legacy) {
                    if s.state != "deferred" { Log.write("jobs: \(spec.name) 不调度 —— launchd 作业 \(legacy) 还加载着") }
                    s.state = "deferred"
                    s.stateReason = "launchd 作业 \(legacy) 还加载着，由它运行；卸载后本任务自动接手"
                    s.nextDueAt = now.addingTimeInterval(min(spec.interval, 60))
                    continue
                }
                if s.state == "deferred" || fresh {
                    if s.state == "deferred" { Log.write("jobs: \(spec.name) 由采集器接手调度") }
                    s.state = "idle"; s.stateReason = nil
                    let first = seed(spec, now: now)
                    if first > now { s.nextDueAt = first; continue }
                }
                if launched { moreDue = true; continue }
                launched = true
                let offset = Jobs.fileSize(spec.stderrPath)
                let (pid, code) = Jobs.spawn(spec)
                s.runs += 1
                s.lastStartedAt = now
                s.nextDueAt = now.addingTimeInterval(spec.interval)
                if code != 0 {
                    finish(&s, spec: spec, now: now, exit: -1, error: "起不了子进程：\(String(cString: strerror(code)))（\(spec.executable)）")
                } else {
                    s.state = "running"; s.pid = pid; s.stateReason = nil
                    running[spec.name] = Running(pid: pid, started: now, errOffset: offset, adopted: false)
                }
            }
            flush(now: now)
            return nextWake(now: now, moreDue: moreDue)
        }

        private func reap(now: Date) {
            for spec in specs {
                guard let r = running[spec.name], var s = states[spec.name] else { continue }
                var code: Int32?
                if r.adopted {
                    guard !Jobs.alive(r.pid) || Jobs.executablePath(of: r.pid) != spec.executable else { continue }
                } else {
                    var info = siginfo_t()
                    guard waitid(P_PID, id_t(r.pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == r.pid else { continue }
                    if r.termSentAt != nil { killpg(r.pid, SIGKILL) }
                    var st: Int32 = 0
                    guard waitpid(r.pid, &st, 0) == r.pid else { continue }
                    let sig = st & 0x7f
                    code = sig == 0 ? (st >> 8) & 0xff : -sig
                }
                running[spec.name] = nil
                if r.adopted {
                    s.state = "idle"; s.pid = nil; s.lastFinishedAt = now; s.lastExit = nil
                    s.lastError = "这一轮跨过了采集器重启，退出码拿不到；已安排补跑"
                    s.nextDueAt = now
                } else if r.termSentAt != nil {
                    finish(&s, spec: spec, now: now, exit: code ?? -9,
                           error: "超时 \(Int(spec.timeout)) 秒，已结束整个进程组")
                } else if code == 0 {
                    finish(&s, spec: spec, now: now, exit: 0, error: nil)
                } else {
                    finish(&s, spec: spec, now: now, exit: code ?? -1,
                           error: Jobs.lastLine(of: spec.stderrPath, from: r.errOffset) ?? "退出码 \(code ?? -1)，stderr 没有输出")
                }
                states[spec.name] = s
                dirty = true
            }
        }

        private func finish(_ s: inout TaskState, spec: Spec, now: Date, exit: Int32, error: String?) {
            let wasFailing = s.consecutiveFailures > 0
            s.state = "idle"; s.pid = nil
            s.lastFinishedAt = now
            s.lastExit = exit
            if exit == 0 {
                s.lastError = nil; s.lastSuccessAt = now; s.consecutiveFailures = 0
                if wasFailing { Log.write("jobs: \(spec.name) 恢复正常") }
            } else {
                s.lastError = error
                s.consecutiveFailures += 1
                Log.write("jobs: \(spec.name) 失败 exit=\(exit)（连续 \(s.consecutiveFailures) 次）：\(error ?? "")")
            }
            let earliest = now.addingTimeInterval(min(spec.interval, 10))
            if let due = s.nextDueAt, due < earliest { s.nextDueAt = earliest }
        }

        private func enforceTimeouts(now: Date) {
            for spec in specs {
                guard var r = running[spec.name] else { continue }
                if let sent = r.termSentAt {
                    if !r.killSent, now.timeIntervalSince(sent) >= killGrace {
                        killpg(r.pid, SIGKILL); r.killSent = true
                        running[spec.name] = r
                    }
                } else if now.timeIntervalSince(r.started) >= spec.timeout {
                    Log.write("jobs: \(spec.name) 超时 \(Int(spec.timeout)) 秒，结束进程组 \(r.pid)")
                    killpg(r.pid, SIGTERM); r.termSentAt = now
                    running[spec.name] = r
                }
            }
        }

        private func nextWake(now: Date, moreDue: Bool) -> Date {
            var wake = now.addingTimeInterval(60)
            if moreDue { wake = min(wake, now.addingTimeInterval(stagger)) }
            for spec in specs {
                if let r = running[spec.name] {
                    let deadline = r.termSentAt.map { $0.addingTimeInterval(killGrace) } ?? r.started.addingTimeInterval(spec.timeout)
                    wake = min(wake, r.killSent ? now.addingTimeInterval(1) : deadline)
                    if r.adopted { wake = min(wake, now.addingTimeInterval(15)) }
                } else if spec.enabled, let due = states[spec.name]?.nextDueAt, due > now {
                    wake = min(wake, due)
                }
            }
            return max(wake, now.addingTimeInterval(1))
        }

        private func flush(now: Date) {
            guard dirty else { return }
            dirty = false
            let tasks = specs.map { (name: $0.name, state: states[$0.name] ?? TaskState()) }
            Jobs.writeReceipt(Receipt(updatedAt: now, daemonPID: getpid(), version: VERSION, tasks: tasks), to: receiptURL)
        }
    }


    final class Runner {
        private let queue = DispatchQueue(label: "notifhub.jobs", qos: .utility)
        private var scheduler: Scheduler?
        private var timer: DispatchSourceTimer?
        private var exits: [pid_t: DispatchSourceProcess] = [:]
        private var configStamp: Date?

        func start() {
            queue.async { [self] in
                Paths.ensureDataDir()
                let specs = Jobs.liveSpecs()
                configStamp = configModified()
                scheduler = Scheduler(specs: specs, receiptURL: Jobs.receiptURL, legacyLoaded: Jobs.launchdLoaded)
                let on = specs.filter(\.enabled).map(\.name)
                Log.write("jobs: 调度器启动，任务 \(on.isEmpty ? "无" : on.joined(separator: " / "))"
                          + (on.count == specs.count ? "" : "（停用 \(specs.filter { !$0.enabled }.map(\.name).joined(separator: " / "))）"))
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.setEventHandler { [weak self] in self?.wake() }
                t.schedule(wallDeadline: .now(), leeway: .milliseconds(100))
                t.resume()
                timer = t
            }
        }

        private func configModified() -> Date? {
            let files = [Paths.configFile.path] + (CloudConnection.configURL.map { [$0.path] } ?? [])
            let stamps = files.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
            guard !stamps.isEmpty else { return nil }
            return stamps.max()!.addingTimeInterval(Double(stamps.count) * 1e-3)
        }

        private func wake() {
            guard let scheduler else { return }
            let stamp = configModified()
            if stamp != configStamp { configStamp = stamp; scheduler.update(specs: Jobs.liveSpecs()) }
            let next = scheduler.tick(now: Date())
            var fresh = false
            for pid in scheduler.runningPIDs where exits[pid] == nil {
                let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
                src.setEventHandler { [weak self] in self?.wake() }
                src.resume()
                exits[pid] = src
                fresh = true
            }
            let live = Set(scheduler.runningPIDs)
            for (pid, src) in exits where !live.contains(pid) { src.cancel(); exits[pid] = nil }
            let delay = fresh ? 1 : max(1, next.timeIntervalSinceNow)
            timer?.schedule(wallDeadline: .now() + delay, leeway: .seconds(fresh ? 0 : 2))
        }
    }


    static func cmd(_ args: [String]) -> Int32 {
        let json = args.contains("--json")
        if let bad = args.first(where: { $0 != "--json" }) {
            let msg = "jobs 不认识的参数：\(bad)（notihub jobs --help）"
            if json { CLI.printJSON(["ok": false, "error": msg, "usageError": true]) }
            Log.err(msg); return 64
        }
        let url = receiptURL
        guard let r = readReceipt(url) else {
            let msg = "读不到后台任务回执 \(url.path)（采集器没在跑、版本早于 1.5.0，或文件损坏）"
            if json { CLI.printJSON(["ok": false, "error": msg, "path": url.path]) }
            Log.err("✗ \(msg)"); return 1
        }
        let now = Date()
        var tasks: [String: Any] = [:]
        var bad: [String] = []
        for (name, s) in r.tasks {
            let st = status(s, now: now)
            if isBad(st) { bad.append(name) }
            var j = s.json
            j["status"] = st
            tasks[name] = j
        }
        if json {
            CLI.printJSON(["ok": bad.isEmpty, "schema": schema, "path": url.path, "updated_at": stamp(r.updatedAt),
                           "daemon_pid": Int(r.daemonPID), "version": r.version, "order": r.tasks.map(\.name),
                           "failing": bad, "tasks": tasks])
            return bad.isEmpty ? 0 : 1
        }
        func ago(_ d: Date?) -> String {
            guard let d else { return "—" }
            let n = Int(now.timeIntervalSince(d))
            let a = abs(n)
            let text = a < 90 ? "\(a) 秒" : a < 5400 ? "\(a / 60) 分钟" : "\(a / 3600) 小时"
            return n >= 0 ? text + "前" : text + "后"
        }
        print("后台任务（采集器 pid \(r.daemonPID) · \(r.version) · 回执 \(ago(r.updatedAt))更新）")
        for (name, s) in r.tasks {
            let st = status(s, now: now)
            let icon = isBad(st) ? "❌" : (st == "ok" || st == "running") ? "✅" : "· "
            var line = "  \(icon) \(CLI.pad(name, 10))\(CLI.pad(st, 9))每 \(s.interval) 秒"
            if st == "disabled" || st == "deferred" {
                line += " · \(s.stateReason ?? "")"
            } else {
                line += " · 上次 \(ago(s.lastFinishedAt ?? s.lastStartedAt))"
                    + (s.lastExit.map { " exit \($0)" } ?? "") + " · 下次 \(ago(s.nextDueAt))"
                if s.consecutiveFailures > 0 { line += " · 连续失败 \(s.consecutiveFailures) 次" }
            }
            print(line)
            if let e = s.lastError { print("      ↳ \(e)") }
        }
        print(bad.isEmpty ? "全部正常。" : "❌ \(bad.joined(separator: "、")) 在失败或逾期（日志路径见 notihub jobs --json 的 log / err）。")
        return bad.isEmpty ? 0 : 1
    }
}
