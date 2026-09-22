// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pennant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PennantCore", targets: ["PennantCore"]),
        .executable(name: "TestRunner", targets: ["TestRunner"]),
    ],
    targets: [
        .target(
            name: "PennantCore",
            path: "Pennant",
            exclude: [
                "PennantApp.swift",
                "Info.plist",
                "Pennant.entitlements",
                "Assets.xcassets",
                "Views",
            ]
        ),
        // Fallback test runner for environments without full Xcode/XCTest.
        // With Xcode installed, prefer `xcodebuild test` via scripts/check.sh.
        .executableTarget(
            name: "TestRunner",
            dependencies: ["PennantCore"],
            path: "PennantTests"
        ),
    ]
)
