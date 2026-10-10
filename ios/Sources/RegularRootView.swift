import Charts
import SwiftUI

struct RegularRootView: View {
    @Environment(Store.self) private var store
    @Binding var tab: Int

    enum Pane: Int, CaseIterable, Identifiable {
        case today, recap, diary, connection
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .today: return "今天"
            case .recap: return "通知"
            case .diary: return "随手记"
            case .connection: return "连接"
            }
        }
        var icon: String {
            switch self {
            case .today: return "checklist"
            case .recap: return "bell"
            case .diary: return "square.and.pencil"
            case .connection: return "gearshape"
            }
        }
    }

    private var pane: Pane { Pane(rawValue: tab) ?? .today }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            switch pane {
            case .today: TodayBoard(openRecap: { tab = Pane.recap.rawValue })
            case .recap: RecapView().readableWidth(760)
            case .diary: DiaryView().readableWidth(720)
            case .connection: ConnectionView().readableWidth(640)
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding<Int?>(get: { tab }, set: { if let v = $0 { tab = v } })) {
            Section {
                ForEach(Pane.allCases) { p in
                    Label(p.title, systemImage: p.icon)
                        .badge(badge(p))
                        .tag(p.rawValue as Int?)
                }
            }
            Section("云端") { SyncStatusRow() }
        }
        .navigationTitle("Notihub")
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
    }

    private func badge(_ p: Pane) -> Int {
        switch p {
        case .today: return store.overdue.count + store.dueToday.count
        case .recap: return store.days[store.landingDate]?.items.filter(\.missed).count ?? 0
        default: return 0
        }
    }
}

private struct SyncStatusRow: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(store.indexError == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.indexError == nil ? "day.example.invalid" : store.indexError!.headline)
                    .font(.caption.weight(.medium))
                if let sync = store.lastSync {
                    HStack(spacing: 3) {
                        Text("最后同步").font(.caption2).foregroundStyle(.secondary)
                        StaleBadge(at: sync)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}


struct TodayBoard: View {
    @Environment(Store.self) private var store
    let openRecap: () -> Void
    @State private var search = UserDefaults.standard.string(forKey: "search") ?? ""

    private var date: String { store.landingDate }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                if geo.size.width >= 700 {
                    let listWidth = min(500, max(340, geo.size.width * 0.42))
                    HStack(spacing: 0) {
                        TodayList(search: search)
                            .frame(width: listWidth)
                        Divider().ignoresSafeArea(edges: .bottom)
                        DayColumn(date: date, narrow: geo.size.width - listWidth < 600, openRecap: openRecap)
                    }
                } else {
                    TodayList(search: search)
                }
            }
            .boardBackground()
            .navigationTitle("今天 · \(store.dueToday.count + store.overdue.count)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "搜索待办")
            .refreshable { await store.refresh() }
            .navigationDestination(for: Agenda.self) { AgendaDetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let at = store.openAt { StaleBadge(at: at) }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await store.refresh() } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .task(id: date) { await store.day(date) }
            .onChange(of: store.indexAt) { _, _ in Task { await store.day(date, force: true) } }
        }
    }
}

private struct DayColumn: View {
    @Environment(Store.self) private var store
    let date: String
    let narrow: Bool
    let openRecap: () -> Void

    private var day: FeedDay? { store.days[date] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let e = store.dayError[date] {
                    ErrorBlock(error: e, stale: store.dayAt[date]).boardCard()
                }
                if let d = day {
                    summary(d)
                    stats(d)
                    if narrow {
                        hours(d)
                        sources(d)
                    } else {
                        HStack(alignment: .top, spacing: 16) {
                            hours(d)
                            sources(d)
                        }
                    }
                    Button(action: openRecap) {
                        Label("看这天的完整时间线", systemImage: "list.bullet.rectangle")
                    }
                    .padding(.top, 2)
                } else if store.dayError[date] == nil {
                    Text("取数中…").font(.callout).foregroundStyle(.secondary).boardCard()
                }
            }
            .padding(20)
        }
    }

    private var dateLabel: String {
        guard date != store.displayToday else { return "今天" }
        return date   // 早上 notifhub 还没发布今天时，落在最近一天 —— 说清楚是哪天
    }

    private func summary(_ d: FeedDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这一天 · \(dateLabel)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let s = d.summary {
                Text(s.headline).font(.title3.weight(.semibold))
                MarkdownText(text: s.text)
            } else {
                Text(T("board.no_summary", "这天还没有生成总结，完整时间线里仍可查看通知与随手记。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .boardCard()
    }

    private func stats(_ d: FeedDay) -> some View {
        let unread = d.items.filter(\.missed).count
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: narrow ? 2 : 4),
                         spacing: 12) {
            tile("通知", "\(d.total)", "条")
            tile("合并后", "\(d.items.count)", "件事")
            tile("未读", "\(unread)", "件", tint: unread > 0 ? .orange : nil)
            tile("随手记", "\(d.notes + d.cloudNotes.count)", "条")
        }
    }

    private func tile(_ title: String, _ value: String, _ unit: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint ?? .primary)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .boardCard()
    }

    private func hours(_ d: FeedDay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("什么时候来的").font(.subheadline.weight(.semibold))
            Chart {
                ForEach(Array(d.byHour.enumerated()), id: \.offset) { hour, count in
                    BarMark(x: .value("时", String(hour)), y: .value("条", count), width: .ratio(0.7))
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(2)
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    if let h = value.as(String.self), ["0", "6", "12", "18"].contains(h) {
                        AxisValueLabel { Text("\(h)时") }
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 150)
        }
        .boardCard()
    }

    private func sources(_ d: FeedDay) -> some View {
        let apps = d.apps.compactMap { row -> (String, Int)? in
            row.count == 2 ? Int(row[1]).map { (row[0], $0) } : nil
        }.prefix(5)
        let top = max(1, apps.map(\.1).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("来自哪里").font(.subheadline.weight(.semibold))
            ForEach(Array(apps), id: \.0) { name, count in
                HStack(spacing: 8) {
                    Text(name).font(.callout).frame(width: 56, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(6, g.size.width * CGFloat(count) / CGFloat(top)))
                    }
                    .frame(height: 8)
                    Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                }
            }
            if let whos = whosLine(d) {
                Divider()
                Label(whos, systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
            }
        }
        .boardCard()
    }

    private func whosLine(_ d: FeedDay) -> String? {
        let parts = d.whos.prefix(3).compactMap { $0.count == 2 ? "\($0[0]) \($0[1])" : nil }
        return parts.isEmpty ? nil : "聊得最多：" + parts.joined(separator: " · ")
    }
}
