// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SlackStatusSyncNativeChecks",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NativeModelChecks", targets: ["NativeModelChecks"]),
    ],
    targets: [
        .executableTarget(
            name: "NativeModelChecks",
            path: ".",
            exclude: [
                "AppEntitlements.plist",
                "Info.plist",
                "SidecarEntitlements.plist",
                "Sources/AppDelegate.swift",
                "Sources/AppModel.swift",
                "Sources/EventKitService.swift",
                "Sources/KeychainService.swift",
                "Sources/LoginItemService.swift",
                "Sources/MenuController.swift",
                "Sources/NotificationService.swift",
                "Sources/SettingsView.swift",
                "Sources/SidecarClient.swift",
            ],
            sources: [
                "Sources/AppPaths.swift",
                "Sources/SettingsModels.swift",
                "Sources/MenuLabelFormatting.swift",
                "Tests/NativeModelChecks.swift",
            ]
        ),
    ]
)
