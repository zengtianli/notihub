import AppKit
import SwiftUI

struct TodayPanelView: View {

    @ObservedObject var model: TodayModel
    @State private var collapsed: Set<String> = []

    private let bg = Color(red: 0.99, green: 0.98, blue: 0.97)     // 暖白
    private let card = Color.white
    private let line = Color(red: 0.90, green: 0.88, blue: 0.86)
    private let ink = Color(red: 0.13, green: 0.12, blue: 0.11)
    private let dim = Color(red: 0.47, green: 0.45, blue: 0.43)
    private let accent = Color(red: 0.918, green: 0.345, blue: 0.047)  // #ea580c

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(line)
            body_
            Divider().overlay(line)
            footer
        }
        .frame(width: 420)
        .background(bg)
        .preferredColorScheme(.light)
    }


    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("今天").font(.system(size: 15, weight: .semibold)).foregroundColor(ink)
                Text(model.snap.date).font(.system(size: 12)).foregroundColor(dim)
                Spacer()
                if model.snap.unread > 0 {
                    Text("\(model.snap.unread) 条未读")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(accent))
                } else if model.snap.problem == nil {
                    Text("没有未读").font(.system(size: 12)).foregroundColor(dim)
                }
            }
            Text(subtitle).font(.system(size: 11)).foregroundColor(dim)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
    }

    private var subtitle: String {
        if model.snap.problem != nil { return "数据源不可用" }
        var parts = ["\(model.snap.total) 条通知", "\(model.snap.groups.count) 个来源"]
        if let f = model.snap.first, let l = model.snap.last {
            parts.append("\(Recap.hhmm(f)) → \(Recap.hhmm(l))")
        }
        if model.snap.notes > 0 { parts.append("随手记 \(model.snap.notes) 条") }
        if model.snap.muted > 0 { parts.append("折叠噪音 \(model.snap.muted) 条") }
        return parts.joined(separator: " · ")
    }


    @ViewBuilder
    private var body_: some View {
        if let problem = model.snap.problem {
            VStack(alignment: .leading, spacing: 6) {
                Text("读不到数据").font(.system(size: 13, weight: .semibold)).foregroundColor(accent)
                Text(problem)
                    .font(.system(size: 11.5)).foregroundColor(ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else if model.snap.groups.isEmpty {
            Text(model.snap.muted > 0
                 ? "今天记录到的 \(model.snap.muted) 条全被折叠了（勾上「含折叠噪音」看）"
                 : "今天还没有记录到通知")
                .font(.system(size: 12)).foregroundColor(dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.snap.groups) { g in groupCard(g) }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .frame(maxHeight: 460)
        }
    }

    private func groupCard(_ g: SourceGroup) -> some View {
        let open = !collapsed.contains(g.canon)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { collapsed.insert(g.canon) } else { collapsed.remove(g.canon) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundColor(dim)
                    Circle().fill(g.unread > 0 ? accent : line).frame(width: 7, height: 7)
                    Text(g.app).font(.system(size: 12.5, weight: .semibold)).foregroundColor(ink)
                    Text("\(g.rows.count)").font(.system(size: 11)).foregroundColor(dim)
                    if g.unread > 0 {
                        Text("\(g.unread) 未读")
                            .font(.system(size: 10.5, weight: .medium)).foregroundColor(accent)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 8)

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(g.rows) { r in
                        Divider().overlay(line)
                        row(r)
                    }
                }
            }
            if g.unread > 0 {
                Divider().overlay(line)
                HStack {
                    Spacer()
                    Button("把这 \(g.unread) 条标为已读") { model.markRead(g.rows) }
                        .disabled(model.writing)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(accent)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(line, lineWidth: 1))
    }

    private func row(_ r: FeedRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Recap.hhmm(r.ts))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(dim)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(r.who)
                        .font(.system(size: 12, weight: r.unread ? .semibold : .regular))
                        .foregroundColor(ink)
                        .lineLimit(1)
                    if r.unread {
                        Circle().fill(accent).frame(width: 5, height: 5)
                    }
                }
                if r.redacted {
                    Text("正文已过保留期，只剩元数据")
                        .font(.system(size: 11)).foregroundColor(dim).italic()
                } else if !r.text.isEmpty, r.text != r.who {
                    Text(r.text)
                        .font(.system(size: 11.5)).foregroundColor(dim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if r.unread {
                Button("已读") { model.markRead([r]) }
                    .disabled(model.writing)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundColor(accent)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }


    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Toggle("含折叠噪音", isOn: $model.includeAll)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundColor(dim)
                Spacer()
                Button("全部标已读") { model.markAllRead() }
                    .font(.system(size: 11))
                    .disabled(model.snap.unread == 0 || model.writing)
                Button("在线复盘") { model.openFullRecap() }
                    .font(.system(size: 11))
                    .disabled(model.openingRecap)
                Button(model.loading ? "刷新中" : "刷新") { model.refresh() }
                    .font(.system(size: 11))
                    .disabled(model.loading)
            }
            HStack(spacing: 6) {
                Text(model.dbPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(dim)
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                if let t = model.refreshedAt {
                    Text("更新于 \(Recap.hhmm(t.timeIntervalSince1970))")
                        .font(.system(size: 10)).foregroundColor(dim)
                }
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10)).foregroundColor(dim)
            }
            if let problem = model.actionProblem {
                Text(problem).font(.system(size: 11)).foregroundColor(accent).textSelection(.enabled)
            }
            Text("「已读」只写本机 notifhub 库的 dismissed_at，不动 macOS 通知中心。")
                .font(.system(size: 9.5)).foregroundColor(dim)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}
