import SwiftUI


enum ReminderPrefs {
    static let listKey = "reminderListID"
}

struct ReminderSettingsButton: View {
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        } label: {
            Label("去设置", systemImage: "gear")
        }
    }
}


struct ReminderConnectionSection: View {
    @Environment(RemindersModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ReminderPrefs.listKey) private var listID = ""

    var body: some View {
        Section("提醒事项") {
            switch model.auth {
            case .notDetermined:
                LabeledContent("授权", value: "尚未允许")
                Button { Task { await model.requestAccess() } } label: {
                    Label("允许访问提醒事项", systemImage: "checklist")
                }
            case .denied(let reason):
                Text(reason).font(.callout).foregroundStyle(Color.orange)
                ReminderSettingsButton()
            case .fullAccess:
                LabeledContent("授权", value: "完全访问")
                let choice = ReminderListChoice.resolve(savedID: listID, lists: model.lists, default: model.defaultList)
                if model.lists.isEmpty {
                    Text(ReminderText.noList).font(.callout).foregroundStyle(.secondary)
                } else {
                    Picker("加入到哪个列表", selection: Binding(
                        get: { choice.list?.id ?? "" },
                        set: { listID = $0 }
                    )) {
                        ForEach(model.lists) { Text($0.title).tag($0.id) }
                    }
                }
                if let notice = choice.notice {
                    Text(notice).font(.caption).foregroundStyle(Color.orange)
                }
                Text("选中共享列表时，列表成员能看到加入的内容（含原文）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { model.refreshAuth() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshAuth() }
        }
    }
}


struct ReminderAddControls: View {
    @Environment(RemindersModel.self) private var model
    @Environment(Store.self) private var store
    @AppStorage(ReminderPrefs.listKey) private var listID = ""
    let item: Agenda

    var body: some View {
        let key = ReminderPlan.key(for: item)
        let busy = model.adding.contains(key)
        let outcome = model.outcome(for: item)

        Button { add(force: false) } label: {
            Label(primaryTitle(outcome), systemImage: "checklist").fontWeight(.semibold)
        }
        .disabled(busy || outcome?.isAdded == true)
        if busy { ProgressView() }

        switch outcome {
        case .alreadyThere:
            Button { add(force: true) } label: {
                Label("仍要再加一次", systemImage: "plus.circle")
            }
            .disabled(busy)
        case .denied(let reason):
            Text(reason).font(.caption).foregroundStyle(Color.orange)
            ReminderSettingsButton()
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(Color.orange)
        case .added, nil:
            EmptyView()
        }
        if let notice = model.notices[key] {
            Text(notice).font(.caption).foregroundStyle(Color.orange)
        }
    }

    private func primaryTitle(_ outcome: AddOutcome?) -> String {
        switch outcome {
        case .added(let list): return "已加入『\(list)』"
        case .alreadyThere(let list): return "已在提醒事项（\(list)）"
        default: return "加入提醒事项"
        }
    }

    private func add(force: Bool) {
        Task {
            _ = await model.add(item, savedListID: listID.isEmpty ? nil : listID,
                                timezone: store.cloudTimezone, force: force)
        }
    }
}


struct ReminderDaySection: View {
    @Environment(RemindersModel.self) private var model
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    let date: String

    var body: some View {
        let state = model.sections[date]
        Section(title(state)) {
            switch state {
            case .notDetermined:
                Button { Task { await model.requestAccess() } } label: {
                    Label("允许访问提醒事项", systemImage: "checklist")
                }
            case .denied(let reason):
                Text(reason).font(.callout).foregroundStyle(Color.orange)
                ReminderSettingsButton()
            case .empty:
                Text("这天没有到期或完成的提醒").font(.callout).foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason).font(.callout).foregroundStyle(Color.orange)
            case .loaded(let rows):
                ForEach(rows) { ReminderLine(row: $0) }
            case nil:
                Text("读取中…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task(id: date) { await model.load(date: date, calendar: store.dayCalendar) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load(date: date, calendar: store.dayCalendar) } }
        }
    }

    private func title(_ state: ReminderSectionState?) -> String {
        if case .loaded(let rows) = state { return "提醒事项 · \(rows.count)（仅本机）" }
        return "提醒事项（仅本机）"
    }
}

struct ReminderLine: View {
    @Environment(Store.self) private var store
    let row: ReminderRow

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: row.completed ? "checkmark.circle.fill" : "circle")
                .font(.callout).foregroundStyle(row.completed ? Color.green : Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.callout)
                    .foregroundStyle(row.completed ? Color.secondary : Color.primary)
                HStack(spacing: 6) {
                    if let t = timeText {
                        Text(t).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(row.listName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if row.addedByNotihub {
                        Text("Notihub").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }.padding(.vertical, 2)
    }

    private var timeText: String? {
        let f = DateFormatter()
        f.timeZone = store.cloudTimezone
        f.dateFormat = "HH:mm"
        if row.completed {
            return row.completionDate.map { "完成 " + f.string(from: $0) }
        }
        if row.isDateOnly { return "全天" }
        return row.dueDate(in: store.dayCalendar).map { f.string(from: $0) }
    }
}


struct ReminderLocalStatus: View {
    @Environment(RemindersModel.self) private var model
    let item: Agenda

    var body: some View {
        switch model.outcome(for: item) {
        case .added(let list), .alreadyThere(let list):
            LabeledContent("本机已加入", value: list)
        case .denied, .failed:
            LabeledContent("本机已加入", value: "否")
        case nil:
            LabeledContent("本机已加入", value: "点加入时核对")
        }
    }
}
