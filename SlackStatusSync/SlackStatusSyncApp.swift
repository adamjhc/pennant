import SwiftUI
import AppKit

@main
struct SlackStatusSyncApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: appModel)
        } label: {
            Image(systemName: "calendar.badge.clock")
                .symbolRenderingMode(.hierarchical)
        }

        // Menu-bar (LSUIElement) apps often cannot open the system Settings scene.
        // A named Window is reliable with openWindow(id:).
        Window("Settings", id: "settings") {
            SettingsView(model: appModel)
                .onAppear { appModel.start() }
        }
        .defaultSize(width: 640, height: 720)
        .windowResizability(.contentMinSize)
    }
}
