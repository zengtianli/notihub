import Foundation

enum AppleExport {


    private static let reminderScript = #"""
    on run argv
        set t to item 1 of argv
        set b to item 2 of argv
        set hasDue to ((item 3 of argv) is "1")
        set lname to item 9 of argv
        set wantAlarm to ((item 10 of argv) is "1")
        tell application "Reminders"
            set props to {name:t, body:b}
            if hasDue then
                set d to current date
                set day of d to 1
                set year of d to ((item 4 of argv) as integer)
                set month of d to ((item 5 of argv) as integer)
                set day of d to ((item 6 of argv) as integer)
                set time of d to (((item 7 of argv) as integer) * hours + ((item 8 of argv) as integer) * minutes)
                if wantAlarm then
                    set props to props & {due date:d, remind me date:d}
                else
                    set props to props & {due date:d}
                end if
            end if
            if lname is "" then
                set r to make new reminder at end of default list with properties props
            else
                set r to make new reminder at end of list lname with properties props
            end if
            return id of r
        end tell
    end run
    """#

    private static let calendarScript = #"""
    on run argv
        set t to item 1 of argv
        set b to item 2 of argv
        set calName to item 13 of argv
        set isAllDay to ((item 14 of argv) is "1")
        set d1 to current date
        set day of d1 to 1
        set year of d1 to ((item 3 of argv) as integer)
        set month of d1 to ((item 4 of argv) as integer)
        set day of d1 to ((item 5 of argv) as integer)
        set time of d1 to (((item 6 of argv) as integer) * hours + ((item 7 of argv) as integer) * minutes)
        set d2 to current date
        set day of d2 to 1
        set year of d2 to ((item 8 of argv) as integer)
        set month of d2 to ((item 9 of argv) as integer)
        set day of d2 to ((item 10 of argv) as integer)
        set time of d2 to (((item 11 of argv) as integer) * hours + ((item 12 of argv) as integer) * minutes)
        tell application "Calendar"
            tell calendar calName
                if isAllDay then
                    set ev to make new event with properties {summary:t, start date:d1, end date:d2, description:b, allday event:true}
                else
                    set ev to make new event with properties {summary:t, start date:d1, end date:d2, description:b}
                end if
                return uid of ev
            end tell
        end tell
    end run
    """#

    private static func osa(_ script: String, _ argv: [String]) -> (Int32, String) {
        let (rc, out) = notifhub.run("/usr/bin/osascript", ["-"] + argv,
                                     stdin: script, stderrToo: true)
        return (rc, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func allDayEnd(_ start: Double) -> Double {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = displayTZ
        return cal.startOfDay(for: Date(timeIntervalSince1970: start)).timeIntervalSince1970
    }

    private static func parts(_ ts: Double) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = displayTZ
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute],
                                   from: Date(timeIntervalSince1970: ts))
        return [c.year, c.month, c.day, c.hour, c.minute].map { String($0 ?? 0) }
    }


    struct Result {
        var reminderID: String?
        var calendarID: String?
        var errors: [String] = []
        var skipped: [String] = []
    }

    static func pushOne(_ a: AgendaItem, to targets: Set<String>, listName: String,
                        calName: String, alarm: Bool, force: Bool, dryRun: Bool) -> Result {
        var res = Result()
        let note = [a.note, a.evidence.map { "原文：\($0)" }, a.who.map { "来源：\($0)" },
                    a.srcDate.map { "抽自 \($0) 的复盘" }]
            .compactMap { $0 }.joined(separator: "\n")

        if targets.contains("reminders") {
            if let rid = a.reminderID, !rid.isEmpty, !force {
                res.skipped.append("提醒事项：已推过（\(rid.suffix(12))），要重推加 --force")
            } else if dryRun {
                res.skipped.append("提醒事项：[dry-run] 列表「\(listName.isEmpty ? "默认" : listName)」"
                                   + (a.dueTS != nil ? " · \(a.whenText!)\(alarm ? " · 到点提醒" : "")" : " · 无到期"))
            } else {
                let p = a.dueTS.map(parts) ?? ["0", "0", "0", "0", "0"]
                let (rc, out) = osa(reminderScript,
                                    [a.title, note, a.dueTS != nil ? "1" : "0"] + p
                                    + [listName, alarm ? "1" : "0"])
                if rc == 0 && out.hasPrefix("x-apple-reminder://") { res.reminderID = out }
                else { res.errors.append("提醒事项写入失败 (rc=\(rc)): \(out.truncated(200))") }
            }
        }

        if targets.contains("calendar") {
            if let cid = a.calendarID, !cid.isEmpty, !force {
                res.skipped.append("日历：已推过（\(cid.prefix(8))…），要重推加 --force")
            } else if a.dueTS == nil {
                res.errors.append("日历：这条没有时间，日历事件必须有起止时刻（先 notihub add ... --due 或改用提醒事项）")
            } else if calName.isEmpty {
                res.errors.append("日历：还没指定写哪个日历。跑一次 `notihub push \(a.id) --cal <日历名>`，"
                                  + "之后会记住。可选日历：notihub targets")
            } else if dryRun {
                res.skipped.append("日历：[dry-run] 「\(calName)」 · \(a.whenText!)")
            } else {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = displayTZ
                let start = a.dueTS!
                let end: Double
                if a.allDay {
                    end = allDayEnd(start)
                } else {
                    end = a.endTS ?? (start + 3600)
                }
                let s = a.allDay
                    ? parts(cal.startOfDay(for: Date(timeIntervalSince1970: start)).timeIntervalSince1970)
                    : parts(start)
                let (rc, out) = osa(calendarScript,
                                    [a.title, note] + s + parts(end) + [calName, a.allDay ? "1" : "0"])
                if rc == 0 && !out.isEmpty && !out.contains("error") { res.calendarID = out }
                else { res.errors.append("日历写入失败 (rc=\(rc)): \(out.truncated(200))") }
            }
        }
        return res
    }


    static func push(items: [AgendaItem], args: [String], store: Store, config: Config) {
        let force = args.contains("--force")
        let dryRun = args.contains("--dry-run")
        let alarm = !args.contains("--no-alarm")
        let listName = CLI.strArg(args, "--list") ?? config.apple.remindersList
        var calName = CLI.strArg(args, "--cal") ?? config.apple.calendarName

        if let given = CLI.strArg(args, "--cal"), given != config.apple.calendarName, !dryRun {
            var c = config; c.apple.calendarName = given
            try? c.save()
            print("已记住默认日历「\(given)」（配置: \(Paths.configFile.path)）")
            calName = given
        }

        let explicitTo = CLI.strArg(args, "--to")
        var okCount = 0, failCount = 0

        for a in items {
            let targets: Set<String>
            switch explicitTo {
            case "both":      targets = ["reminders", "calendar"]
            case "calendar":  targets = ["calendar"]
            case "reminders": targets = ["reminders"]
            default:          targets = a.kind == "event" && a.dueTS != nil ? ["calendar"] : ["reminders"]
            }

            let res = pushOne(a, to: targets, listName: listName, calName: calName,
                              alarm: alarm, force: force, dryRun: dryRun)
            var marks: [String] = []
            if res.reminderID != nil { marks.append("提醒事项 ✓") }
            if res.calendarID != nil { marks.append("日历「\(calName)」✓") }
            if !marks.isEmpty {
                store.setAgendaPushed(a.id, reminderID: res.reminderID, calendarID: res.calendarID)
                okCount += 1
            }
            let head = "#\(a.id) \(a.title)" + (a.whenText.map { " · \($0)" } ?? "")
            print(marks.isEmpty ? head : "\(head)  → \(marks.joined(separator: " / "))")
            for s in res.skipped { print("     \(s)") }
            for e in res.errors { failCount += 1; Log.err("     ✗ \(e)") }
        }

        if !dryRun && okCount > 0 { Log.write("push: \(okCount) 条已推进苹果 app") }
        if failCount > 0 { exit(1) }
    }

    static func pushCLI(args: [String]) {
        guard let store = Store() else { exit(1) }
        let config = Config.load()
        let ids = args.compactMap { Int64($0) }
        let items: [AgendaItem]
        if args.contains("--all") {
            items = store.agenda(where: "status='open'")
        } else if !ids.isEmpty {
            items = ids.compactMap {
                let a = store.agendaItem(id: $0)
                if a == nil { Log.err("#\($0) 不存在") }
                return a
            }
        } else {
            Log.err("""
            用法: notihub push <id> [id...] | --all
                  [--to reminders|calendar|both] [--list 列表名] [--cal 日历名]
                  [--no-alarm] [--force] [--dry-run]
            不带 --to 时按类型分流：日程→日历，待办→提醒事项。
            先看有哪些条目: notihub agenda
            """)
            exit(2)
        }
        guard !items.isEmpty else { print("没有可推的条目"); return }
        push(items: items, args: args, store: store, config: config)
    }


    static func completeReminder(id: String) -> Bool {
        let script = #"""
        on run argv
            tell application "Reminders"
                set completed of (first reminder whose id is (item 1 of argv)) to true
                return "ok"
            end tell
        end run
        """#
        let (rc, out) = osa(script, [id])
        return rc == 0 && out == "ok"
    }

    static func echoArgv(_ s: String) -> String {
        let (_, out) = osa(#"""
        on run argv
            return item 1 of argv
        end run
        """#, [s])
        return out
    }

    static func targets() {
        let cfg = Config.load()
        let (rc1, cals) = osa(#"""
        on run argv
            tell application "Calendar" to return name of calendars as text
        end run
        """#, [])
        print("日历（Calendar.app）：")
        if rc1 == 0 && !cals.isEmpty {
            for c in cals.components(separatedBy: ", ") { print("  · \(c)") }
        } else {
            print("  拿不到（rc=\(rc1)）：\(cals.truncated(160))")
        }
        print("  当前默认: \(cfg.apple.calendarName.isEmpty ? "未设置（第一次推送时用 --cal 指定一次即可记住）" : cfg.apple.calendarName)")
        print("  ⚠ 订阅类日历（节假日 / Weather / Birthdays）是只读的，写进去会报错")

        let (rc2, def) = osa(#"""
        on run argv
            tell application "Reminders" to return name of default list
        end run
        """#, [])
        let (_, lists) = osa(#"""
        on run argv
            tell application "Reminders"
                set out to ""
                repeat with l in lists
                    set out to out & (name of l) & linefeed
                end repeat
                return out
            end tell
        end run
        """#, [])
        print("\n提醒事项（Reminders.app）：")
        print("  默认列表: \(rc2 == 0 && !def.isEmpty ? def : "拿不到（\(def.truncated(120))）")")
        let names = lists.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if names.isEmpty {
            print("  其它列表: 这台机器枚举不出来（Reminders 脚本接口返回空集），"
                  + "但 --list <名字> 依然能指定；不指定就进默认列表")
        } else {
            for n in names { print("  · \(n)") }
        }
        print("  当前默认: \(cfg.apple.remindersList.isEmpty ? "跟随 Reminders.app 的默认列表" : cfg.apple.remindersList)")
    }
}
