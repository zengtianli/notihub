import SwiftUI

struct DiaryView: View {
    @Environment(Store.self) private var store
    @AppStorage("diary.cloudDraft.text") private var text = ""
    @AppStorage("diary.cloudDraft.date") private var draftDate = ""
    @AppStorage("diary.cloudDraft.key") private var draftKey = ""
    @State private var sending = false
    @State private var result: String?
    @State private var failed = false
    @FocusState private var focused: Bool

    private var date: String { draftDate.isEmpty ? store.displayToday : draftDate }
    private var day: FeedDay? { store.days[date] }
    private var count: Int { (day?.notes ?? 0) + (day?.cloudNotes.count ?? 0) }

    var body: some View {
        NavigationStack {
            Form {
                Section("写点什么 · \(date)") {
                    TextEditor(text: Binding(get: { text }, set: { value in
                        guard !sending else { return }
                        text = value
                        if value.isEmpty {
                            draftDate = ""
                            draftKey = ""
                        } else {
                            if draftDate.isEmpty { draftDate = store.displayToday }
                            draftKey = UUID().uuidString
                        }
                        result = nil
                    }))
                        .frame(minHeight: 140)
                        .focused($focused)
                        .font(.callout)
                        .disabled(sending)
                    HStack {
                        Text("\(text.count) 字 · 草稿已保存在此设备")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await send() } } label: {
                            if sending { ProgressView() } else { Text("记下来") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 20000)
                    }
                }
                if let result {
                    Section {
                        Label(result, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.callout).foregroundStyle(failed ? Color.orange : Color.green)
                    }
                }
                if let error = store.dayError[date] {
                    Section { ErrorBlock(error: error, stale: store.dayAt[date]) }
                }
                Section {
                    if let day {
                        ForEach(day.cloudNotes) { note in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(time(note.ts)).font(.caption2).foregroundStyle(.secondary)
                                CollapsibleBody(text: note.text)
                            }.padding(.vertical, 2)
                        }
                        ForEach(day.items.filter { $0.app == "随手记" }) { item in
                            TimelineRow(item: item)
                        }
                        if count == 0 {
                            Text(T("diary.empty", "这一天还没有随手记。")).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if store.dayError[date] == nil {
                        Text("取数中…").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("已记下的 · \(count)")
                } footer: {
                    Text(T("diary.sync_note", "在线保存的随手记会立即出现在复盘里；Mac 上记录的随手记在同步后显示。"))
                }
                if let at = store.dayAt[date] {
                    Section { LabeledContent("缓存更新") { StaleBadge(at: at) } }
                }
            }
            .navigationTitle("随手记")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: date) { await store.day(date) }
            .onChange(of: store.indexAt) { _, _ in Task { await store.day(date, force: true) } }
            .refreshable { await store.day(date, force: true) }
            #if !os(visionOS)
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    Button("收起键盘") { focused = false }
                }
            }
            #endif
        }
    }

    private func time(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = store.cloudTimezone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !body.isEmpty else { return }
        if draftDate.isEmpty { draftDate = store.displayToday }
        if draftKey.isEmpty { draftKey = UUID().uuidString }
        let savedDate = draftDate
        sending = true
        defer { sending = false }
        switch await Writer.note(body, date: savedDate, idempotencyKey: draftKey) {
        case .success:
            failed = false
            result = "已保存到云端 · \(savedDate)"
            text = ""
            draftDate = ""
            draftKey = ""
            focused = false
            store.invalidateDays()
            await store.refresh()
            await store.day(savedDate, force: true)
        case .failure(let error):
            failed = true
            result = "\(error.headline) —— \(error.whatToDo)"
        }
    }
}
