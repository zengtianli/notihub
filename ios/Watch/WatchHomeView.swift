import SwiftUI

struct WatchHomeView: View {
    let digest: WatchDigest
    let receivedAt: Date?
    @State private var page = min(2, max(0, UserDefaults.standard.integer(forKey: "tab")))

    private var isToday: Bool { digest.isToday() }
    private let theme = Color("AccentColor")

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                glance
                    .containerBackground(theme.gradient.opacity(0.55), for: .tabView)
                    .tag(0)
                sources
                    .containerBackground(theme.gradient.opacity(0.3), for: .tabView)
                    .tag(1)
                highlights
                    .containerBackground(theme.gradient.opacity(0.3), for: .tabView)
                    .tag(2)
            }
            .tabViewStyle(.verticalPage)
        }
        .onAppear { LaneSignal.ready("watch-digest") }
    }

    private var glance: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(dayLabel)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isToday ? Color.white : Color.orange)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(digest.unread)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(digest.unread > 0 ? Color.orange : Color.white)
                Text("件未读").font(.footnote.weight(.medium))
            }
            Text("\(digest.total) 条通知 · 合并后 \(digest.events) 件")
                .font(.caption2).foregroundStyle(.white.opacity(0.75))
            if !digest.headline.isEmpty {
                Text(digest.headline)
                    .font(.footnote)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .padding(.top, 4)
            }
            Spacer(minLength: 4)
            if digest.dueToday + digest.overdue > 0 {
                Label(agendaText, systemImage: "checklist")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(digest.overdue > 0 ? Color.orange : Color.white)
            }
            Text(syncText)
                .font(.caption2)
                .foregroundStyle(stale ? Color.orange : Color.white.opacity(0.55))
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)        // 圆角屏的下角会切掉贴底的东西
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sources: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                let top = max(1, digest.apps.map(\.count).max() ?? 1)
                ForEach(digest.apps, id: \.self) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(app.name).font(.footnote)
                            Spacer()
                            Text("\(app.count)").font(.footnote.weight(.semibold)).monospacedDigit()
                        }
                        GeometryReader { geo in
                            Capsule().fill(Color.accentColor)
                                .frame(width: max(5, geo.size.width * CGFloat(app.count) / CGFloat(top)))
                        }
                        .frame(height: 5)
                    }
                }
                if digest.apps.isEmpty {
                    Text(T("watch.no_apps", "这天没有按 App 的计数")).font(.footnote).foregroundStyle(.secondary)
                }
                if !digest.whos.isEmpty {
                    Text("聊得最多").font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
                    ForEach(digest.whos, id: \.self) { who in
                        HStack {
                            Text(who.name).font(.footnote).lineLimit(1)
                            Spacer()
                            Text("\(who.count)").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)     // 右边让出竖向翻页的指示点
        }
        .navigationTitle("从哪来")
    }

    private var highlights: some View {
        List {
            if digest.top.isEmpty {
                Text(T("watch.no_items", "这天还没有通知")).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(digest.top) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if item.missed {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                        }
                        Text(item.who).font(.footnote.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(time(item.ts)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(item.app).font(.caption2).foregroundStyle(Color.accentColor)
                    if !item.line.isEmpty {
                        Text(item.line).font(.caption2).lineLimit(3)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("要点")
    }

    private var dayLabel: String {
        isToday ? "今天" : T("watch.day_stale", "{date} · 今天的还没同步", ["date": monthDay(digest.date)])
    }

    private var agendaText: String {
        var parts = ["\(T("today.group.today", "今天")) \(digest.dueToday)"]
        if digest.overdue > 0 { parts.append("\(T("today.group.overdue", "逾期")) \(digest.overdue)") }
        return "待办 " + parts.joined(separator: " · ")
    }

    private var syncAt: Date? {
        digest.lastSync.map { Date(timeIntervalSince1970: $0) } ?? receivedAt
    }

    private var stale: Bool {
        guard let at = syncAt else { return true }
        return Date().timeIntervalSince(at) > WatchDigest.staleAfter
    }

    private var syncText: String {
        guard let at = syncAt else { return T("watch.sync_never", "还没同步过") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = digest.cloudTimeZone
        let formatter = DateFormatter()
        formatter.timeZone = digest.cloudTimeZone
        formatter.dateFormat = calendar.isDateInToday(at) ? "HH:mm" : "M月d日 HH:mm"
        return T("watch.sync_at", "同步于 {time}", ["time": formatter.string(from: at)])
    }

    private func time(_ ts: Double) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = digest.cloudTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: ts))
    }

    private func monthDay(_ date: String) -> String {
        let parts = date.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return date }
        return "\(m)月\(d)日"
    }
}
