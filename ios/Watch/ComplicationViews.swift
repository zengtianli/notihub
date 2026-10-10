import SwiftUI
import WidgetKit

struct DigestEntry: TimelineEntry {
    let date: Date
    let digest: WatchDigest?
}

struct DigestComplicationView: View {
    @Environment(\.widgetFamily) private var envFamily
    let entry: DigestEntry
    var familyOverride: WidgetFamily?

    private var family: WidgetFamily { familyOverride ?? envFamily }

    private var today: WatchDigest? {
        guard let d = entry.digest, d.isToday(entry.date) else { return nil }
        return d
    }

    private var countText: String { today.map { "\($0.unread)" } ?? "–" }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "bell.fill").font(.system(size: 11, weight: .semibold))
                    Text(countText)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                }
            }
            .widgetAccentable()
            .containerBackground(for: .widget) { Color.clear }
        case .accessoryCorner:
            Image(systemName: "bell.fill")
                .font(.system(size: 20, weight: .semibold))
                .widgetLabel { Text("未读 \(countText)") }
                .containerBackground(for: .widget) { Color.clear }
        case .accessoryInline:
            Label(inlineText, systemImage: "bell")
                .containerBackground(for: .widget) { Color.clear }
        default:   // .accessoryRectangular
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "bell.fill").font(.caption2)
                    Text("Notihub").font(.headline)
                }
                .widgetAccentable()
                if let d = today {
                    Text("未读 \(d.unread) · 通知 \(d.total) 条").font(.caption)
                    Text(d.headline.isEmpty ? "合并后 \(d.events) 件事" : d.headline)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(entry.digest == nil ? "在 iPhone 上打开 Notihub" : T("watch.not_today", "今天的摘要还没同步"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(for: .widget) { Color.clear }
        }
    }

    private var inlineText: String {
        guard let d = today else { return "Notihub" }
        return "未读 \(d.unread) · \(d.total) 条通知"
    }
}
