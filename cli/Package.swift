// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "notifhub",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "notifhub",
            path: "Sources/notifhub",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        .testTarget(name: "notifhubTests", dependencies: ["notifhub"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
