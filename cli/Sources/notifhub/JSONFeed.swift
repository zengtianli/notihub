import Foundation

enum JSONFeed {


    struct IndexDay: Codable {
        let date: String
        let total: Int          // 合并前的原始通知条数
        let merged: Int         // 合并后的「事」数
        let headline: String    // LLM 一句话；没总结时为空串
        let agendaOpen: Int     // 这天抽出来、还没做掉的条数
        let whos: [String]      // 联系人/来源，最多 4 个
        var aiMinutes: Int? = nil   // 这天 AI 协作总用时（分钟，全天去重）；没有就不出这个键
    }

    struct FeedIndex: Codable {
        let generatedAt: Double
        let days: [IndexDay]
    }

    struct FeedAgenda: Codable {
        let id: Int64
        let kind: String        // todo | event
        let title: String
        let note: String?
        let dueTS: Double?
        let endTS: Double?
        let allDay: Bool
        let who: String?
        let evidence: String?   // 从哪条通知抽出来的原文佐证
        let status: String      // open | done | dropped
        let source: String      // llm | manual
        let srcDate: String?
        let pushed: Bool        // 已经进过提醒事项/日历
    }

    struct FeedItem: Codable {
        let ts: Double
        let endTs: Double
        let app: String
        let who: String
        let lines: [String]
        let missed: Bool        // 至今没点开
        let redacted: Bool
    }

    struct FeedSummary: Codable {
        let headline: String
        let text: String
        let generatedAt: Double
    }

    struct FeedWorkRow: Codable {
        let project: String
        let minutes: Int
        let prompts: Int
        let first: Double?
        let last: Double?
        let tools: [[String]]   // [[工具名, 分钟]]，分钟转字符串，同 apps 的约定
    }

    struct FeedWork: Codable {
        let wallMinutes: Int    // 全天去重合计
        let idleMinutes: Int    // 间隔不超过这么多分钟算连续
        let prompts: Int
        let rows: [FeedWorkRow]
    }

    struct FeedDay: Codable {
        let date: String
        let total: Int
        let muted: Int
        let notes: Int
        let first: Double?
        let last: Double?
        let byHour: [Int]
        let apps: [[String]]    // [[名字, 次数]]，次数转字符串以免客户端两种类型
        let whos: [[String]]
        let summary: FeedSummary?
        let agenda: [FeedAgenda]
        let items: [FeedItem]
        var aiInputs: Int = 0
        var work: FeedWork? = nil
    }

    struct FeedOpen: Codable {
        let generatedAt: Double
        let items: [FeedAgenda]
    }


    static func agenda(_ a: AgendaItem) -> FeedAgenda {
        FeedAgenda(id: a.id, kind: a.kind, title: a.title, note: a.note,
                   dueTS: a.dueTS, endTS: a.endTS, allDay: a.allDay, who: a.who,
                   evidence: a.evidence, status: a.status, source: a.source,
                   srcDate: a.srcDate, pushed: a.pushedAt != nil)
    }

    static func day(_ d: Recap.Day) -> FeedDay {
        FeedDay(
            date: d.date, total: d.total, muted: d.muted, notes: d.notes,
            first: d.first, last: d.last, byHour: d.byHour,
            apps: d.apps.map { [$0.0, String($0.1)] },
            whos: d.whos.map { [$0.0, String($0.1)] },
            summary: d.summary.map { FeedSummary(headline: $0.headline, text: $0.text,
                                                 generatedAt: $0.generatedAt) },
            agenda: d.agenda.map(agenda),
            items: d.items.map { FeedItem(ts: $0.ts, endTs: $0.endTs, app: $0.app, who: $0.who,
                                          lines: $0.lines, missed: $0.missed, redacted: $0.redacted) },
            aiInputs: d.aiInputs,
            work: d.work.map(work))
    }

    static func work(_ w: AIWork.Day) -> FeedWork {
        FeedWork(wallMinutes: w.wallMinutes, idleMinutes: w.idleMinutes, prompts: w.prompts,
                 rows: w.rows.map { r in
                     FeedWorkRow(project: r.project, minutes: r.minutes, prompts: r.prompts,
                                 first: r.first > 0 ? r.first : nil, last: r.last > 0 ? r.last : nil,
                                 tools: r.byTool.map { [$0.0, String($0.1)] })
                 })
    }

    static let enc: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try enc.encode(value).write(to: url, options: .atomic)
    }

    static func emit(store: Store, dates: [String], days: [Recap.Day],
                     index: [IndexDay], outDir: URL) throws {
        precondition(dates.count == days.count, "dates 与 days 必须一一对应")
        guard !days.isEmpty else {
            throw NSError(domain: "JSONFeed", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有任何一天可写 —— 拒绝产出空的 feed"])
        }
        for d in days {
            try write(day(d), to: outDir.appendingPathComponent("\(d.date).json"))
        }
        try write(FeedIndex(generatedAt: nowUnix(), days: index),
                  to: outDir.appendingPathComponent("index.json"))

        let open = store.agenda(where: "status='open'", [], order: "COALESCE(due_ts, 1e18) ASC, id ASC")
        try write(FeedOpen(generatedAt: nowUnix(), items: open.map(agenda)),
                  to: outDir.appendingPathComponent("open.json"))
    }
}
