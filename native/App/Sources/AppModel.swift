import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let eventKit = EventKitService()
    let loginItem = LoginItemService()
    let notifications = NotificationService()
    let sidecar = SidecarClient()

    @Published var settings: AppSettings
    @Published var hasToken: Bool = false
    @Published var isPaused: Bool = false
    @Published var isSyncing: Bool = false
    @Published var lastPollAt: Date?
    @Published var lastSlackUpdateAt: Date?
    @Published var lastError: String?
    @Published var showSettings: Bool = false
    @Published var isFirstRun: Bool = false
    @Published var needsSetup: Bool = false

    private var pollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init() {
        let hasCompletedFirstRun = FileManager.default.fileExists(
            atPath: AppPaths.firstRunFlagURL.path
        )
        if let loaded = AppSettings.load() {
            settings = loaded
            isFirstRun = !hasCompletedFirstRun
        } else {
            settings = .freshDefaults()
            isFirstRun = true
        }
        hasToken = KeychainService.hasToken()
    }

    func start() {
        notifications.configure()
        eventKit.refreshStatus()
        loginItem.refresh()
        hasToken = KeychainService.hasToken()

        needsSetup =
            !FileManager.default.fileExists(atPath: AppPaths.settingsURL.path)
            || !hasToken
            || !eventKit.isAuthorized
        if isFirstRun || needsSetup {
            showSettings = true
        }

        // Enable launch at login by default on first successful install from /Applications.
        if isFirstRun, loginItem.canRegister, !loginItem.isEnabled {
            _ = loginItem.setEnabled(true)
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.schedulePolling(reset: true)
                if self?.isPaused == false {
                    await self?.syncNow()
                }
            }
        }

        schedulePolling(reset: true)
        Task {
            await hydrateTelemetry()
            if !isPaused && (!isFirstRun || (hasToken && eventKit.isAuthorized)) {
                await syncNow()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        Task { await sidecar.shutdown() }
    }

    func schedulePolling(reset: Bool) {
        if reset {
            pollTimer?.invalidate()
            pollTimer = nil
        }
        guard pollTimer == nil else { return }
        let interval = TimeInterval(max(5, settings.pollIntervalSeconds))
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                await self.syncNow()
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    func togglePause() {
        isPaused.toggle()
        if !isPaused {
            Task { await syncNow() }
        }
    }

    func markFirstRunCompleteIfReady() {
        if hasToken, eventKit.isAuthorized, FileManager.default.fileExists(atPath: AppPaths.settingsURL.path) {
            isFirstRun = false
            needsSetup = false
            try? "ok".write(to: AppPaths.firstRunFlagURL, atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    func syncNow() async -> Bool {
        guard !isSyncing else { return false }
        if isPaused {
            return false
        }
        guard eventKit.isAuthorized else {
            lastError = "Calendar Full Access is not granted"
            notifications.recordFailure(
                code: "calendar_permission",
                message: lastError!,
                immediate: true
            )
            return false
        }
        guard let token = KeychainService.readToken() else {
            lastError = "Slack token missing — open Settings"
            notifications.recordFailure(code: "missing_token", message: lastError!)
            showSettings = true
            return false
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            var working = settings
            working.applyDragPrioritiesInPlace()

            let events = try eventKit.fetchEvents(
                lookBehindMinutes: working.lookBehindMinutes,
                lookAheadMinutes: working.lookAheadMinutes
            )

            let response = try await sidecar.requestWithRestart(
                method: "sync",
                params: [
                    "settings": working.asWire(),
                    "events": events.map { $0.asDictionary() },
                    "slackToken": token,
                    "now": isoFormatter.string(from: Date()),
                ],
                timeout: 90
            )
            let result = try await sidecar.unwrapResult(response)

            if let poll = result["lastPollAt"] as? String {
                lastPollAt = parseDate(poll)
            } else {
                lastPollAt = Date()
            }
            if let applied = result["lastSlackUpdateAt"] as? String {
                lastSlackUpdateAt = parseDate(applied)
            }
            lastError = nil
            notifications.clearFailures()
            return true
        } catch {
            lastError = error.localizedDescription
            let immediate = error.localizedDescription.lowercased().contains("calendar")
            notifications.recordFailure(
                code: "sync_failed",
                message: error.localizedDescription,
                immediate: immediate
            )
            return false
        }
    }

    func saveSettingsFromUI(
        draft: AppSettings,
        replacementToken: String?
    ) async -> String? {
        var toSave = draft
        toSave.applyDragPrioritiesInPlace()

        // Validate rules locally first.
        if toSave.rules.isEmpty {
            return "Add at least one rule"
        }
        for (index, rule) in toSave.rules.enumerated() {
            if rule.eventNameContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Rule \(index + 1): event match text is required"
            }
            if rule.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Rule \(index + 1): status is required"
            }
            if rule.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Rule \(index + 1): emoji is required"
            }
            if rule.notifications != "snooze" && rule.notifications != "normal" {
                return "Rule \(index + 1): notifications must be snooze or normal"
            }
        }

        let trimmedReplacement = replacementToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasReplacement = !(trimmedReplacement ?? "").isEmpty

        if !hasToken && !hasReplacement {
            return "Paste a Slack user token (xoxp-...)"
        }

        do {
            // The sidecar validates the exact schema and replacement token.
            // Swift is the sole owner of settings and Keychain persistence.
            var params: [String: Any] = ["settings": toSave.asWire()]
            if hasReplacement, let trimmedReplacement {
                params["slackToken"] = trimmedReplacement
            }

            let response = try await sidecar.requestWithRestart(
                method: "settings.validate",
                params: params,
                timeout: 60
            )
            _ = try await sidecar.unwrapResult(response)

            let previousToken = KeychainService.readToken()
            if hasReplacement, let trimmedReplacement {
                try KeychainService.saveToken(trimmedReplacement)
            }

            do {
                try toSave.saveAtomically()
            } catch {
                if hasReplacement {
                    do {
                        if let previousToken {
                            try KeychainService.saveToken(previousToken)
                        } else {
                            KeychainService.deleteToken()
                        }
                    } catch {
                        return "Settings save failed and the previous Slack token could not be restored."
                    }
                }
                throw error
            }

            settings = toSave
            hasToken = KeychainService.hasToken()
            markFirstRunCompleteIfReady()
            schedulePolling(reset: true)
            if !isPaused {
                await syncNow()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func hydrateTelemetry() async {
        do {
            let response = try await sidecar.requestWithRestart(
                method: "settings.get",
                timeout: 10
            )
            let result = try await sidecar.unwrapResult(response)
            if let poll = result["lastPollAt"] as? String {
                lastPollAt = parseDate(poll)
            }
            if let applied = result["lastSlackUpdateAt"] as? String {
                lastSlackUpdateAt = parseDate(applied)
            }
        } catch {
            // The first normal sync will surface a sidecar error if it persists.
        }
    }

    private func parseDate(_ value: String) -> Date? {
        if let d = isoFormatter.date(from: value) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)
    }

    func formatMenuDate(_ date: Date?) -> String {
        MenuLabelFormatting.lastUpdate(date)
    }
}
