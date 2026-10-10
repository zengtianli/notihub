// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "notifhub-bar",
    platforms: [.macOS(.v13)],          // MenuBarExtra 最低要求
    products: [
        .executable(name: "notifhub-bar", targets: ["notifhub"])
    ],
    targets: [
        .executableTarget(
            name: "notifhub",
            path: "Sources/notifhub",
            exclude: ["shared/main.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "NotifhubTests", dependencies: ["notifhub"], path: "Tests",
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
