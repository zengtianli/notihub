import Foundation

enum Installer {

    static var labelPrefix: String { Instance.current?.labelPrefix ?? "com.notifhub" }
    static var label: String { labelPrefix + ".daemon" }
    static var publishLabel: String { labelPrefix + ".publish" }
    static var queueLabel: String { labelPrefix + ".queue" }


    struct Job {
        let label: String
        let plist: URL
        let content: [String: Any]
    }

    struct Link {
        let path: URL
        let target: URL
        let action: String   // create | update | keep | skip-regular-file
    }

    enum LinkState: Equatable {
        case missing
        case symlink(resolvedTo: String)   // 已解开的最终目标（悬空链给原始目标串）
        case regularFile                   // 普通文件/目录：一律不碰
    }

    struct Plan {
        let binary: URL
        let app: URL
        let instance: String?
        let jobs: [Job]
        let links: [Link]
        let untouchedJobs: [String]

        var json: [String: Any] {
            [
                "mode": "app",
                "binary": binary.path,
                "app": app.path,
                "instance": instance.map { $0 as Any } ?? NSNull(),
                "jobs": jobs.map { ["label": $0.label, "plist": $0.plist.path, "plist_content": $0.content] },
                "links": links.map { ["path": $0.path.path, "target": $0.target.path, "action": $0.action] },
                "untouched_jobs": untouchedJobs,
                "daemon_tasks": instance == nil ? ["queue", "sync", "summarize"] : ["sync"],
                "copies_binary": false,
                "resigns": false,
            ]
        }
    }

    static func plan(binary: URL, app: URL, instanceID: String?, labelPrefix: String,
                     instanceConfig: String?, dataDir: URL, launchAgentsDir: URL, binDir: URL,
                     linkState: (URL) -> LinkState) -> Plan {
        func job(_ kind: String, _ args: [String], _ extra: [String: Any]) -> Job {
            let l = "\(labelPrefix).\(kind)"
            var c: [String: Any] = [
                "Label": l,
                "ProgramArguments": [binary.path] + args,
                "RunAtLoad": true,
                "ProcessType": "Background",
                "LowPriorityIO": true,
                "StandardErrorPath": dataDir.appendingPathComponent("\(kind).err").path,
            ]
            for (k, v) in extra { c[k] = v }
            if let cfg = instanceConfig { c["EnvironmentVariables"] = ["NOTIFHUB_INSTANCE_CONFIG": cfg] }
            return Job(label: l, plist: launchAgentsDir.appendingPathComponent("\(l).plist"), content: c)
        }

        let jobs = [job("daemon", ["daemon"], ["KeepAlive": true])]

        var names = ["notihub", "notifhub"]
        if let id = instanceID { names.append("notifhub-\(id)") }
        let want = binary.resolvingSymlinksInPath().path
        let links = names.map { name -> Link in
            let p = binDir.appendingPathComponent(name)
            let action: String
            switch linkState(p) {
            case .missing: action = "create"
            case .regularFile: action = "skip-regular-file"
            case .symlink(let to): action = (to == want || to == binary.path) ? "keep" : "update"
            }
            return Link(path: p, target: binary, action: action)
        }

        let retired = (instanceID == nil ? ["queue"] : []) + ["publish", "summarize"]
        return Plan(binary: binary, app: app, instance: instanceID, jobs: jobs, links: links,
                    untouchedJobs: retired.map { "\(labelPrefix).\($0)" })
    }

