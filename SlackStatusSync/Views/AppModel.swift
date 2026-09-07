import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var menuSnapshot = MenuSnapshot(state: .setupRequired)
    @Published var showSettings = false
    @Published var settingsVersion = 0

    let calendarService: EventKitCalendarService
    let settingsStore: FileSettingsStore
    let runtimeStore: FileRuntimeStateStore
    let tokenStore: KeychainTokenStore
    let slackClient: SlackClient
    let launchAtLogin: LaunchAtLoginService
    let coordinator: SyncCoordinator
    let settingsViewModel: SettingsViewModel

    private var wakeObserver: NSObjectProtocol?
    private var timerScheduler: RunLoopScheduler
    private var syncActivity: NSObjectProtocol?
    private var didStart = false

    init() {
        let calendar = EventKitCalendarService()
        let settingsStore = (try? FileSettingsStore()) ?? FileSettingsStore(directory: FileManager.default.temporaryDirectory)
        let runtimeStore = (try? FileRuntimeStateStore()) ?? FileRuntimeStateStore(directory: FileManager.default.temporaryDirectory)
        let tokenStore = KeychainTokenStore()
        let slack = SlackClient()
        let launch = LaunchAtLoginService()
        let scheduler = RunLoopScheduler()

        self.calendarService = calendar
        self.settingsStore = settingsStore
        self.runtimeStore = runtimeStore
        self.tokenStore = tokenStore
        self.slackClient = slack
        self.launchAtLogin = launch
        self.timerScheduler = scheduler

        let coordinator = SyncCoordinator(
            calendar: calendar,
            slack: slack,
            settingsStore: settingsStore,
            runtimeStore: runtimeStore,
            tokenStore: tokenStore,
            scheduler: scheduler
        )
        self.coordinator = coordinator

        self.settingsViewModel = SettingsViewModel(
            settingsStore: settingsStore,
            runtimeStore: runtimeStore,
            tokenStore: tokenStore,
            calendar: calendar,
            slack: slack,
            launchAtLogin: launch
        )

        coordinator.onMenuSnapshotChange = { [weak self] snapshot in
            Task { @MainActor in
                self?.menuSnapshot = snapshot
            }
        }

        calendar.onStoreChanged = { [weak self] in
            Task { await self?.coordinator.calendarDidChange() }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.slackClient.resetNetworkSession()
            AppLogger.info("system wake; reset Slack network session", category: "sync")
            Task { await self.coordinator.systemDidWake() }
        }

        // Start polling at launch — MenuBarExtra menu onAppear only runs when opened.
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    func start() {
        guard !didStart else {
            menuSnapshot = coordinator.currentMenuSnapshot()
            return
        }

        didStart = true
        // Reduce App Nap deferring our 60s poll while the menu-bar app has no windows.
        syncActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Polling calendar to sync Slack status"
        )
        coordinator.start()
        menuSnapshot = coordinator.currentMenuSnapshot()
        if menuSnapshot.state == .setupRequired {
            showSettings = true
        }
    }

    /// Prefer `openWindow(id:)` from SwiftUI views.
    func openSettingsWindow() {
        showSettings = true
    }

    func syncNow() {
        Task { await coordinator.syncNow() }
    }

    func togglePause() {
        coordinator.togglePause()
        menuSnapshot = coordinator.currentMenuSnapshot()
    }

    func settingsDidSave() {
        Task {
            await coordinator.settingsDidSave()
            settingsVersion += 1
            menuSnapshot = coordinator.currentMenuSnapshot()
        }
    }

    deinit {
        if let syncActivity {
            ProcessInfo.processInfo.endActivity(syncActivity)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        coordinator.stop()
    }
}

/// Main-run-loop timers survive menu-bar App Nap better than plain GCD asyncAfter.
final class RunLoopScheduler: SchedulerProtocol, @unchecked Sendable {
    private var timers: [String: Timer] = [:]
    private let lock = NSLock()

    func schedule(after interval: TimeInterval, id: String, work: @escaping @Sendable () -> Void) {
        // Timer must be created/added on the main thread for the main run loop.
        DispatchQueue.main.async {
            self.lock.lock()
            self.timers[id]?.invalidate()
            self.timers.removeValue(forKey: id)
            self.lock.unlock()

            let timer = Timer(timeInterval: max(0.1, interval), repeats: false) { [weak self] _ in
                self?.lock.lock()
                self?.timers.removeValue(forKey: id)
                self?.lock.unlock()
                work()
            }
            // .common keeps firing while menu tracking / scrolling runs.
            RunLoop.main.add(timer, forMode: .common)

            self.lock.lock()
            self.timers[id] = timer
            self.lock.unlock()
        }
    }

    func cancel(id: String) {
        DispatchQueue.main.async {
            self.lock.lock()
            self.timers[id]?.invalidate()
            self.timers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    func cancelAll() {
        DispatchQueue.main.async {
            self.lock.lock()
            self.timers.values.forEach { $0.invalidate() }
            self.timers.removeAll()
            self.lock.unlock()
        }
    }
}
