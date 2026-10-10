import Foundation


let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? "help"
let rest = Array(argv.dropFirst())

if LifecycleRelay.verbs.contains(cmd) { exit(LifecycleRelay.run(argv)) }
if cmd == "help", let sub = rest.first, LifecycleRelay.verbs.contains(sub) { exit(LifecycleRelay.run([sub, "--help"])) }

switch cmd {
case "help", "--help", "-h":
    if let sub = rest.first, let u = Help.usage(sub) { print(u) } else { print(Help.main) }
    exit(0)
default:
    if Help.requested(rest), let u = Help.usage(cmd) { print(u); exit(0) }
}
if ProcessInfo.processInfo.environment["NOTIHUB_HELP_PROBE"] != nil, Help.requested(rest) {
    Log.err("help probe: \(cmd) --help 没被截住"); exit(99)
}

switch cmd {

case "instance": exit(Instance.command(rest))

case "daemon":
    guard let d = Daemon() else { Log.err("初始化失败"); exit(1) }
    d.run()

case "once":
    guard let d = Daemon() else { exit(1) }
    d.ingest()
    d.markDismissed()
    print("已跑一轮采集")

case "day", "recap":  Recap.run(args: rest)
case "today":         exit(TodayCLI.today(rest))
case "mark-read":     exit(TodayCLI.markRead(rest))
case "cloud":         exit(CloudCLI.run(rest))
case "publish":       Publish.run(args: rest)
case "sync":          exit(CloudSync.run(rest))

case "summarize", "sum": Summarizer.run(args: rest)

case "add":     AgendaCLI.add(args: rest)
case "note":    AgendaCLI.note(args: rest)
case "agenda", "todo": AgendaCLI.list(args: rest)
case "done":    exit(AgendaCLI.setStatus(args: rest, status: "done"))
case "drop":    exit(AgendaCLI.setStatus(args: rest, status: "dropped"))
case "reopen":  exit(AgendaCLI.setStatus(args: rest, status: "open"))
case "push":    AppleExport.pushCLI(args: rest)
case "targets": AppleExport.targets()
case "queue":   exit(AgendaQueue.cmd(rest))
case "jobs":    exit(Jobs.cmd(rest))
case "status":  exit(CLI.status(args: rest))

case "tail":    CLI.tail(args: rest)
case "search":  CLI.search(args: rest)
case "stats":   CLI.stats(args: rest)
case "doctor":
    if rest.contains("--sources") { exit(CLI.doctorSources(json: rest.contains("--json"))) }
    let json = rest.contains("--json")
    let online = rest.contains("--online") || (!json && !rest.contains("--offline"))
    if Instance.current != nil && !json && online { exit(Instance.doctor()) }
    exit(CLI.doctor(online: online, json: json))

case "install":   exit(Installer.install(args: rest))
case "uninstall":
    guard rest.contains("--yes") else {
        Log.err("uninstall 会停掉常驻采集；确认请加 --yes（notihub uninstall --yes）"); exit(64)
    }
    Installer.uninstall()

case "rules":
    if rest.first == "init" {
        exit(Config.initDefault(force: rest.contains("--force")))
    } else if rest.first == "test", rest.count > 1 {
        let text = rest.dropFirst().joined(separator: " ")
        let cfg = Config.load()
        let e = Event(ts: nowUnix(), source: "test", bundle: "test.app", app: "测试",
                      title: "", subtitle: "", body: text, extID: "", recID: nil)
        let hits = Engine.match(e, config: cfg)
        if hits.isEmpty { print("没有规则命中") }
        for h in hits {
            print("命中规则 [\(h.rule.name)] → 动作 \(h.rule.actions.joined(separator: ","))"
                  + (h.code.map { " · 抽到验证码 \($0)" } ?? ""))
        }
    } else {
        let cfg = Config.load()
        print("配置文件: \(Paths.configFile.path)"
              + (FileManager.default.fileExists(atPath: Paths.configFile.path) ? "" : "（不存在，用内置默认）"))
        print("保留期 \(cfg.retentionDays) 天 · 复盘视图折叠 \(cfg.muteInViews.joined(separator: ","))")
        for r in cfg.rules {
            print("  [\(r.enabled ? "on " : "off")] \(r.name): apps=\(r.apps.isEmpty ? "全部" : r.apps.joined(separator: ","))"
                  + " kw=\(r.keywords.isEmpty ? "-" : r.keywords.joined(separator: "/"))"
                  + " → \(r.actions.joined(separator: ","))")
        }
        print("\n用法: notihub rules init | notihub rules test \"你的验证码是 123456\"")
    }

case "data":
    exit(DataCLI.run(rest))

case "__data-fixture":
    guard let dir = rest.first else { Log.err("用法: notihub __data-fixture <目录>"); exit(64) }
    do { print(try DataFixture.build(at: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)).path) }
    catch { Log.err("夹具生成失败: \(error)"); exit(1) }

case "__sync-payload":
    guard let path = rest.first else { Log.err("用法: notihub __sync-payload <文件>"); exit(64) }
    do {
        let body = try CloudSync.snapshot(instance: Instance.current?.id ?? "personal", database: Paths.db,
                                          site: Paths.dataDir.appendingPathComponent("site"), now: nowUnix()).body
        guard FileManager.default.createFile(atPath: (path as NSString).expandingTildeInPath, contents: body,
                                             attributes: [.posixPermissions: 0o600]) else { Log.err("写不了 \(path)"); exit(1) }
        print("\(body.count) 字节 → \(path)")
    } catch let f as CloudSync.Failure { Log.err(f.message); exit(f.code) } catch { Log.err("\(error)"); exit(1) }

case "__tzprobe":
    print(dayString(Double(rest.first ?? "") ?? nowUnix()))

case "selftest":
    exit(SelfTest.run(live: rest.contains("--live")) ? 0 : 1)

case "version", "--version", "-v":
    print("notihub \(VERSION)")

default:
    if rest.contains("--json") { CLI.jsonUsageFail("未知命令：\(cmd)（notihub --help 看全部命令）") }
    Log.err("未知命令：\(cmd)\n")
    Log.err(Help.main)
    exit(64)
}
