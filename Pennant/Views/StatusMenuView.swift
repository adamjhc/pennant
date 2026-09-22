import SwiftUI
import AppKit

struct StatusMenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let snap = model.menuSnapshot
        VStack(alignment: .leading, spacing: 4) {
            Text(stateLabel(snap))
                .font(.headline)
            if let ends = snap.controllingEndsAt {
                Text("Until \(ends.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let last = snap.lastSuccessfulSyncAt {
                Text("Last sync \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = snap.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Divider()
            Button("Sync Now") {
                model.syncNow()
            }
            Button(snap.isPaused ? "Resume" : "Pause") {
                model.togglePause()
            }
            Button("Settings…") {
                openSettings()
            }
            Divider()
            Button("Quit Pennant") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(4)
        .onAppear {
            model.start()
            if model.menuSnapshot.state == .setupRequired {
                openSettings()
            }
        }
        .onChange(of: model.showSettings) { _, shouldOpen in
            guard shouldOpen else { return }
            openSettings()
            model.showSettings = false
        }
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func stateLabel(_ snap: MenuSnapshot) -> String {
        switch snap.state {
        case .setupRequired: return "Setup required"
        case .idle: return "Idle — no matching event"
        case .syncing: return "Syncing…"
        case .active: return "Active status sync"
        case .paused: return "Paused"
        case .error: return "Error"
        }
    }
}
