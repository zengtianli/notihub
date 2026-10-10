import AppKit
import SwiftUI

#if !DEMO_CAPTURE

@main
enum NotifhubEntryPoint {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--collector-update" {
            exit(CollectorUpdate.main(Array(CommandLine.arguments.dropFirst(2))))
        }
        let words = Array(CommandLine.arguments.dropFirst())
        if AppLifecycleCLI.handles(words.first) { exit(Lifecycle.run(words)) }
        if words.first == Lifecycle.probeFlag { Lifecycle.runFollowProbe(words) }
        DataRichText.install()
        if let position = CommandLine.arguments.firstIndex(of: "--data-probe") {
            let arguments = CommandLine.arguments
            guard arguments.indices.contains(position + 1) else {
                fputs("用法：NotifhubBar --data-probe <输出 JSON 文件>\n", stderr); exit(64)
            }
            do { try DataProbe.run(output: URL(fileURLWithPath: arguments[position + 1])); exit(0) }
            catch { fputs("数据探针失败：\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--ui-self-test") {
            do { try UISelfTest.run(); exit(0) }
            catch { fputs("UI self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        NotifhubBarApp.main()
    }
}

struct NotifhubBarApp: App {

    init() {
        if CommandLine.arguments.contains("--recap-url") {
            print(TodayModel.onlineRecapURL.absoluteString)
            exit(0)
        }
        if CommandLine.arguments.contains("--render-recap") {
            do { print(try TodayModel.renderRecap(false).path); exit(0) }
            catch { fputs("完整复盘失败：\(error.localizedDescription)\n", stderr); exit(1) }
        }
        guard !CommandLine.arguments.contains("--demo") else { return }
        if let store = Lifecycle.store() { Lifecycle.installApp(store) }
    }

    @StateObject private var badge = TodayModel.shared.badge
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Notihub", id: "cloud") {
            CloudWindowView()
        }
        .defaultSize(width: 1100, height: 760)
        MenuBarExtra(isInserted: .constant(!LaneSignal.quiet)) {
            MenuPanel(model: TodayModel.shared)
                .onAppear { TodayModel.shared.refresh() }
        } label: {
            if badge.unread > 0 {
                Image(systemName: "bell.badge.fill")
                Text("\(badge.unread)")
            } else {
                Image(systemName: "bell")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuPanel: View {
    @ObservedObject var model: TodayModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 0) {
            Button {
                openWindow(id: "cloud")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack {
                    Label("打开 Notihub", systemImage: "macwindow")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }.padding(16)
            }.buttonStyle(.plain)
            Divider()
            HStack {
                Button(Lifecycle.windowEntry) { AppLifecycleUI.shared.show() }
                Spacer()
                Button("检查更新…") { AppLifecycleUI.shared.checkForUpdates() }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            TodayPanelView(model: model)
        }.frame(width: 420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { LaneSignal.enterQuietIfAsked() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { UISelfTest.finishDemoSession() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        guard !LaneSignal.quiet else { return }

        guard ProcessInfo.processInfo.environment["NOTIFHUB_BAR_PANEL"] == "1" else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Notihub") · 面板预览"
        w.contentView = NSHostingView(rootView: TodayPanelView(model: TodayModel.shared))
        w.center()
        previewWindow = w
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
