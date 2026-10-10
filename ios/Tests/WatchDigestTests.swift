import XCTest
import Foundation
@testable import DayDeckCore

final class WatchDigestTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    private func item(_ ts: Double, _ who: String, missed: Bool, lines: [String] = ["合成正文"],
                      redacted: Bool = false) -> FeedItem {
        FeedItem(ts: ts, endTs: ts, app: "微信", who: who, lines: lines, missed: missed, redacted: redacted)
    }

    private func agenda(_ id: Int64, due: Double?) -> Agenda {
        Agenda(id: id, kind: "todo", title: "合成待办 \(id)", note: nil, dueTS: due, endTS: nil, allDay: false,
               who: nil, evidence: nil, status: "open", source: "llm", srcDate: nil, pushed: false)
    }

    private func day(_ items: [FeedItem], apps: [[String]] = [["微信", "5"], ["邮件", "x"], ["短信", "2"]]) -> FeedDay {
        FeedDay(date: "2026-10-02", total: 12, muted: 3, notes: 1, first: nil, last: nil, byHour: Array(repeating: 0, count: 24),
                apps: apps, whos: [["甲", "4"], ["乙", "3"], ["丙", "2"], ["丁", "1"]],
                summary: FeedSummary(headline: "合成一句话", text: "**合成**", generatedAt: 0),
                agenda: [], items: items,
                cloudNotes: [CloudNote(id: 1, text: "合成随手记", ts: 0, date: "2026-10-02")])
    }

    func testCountsComeFromTheSameDay() {
        let base = 1_791_000_000.0
        let items = [item(base, "甲", missed: false), item(base + 60, "乙", missed: true), item(base + 120, "丙", missed: true)]
        let digest = WatchDigest.make(day: day(items), open: [], timezone: tz, lastSync: nil)
        XCTAssertEqual(digest.total, 12)
        XCTAssertEqual(digest.events, 3)
        XCTAssertEqual(digest.unread, 2)
        XCTAssertEqual(digest.notes, 2, "本机随手记 + 云端随手记，与复盘页「随手记」同一个数")
        XCTAssertEqual(digest.headline, "合成一句话")
        XCTAssertEqual(digest.apps, [.init(name: "微信", count: 5), .init(name: "短信", count: 2)])
        XCTAssertEqual(digest.whos.map(\.name), ["甲", "乙", "丙"], "聊得最多最多 3 个")
    }

    func testTopPutsUnreadFirstThenNewestAndTrims() {
        let base = 1_791_000_000.0
        let long = String(repeating: "长", count: 120)
        var items = (0..<8).map { item(base + Double($0) * 60, "人\($0)", missed: false) }
        items.append(item(base - 600, "未读早", missed: true, lines: ["", "  \(long)  "]))
        items.append(item(base - 900, "抹除", missed: true, redacted: true))
        let digest = WatchDigest.make(day: day(items), open: [], timezone: tz, lastSync: nil)
        XCTAssertEqual(digest.top.count, WatchDigest.topLimit)
        XCTAssertEqual(digest.top.map(\.who), ["未读早", "抹除", "人7", "人6", "人5", "人4"])
        XCTAssertEqual(digest.top[0].line, String(repeating: "长", count: WatchDigest.lineLimit) + "…",
                       "第一行非空的那行，裁到 80 字")
        XCTAssertEqual(digest.top[1].line, "正文已按保留期抹除")
    }

    func testAgendaCountsUseTheTodayPageRules() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)   // 云端时区某天中午附近
        let startOfDay = calendar.startOfDay(for: now).timeIntervalSince1970
        let open = [agenda(1, due: startOfDay - 3600),          // 昨天 → 逾期
                    agenda(2, due: startOfDay + 3600),          // 今天已过 → 今天（不算逾期）
                    agenda(3, due: startOfDay + 86_400 + 60),   // 明天 → 之后
                    agenda(4, due: nil)]                        // 没定时间
        let digest = WatchDigest.make(day: day([]), open: open, timezone: tz, lastSync: nil, now: now)
        XCTAssertEqual(digest.overdue, AgendaBuckets.overdue(open, calendar: calendar, now: now).count)
        XCTAssertEqual(digest.dueToday, AgendaBuckets.dueToday(open, calendar: calendar, now: now).count)
        XCTAssertEqual(AgendaBuckets.overdue(open, calendar: calendar, now: now).map(\.id), [1])
        XCTAssertEqual(AgendaBuckets.dueToday(open, calendar: calendar, now: now).map(\.id), [2])
        XCTAssertEqual(AgendaBuckets.upcoming(open, calendar: calendar, now: now).map(\.id), [3])
        XCTAssertEqual(AgendaBuckets.undated(open).map(\.id), [4])
    }

    func testRoundTripTodayAndOrdering() throws {
        let digest = WatchDigest.make(day: day([item(1, "甲", missed: true)]), open: [], timezone: tz,
                                      lastSync: Date(timeIntervalSince1970: 100))
        let decoded = try JSONDecoder().decode(WatchDigest.self, from: JSONEncoder().encode(digest))
        XCTAssertEqual(decoded, digest)
        XCTAssertTrue(digest.isToday(Date(timeIntervalSince1970: 1_790_913_600)))
        XCTAssertTrue(digest.isToday(Date(timeIntervalSince1970: 1_790_913_600 + 11 * 3600 + 59 * 60)))
        XCTAssertFalse(digest.isToday(Date(timeIntervalSince1970: 1_790_913_600 + 12 * 3600)))
        let newer = WatchDigest.make(day: day([]), open: [], timezone: tz, lastSync: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(digest.isOlder(than: newer))
        XCTAssertFalse(newer.isOlder(than: digest), "转交顺序不保证：旧的不能盖掉新的")
    }

    func testDemoFeedDigestIsSynthetic() {
        let feed = DemoFeed.make()
        let digest = WatchDigest.make(day: feed.day, open: feed.open, timezone: feed.timezone,
                                      lastSync: feed.lastSync, now: feed.now)
        XCTAssertEqual(digest.unread, 2)
        XCTAssertEqual(digest.total, 46)
        XCTAssertTrue(digest.isToday(feed.now))
    }


    override func setUp() { super.setUp(); Remote.ui = nil }
    override func tearDown() { Remote.ui = nil; super.tearDown() }

    private func object(_ digest: WatchDigest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(digest)) as? [String: Any])
    }

    func testOnlyWatchCopyRidesWithTheDigestAndNothingWhenUnset() throws {
        let before = WatchDigest.make(day: day([]), open: [], timezone: tz, lastSync: nil)
        for unset in [nil, FeedUI(), FeedUI(copy: [:], vocab: [:], order: [], limits: [:]),
                      FeedUI(copy: ["today.empty": "只有 iPhone 页面用的键"], limits: ["poll_seconds": 30])] as [FeedUI?] {
            let digest = WatchDigest.make(day: day([]), open: [], timezone: tz, lastSync: nil, ui: unset)
            XCTAssertNil(digest.ui)
            XCTAssertEqual(digest, before)
            XCTAssertEqual(Set(try object(digest).keys), Set(try object(before).keys))
            XCTAssertNil(try object(digest)["ui"])
        }
        let ui = FeedUI(copy: ["watch.no_items": "今天很安静", "today.group.overdue": "拖着的",
                               "today.empty": "只有 iPhone 页面用的键", "watch.sync_at": "",
                               "watch.no_apps": String(repeating: "长", count: WatchDigest.carriedCopyLimit + 1)],
                        limits: ["stale_seconds": 7200, "poll_seconds": 30])
        let digest = WatchDigest.make(day: day([]), open: [], timezone: tz, lastSync: nil, ui: ui)
        XCTAssertEqual(digest.ui?.value?.copy, ["watch.no_items": "今天很安静", "today.group.overdue": "拖着的"],
                       "空串等于没写；超过 80 字的不带；别的页面的键不带")
        XCTAssertEqual(digest.ui?.value?.limits, ["stale_seconds": 7200])
        XCTAssertNotEqual(digest, before, "覆盖项变了摘要就不同，WatchLink 会重发")
    }

    func testWatchShowsCarriedCopyFromTheDecodedDigestAndDropsItWithTheNextOne() throws {
        let ui = FeedUI(copy: ["watch.no_items": "今天很安静", "watch.sync_at": "上次同步 {time}",
                               "watch.day_stale": "{date} 的（今天的没到）", "today.group.overdue": "拖着的"],
                        limits: ["stale_seconds": 7200])
        let sent = try JSONEncoder().encode(WatchDigest.make(day: day([]), open: [], timezone: tz, lastSync: nil, ui: ui))
        XCTAssertEqual(T("watch.no_items", "这天还没有通知"), "这天还没有通知")
        XCTAssertEqual(WatchDigest.staleAfter, 3 * 3600)

        Remote.ui = try JSONDecoder().decode(WatchDigest.self, from: sent).ui?.value
        XCTAssertEqual(T("watch.no_items", "这天还没有通知"), "今天很安静")
        XCTAssertEqual(T("watch.sync_at", "同步于 {time}", ["time": "09:30"]), "上次同步 09:30")
        XCTAssertEqual(T("watch.day_stale", "{date} · 今天的还没同步", ["date": "10月2日"]), "10月2日 的（今天的没到）")
        XCTAssertEqual(T("today.group.overdue", "逾期"), "拖着的")
        XCTAssertEqual(T("today.group.today", "今天"), "今天", "没写的键仍是自带的")
        XCTAssertEqual(WatchDigest.staleAfter, 7200)

        let next = try JSONEncoder().encode(WatchDigest.make(day: day([]), open: [], timezone: tz, lastSync: nil))
        Remote.ui = try JSONDecoder().decode(WatchDigest.self, from: next).ui?.value
        XCTAssertEqual(T("watch.no_items", "这天还没有通知"), "这天还没有通知")
        XCTAssertEqual(T("watch.sync_at", "同步于 {time}", ["time": "09:30"]), "同步于 09:30")
        XCTAssertEqual(T("watch.sync_never", "还没同步过"), "还没同步过")
        XCTAssertEqual(T("watch.no_apps", "这天没有按 App 的计数"), "这天没有按 App 的计数")
        XCTAssertEqual(T("watch.not_today", "今天的摘要还没同步"), "今天的摘要还没同步")
        XCTAssertEqual(T("watch.day_stale", "{date} · 今天的还没同步", ["date": "10月2日"]), "10月2日 · 今天的还没同步")
        XCTAssertEqual(WatchDigest.staleAfter, 3 * 3600)
    }

    func testBrokenCarriedCopyCostsOnlyTheCopy() throws {
        let good = WatchDigest.make(day: day([item(1, "甲", missed: true)]), open: [], timezone: tz,
                                    lastSync: Date(timeIntervalSince1970: 100))
        for broken in ["oops", 7, ["a", "b"], ["copy": ["a", "b"]], ["copy": ["watch.no_items": 5]],
                       ["limits": ["stale_seconds": "soon"]]] as [Any] {
            var body = try object(good)
            body["ui"] = broken
            let decoded = try JSONDecoder().decode(WatchDigest.self, from: JSONSerialization.data(withJSONObject: body))
            XCTAssertEqual(decoded.total, 12, "\(broken)")
            XCTAssertEqual(decoded.unread, 1, "\(broken)")
            XCTAssertEqual(decoded.top.first?.who, "甲", "\(broken)")
            XCTAssertNil(decoded.ui?.value, "\(broken)")
        }
        var body = try object(good)
        body["somethingNewer"] = ["x": 1]
        XCTAssertEqual(try JSONDecoder().decode(WatchDigest.self, from: JSONSerialization.data(withJSONObject: body)), good)
    }

    func testRedactedLineAndStaleWindowFollowTheBackend() {
        let redacted = [item(1, "抹除", missed: true, redacted: true)]
        XCTAssertEqual(WatchDigest.make(day: day(redacted), open: [], timezone: tz, lastSync: nil).top.first?.line,
                       "正文已按保留期抹除")
        Remote.ui = FeedUI(copy: ["watch.redacted": "正文已清理"], limits: ["stale_seconds": 5])
        XCTAssertEqual(WatchDigest.make(day: day(redacted), open: [], timezone: tz, lastSync: nil).top.first?.line,
                       "正文已清理")
        XCTAssertEqual(WatchDigest.staleAfter, 600, "写得离谱的数被夹到范围里")
        Remote.ui = FeedUI(limits: ["stale_seconds": 9_999_999])
        XCTAssertEqual(WatchDigest.staleAfter, 86_400)
    }
}
