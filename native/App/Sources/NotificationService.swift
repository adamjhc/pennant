import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    @Published private(set) var requestError: String?

    private var lastFingerprint: String?
    private var consecutiveCounts: [String: Int] = [:]

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        status = await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                cont.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAccess() async {
        requestError = nil
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            requestError = "Notification permission request failed: \(error.localizedDescription)"
        }
        await refreshStatus()
    }

    var statusLabel: String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        case .provisional: return "Provisional"
        case .ephemeral: return "Temporary"
        @unknown default: return "Unknown"
        }
    }

    var isAuthorized: Bool {
        status == .authorized || status == .provisional
    }

    func openSystemSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?bundleId=\(AppPaths.bundleID)"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Record a failure. Notifies once per fingerprint after 2 consecutive hits,
    /// or immediately for calendar permission errors.
    func recordFailure(code: String, message: String, immediate: Bool = false) {
        let fingerprint = "\(code)|\(message)"
        let count = (consecutiveCounts[fingerprint] ?? 0) + 1
        consecutiveCounts = [fingerprint: count]

        let shouldNotify = immediate || count >= 2
        guard shouldNotify else { return }
        guard lastFingerprint != fingerprint else { return }
        lastFingerprint = fingerprint

        let content = UNMutableNotificationContent()
        content.title = "Slack Status Sync"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "error-\(fingerprint.hashValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func clearFailures() {
        consecutiveCounts.removeAll()
        lastFingerprint = nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
