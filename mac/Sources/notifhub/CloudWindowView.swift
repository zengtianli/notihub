import AppKit
import SwiftUI

private enum NotihubStyle {
    static let ink = Color(red: 0.18, green: 0.20, blue: 0.22)
    static let muted = Color(red: 0.48, green: 0.49, blue: 0.49)
    static let accent = Color(red: 0.87, green: 0.34, blue: 0.23)
    static let paper = Color(red: 0.98, green: 0.975, blue: 0.96)
    static let line = Color.black.opacity(0.065)
}

struct CloudWindowView: View {
    @StateObject private var model: CloudModel
    private let updatesAutomatically: Bool
    @State private var section = "timeline"
    @State private var search = ""
    @State private var composing = false
    @State private var allTasks = false
    @State private var expandedSummary = false
    @State private var onScreen = false
    @State private var lastTimedRefresh = Date()
    @State private var readyAnnounced = false
    @State private var dataPage: DataPageModel?

    @MainActor
    init() {
        _model = StateObject(wrappedValue: CommandLine.arguments.contains("--demo")
                             ? UISelfTest.makeDemoCloudModel() : CloudModel())
        updatesAutomatically = true
    }

    @MainActor
    init(demoModel: CloudModel, section: String, dataModel: DataPageModel? = nil) {
        _model = StateObject(wrappedValue: demoModel)
        _section = State(initialValue: section)
        _dataPage = State(initialValue: dataModel)
        updatesAutomatically = false
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 218)
            Rectangle().fill(NotihubStyle.line).frame(width: 1)
            if let dataPage {
                DataPageView(model: dataPage, scansOnAppear: updatesAutomatically)
            } else {
                cloudPage
            }
        }
        .foregroundStyle(NotihubStyle.ink)
        .tint(NotihubStyle.accent)
        .frame(minWidth: 920, minHeight: 630)
        .preferredColorScheme(.light)
        .task {
            if updatesAutomatically { model.refresh(); LaneSignal.applyWindowFrame() }
        }
        .background(CloudReadyLayout(ready: !readyAnnounced && updatesAutomatically && !model.loading && model.problem == nil
                                    && model.index != nil && (model.selectedDate.isEmpty || model.day != nil)) {
            guard !readyAnnounced, !model.loading, model.problem == nil, model.index != nil,
                  model.selectedDate.isEmpty || model.day != nil else { return }
            readyAnnounced = true
            LaneSignal.ready("cloud")
        })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if updatesAutomatically && model.index != nil && !model.loading { model.refresh() }
        }
        .background(WindowVisibilityReader { onScreen = $0 })
        .task(id: onScreen) {
            guard updatesAutomatically && onScreen else { return }
            if Date().timeIntervalSince(lastTimedRefresh) >= 60 && !model.loading {
                model.refresh(); lastTimedRefresh = Date()
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { return }
                if !model.loading { model.refresh(); lastTimedRefresh = Date() }
            }
        }
        .sheet(isPresented: $composing) { composer }
    }

    private var cloudPage: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(NotihubStyle.line).frame(height: 1)
            if let error = model.problem { errorBanner(error) }
            if let error = model.writeProblem, !composing { errorBanner(error) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if allTasks {
                        sectionTitle("待办事项", subtitle: "跨日期汇总 · \(model.opened.count) 项未完成")
                        agendaList(model.opened)
                    } else if let day = model.day {
                        dayHeading(day)
                        if let summary = day.summary, !summary.headline.isEmpty { summaryCard(summary) }
                        HStack {
                            Picker("内容", selection: $section) {
                                Text("时间线").tag("timeline")
                                Text("当日待办 · \(day.agenda.count)").tag("agenda")
                                Text("云端笔记 · \(day.cloudNotes.count)").tag("notes")
                            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 390)
                            Spacer()
                        }
                        if section == "timeline" { timeline(day) }
                        if section == "agenda" { agendaList(day.agenda) }
                        if section == "notes" { notes(day.cloudNotes) }
                    } else if model.loading {
                        ProgressView(T("mac.loading", "正在读取云端记录…")).frame(maxWidth: .infinity).padding(.top, 100)
                    } else if model.problem == nil {
                        empty(T("mac.empty.none_title", "还没有云端记录"), detail: T("mac.empty.none_detail", "首次同步完成后，你的每日记录会出现在这里。"), symbol: "tray")
                    }
                }.padding(30).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }.id(allTasks ? "allTasks" : model.selectedDate + section)
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(NotihubStyle.muted).padding(.bottom, 12)
            }
        }.background(NotihubStyle.paper)
    }

    private func enterDataPage() {
        guard dataPage == nil else { return }
        search = ""
        dataPage = DataPageModel()
    }

    private func leaveDataPage() {
        dataPage?.release()
        dataPage = nil
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notihub").font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("把每一天，收拢起来").font(.system(size: 10)).foregroundStyle(NotihubStyle.muted)
                }
            }.padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 28)
            Button {
                leaveDataPage(); allTasks = true; search = ""
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle").font(.system(size: 15))
                    Text("待办事项").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(model.opened.count)").font(.system(size: 11, design: .rounded)).monospacedDigit()
                }.padding(11).background(allTasks && dataPage == nil ? NotihubStyle.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.horizontal, 12)
            Button {
                enterDataPage()
            } label: {
                HStack {
                    Image(systemName: "internaldrive").font(.system(size: 14))
                    Text("本机数据").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(NotihubStyle.muted)
                }.padding(11).background(dataPage != nil ? NotihubStyle.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 2)
                .help("查看并导出本机信息、通话、Safari、备忘录等数据（只读，不上云）")
                .accessibilityLabel("本机数据")
            Text("每日记录").font(.system(size: 10, weight: .semibold)).foregroundStyle(NotihubStyle.muted)
                .padding(.horizontal, 23).padding(.top, 25).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.index?.days ?? []) { day in
                        Button {
                            leaveDataPage(); allTasks = false; search = ""; expandedSummary = false
                            model.select(date: day.date)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(day.date).font(.system(size: 13, weight: .medium)).monospacedDigit()
                                    Text(day.headline?.isEmpty == false ? day.headline! : "\(day.total) 条记录")
                                        .font(.system(size: 11)).lineLimit(1).foregroundStyle(NotihubStyle.muted)
                                }
                                Spacer(minLength: 0)
                                if day.agendaOpen > 0 {
                                    Circle().fill(NotihubStyle.accent.opacity(0.65)).frame(width: 5, height: 5).padding(.top, 5)
                                }
                            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                .background(!allTasks && dataPage == nil && day.date == model.selectedDate ? Color.white : .clear,
                                            in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(!allTasks && dataPage == nil && day.date == model.selectedDate ? NotihubStyle.line : .clear))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 12)
            }
            VStack(alignment: .leading, spacing: 7) {
                Label(CloudCopy.connection(problem: model.problem != nil, connected: model.index != nil), systemImage: "cloud")
                    .font(.system(size: 11, weight: .medium))
                if let index = model.index {
                    Text(T("mac.sync_at", "同步于 {time}", ["time": cloudTime(index.lastSync, format: "MM-dd HH:mm")]))
                        .font(.system(size: 10)).foregroundStyle(NotihubStyle.muted)
                    Text(TimeZone(identifier: index.timezone)?.localizedName(for: .standard, locale: Locale(identifier: "zh_CN")) ?? index.timezone)
                        .font(.system(size: 10)).foregroundStyle(NotihubStyle.muted)
                }
                Text(model.siteURL.host ?? "").font(.system(size: 10)).foregroundStyle(NotihubStyle.muted)
            }.padding(22)
        }.background(Color(red: 0.955, green: 0.947, blue: 0.925))
    }

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(NotihubStyle.muted)
                TextField(allTasks ? "搜索待办" : "搜索当前内容", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("搜索当前内容")
            }.font(.system(size: 12)).frame(maxWidth: 300)
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("刷新云端记录").accessibilityLabel("刷新云端记录")
            Button { NSWorkspace.shared.open(model.siteURL) } label: { Image(systemName: "safari") }
                .buttonStyle(.plain).help("打开网页版").accessibilityLabel("打开网页版")
            Button {
                model.beginNote(); composing = true
            } label: { Label("随手记", systemImage: "square.and.pencil").padding(.horizontal, 4) }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.index == nil)
        }.padding(.horizontal, 28).padding(.vertical, 16)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(NotihubStyle.muted)
        }.padding(.bottom, 4)
    }

    private func dayHeading(_ day: CloudDay) -> some View {
        HStack(alignment: .top) {
            sectionTitle(displayDate(day.date), subtitle: "\(day.total) 条通知  ·  \(day.agenda.filter { $0.status == "open" }.count) 项待办  ·  \(day.cloudNotes.count) 篇云端笔记")
            Spacer()
            Text(String(day.date.prefix(4))).font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(NotihubStyle.muted).padding(.top, 8)
        }
    }

    private func displayDate(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return date }
        return "\(m) 月 \(d) 日"
    }

    private func cloudTime(_ stamp: Double, format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(identifier: model.index?.timezone ?? "") ?? .current
        return formatter.string(from: Date(timeIntervalSince1970: stamp))
    }

    private func summaryCard(_ summary: CloudSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("一天的重点", systemImage: "sparkle").font(.system(size: 11, weight: .medium)).foregroundStyle(NotihubStyle.accent)
            Text(summary.headline).font(.system(size: 17, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if expandedSummary {
                Text(.init(summary.text)).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
            }
            Button(expandedSummary ? "收起总结 ↑" : "阅读总结 →") { expandedSummary.toggle() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(NotihubStyle.accent)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.99, green: 0.935, blue: 0.87), in: RoundedRectangle(cornerRadius: 15))
    }

    private func timeline(_ day: CloudDay) -> some View {
        let items = day.items.enumerated().filter { _, item in
            search.isEmpty || ([item.app, item.who] + item.lines).joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
        return LazyVStack(spacing: 0) {
            if items.isEmpty { empty(T("mac.empty.timeline_title", "没有匹配的记录"), detail: search.isEmpty ? T("mac.empty.timeline_detail", "当天暂无可展示的通知。") : T("mac.empty.search_detail", "试试其他关键词。"), symbol: "text.magnifyingglass") }
            ForEach(items, id: \.offset) { offset, item in
                CloudTimelineRow(item: item, timezone: model.index?.timezone)
                if offset != items.last?.offset { Divider().padding(.leading, 84) }
            }
        }.background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(NotihubStyle.line))
    }

    private func agendaList(_ items: [CloudAgenda]) -> some View {
        let filtered = items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.note ?? "").localizedCaseInsensitiveContains(search) }
        return LazyVStack(spacing: 0) {
            if filtered.isEmpty { empty(search.isEmpty ? T("mac.empty.agenda_title", "这里都处理好了") : T("mac.empty.agenda_search_title", "没有匹配的待办"), detail: search.isEmpty ? T("mac.empty.agenda_detail", "没有待办事项。") : T("mac.empty.agenda_search_detail", "没有符合关键词的待办。"), symbol: "checkmark.circle") }
            ForEach(filtered) { item in
                HStack(alignment: .top, spacing: 13) {
                    Button { Task { await model.setStatus(item, status: item.status == "open" ? "done" : "open") } } label: {
                        Image(systemName: item.status == "open" ? "circle" : "checkmark.circle.fill")
                            .font(.system(size: 20)).foregroundStyle(item.status == "open" ? NotihubStyle.muted : NotihubStyle.accent)
                    }.buttonStyle(.plain).disabled(model.writing).accessibilityLabel(item.status == "open" ? "完成：\(item.title)" : "重新打开：\(item.title)")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.system(size: 14, weight: .medium)).strikethrough(item.status != "open")
                        if let note = item.note, !note.isEmpty { Text(note).font(.system(size: 12)).foregroundStyle(NotihubStyle.muted).textSelection(.enabled) }
                        if let due = item.dueTS { Text(cloudTime(due, format: "M 月 d 日 HH:mm")).font(.system(size: 11)).foregroundStyle(NotihubStyle.accent) }
                    }
                    Spacer(minLength: 0)
                }.padding(20)
                if item.id != filtered.last?.id { Divider().padding(.leading, 52) }
            }
        }.frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(NotihubStyle.line))
    }

    private func notes(_ items: [CloudNote]) -> some View {
        let filtered = items.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
        return LazyVStack(alignment: .leading, spacing: 12) {
            if filtered.isEmpty { empty(T("mac.empty.notes_title", "留下一点想法"), detail: T("mac.empty.notes_detail", "点击右上角「随手记」，内容会保存到云端。"), symbol: "square.and.pencil") }
            ForEach(filtered) { note in
                VStack(alignment: .leading, spacing: 10) {
                    Text(note.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                    Text(cloudTime(note.ts, format: "HH:mm")).font(.system(size: 11)).foregroundStyle(NotihubStyle.muted)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(NotihubStyle.line))
            }
        }
    }

    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(NotihubStyle.accent)
            Text(title).font(.system(size: 16, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(NotihubStyle.muted)
        }.frame(maxWidth: .infinity).padding(.vertical, 55)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack {
            Label(text, systemImage: "exclamationmark.circle")
            Spacer()
            Button("重试") { model.refresh() }
        }.font(.system(size: 12)).padding(14).background(NotihubStyle.accent.opacity(0.09))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("随手记").font(.system(size: 23, weight: .semibold, design: .rounded))
                Spacer()
                Text(model.draftDate).font(.system(size: 12)).foregroundStyle(NotihubStyle.muted)
            }
            Text(T("mac.note.hint", "记下想法，回头在任何设备上继续。"))
                .font(.system(size: 12)).foregroundStyle(NotihubStyle.muted)
            TextEditor(text: $model.draft).font(.system(size: 15)).scrollContentBackground(.hidden)
                .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 10)).frame(height: 200)
                .disabled(model.writing).accessibilityLabel("随手记正文")
            if let error = model.writeProblem { Text(error).font(.system(size: 12)).foregroundStyle(NotihubStyle.accent) }
            HStack {
                Text(T("mac.note.draft_kept", "草稿自动保留在本机")).font(.system(size: 11)).foregroundStyle(NotihubStyle.muted)
                Spacer()
                Button("稍后再写") { composing = false }.disabled(model.writing)
                Button(model.writing ? "保存中…" : "保存到云端") {
                    Task { if await model.saveNote() { composing = false; section = "notes"; allTasks = false; search = "" } }
                }.buttonStyle(.borderedProminent).disabled(model.writing || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.draft.count > 20000)
            }
        }.padding(28).frame(width: 520).background(NotihubStyle.paper)
            .tint(NotihubStyle.accent).foregroundStyle(NotihubStyle.ink).preferredColorScheme(.light)
            .interactiveDismissDisabled(model.writing)
    }
}

