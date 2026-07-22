import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure.failed(message)
    }
}

@main
enum NativeModelChecks {
    static func main() throws {
        var settings = AppSettings.freshDefaults()
        settings.rules.swapAt(0, 2)
        settings.applyDragPrioritiesInPlace()
        try expect(
            settings.rules.map(\.priority) == [10, 20, 30],
            "Drag order must rewrite priorities to 10, 20, 30"
        )
        try expect(
            settings.rules.first?.eventNameContains == "Standup",
            "Drag order must preserve reordered rules"
        )

        settings.calendarNames = []
        let wire = settings.asWire()
        try expect(wire["calendarNames"] != nil, "Empty calendar selection must be present on wire")
        try expect(
            (wire["calendarNames"] as? [String]) == [],
            "Empty calendar selection must remain empty"
        )

        let calendars = [
            LocalCalendarInfo(id: "work", title: "Work", source: "Exchange"),
            LocalCalendarInfo(id: "home", title: "Home", source: "iCloud"),
        ]
        let defaultSelection = CalendarSelection.initialNames(
            configuredNames: nil,
            availableCalendars: calendars
        )
        try expect(
            defaultSelection == Set(["Work", "Home"]),
            "An omitted calendar selection must default to all visible calendars"
        )

        let explicitEmpty = CalendarSelection.initialNames(
            configuredNames: [],
            availableCalendars: calendars
        )
        try expect(explicitEmpty.isEmpty, "An explicit empty selection must stay empty")
        try expect(
            CalendarSelection.persistedNames(Set(["work", "Home"])) == ["Home", "work"],
            "Persisted calendar names must be deterministic"
        )
        try expect(MenuLabelFormatting.lastUpdate(nil) == "Never", "Nil update date must show Never")
        try expect(
            MenuLabelFormatting.errorFingerprint(code: "sync", message: "failed") == "sync|failed",
            "Error fingerprint must be stable"
        )

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slack-status-sync-native-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let settingsURL = tempDirectory.appendingPathComponent("settings.json")
        try settings.saveAtomically(to: settingsURL)
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(contentsOf: settingsURL)
        )
        try expect(
            decoded.rules.map(\.priority) == [10, 20, 30],
            "Atomic settings persistence must preserve normalized priorities"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: settingsURL.path)
        try expect(
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            "Settings file permissions must be 0600"
        )

        print("Native model checks passed.")
    }
}
