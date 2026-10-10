#if DEMO_CAPTURE
import AppKit
import SwiftUI

@main
enum DemoCapture {
    @MainActor
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3, args[1] == "--demo-snapshot" else {
            throw NSError(domain: "DemoCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: demo-capture --demo-snapshot <output-directory>"])
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        if let icon = NSImage(contentsOfFile: "icon/AppIcon.png") { app.applicationIconImage = icon }
        let out = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().date(from: "2026-09-24T02:00:00Z")!.timeIntervalSince1970
        let day = CloudDay(date: "2026-09-24", total: 3,
            items: [
                CloudItem(ts: stamp, app: "日历", who: "周末读书会（虚构）", lines: ["周六 10:00，带上一本最近读过的书。"], redacted: false),
                CloudItem(ts: stamp - 1800, app: "提醒事项", who: "生活清单（虚构）", lines: ["下班路上买水果，记得带购物袋。"], redacted: false),
                CloudItem(ts: stamp - 3600, app: "备忘录", who: "灵感记录（虚构）", lines: ["把重要的事情收拢起来，留出时间专心做事。"], redacted: false)
            ], summary: CloudSummary(headline: "把今天的三件小事安排好", text: "读书会、购物和一个灵感，都能在同一页回看。本页全部内容为固定虚构示例。"),
            agenda: [
                CloudAgenda(id: 1, title: "为读书会选一本书", status: "open", dueTS: stamp + 86400, note: "虚构示例 · 准备一段喜欢的文字"),
                CloudAgenda(id: 2, title: "买水果并带上购物袋", status: "open", dueTS: nil, note: "虚构示例 · 放到生活清单"),
                CloudAgenda(id: 3, title: "整理桌面上的便签", status: "done", dueTS: nil, note: "虚构状态，用于展示已完成样式")
            ], cloudNotes: [
                CloudNote(id: 1, text: "读到喜欢的句子，先记下来，周末再整理。\n固定虚构笔记，无用户数据。", ts: stamp),
                CloudNote(id: 2, text: "一次只关注一件事。\n这是一条演示笔记，没有上传或保存到服务器。", ts: stamp - 3600)
            ])
        let index = CloudIndex(days: [CloudDayIndex(date: day.date, total: 3, headline: "把今天的三件小事安排好", agendaOpen: 2)], lastSync: stamp, timezone: "Asia/Shanghai")
        let model = CloudModel.documentationModel(index: index, day: day)
        for (file, section, caption) in [("01-timeline", "timeline", "1 · 按日期回看通知与摘要"), ("02-agenda", "agenda", "2 · 看清当日待办与完成状态"), ("03-notes", "notes", "3 · 在同一天回看随手记")] {
            let view = CloudWindowView(demoModel: model, section: section)
            try snapshot(view, to: out.appendingPathComponent(file + ".png"))
            try snapshot(view, to: out.appendingPathComponent(file + ".video.png"), caption: caption)
        }
        let data = try dataPageModel()
        let dataScene = DemoDataScene(cloud: model, data: data)
        try snapshot(dataScene, to: out.appendingPathComponent("04-data.png"))
        try snapshot(dataScene, to: out.appendingPathComponent("04-data.video.png"), caption: "4 · 本机 Apple 数据只读查看与导出（数据不上云）")
        data.release()
        print("Captured 4 production-view states; synthetic in-memory data; no live requests or local Apple data reads.")
    }

    @MainActor
    private static func dataPageModel() throws -> DataPageModel {
        let model = DataPageModel { domain, _ in DemoDataFixture.result(for: domain) }
        model.scanAll()
        let deadline = Date().addingTimeInterval(8)
        while model.isScanning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard !model.isScanning, model.results.count == model.domains.count else {
            throw NSError(domain: "DemoCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Synthetic data scan did not finish"])
        }
        for id in ["reminders", "notes", "books", "safari-bookmarks", "voicememos"] {
            if let domain = model.domains.first(where: { $0.id == id }) { model.toggle(domain) }
        }
        if let reminders = model.domains.first(where: { $0.id == "reminders" }) { model.focus(on: reminders) }
        model.format = .csv
        return model
    }

    @MainActor
    private static func snapshot<V: View>(_ view: V, to url: URL, caption: String? = nil) throws {
        let frame = NSRect(x: 0, y: 0, width: 1200, height: caption == nil ? 820 : 960)
        let content = VStack(spacing: 0) {
            if let caption {
                Text(caption).font(.system(size: 28, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).frame(height: 76)
            }
            view.frame(width: 1200, height: 820)
            if caption != nil {
                Text("真实界面离屏导览，虚构示例；非连续实机录屏").font(.system(size: 19)).foregroundStyle(.secondary).frame(height: 64)
            }
        }.frame(width: frame.width, height: frame.height).background(Color(NSColor.windowBackgroundColor))
        let host = NSHostingView(rootView: content.environment(\.locale, Locale(identifier: "zh_CN")))
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
        precondition(!window.isVisible && !window.isKeyWindow, "Documentation window must remain offscreen")
        window.close()
    }
}

