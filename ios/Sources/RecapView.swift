import SwiftUI

struct RecapView: View {
    @Environment(Store.self) private var store
    @State private var date = ""
    @State private var showPicker = false
    @State private var search = UserDefaults.standard.string(forKey: "search") ?? ""

    private var day: FeedDay? { store.days[date] }

    var body: some View {
        NavigationStack {
            List {
                if let e = store.dayError[date] {
                    Section { ErrorBlock(error: e, stale: store.dayAt[date]) }
                }
                if let at = store.dayAt[date], search.isEmpty {
                    Section {
                        LabeledContent("缓存更新") { StaleBadge(at: at) }
                        if let sync = store.lastSync { LabeledContent("最后同步") { StaleBadge(at: sync) } }
                    }
                }

                if let d = day, search.isEmpty {
                    if let s = d.summary {
                        Section("这一天") {
                            Text(s.headline).font(.headline)
                            MarkdownText(text: s.text)
                        }
                    } else {
                        Section {
                            Text(T("recap.no_summary", "这天还没有生成总结，下面仍可查看通知与随手记。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }

                    Section("这天抽出来的事 · \(d.agenda.count)") {
                        if d.agenda.isEmpty {
                            Text(T("recap.no_agenda", "没抽出时间节点")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(d.agenda) { a in
                                NavigationLink(value: a) {
                                    AgendaRow(item: a, tint: a.status == "open" ? .accentColor : .secondary)
                                }
                            }
                        }
                    }

                    Section("这天的数") {
                        LabeledContent("通知", value: "\(d.total) 条")
                        LabeledContent("合并后", value: "\(d.items.count) 件事")
                        if d.muted > 0 { LabeledContent("折叠的噪音", value: "\(d.muted) 条") }
                        LabeledContent("随手记", value: "\(d.notes + d.cloudNotes.count) 条")
                        if let who = d.whos.first, who.count == 2 {
                            LabeledContent("聊得最多", value: "\(who[0])（\(who[1]) 条）")
                        }
                    }
                }

                if search.isEmpty { ReminderDaySection(date: reminderDate) }

                if let d = day {
                    let shown = entries(d).filter(matches)
                    Section(search.isEmpty ? "时间线 · \(d.items.count + d.cloudNotes.count)" : "匹配 · \(shown.count)") {
                        if shown.isEmpty && !search.isEmpty {
                            Text(T("recap.no_match", "当天没有匹配的通知或笔记，试试其他关键词。")).font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(shown) { entry in
                            switch entry {
                            case .notification(let item): TimelineRow(item: item)
                            case .note(let note): CloudNoteRow(note: note)
                            }
                        }
                    }
                } else if store.dayError[date] == nil {
                    Section { Text("取数中…").font(.callout).foregroundStyle(.secondary) }
                }
            }
            .id(date)
            .navigationTitle(date.isEmpty ? "通知" : date)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Agenda.self) { AgendaDetailView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(prevDate == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(nextDate == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "calendar") }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索当天通知与笔记")
            .sheet(isPresented: $showPicker) { DayPicker(date: $date) }
            .task(id: date) { if !date.isEmpty { await store.day(date) } }
            .task(id: store.index.count) { if date.isEmpty { date = store.landingDate } }
            .onChange(of: store.indexAt) { _, _ in
                if !date.isEmpty { Task { await store.day(date, force: true) } }
            }
            .refreshable { if !date.isEmpty { await store.day(date, force: true) } }
        }
    }

    private var reminderDate: String { date.isEmpty ? store.displayToday : date }

    private var dates: [String] { store.index.map(\.date) }
    private var prevDate: String? {
        guard let i = dates.firstIndex(of: date) else { return dates.first }
        return i + 1 < dates.count ? dates[i + 1] : nil   // index 是新→旧
    }
    private var nextDate: String? {
        guard let i = dates.firstIndex(of: date), i > 0 else { return nil }
        return dates[i - 1]
    }
    private func step(_ n: Int) {
        if let d = n < 0 ? prevDate : nextDate { date = d }
    }
    private func matches(_ entry: RecapEntry) -> Bool {
        guard !search.isEmpty else { return true }
        switch entry {
        case .notification(let item):
            return ([item.app, item.who] + item.lines).joined(separator: " ").localizedCaseInsensitiveContains(search)
        case .note(let note):
            return note.text.localizedCaseInsensitiveContains(search)
        }
    }
    private func entries(_ day: FeedDay) -> [RecapEntry] {
        (day.items.map(RecapEntry.notification) + day.cloudNotes.map(RecapEntry.note)).sorted { $0.timestamp < $1.timestamp }
    }
}

struct DayPicker: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var date: String

    var body: some View {
        NavigationStack {
            List(store.index) { d in
                Button {
                    date = d.date; dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(d.date).font(.callout.weight(.medium))
                            if d.agendaOpen > 0 {
                                Text("\(d.agendaOpen) 个时间节点").font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                            Spacer()
                            Text("\(d.total) 条").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(d.headline.isEmpty ? d.whos.joined(separator: " · ") : d.headline)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(.vertical, 2)
                }.buttonStyle(.plain)
            }
            .navigationTitle("挑一天 · \(store.index.count)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct TimelineRow: View {
    @Environment(Store.self) private var store
    let item: FeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(timeText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(item.app).font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)
                Text(item.who).font(.caption.weight(.medium)).lineLimit(1)
                if item.missed {
                    Text("未读").font(.caption2).foregroundStyle(Color.orange)
                }
            }
            CollapsibleBody(text: item.lines.joined(separator: "\n"))
            if item.redacted {
                Text("正文已按保留期抹除").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }

    private var timeText: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = store.cloudTimezone
        let a = f.string(from: item.start)
        let b = f.string(from: item.end)
        return a == b ? a : "\(a)–\(b)"
    }
}


private enum RecapEntry: Identifiable {
    case notification(FeedItem)
    case note(CloudNote)
    var id: String {
        switch self {
        case .notification(let item): return "notification:\(item.id)"
        case .note(let note): return "cloud:\(note.id)"
        }
    }
    var timestamp: Double {
        switch self {
        case .notification(let item): return item.start.timeIntervalSince1970
        case .note(let note): return note.ts
        }
    }
}

struct CloudNoteRow: View {
    @Environment(Store.self) private var store
    let note: CloudNote
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("随手记").font(.caption2).foregroundStyle(.secondary)
            }
            CollapsibleBody(text: note.text)
        }.padding(.vertical, 3)
    }
    private var time: String {
        let formatter = DateFormatter()
        formatter.timeZone = store.cloudTimezone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: note.ts))
    }
}

struct CollapsibleBody: View {
    let text: String
    @State private var expanded = false
    private var isLong: Bool { text.count > 500 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 8 }
    private var preview: String {
        String(text.prefix(500).split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(expanded || !isLong ? text : preview + "…").font(.callout).textSelection(.enabled)
            if isLong {
                Button(expanded ? "收起正文" : "展开正文") { expanded.toggle() }
                    .font(.caption).buttonStyle(.borderless)
            }
        }
    }
}
