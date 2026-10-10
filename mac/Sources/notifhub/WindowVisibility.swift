import AppKit
import SwiftUI

struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { probe.onChange = onChange }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private var reported: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { report(false); return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.evaluate() }
            evaluate()
        }

        private func evaluate() { report(window?.occlusionState.contains(.visible) == true) }

        private func report(_ visible: Bool) {
            guard visible != reported else { return }
            reported = visible
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
