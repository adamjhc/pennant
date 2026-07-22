import Foundation

enum AppPaths {
    static let appName = "Slack Status Sync"
    static let bundleID = "com.slack-status-sync.app"
    static let keychainService = "com.slack-status-sync.app"
    static let keychainAccount = "slack-user-token"
    static let tokenMask = "••••••••••••••••"

    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: dir.path
        )
        return dir
    }

    static var settingsURL: URL {
        applicationSupport.appendingPathComponent("settings.json")
    }

    static var stateURL: URL {
        applicationSupport.appendingPathComponent("state.json")
    }

    static var logURL: URL {
        applicationSupport.appendingPathComponent("sync.log")
    }

    static var firstRunFlagURL: URL {
        applicationSupport.appendingPathComponent(".first-run-complete")
    }

    /// Bundled Node SEA sidecar.
    static var sidecarURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "slack-status-sync-core")
            ?? Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/slack-status-sync-core")
    }

    static var legacyDataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".slack-status-sync", isDirectory: true)
    }
}