private struct DemoDataScene: View {
    let cloud: CloudModel
    let data: DataPageModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CloudWindowView(demoModel: cloud, section: "timeline", dataModel: data)
            DataExportSheet(model: data, presented: .constant(true))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.12)))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
                .scaleEffect(0.78, anchor: .bottomTrailing)
                .padding(.trailing, 22).padding(.bottom, 22)
        }
    }
}

private enum DemoDataFixture {
    static func result(for domain: DataDomain) -> DomainResult {
        switch domain.id {
        case "reminders":
            let rows: [[String]] = [
                ["为读书会选一本书", "生活（虚构）", "未完成", "2026-09-26 10:00", "2026-09-24 09:12", "摘一段喜欢的话"],
                ["下班路上买水果", "生活（虚构）", "未完成", "2026-09-24 18:30", "2026-09-24 08:40", "记得带购物袋"],
                ["整理桌面上的便签", "整理（虚构）", "已完成", "", "2026-09-23 21:05", ""],
                ["给绿植浇水", "家务（虚构）", "未完成", "2026-09-25 08:00", "2026-09-23 19:30", "阳台两盆"],
                ["备份相册", "整理（虚构）", "未完成", "2026-09-28 20:00", "2026-09-23 12:16", "虚构示例"],
                ["预约体检", "健康（虚构）", "已完成", "2026-09-22 09:00", "2026-09-20 10:02", ""],
                ["周末散步一小时", "健康（虚构）", "未完成", "2026-09-27 16:00", "2026-09-20 09:45", "天气好就去公园"],
                ["归还图书馆的书", "生活（虚构）", "已完成", "2026-09-21 17:00", "2026-09-18 14:20", ""],
                ["练习二十分钟书法", "兴趣（虚构）", "未完成", "", "2026-09-17 20:11", "虚构示例"],
                ["更新旅行清单", "兴趣（虚构）", "未完成", "2026-10-01 09:00", "2026-09-16 22:03", "带上充电器"],
                ["清理冰箱", "家务（虚构）", "已完成", "", "2026-09-15 18:27", ""],
                ["写一段读书笔记", "兴趣（虚构）", "未完成", "2026-09-29 21:00", "2026-09-14 21:40", "虚构示例"]
            ]
            return DomainResult(domainID: domain.id, resolvedCount: 1,
                                columns: ["标题", "清单", "状态", "截止", "创建时间", "备注"], rows: rows)
        case "voicememos":
            return DomainResult(domainID: domain.id, verdict: .notFound)
        case "stickies":
            return DomainResult(domainID: domain.id, resolvedCount: 1, columns: ["标题"], rows: [])
        default:
            let counts = ["notes": 86, "books": 24, "safari-bookmarks": 57, "safari-history": 1_320, "safari-tabs": 18,
                          "messages": 640, "mail": 412, "callhistory": 75, "podcasts": 33, "screentime": 960,
                          "contacts": 140, "icloud-drive": 210]
            let n = counts[domain.id] ?? 12
            return DomainResult(domainID: domain.id, resolvedCount: 1, columns: ["示例", "说明"],
                                rows: (0..<n).map { ["虚构示例 \($0 + 1)", domain.name] })
        }
    }
}
#endif
