import SwiftUI
import WidgetKit

@main
struct NotihubWatchApp: App {
    @StateObject private var link = WatchDigestReceiver.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView().environmentObject(link)
                .accentColor(.accentOnDark)
                .tint(.accentOnDark)
        }
        .backgroundTask(.watchConnectivity) {
            await WatchDigestReceiver.shared.drain()
        }
    }
}

struct WatchRootView: View {
    @EnvironmentObject var link: WatchDigestReceiver

    var body: some View {
        Group {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "complications") {
                ComplicationGallery(digest: link.digest)
            } else {
                content
            }
            #else
            content
            #endif
        }
        .task {
            LaneSignal.applyOrientation()
            LaneSignal.applyWindowFrame()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let digest = link.digest {
            WatchHomeView(digest: digest, receivedAt: link.receivedAt)
        } else {
            WatchWaitingView()
        }
    }
}

struct WatchWaitingView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("在 iPhone 上打开 Notihub")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("今天的通知摘要会自动同步到手表")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 6)
    }
}

#if DEBUG
private struct ComplicationGallery: View {
    let digest: WatchDigest?

    var body: some View {
        let entry = DigestEntry(date: .now, digest: digest)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    DigestComplicationView(entry: entry, familyOverride: .accessoryCircular)
                        .frame(width: 50, height: 50)
                    DigestComplicationView(entry: entry, familyOverride: .accessoryCorner)
                        .frame(width: 50, height: 50)
                }
                DigestComplicationView(entry: entry, familyOverride: .accessoryRectangular)
                    .frame(height: 52)
                DigestComplicationView(entry: entry, familyOverride: .accessoryInline)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .onAppear { LaneSignal.ready("watch-complications") }
    }
}
#endif
