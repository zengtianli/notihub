import Foundation
#if os(iOS)
import WatchConnectivity
#endif

@MainActor
final class WatchLink: NSObject {
    static let shared = WatchLink()

    #if os(iOS)
    private weak var store: Store?
    private var sent: WatchDigest?
    private var sentUnread: Int?

    func activate(store: Store) {
        self.store = store
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        if session.activationState != .activated { session.activate() }
    }

    private var watchReady: Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    func sync() async {
        guard watchReady, let store else { return }
        #if DEBUG
        if DemoData.enabled { return }
        #endif
        let date = store.landingDate
        guard let day = await store.day(date) else { return }
        publish(WatchDigest.make(day: day, open: store.open, timezone: store.cloudTimezone, lastSync: store.lastSync,
                                 ui: Remote.ui))
    }

    private func publish(_ digest: WatchDigest) {
        guard digest != sent, let data = try? JSONEncoder().encode(digest) else { return }
        let session = WCSession.default
        let payload: [String: Any] = [WatchDigest.contextKey: data]
        do { try session.updateApplicationContext(payload) } catch { return }
        sent = digest
        if session.isComplicationEnabled, digest.unread != sentUnread, session.remainingComplicationUserInfoTransfers > 0 {
            session.transferCurrentComplicationUserInfo(payload)
        }
        sentUnread = digest.unread
    }

    fileprivate func watchChanged() {
        sent = nil
        sentUnread = nil
        Task { await sync() }
    }
    #else
    func activate(store: Store) {}
    func sync() async {}
    #endif
}

#if os(iOS)
extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        guard state == .activated else { return }
        Task { @MainActor in await self.sync() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.watchChanged() }
    }
}
#endif
