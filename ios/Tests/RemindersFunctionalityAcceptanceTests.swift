import XCTest
import Foundation
@testable import DayDeckCore

final class RemindersFunctionalityAcceptanceTests: XCTestCase {
    private typealias F = ReminderFixture
    private var savedDefaultZone: TimeZone!
    private let now = ReminderFixture.at("2026-09-08T20:00:00+08:00")

    override func setUp() {
        super.setUp()
        savedDefaultZone = NSTimeZone.default
    }
    override func tearDown() {
        NSTimeZone.default = savedDefaultZone
        super.tearDown()
    }

    private func useDeviceZone(_ id: String) {
        NSTimeZone.default = TimeZone(identifier: id)!
        XCTAssertEqual(NSTimeZone.default.identifier, id)
        XCTAssertEqual(Calendar.current.timeZone.identifier, id)
        XCTAssertEqual(Calendar(identifier: .gregorian).timeZone.identifier, id)
    }

    private func add(_ agenda: Agenda, _ store: ReminderTestStore, list: String? = nil,
                     force: Bool = false) async -> (outcome: AddOutcome, notice: String?) {
        await ReminderAdder.add(agenda: agenda, store: store, savedListID: list, timezone: F.cloud, force: force, now: now)
    }


    func testPlanTitleNotesMarkerAndURL() throws {
        let agenda = F.agenda()
        let inbox = ReminderListInfo(id: "list-inbox", title: "合成收件箱")
        let draft = ReminderPlan.make(agenda: agenda, timezone: F.cloud, list: inbox)
        let key = draft.key
        XCTAssertEqual(key.count, 16)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(key, ReminderPlan.key(for: agenda))
        XCTAssertEqual(draft.title, "合成待办：交季度材料")
        XCTAssertEqual(draft.notes, """
            带上合成复印件
            原文：合成原文：周二下午交材料
            来源：合成联系人
            抽自 2026-09-07 的复盘
            notihub:agenda/\(key)
            """)
        XCTAssertEqual(draft.notes.components(separatedBy: "\n").last, "notihub:agenda/\(key)")
        XCTAssertEqual(draft.url.absoluteString, "notihub://agenda/\(key)")
        XCTAssertEqual(draft.listID, "list-inbox")
        XCTAssertEqual(ReminderMarker.key(url: draft.url, notes: nil), key)
        XCTAssertEqual(ReminderMarker.key(url: nil, notes: draft.notes), key)

        let bare = F.agenda(note: nil, who: nil, evidence: nil, srcDate: nil)
        let bareDraft = ReminderPlan.make(agenda: bare, timezone: F.cloud, list: inbox)
        XCTAssertEqual(bareDraft.notes, "notihub:agenda/\(bareDraft.key)")
    }

    func testTimedItemHasCloudZoneMinutesAndAlarm() throws {
        let agenda = F.agenda()
        let draft = ReminderPlan.make(agenda: agenda, timezone: F.cloud, list: ReminderListInfo(id: "l", title: "L"))
        let due = try XCTUnwrap(draft.due)
        XCTAssertEqual([due.year, due.month, due.day, due.hour, due.minute], [2026, 9, 8, 14, 30])
        XCTAssertNil(due.second)
        XCTAssertEqual(due.timeZone?.identifier, "Asia/Shanghai")
        XCTAssertEqual(draft.alarm, agenda.due)
    }