    static func probeLink(_ url: URL) -> LinkState {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return .missing }
        guard (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else { return .regularFile }
        let resolved = url.resolvingSymlinksInPath()
        if fm.fileExists(atPath: resolved.path) { return .symlink(resolvedTo: resolved.path) }
        return .symlink(resolvedTo: (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "")
    }

    static func currentPlan() -> Plan? {
        guard let bin = Paths.appBinary else { return nil }
        return plan(binary: bin, app: Paths.bundle(ofAppBinary: bin),
                    instanceID: Instance.current?.id, labelPrefix: labelPrefix,
                    instanceConfig: Instance.current == nil ? nil : Instance.configURL.path,
                    dataDir: Paths.dataDir, launchAgentsDir: Paths.launchAgentsDir, binDir: Paths.binDir,
                    linkState: probeLink)
    }

    static let unavailableMessage =
        "找不到 Notihub.app 里的采集器（\(Paths.defaultAppBinary.path)）。先安装 Notihub.app，再运行 notihub install。"


    static func install(args: [String]) -> Int32 {
        let dryRun = args.contains("--dry-run")
        let asJSON = args.contains("--json")

        guard let plan = currentPlan() else {
            if dryRun && asJSON {
                printJSON(["mode": "unavailable", "error": unavailableMessage])
            } else {
                Log.err("❌ " + unavailableMessage)
            }
            return 2
        }

        if dryRun {
            if asJSON { printJSON(plan.json) } else { printPlan(plan) }
            return 0
        }

        let fm = FileManager.default
        Paths.ensureDataDir()   // StandardErrorPath 指向数据目录，目录得先在
        do {
            try fm.createDirectory(at: Paths.launchAgentsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: Paths.binDir, withIntermediateDirectories: true)
        } catch { Log.err("创建目录失败：\(error)"); return 1 }
        print("采集器：\(plan.binary.path)（在 \(plan.app.lastPathComponent) 里，不复制、不重签）")

        if !fm.fileExists(atPath: Paths.configFile.path) {
            try? Config().save()
            print("✅ 默认配置 \(Paths.configFile.path)")
        } else {
            print("✅ 配置已存在，不覆盖 \(Paths.configFile.path)")
        }

        var failed = 0
        for job in plan.jobs {
            let (ok, why) = installJob(job)
            print("\(ok ? "✅" : "❌") launchd \(job.label) \(ok ? "已加载" : "加载失败：\(why)")")
            if !ok { failed += 1 }
        }
        print("   接单 / 云同步 / 总结由采集器自己调度：notihub jobs 看每条任务的上次结果与下次到期")
        for old in plan.untouchedJobs where Jobs.launchdLoaded(old) {
            print("⚠️  旧作业 \(old) 还加载着：采集器不会调度对应任务（避免同一件事跑两遍）。")
            print("     退役它：launchctl bootout \(guiDomain)/\(old)，再把 \(Paths.launchAgentsDir.path)/\(old).plist 移走")
        }

        for link in plan.links {
            switch link.action {
            case "keep":
                print("✅ 软链 \(link.path.path) 已指向 App，保持")
            case "skip-regular-file":
                print("⚠️  skip \(link.path.path) 是普通文件（不是软链），不碰它；要换成 App 里那份请自己备份后删掉再重跑 install")
            default:
                do {
                    try atomicSymlink(at: link.path, to: link.target)
                    print("✅ 软链 \(link.path.path) → \(link.target.path)（\(link.action == "create" ? "新建" : "已更新")）")
                } catch {
                    print("❌ 软链 \(link.path.path) 失败：\(error)"); failed += 1
                }
            }
        }

        if Instance.personalFeatures {
            let (arc, _) = run("/usr/bin/osascript", ["-e", "tell application \"Reminders\" to return name of default list"],
                               timeout: 10)
            if arc == 0 {
                print("✅ 自动化授权已就绪（提醒事项）")
            } else {
                print("""
                ⚠️  控制「提醒事项」没跑通 —— 站上那个「⏰ 存进提醒事项」按钮现在点了会失败。
                   两种原因，现象一样（脚本挂住不返回），处理相反：
                   ① 授权弹窗没人点 → 终端手动跑一次 `notihub push <某个id>`，
                      弹出「notihub 想要控制提醒事项」时点**允许**。
                   ② 「提醒事项」App 自己卡住了（2026-08-16 实测碰到过：进程在、0% CPU、
                      AppleEvent 65s 不应答）→ 退出 Reminders 再打开。
                   分辨：⌘Tab 切到提醒事项，界面转圈/点不动 = ②，否则按 ① 走。
                   （不修也不会静默卡住：接单器 90s 超时会判 failed，并会自己发探针
                     分辨是 ① 还是 ②，把对的那句写进站上的失败提示。）
                """)
            }
        }

        let needsTCC = !fm.isReadableFile(atPath: Paths.chatDB.path)
        print("""

        ┌─ 还差一步：完全磁盘访问 ───────────────────────────
        │ TCC 认的是二进制本体，不是调它的终端，也不是软链。要把这个路径加进去：
        │   \(plan.binary.path)
        │ 系统设置 → 隐私与安全性 → 完全磁盘访问 → + → ⌘⇧G 粘贴上面的路径
        │ 加完跑 `notihub doctor` 确认采集源都 ✅
        │ 注意：采集器在 Notihub.app 里 —— 删除或移动 Notihub.app 就等于停止采集。
        └────────────────────────────────────────────────────
        """)
        if needsTCC {
            run("/usr/bin/open", ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
        }
        return failed == 0 ? 0 : 1
    }


    static func uninstall() {
        var gone: [String] = []
        for (l, p) in [(label, Paths.launchAgent), (queueLabel, Paths.queueAgent)] {
            bootout(l)
            if FileManager.default.fileExists(atPath: p.path) {
                try? FileManager.default.removeItem(at: p)
                gone.append(l)
            }
        }
        print("✅ 已卸载 launchd：\(gone.isEmpty ? "（本来就没有）" : gone.joined(separator: " + "))")
        for old in [publishLabel, "\(labelPrefix).summarize"] where Jobs.launchdLoaded(old) {
            print("   未动：旧作业 \(old) 还加载着（launchctl bootout \(guiDomain)/\(old) 可卸）")
        }
        print("   未动：~/.local/bin 下的 notihub / notifhub 软链、Notihub.app、数据 \(Paths.dataDir.path)（要删自己动手）")
    }


    static var guiDomain: String { "gui/\(getuid())" }

    @discardableResult
    static func bootout(_ label: String) -> Bool {
        run("/bin/launchctl", ["bootout", "\(guiDomain)/\(label)"]).0 == 0
    }

    static func installJob(_ job: Job) -> (Bool, String) {
        let target = "\(guiDomain)/\(job.label)"
        if run("/bin/launchctl", ["print", target]).0 == 0 {
            bootout(job.label)
            var gone = false
            for _ in 0..<50 {
                if run("/bin/launchctl", ["print", target]).0 != 0 { gone = true; break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            if !gone { return (false, "旧作业 10 秒内没卸掉，plist 未改") }
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: job.content, format: .xml, options: 0)
            try data.write(to: job.plist, options: .atomic)
        } catch { return (false, "写 plist 失败：\(error)") }
        run("/bin/launchctl", ["enable", target])
        let (rc, out) = run("/bin/launchctl", ["bootstrap", guiDomain, job.plist.path], stderrToo: true)
        return (rc == 0, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func atomicSymlink(at path: URL, to target: URL) throws {
        let tmp = path.deletingLastPathComponent().appendingPathComponent(".\(path.lastPathComponent).tmp-\(getpid())")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createSymbolicLink(atPath: tmp.path, withDestinationPath: target.path)
        if rename(tmp.path, path.path) != 0 {
            let e = errno
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
    }

    static func printJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    static func printPlan(_ plan: Plan) {
        print("安装计划（--dry-run，不做任何改动）")
        print("  采集器 \(plan.binary.path)")
        print("  App    \(plan.app.path)\(plan.instance.map { " · 实例 \($0)" } ?? "")")
        print("  不复制二进制、不重签")
        for j in plan.jobs {
            let args = (j.content["ProgramArguments"] as? [String] ?? []).joined(separator: " ")
            print("  作业 \(j.label) → \(j.plist.path)\n       \(args)")
        }
        for l in plan.links { print("  软链 \(l.path.path) → \(l.target.path)  [\(l.action)]") }
        print("  采集器自己调度：接单 / 云同步 / 总结（notihub jobs 查看）")
        print("  已退役、不写也不卸 \(plan.untouchedJobs.joined(separator: "、"))")
    }
}
