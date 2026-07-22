import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuController: NSObject {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private var settingsWindow: NSWindow?
    private var modelObservation: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.title = "🔄"
            button.toolTip = "Slack Status Sync"
        }

        rebuildMenu()
        modelObservation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.rebuildMenu()
            }
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let lastUpdate = NSMenuItem(
            title: "Last Slack update: \(model.formatMenuDate(model.lastSlackUpdateAt))",
            action: nil,
            keyEquivalent: ""
        )
        lastUpdate.isEnabled = false
        menu.addItem(lastUpdate)

        let lastPoll = NSMenuItem(
            title: "Last poll: \(model.formatMenuDate(model.lastPollAt))",
            action: nil,
            keyEquivalent: ""
        )
        lastPoll.isEnabled = false
        menu.addItem(lastPoll)

        if let error = model.lastError {
            let errItem = NSMenuItem(
                title: "Error: \(error)",
                action: nil,
                keyEquivalent: ""
            )
            errItem.isEnabled = false
            menu.addItem(errItem)
        } else if model.isPaused {
            let paused = NSMenuItem(title: "Status: Paused", action: nil, keyEquivalent: "")
            paused.isEnabled = false
            menu.addItem(paused)
        } else if model.isSyncing {
            let syncing = NSMenuItem(title: "Status: Syncing…", action: nil, keyEquivalent: "")
            syncing.isEnabled = false
            menu.addItem(syncing)
        } else {
            let ok = NSMenuItem(title: "Status: Running", action: nil, keyEquivalent: "")
            ok.isEnabled = false
            menu.addItem(ok)
        }

        menu.addItem(.separator())

        let syncNow = NSMenuItem(
            title: "Sync Now",
            action: #selector(syncNowAction),
            keyEquivalent: "s"
        )
        syncNow.target = self
        syncNow.isEnabled = !model.isPaused && !model.isSyncing
        menu.addItem(syncNow)

        let pause = NSMenuItem(
            title: model.isPaused ? "Resume" : "Pause",
            action: #selector(pauseAction),
            keyEquivalent: "p"
        )
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Slack Status Sync",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func syncNowAction() {
        Task { await model.syncNow() }
    }

    @objc private func pauseAction() {
        model.togglePause()
        rebuildMenu()
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    @objc private func quitAction() {
        model.stop()
        NSApp.terminate(nil)
    }

    func openSettings() {
        model.showSettings = true
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsRootView(model: model)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Slack Status Sync — Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