    func testTimedItemAbsoluteDueSurvivesDeviceZoneDifferentFromCloud() async throws {
        useDeviceZone("America/Los_Angeles")
        let agenda = F.agenda()
        let store = ReminderTestStore()
        let result = await add(agenda, store)
        XCTAssertEqual(result.outcome, .added("合成收件箱"))
        let draft = try XCTUnwrap(store.savedDrafts.first)
        let due = try XCTUnwrap(draft.due)
        XCTAssertEqual([due.day, due.hour, due.minute], [8, 14, 30])
        XCTAssertEqual(due.timeZone?.identifier, "Asia/Shanghai")
        XCTAssertEqual(ReminderTestStore.absoluteDue(due), agenda.due)
        XCTAssertEqual(draft.alarm, agenda.due)
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.dueDate(in: Calendar.current), agenda.due)
        XCTAssertEqual(row.dueDate(in: F.cloudCalendar), agenda.due)
    }

    func testAllDayItemIsFloatingDateWithoutAlarm() throws {
        useDeviceZone("America/Los_Angeles")
        let agenda = F.agenda(dueTS: F.at("2026-09-08T00:00:00+08:00").timeIntervalSince1970, allDay: true)
        let draft = ReminderPlan.make(agenda: agenda, timezone: F.cloud, list: ReminderListInfo(id: "l", title: "L"))
        let due = try XCTUnwrap(draft.due)
        XCTAssertEqual([due.year, due.month, due.day], [2026, 9, 8])
        XCTAssertNil(due.hour)
        XCTAssertNil(due.minute)
        XCTAssertNil(due.timeZone)
        XCTAssertNil(draft.alarm)
    }

    func testNoDueAndEventUsesStart() throws {
        let list = ReminderListInfo(id: "l", title: "L")
        let undated = ReminderPlan.make(agenda: F.agenda(dueTS: nil), timezone: F.cloud, list: list)
        XCTAssertNil(undated.due)
        XCTAssertNil(undated.alarm)

        let start = F.at("2026-09-09T09:15:00+08:00")
        let event = F.agenda(kind: "event", title: "合成会议", dueTS: start.timeIntervalSince1970,
                             endTS: F.at("2026-09-09T11:45:00+08:00").timeIntervalSince1970)
        let draft = ReminderPlan.make(agenda: event, timezone: F.cloud, list: list)
        let due = try XCTUnwrap(draft.due)
        XCTAssertEqual([due.day, due.hour, due.minute], [9, 9, 15])
        XCTAssertEqual(draft.alarm, start)
    }


    func testURLMarkerHitBlocksAndForceWrites() async throws {
        let agenda = F.agenda()
        let store = ReminderTestStore()
        let key = ReminderPlan.key(for: agenda)
        store.seed(title: "别的标题也算（按标记）", notes: "手写备注", url: ReminderMarker.url(key), listID: "list-work")
        let blocked = await add(agenda, store)
        XCTAssertEqual(blocked.outcome, .alreadyThere("合成工作"))
        XCTAssertFalse(blocked.outcome.isAdded)
        XCTAssertEqual(store.saveCalls, 0)

        let forced = await add(agenda, store, force: true)
        XCTAssertEqual(forced.outcome, .added("合成收件箱"))
        XCTAssertEqual(store.saveCalls, 1)
        XCTAssertEqual(store.rows.count, 2)
    }

    func testNotesOnlyMarkerHitBlocksWhenURLIsNotReadBack() async throws {
        let agenda = F.agenda()
        let store = ReminderTestStore()
        store.dropURLOnSave = true
        let first = await add(agenda, store)
        XCTAssertEqual(first.outcome, .added("合成收件箱"))
        XCTAssertNil(store.rows.first?.url)
        XCTAssertEqual(store.rows.first?.notihubKey, ReminderPlan.key(for: agenda))

        let second = await add(agenda, store)
        XCTAssertEqual(second.outcome, .alreadyThere("合成收件箱"))
        XCTAssertEqual(store.saveCalls, 1)
        let forced = await add(agenda, store, force: true)
        XCTAssertEqual(forced.outcome, .added("合成收件箱"))
        XCTAssertEqual(store.saveCalls, 2)
    }

    func testCompletedMarkerOnlyWithinThirtyDays() async throws {
        let agenda = F.agenda()
        let key = ReminderPlan.key(for: agenda)
        let recent = ReminderTestStore()
        recent.seed(title: agenda.title, notes: ReminderMarker.noteLine(key), completedAt: now.addingTimeInterval(-10 * 86_400))
        let hit = await add(agenda, recent)
        XCTAssertEqual(hit.outcome, .alreadyThere("合成收件箱"))

        let old = ReminderTestStore()
        old.seed(title: agenda.title, notes: ReminderMarker.noteLine(key), completedAt: now.addingTimeInterval(-40 * 86_400))
        let miss = await add(agenda, old)
        XCTAssertEqual(miss.outcome, .added("合成收件箱"))
    }

    func testMacPushedSameTitleSameCloudDayIsBlocked() async throws {
        useDeviceZone("America/Los_Angeles")
        let agenda = F.agenda(dueTS: F.at("2026-09-08T15:30:00+08:00").timeIntervalSince1970, pushed: true)
        let mac = ReminderTestStore()
        mac.seed(title: agenda.title, notes: "带上合成复印件\n抽自 2026-09-07 的复盘",
                 due: F.zoned(F.at("2026-09-08T14:30:00+08:00")))
        let blocked = await add(agenda, mac)
        XCTAssertEqual(blocked.outcome, .alreadyThere("合成收件箱"))
        XCTAssertEqual(mac.saveCalls, 0)

        let notPushed = F.agenda(dueTS: agenda.dueTS, pushed: false)
        let written = await add(notPushed, mac)
        XCTAssertEqual(written.outcome, .added("合成收件箱"))

        let otherDay = ReminderTestStore()
        otherDay.seed(title: agenda.title, due: F.zoned(F.at("2026-09-09T14:30:00+08:00")))
        let otherDayResult = await add(agenda, otherDay)
        XCTAssertEqual(otherDayResult.outcome, .added("合成收件箱"))
    }

    func testChangedIDIsSameThingButDifferentTitleOrDateIsNot() async throws {
        let store = ReminderTestStore()
        let original = F.agenda(id: 101)
        let first = await add(original, store)
        XCTAssertEqual(first.outcome, .added("合成收件箱"))

        let renumbered = F.agenda(id: 999)
        XCTAssertEqual(ReminderPlan.key(for: renumbered), ReminderPlan.key(for: original))
        let dup = await add(renumbered, store)
        XCTAssertEqual(dup.outcome, .alreadyThere("合成收件箱"))

        let retitled = F.agenda(id: 101, title: "合成待办：交年度材料")
        let titled = await add(retitled, store)
        XCTAssertEqual(titled.outcome, .added("合成收件箱"))

        let redated = F.agenda(id: 101, dueTS: F.at("2026-09-10T14:30:00+08:00").timeIntervalSince1970)
        let dated = await add(redated, store)
        XCTAssertEqual(dated.outcome, .added("合成收件箱"))

        let redatedPushed = F.agenda(id: 5, dueTS: F.at("2026-09-11T14:30:00+08:00").timeIntervalSince1970, pushed: true)
        let pushedOtherDay = await add(redatedPushed, store)
        XCTAssertEqual(pushedOtherDay.outcome, .added("合成收件箱"))
        XCTAssertEqual(store.saveCalls, 4)
    }


    func testDeletedSavedListFallsBackToDefaultWithNotice() async throws {
        let store = ReminderTestStore()
        let kept = ReminderListChoice.resolve(savedID: "list-work", lists: store.lists(), default: store.defaultList())
        XCTAssertEqual(kept.list?.id, "list-work")
        XCTAssertNil(kept.notice)
        let unset = ReminderListChoice.resolve(savedID: nil, lists: store.lists(), default: store.defaultList())
        XCTAssertEqual(unset.list?.id, "list-inbox")
        XCTAssertNil(unset.notice)

        store.deleteList(id: "list-work")
        let fallback = ReminderListChoice.resolve(savedID: "list-work", lists: store.lists(), default: store.defaultList())
        XCTAssertEqual(fallback.list?.id, "list-inbox")
        let notice = try XCTUnwrap(fallback.notice)
        XCTAssertTrue(notice.contains("合成收件箱"), notice)

        let result = await add(F.agenda(), store, list: "list-work")
        XCTAssertEqual(result.outcome, .added("合成收件箱"))
        XCTAssertNotNil(result.notice)
        XCTAssertEqual(store.savedDrafts.last?.listID, "list-inbox")
    }


    func testDayQueryMidnightBoundariesAndMarkers() async throws {
        useDeviceZone("America/Los_Angeles")
        let store = ReminderTestStore()
        let key = "0123456789abcdef"
        let lastMinute = store.seed(title: "云端 23:59 到期", url: ReminderMarker.url(key),
                                    due: F.zoned(F.at("2026-09-08T23:59:00+08:00")))
        store.seed(title: "次日 00:00 到期", due: F.zoned(F.at("2026-09-09T00:00:00+08:00")))
        let firstMinute = store.seed(title: "当天 00:00 到期", notes: "手写\nnotihub:agenda/\(key)",
                                     due: F.zoned(F.at("2026-09-08T00:00:00+08:00")))
        store.seed(title: "前一天 23:59 到期", due: F.zoned(F.at("2026-09-07T23:59:00+08:00")))
        let allDay = store.seed(title: "全天 9/8", due: DateComponents(year: 2026, month: 9, day: 8))
        store.seed(title: "全天 9/9", due: DateComponents(year: 2026, month: 9, day: 9))
        store.seed(title: "没有到期")
        let doneLate = store.seed(title: "云端 23:59:59 完成", completedAt: F.at("2026-09-08T23:59:59+08:00"))
        store.seed(title: "次日 00:00 完成", completedAt: F.at("2026-09-09T00:00:00+08:00"))
        store.seed(title: "前一天 23:59 完成", completedAt: F.at("2026-09-07T23:59:00+08:00"))
        store.seed(title: "当天到期但别天完成", due: F.zoned(F.at("2026-09-08T10:00:00+08:00")),
                   completedAt: F.at("2026-09-10T09:00:00+08:00"))

        let state = await ReminderDay.fetch(date: "2026-09-08", calendar: F.cloudCalendar, store: store)
        guard case .loaded(let rows) = state else { return XCTFail("expected loaded, got \(state)") }
        XCTAssertEqual(Set(rows.map(\.id)), [lastMinute.id, firstMinute.id, allDay.id, doneLate.id],
                       rows.map(\.title).joined(separator: " / "))
        XCTAssertEqual(rows.last?.id, doneLate.id)
        let order = rows.map(\.id)
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: firstMinute.id)), try XCTUnwrap(order.firstIndex(of: lastMinute.id)))
        let marked = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.addedByNotihub) })
        XCTAssertEqual(marked[lastMinute.id], true)   // url 标记
        XCTAssertEqual(marked[firstMinute.id], true)  // 仅备注末行标记
        XCTAssertEqual(marked[allDay.id], false)
        XCTAssertEqual(marked[doneLate.id], false)
        XCTAssertEqual(rows.first { $0.id == firstMinute.id }?.notihubKey, key)

        let next = await ReminderDay.fetch(date: "2026-09-09", calendar: F.cloudCalendar, store: store)
        guard case .loaded(let nextRows) = next else { return XCTFail("expected loaded, got \(next)") }
        XCTAssertEqual(Set(nextRows.map(\.title)), ["次日 00:00 到期", "全天 9/9", "次日 00:00 完成"])

        let quiet = await ReminderDay.fetch(date: "2026-08-01", calendar: F.cloudCalendar, store: store)
        XCTAssertEqual(quiet, .empty)
    }

    func testMarkerParsingRejectsForeignURLsAndNonFinalLines() {
        XCTAssertNil(ReminderMarker.key(url: URL(string: "https://agenda/0123456789abcdef"), notes: nil))
        XCTAssertNil(ReminderMarker.key(url: nil, notes: "notihub:agenda/0123456789abcdef\n之后又手写了一行"))
        XCTAssertNil(ReminderMarker.key(url: nil, notes: nil))
        XCTAssertEqual(ReminderMarker.key(url: nil, notes: "a\nnotihub:agenda/0123456789abcdef\n"), "0123456789abcdef")
    }


    func testNotDeterminedStateAndRequestOutcomes() async throws {
        let refused = ReminderTestStore(auth: .notDetermined, grantOnRequest: false)
        let section = await ReminderDay.fetch(date: "2026-09-08", calendar: F.cloudCalendar, store: refused)
        XCTAssertEqual(section, .notDetermined)
        XCTAssertTrue(refused.fetchCalls.isEmpty)
        XCTAssertEqual(refused.requestCalls, 0, "读小节不能弹授权")

        let refusedResult = await add(F.agenda(), refused)
        guard case .denied(let reason) = refusedResult.outcome else { return XCTFail("\(refusedResult.outcome)") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(refused.requestCalls, 1)
        XCTAssertEqual(refused.saveCalls, 0)
        XCTAssertTrue(refused.rows.isEmpty)

        let granted = ReminderTestStore(auth: .notDetermined, grantOnRequest: true)
        let grantedResult = await add(F.agenda(), granted)
        XCTAssertEqual(grantedResult.outcome, .added("合成收件箱"))
        XCTAssertEqual(granted.requestCalls, 1)
        XCTAssertEqual(granted.saveCalls, 1)
        let after = await ReminderDay.fetch(date: "2026-09-08", calendar: F.cloudCalendar, store: granted)
        guard case .loaded(let rows) = after else { return XCTFail("expected loaded, got \(after)") }
        XCTAssertEqual(rows.map(\.title), ["合成待办：交季度材料"])
        XCTAssertTrue(rows[0].addedByNotihub)
    }

    func testDeniedNeverPromptsReadsOrWrites() async throws {
        let store = ReminderTestStore(auth: .denied("合成拒绝原因"))
        store.seed(title: "拒绝时不该被读到", due: F.zoned(F.at("2026-09-08T10:00:00+08:00")))
        let section = await ReminderDay.fetch(date: "2026-09-08", calendar: F.cloudCalendar, store: store)
        XCTAssertEqual(section, .denied("合成拒绝原因"))
        let result = await add(F.agenda(), store)
        XCTAssertEqual(result.outcome, .denied("合成拒绝原因"))
        let forced = await add(F.agenda(), store, force: true)
        XCTAssertEqual(forced.outcome, .denied("合成拒绝原因"))
        XCTAssertEqual(store.saveCalls, 0)
        XCTAssertEqual(store.requestCalls, 0)
        XCTAssertTrue(store.fetchCalls.isEmpty)
        XCTAssertEqual(store.rows.count, 1)
    }

    func testFullAccessStatesAndOutcomes() async throws {
        let store = ReminderTestStore()
        let empty = await ReminderDay.fetch(date: "2026-09-08", calendar: F.cloudCalendar, store: store)
        XCTAssertEqual(empty, .empty)
        let result = await add(F.agenda(), store)
        XCTAssertEqual(result.outcome, .added("合成收件箱"))
        XCTAssertTrue(result.outcome.isAdded)
        XCTAssertNil(result.notice)
        XCTAssertEqual(store.requestCalls, 0)
        let loaded = await ReminderDay.fetch(date: "2026-09-08", calendar: F.cloudCalendar, store: store)
        guard case .loaded(let rows) = loaded else { return XCTFail("expected loaded, got \(loaded)") }
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(AddOutcome.alreadyThere("x").isAdded)
        XCTAssertFalse(AddOutcome.denied("x").isAdded)
        XCTAssertFalse(AddOutcome.failed("x").isAdded)
    }

    @MainActor
    func testModelTracksSectionsOutcomesAndAccessRequest() async throws {
        let store = ReminderTestStore(auth: .notDetermined, grantOnRequest: true)
        store.seed(title: "合成已有提醒", due: F.zoned(F.at("2026-09-08T09:00:00+08:00")))
        let model = RemindersModel(store: store)
        XCTAssertEqual(model.auth, .notDetermined)
        await model.load(date: "2026-09-08", calendar: F.cloudCalendar)
        XCTAssertEqual(model.sections["2026-09-08"], .notDetermined)
        XCTAssertEqual(store.requestCalls, 0)

        await model.requestAccess()
        XCTAssertEqual(model.auth, .fullAccess)
        XCTAssertEqual(model.lists.map(\.id), ["list-inbox", "list-work"])
        XCTAssertEqual(model.defaultList?.id, "list-inbox")
        guard case .loaded(let rows) = model.sections["2026-09-08"] else {
            return XCTFail("access grant must reload the visible date")
        }
        XCTAssertEqual(rows.map(\.title), ["合成已有提醒"])

        let agenda = F.agenda()
        XCTAssertNil(model.outcome(for: agenda))
        let outcome = await model.add(agenda, savedListID: "list-work", timezone: F.cloud)
        XCTAssertEqual(outcome, .added("合成工作"))
        XCTAssertEqual(model.outcome(for: F.agenda(id: 777)), .added("合成工作"))
        XCTAssertTrue(model.adding.isEmpty)
        let again = await model.add(agenda, savedListID: "list-work", timezone: F.cloud)
        XCTAssertEqual(again, .alreadyThere("合成工作"))
        XCTAssertEqual(model.outcome(for: agenda), .alreadyThere("合成工作"))
    }
}
