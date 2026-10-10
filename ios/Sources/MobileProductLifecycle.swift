import Foundation

@MainActor
enum MobileProductLifecycle {
    static var channel: MobileUpdateChannel {
        return .unreleased(helpURL: nil, instructions: "Build from source; no public mobile release is available.")
    }
    static let configuration: AppConfiguration? = nil
}