private struct CloudReadyLayout: NSViewRepresentable {
    let ready: Bool
    let announce: () -> Void
    func makeNSView(context: Context) -> LayoutView { LayoutView() }
    func updateNSView(_ view: LayoutView, context: Context) {
        view.announce = ready ? announce : nil
        view.needsLayout = true
        view.layoutWhenReady()
    }
    final class LayoutView: NSView {
        var announce: (() -> Void)?
        private var layoutScheduled = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true; layoutWhenReady() }
        func layoutWhenReady() {
            guard announce != nil, window != nil, !layoutScheduled else { return }
            layoutScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.layoutScheduled = false }
                guard self.announce != nil, let content = self.window?.contentView else { return }
                content.needsLayout = true
                content.layoutSubtreeIfNeeded()
            }
        }
        override func layout() {
            super.layout()
            guard window != nil, bounds.width > 0, bounds.height > 0, let announce else { return }
            self.announce = nil
            DispatchQueue.main.async { [weak self] in
                guard let content = self?.window?.contentView, content.bounds.width > 0, content.bounds.height > 0,
                      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
                content.layoutSubtreeIfNeeded()
                content.cacheDisplay(in: content.bounds, to: bitmap)
                announce()
            }
        }
    }
}

private struct CloudTimelineRow: View {
    let item: CloudItem
    let timezone: String?
    @State private var expanded = false
    private var text: String { item.lines.joined(separator: "\n\n") }
    private var time: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: timezone ?? "") ?? .current
        return formatter.string(from: Date(timeIntervalSince1970: item.ts))
    }
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(time).font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(NotihubStyle.muted).frame(width: 46, alignment: .leading).padding(.top, 4)
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.who.isEmpty ? item.app : item.who).font(.system(size: 14, weight: .semibold)).lineLimit(expanded ? nil : 1)
                    Spacer(minLength: 8)
                    Text(item.app).font(.system(size: 10)).foregroundStyle(NotihubStyle.muted)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(NotihubStyle.paper, in: Capsule())
                }
                Text(item.redacted ? T("mac.redacted", "正文已按保留策略清理") : text)
                    .font(.system(size: 13)).lineSpacing(5).lineLimit(expanded ? nil : 3)
                    .foregroundStyle(NotihubStyle.ink.opacity(0.8)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if text.count > 100 || item.lines.count > 1 || text.contains("\n") {
                    Button(expanded ? "收起" : "展开全文") { expanded.toggle() }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(NotihubStyle.accent)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(20)
    }
}
