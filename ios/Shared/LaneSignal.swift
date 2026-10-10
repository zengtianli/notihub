import Foundation
import os
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum LaneSignal {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "lane",
                                    category: "lane")
    @MainActor private static var announced = false

    @MainActor static func ready(_ screen: String) {
        guard !announced else { return }
        announced = true
        log.notice("lane-ready \(screen, privacy: .public)")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            log.notice("lane-settled \(screen, privacy: .public)")
            #if os(macOS)
            writeSnapshotIfAsked()
            #endif
        }
    }

    @MainActor static func applyOrientation() {
        #if os(iOS)
        guard UserDefaults.standard.string(forKey: "lane_orientation") == "landscape",
              UIDevice.current.userInterfaceIdiom == .pad else { return }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                log.error("lane-orientation \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }

    @MainActor static func applyWindowFrame() {
        #if os(macOS)
        guard let spec = UserDefaults.standard.string(forKey: "lane_window") else { return }
        let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 400, parts[1] >= 300 else { return }
        let size = CGSize(width: parts[0], height: parts[1])
        Task { @MainActor in
            for _ in 0..<30 {   // 窗口在第一帧之后才挂上来
                if quiet, let window = laneWindow {
                    window.setContentSize(size)      // 静默：窗口不上屏，按内容区出图，正好 2 倍 = 商店尺寸
                    log.notice("lane-window \(Int(size.width))x\(Int(size.height)) content, quiet")
                    return
                }
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                    let fits = NSScreen.screens.filter {
                        $0.visibleFrame.width >= size.width && $0.visibleFrame.height >= size.height
                    }
                    let screen = fits.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? window.screen
                    let area = screen?.visibleFrame ?? window.frame
                    window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                           width: size.width, height: size.height), display: true)
                    log.notice("lane-window \(Int(size.width))x\(Int(size.height)) @\(window.backingScaleFactor)x")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        #endif
    }

    #if os(macOS)
    static var quiet: Bool { UserDefaults.standard.bool(forKey: "lane_quiet") }

    @MainActor static var laneWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.titled) && $0.contentView != nil }
    }

    @MainActor static func enterQuietIfAsked() {
        guard quiet else { return }
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.alphaValue != 0 {
                    window.alphaValue = 0
                    window.ignoresMouseEvents = true
                    window.collectionBehavior.insert([.transient, .ignoresCycle])
                    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                }
            }
        }
        log.notice("lane-quiet accessory")
    }

    @MainActor static func writeSnapshotIfAsked() {
        guard quiet, let path = UserDefaults.standard.string(forKey: "lane_snapshot") else { return }
        guard let view = laneWindow?.contentView else {
            log.error("lane-snapshot failed: no window")
            return
        }
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            log.error("lane-snapshot failed: no bitmap")
            return
        }
        rep.size = size                      // 点尺寸不变、像素翻倍 = 2 倍渲染，与本机接的是几倍屏无关
        view.cacheDisplay(in: view.bounds, to: rep)
        do {
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: URL(fileURLWithPath: path))
            log.notice("lane-snapshot \(Int(size.width * 2))x\(Int(size.height * 2)) \(path, privacy: .public)")
        } catch {
            log.error("lane-snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}

#if os(macOS)
final class LaneAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { LaneSignal.enterQuietIfAsked() }
    }
}
#endif
