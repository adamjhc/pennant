import Foundation
import ServiceManagement

@MainActor
final class LoginItemService: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered

    func refresh() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var statusLabel: String {
        switch status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Not registered"
        case .notFound: return "Not found"
        case .requiresApproval: return "Requires approval in System Settings"
        @unknown default: return "Unknown"
        }
    }

    /// Only register when running from /Applications so the login item path stays stable.
    var canRegister: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard canRegister else {
            return false
        }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled {
                try service.unregister()
            }
            refresh()
            return true
        } catch {
            refresh()
            return false
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
