import AppKit
import Combine
import Sparkle

@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        updaterDelegate: nil,
        userDriverDelegate: self
    )

    var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // Pennant has no Dock icon, so Sparkle shows scheduled update alerts without stealing focus.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
