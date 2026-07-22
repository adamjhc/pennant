import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var menuController: MenuController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        LegacyCleanup.runIfNeeded()

        model = AppModel()
        menuController = MenuController(model: model)
        model.start()

        if model.showSettings || model.isFirstRun {
            menuController.openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuController?.openSettings()
        return true
    }
}

/// One-time removal of the CLI/launchd data directory and legacy Keychain token.
enum LegacyCleanup {
    private static let flagName = ".legacy-cleanup-done"

    static func runIfNeeded() {
        let flag = AppPaths.applicationSupport.appendingPathComponent(flagName)
        if FileManager.default.fileExists(atPath: flag.path) {
            return
        }

        // Unload old launchd agent if present.
        let uid = getuid()
        let domain = "gui/\(uid)/com.slack-status-sync"
        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["bootout", domain]
        try? unload.run()
        unload.waitUntilExit()

        let legacyDir = AppPaths.legacyDataDir
        if FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.removeItem(at: legacyDir)
        }

        let legacyHelper = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Slack Status Sync Calendar.app")
        if FileManager.default.fileExists(atPath: legacyHelper.path) {
            try? FileManager.default.removeItem(at: legacyHelper)
        }

        KeychainService.deleteLegacyToken()

        try? "done".write(to: flag, atomically: true, encoding: .utf8)
    }
}

@main
enum SlackStatusSyncMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
