#if DEBUG
import Foundation


struct DemoFeed {
    let now: Date
    let timezone: TimeZone
    let open: [Agenda]
    let index: [IndexDay]
    let day: FeedDay
    let lastSync: Date

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "demo") }

    static func make(now: Date = Date()) -> DemoFeed {
        let tz = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let startOfToday = cal.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Double {
            let day = cal.date(byAdding: .day, value: dayOffset, to: startOfToday) ?? startOfToday
            return (cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day).timeIntervalSince1970
        }
        func dayString(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = tz
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        let today = dayString(now)
        let yesterday = dayString(now.addingTimeInterval(-86_400))

        func agenda(_ id: Int64, _ title: String, kind: String = "todo", due: Double?, allDay: Bool = false,
                    who: String? = nil, note: String? = nil, evidence: String? = nil,
                    status: String = "open", src: String? = nil, pushed: Bool = false) -> Agenda {
            Agenda(id: id, kind: kind, title: title, note: note, dueTS: due, endTS: nil, allDay: allDay,
                   who: who, evidence: evidence, status: status, source: "llm",
                   srcDate: src ?? today, pushed: pushed)
        }

        let open: [Agenda] = [
            agenda(901, "交季度报销单", due: at(-1, 18), who: "财务 · 小周",
                   evidence: "报销单周五下班前交齐哦，逾期就进下个月了", src: yesterday),
            agenda(902, "产品评审会", kind: "event", due: at(0, 15), who: "项目群",
                   evidence: "下午三点 3 号会议室过一下新版交互", pushed: true),
            agenda(903, "回复房东续租条款", due: at(0, 20), who: "房东",
                   evidence: "续租合同我改了两处，你今晚看下没问题就签"),
            agenda(904, "给妈妈寄生日礼物", due: nil, who: "家人群",
                   note: "上次说想要一个轻一点的保温杯"),
            agenda(905, "整理周报图表", due: nil, who: "自己"),
            agenda(906, "牙科复查", kind: "event", due: at(2, 10), who: "口腔诊所",
                   evidence: "您预约的复查在周六上午 10:00，请提前 10 分钟到"),
            agenda(907, "续费云服务器", due: at(5, 9), allDay: true, who: "云服务商",
                   evidence: "您的实例将于 5 天后到期，请及时续费")
        ]

        let items: [FeedItem] = [
            FeedItem(ts: at(0, 8, 12), endTs: at(0, 8, 12), app: "日历", who: "今日日程",
                     lines: ["15:00 产品评审会", "20:00 前回复续租条款"], missed: false, redacted: false),
            FeedItem(ts: at(0, 9, 5), endTs: at(0, 9, 41), app: "微信", who: "项目群",
                     lines: ["小林：新版交互稿已经放共享盘了", "阿杰：下午三点 3 号会议室过一下新版交互",
                             "小林：收到，我把问题清单也带上"], missed: false, redacted: false),
            FeedItem(ts: at(0, 10, 30), endTs: at(0, 10, 30), app: "短信", who: "快递柜",
                     lines: ["您的包裹已到小区东门快递柜，取件码 4821"], missed: true, redacted: false),
            FeedItem(ts: at(0, 11, 47), endTs: at(0, 12, 3), app: "微信", who: "房东",
                     lines: ["续租合同我改了两处，你今晚看下没问题就签", "主要是物业费那条和押金退还时间"],
                     missed: false, redacted: false),
            FeedItem(ts: at(0, 13, 20), endTs: at(0, 13, 20), app: "邮件", who: "云服务商",
                     lines: ["您的实例将于 5 天后到期，请及时续费"], missed: true, redacted: false),
            FeedItem(ts: at(0, 16, 45), endTs: at(0, 17, 2), app: "微信", who: "家人群",
                     lines: ["妈：周末回来吃饭吗", "爸：顺便把上次说的保温杯带回来看看"],
                     missed: false, redacted: false)
        ]
        let notes = [
            CloudNote(id: 801, text: "评审会结论：搜索入口挪到首页顶部，下周一前出第二版。", ts: at(0, 16, 10), date: today)
        ]
        let summary = FeedSummary(
            headline: "评审会定了新版交互，续租合同今晚要看",
            text: """
            **工作**：下午评审会通过新版交互，搜索入口挪到首页顶部，下周一前出第二版。

            **生活**：房东改了续租合同两处（物业费、押金退还时间），今晚 8 点前回复；快递已到东门快递柜。

            **提醒**：云服务器 5 天后到期；周六上午牙科复查。
            """,
            generatedAt: at(0, 17, 30))
        let agendaToday = open.filter { $0.srcDate == today }
            + [agenda(908, "取快递", due: at(0, 21), who: "快递柜", status: "done")]
        let day = FeedDay(date: today, total: 46, muted: 18, notes: 0,
                          first: at(0, 8, 12), last: at(0, 17, 2),
                          byHour: [0, 0, 0, 0, 0, 0, 0, 0, 3, 9, 4, 6, 2, 3, 1, 2, 7, 5, 0, 0, 0, 0, 0, 0],
                          apps: [["微信", "28"], ["邮件", "7"], ["短信", "6"], ["日历", "5"]],
                          whos: [["项目群", "14"], ["家人群", "9"], ["房东", "4"]],
                          summary: summary, agenda: agendaToday, items: items, cloudNotes: notes)

        let index = [
            IndexDay(date: today, total: 46, merged: items.count, headline: summary.headline,
                     agendaOpen: agendaToday.count, whos: ["项目群", "家人群", "房东"]),
            IndexDay(date: yesterday, total: 38, merged: 9, headline: "月底报销提醒，周末家庭聚餐定了",
                     agendaOpen: 1, whos: ["财务 · 小周", "家人群"])
        ]
        return DemoFeed(now: now, timezone: tz, open: open, index: index, day: day,
                        lastSync: now.addingTimeInterval(-120))
    }
}
#endif
