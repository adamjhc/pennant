// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SlackStatusSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SlackStatusSyncCore", targets: ["SlackStatusSyncCore"]),
        .executable(name: "TestRunner", targets: ["TestRunner"]),
    ],
    targets: [
        .target(
            name: "SlackStatusSyncCore",
            path: "SlackStatusSync",
            exclude: [
                "SlackStatusSyncApp.swift",
                "Info.plist",
                "SlackStatusSync.entitlements",
                "Assets.xcassets",
                "Views",
            ]
        ),
        // Fallback test runner for environments without full Xcode/XCTest.
        // With Xcode installed, prefer `xcodebuild test` via scripts/check.sh.
        .executableTarget(
            name: "TestRunner",
            dependencies: ["SlackStatusSyncCore"],
            path: "SlackStatusSyncTests"
        ),
    ]
)
