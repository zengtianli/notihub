import SwiftUI
import WidgetKit

struct DigestProvider: TimelineProvider {
    func placeholder(in context: Context) -> DigestEntry { DigestEntry(date: .now, digest: nil) }

    private func latest() -> WatchDigest? {
        let digest = DigestVault.load()?.digest
        Remote.ui = digest?.ui?.value
        return digest
    }

    func getSnapshot(in context: Context, completion: @escaping (DigestEntry) -> Void) {
        completion(DigestEntry(date: .now, digest: latest()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DigestEntry>) -> Void) {
        let digest = latest()
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = digest?.cloudTimeZone ?? .current
        let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(86_400)
        completion(Timeline(entries: [DigestEntry(date: now, digest: digest), DigestEntry(date: midnight, digest: digest)],
                            policy: .never))
    }
}

@main
struct NotihubComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NotihubUnread", provider: DigestProvider()) { entry in
            DigestComplicationView(entry: entry)
        }
        .configurationDisplayName("Notihub")
        .description("今天还有几件通知没点开")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
