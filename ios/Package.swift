// swift-tools-version: 5.9
import Foundation
import PackageDescription

let core = ["Sources/API.swift", "Sources/Models.swift", "Sources/Store.swift", "Sources/Gate.swift",
            "Sources/Writer.swift", "Sources/DemoData.swift", "Sources/DemoFeed.swift", "Sources/Reminders.swift",
            "Sources/AgendaBuckets.swift", "Sources/WatchDigest.swift",
            "Shared/RemoteUI.swift"]

func entries(_ directory: String) -> [String] {
    let path = directory.isEmpty ? Context.packageDirectory : Context.packageDirectory + "/" + directory
    return ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
        .filter { !$0.hasPrefix(".") && $0 != "Package.swift" && $0 != "Package.resolved" }
        .map { directory.isEmpty ? $0 : directory + "/" + $0 }.sorted()
}
let coreDirectories = Set(core.map { String($0.split(separator: "/")[0]) })
let notCore = entries("").filter { !coreDirectories.contains($0) }
    + coreDirectories.sorted().flatMap(entries).filter { !core.contains($0) }

let package = Package(
    name: "DayDeckCore",
    platforms: [.macOS("15.0")],
    products: [.library(name: "DayDeckCore", targets: ["DayDeckCore"])],
    targets: [
        .target(name: "DayDeckCore", path: ".", exclude: notCore, sources: core),
        .testTarget(name: "DayDeckCoreTests", dependencies: ["DayDeckCore"], path: "Tests",
                    exclude: ["check-platform-typecheck.sh"])
    ],
    swiftLanguageVersions: [.v5]
)
