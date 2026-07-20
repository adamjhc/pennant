import AppKit
import EventKit
import Foundation

struct CalendarInfo: Codable {
    let id: String
    let title: String
    let source: String?
    let type: String
}

struct EventInfo: Codable {
    let id: String
    let eventIdentifier: String
    let calendarItemExternalIdentifier: String?
    let title: String
    let start: String
    let end: String
    let isAllDay: Bool
    let isCancelled: Bool
    let response: String
    let availability: String
    let calendarName: String
    let calendarId: String
}

struct EventsPayload: Codable {
    let events: [EventInfo]
}

struct CalendarsPayload: Codable {
    let calendars: [CalendarInfo]
}

struct StatusPayload: Codable {
    let authorized: Bool
    let status: String
    let bundleId: String
    let appPath: String
    let calendarCount: Int?
}

struct ErrorPayload: Codable {
    let error: String
    let code: String
    let bundleId: String
}

enum ExitCode: Int32 {
    case success = 0
    case usage = 2
    case permissionDenied = 3
    case invalidArgs = 4
    case runtime = 5
}

/// When set, JSON is written here (for LaunchServices `open` launches where stdout is discarded).
var outputPath: String?

func bundleId() -> String {
    Bundle.main.bundleIdentifier ?? "com.slack-status-sync.calendar-reader"
}

func appPath() -> String {
    Bundle.main.bundlePath
}

func isoString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

func parseISODate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

func emitJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
        let data = try encoder.encode(value)
        if let path = outputPath {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        if let text = String(data: data, encoding: .utf8) {
            print(text)
            fflush(stdout)
        }
    } catch {
        fputs("Failed to encode/write JSON: \(error)\n", stderr)
        exit(ExitCode.runtime.rawValue)
    }
}

func emitError(code: String, message: String, exitCode: ExitCode) -> Never {
    emitJSON(ErrorPayload(error: message, code: code, bundleId: bundleId()))
    exit(exitCode.rawValue)
}

func authorizationStatusName(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .fullAccess: return "fullAccess"
    case .writeOnly: return "writeOnly"
    @unknown default: return "unknown"
    }
}

func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
    if #available(macOS 14.0, *) {
        return status == .fullAccess
    }
    return status.rawValue == 3
}

func calendarTypeName(_ type: EKCalendarType) -> String {
    switch type {
    case .local: return "local"
    case .calDAV: return "calDAV"
    case .exchange: return "exchange"
    case .subscription: return "subscription"
    case .birthday: return "birthday"
    @unknown default: return "unknown"
    }
}

func responseName(_ status: EKEventStatus) -> String {
    switch status {
    case .canceled: return "declined"
    case .confirmed: return "accepted"
    case .tentative: return "tentative"
    case .none: return "none"
    @unknown default: return "unknown"
    }
}

func currentUserResponse(for event: EKEvent) -> String {
    if event.status == .canceled {
        return "declined"
    }
    if let attendees = event.attendees {
        if let me = attendees.first(where: { $0.isCurrentUser }) {
            switch me.participantStatus {
            case .declined: return "declined"
            case .accepted: return "accepted"
            case .tentative: return "tentative"
            case .pending: return "notResponded"
            case .unknown: return "unknown"
            case .delegated: return "delegated"
            case .completed: return "accepted"
            case .inProcess: return "tentative"
            @unknown default: return "unknown"
            }
        }
    }
    return responseName(event.status)
}

func availabilityName(_ value: EKEventAvailability) -> String {
    switch value {
    case .busy: return "busy"
    case .free: return "free"
    case .tentative: return "tentative"
    case .unavailable: return "oof"
    case .notSupported: return "notSupported"
    @unknown default: return "unknown"
    }
}

final class AuthorizeWindowController {
    let window: NSWindow
    let label: NSTextField
    let button: NSButton
    let store = EKEventStore()
    var onFinished: (() -> Void)?

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Slack Status Sync — Calendar Access"
        window.center()
        window.isReleasedWhenClosed = false

        label = NSTextField(wrappingLabelWithString: """
        This app needs Full Access to your calendars so it can update Slack when matching meetings start.

        Click “Request Access”. If macOS shows a permission dialog, choose Allow.
        Afterwards you should see “Slack Status Sync Calendar” under
        System Settings → Privacy & Security → Calendars.
        """)
        label.frame = NSRect(x: 20, y: 70, width: 440, height: 120)

        button = NSButton(title: "Request Access", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 170, y: 20, width: 140, height: 32)
        button.target = self
        button.action = #selector(requestAccess)

        window.contentView?.addSubview(label)
        window.contentView?.addSubview(button)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func requestAccess() {
        button.isEnabled = false
        label.stringValue = "Requesting Calendar access…"

        let status = EKEventStore.authorizationStatus(for: .event)
        if isAuthorized(status) {
            finishSuccess(status: status)
            return
        }

        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] granted, error in
                DispatchQueue.main.async {
                    self?.handleResult(granted: granted, error: error)
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, error in
                DispatchQueue.main.async {
                    self?.handleResult(granted: granted, error: error)
                }
            }
        }
    }

    private func handleResult(granted: Bool, error: Error?) {
        let status = EKEventStore.authorizationStatus(for: .event)
        if granted || isAuthorized(status) {
            finishSuccess(status: status)
            return
        }

        let detail = error.map { String(describing: $0) } ?? "no system dialog / denied"
        label.stringValue = """
        Access not granted (\(detail); status=\(authorizationStatusName(status))).

        Open System Settings → Privacy & Security → Calendars and enable
        “Slack Status Sync Calendar”, then click Request Access again.
        Bundle ID: \(bundleId())
        """
        button.title = "Open Settings & Retry"
        button.isEnabled = true
        button.action = #selector(openSettingsAndRetry)
    }

    @objc func openSettingsAndRetry() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.requestAccess()
        }
    }

    private func finishSuccess(status: EKAuthorizationStatus) {
        let count = store.calendars(for: .event).count
        label.stringValue = """
        Calendar access granted (\(authorizationStatusName(status))).
        Visible calendars: \(count)
        App: \(appPath())

        Keep Full Access enabled for this exact app in
        System Settings → Privacy & Security → Calendars.
        Then click Done and run: npm run calendar:list
        """
        button.title = "Done"
        button.isEnabled = true
        button.action = #selector(done)
        emitJSON(
            StatusPayload(
                authorized: true,
                status: authorizationStatusName(status),
                bundleId: bundleId(),
                appPath: appPath(),
                calendarCount: count
            )
        )
    }

    @objc func done() {
        onFinished?()
        NSApp.terminate(nil)
    }
}

final class AuthorizeAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AuthorizeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AuthorizeWindowController()
        self.controller = controller
        controller.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            controller.requestAccess()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

func runAuthorizeWithAppKit() {
    let app = NSApplication.shared
    let delegate = AuthorizeAppDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
}

func ensureAccess(store: EKEventStore) {
    let status = EKEventStore.authorizationStatus(for: .event)
    if isAuthorized(status) {
        return
    }

    emitError(
        code: "permission_denied",
        message: "Calendar access is \(authorizationStatusName(status)) for \(bundleId()). Enable Full Access for “Slack Status Sync Calendar” in System Settings → Privacy & Security → Calendars, then re-run calendar authorize. Note: rebuilds of an ad-hoc signed app can require re-approving.",
        exitCode: .permissionDenied
    )
}

func listCalendars(store: EKEventStore) {
    ensureAccess(store: store)
    let calendars = store.calendars(for: .event).map { calendar in
        CalendarInfo(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            source: calendar.source?.title,
            type: calendarTypeName(calendar.type)
        )
    }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    emitJSON(CalendarsPayload(calendars: calendars))
}

func listEvents(store: EKEventStore, startISO: String, endISO: String) {
    ensureAccess(store: store)

    guard let start = parseISODate(startISO), let end = parseISODate(endISO) else {
        emitError(
            code: "invalid_args",
            message: "start and end must be ISO-8601 timestamps",
            exitCode: .invalidArgs
        )
    }

    guard end > start else {
        emitError(
            code: "invalid_args",
            message: "end must be after start",
            exitCode: .invalidArgs
        )
    }

    let calendars = store.calendars(for: .event)
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
    let events = store.events(matching: predicate).map { event -> EventInfo in
        EventInfo(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            eventIdentifier: event.eventIdentifier ?? event.calendarItemIdentifier,
            calendarItemExternalIdentifier: event.calendarItemExternalIdentifier,
            title: event.title ?? "",
            start: isoString(event.startDate),
            end: isoString(event.endDate),
            isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled,
            response: currentUserResponse(for: event),
            availability: availabilityName(event.availability),
            calendarName: event.calendar?.title ?? "",
            calendarId: event.calendar?.calendarIdentifier ?? ""
        )
    }.sorted { $0.start < $1.start }

    emitJSON(EventsPayload(events: events))
}

func status() {
    let authStatus = EKEventStore.authorizationStatus(for: .event)
    let count = isAuthorized(authStatus) ? EKEventStore().calendars(for: .event).count : nil
    emitJSON(
        StatusPayload(
            authorized: isAuthorized(authStatus),
            status: authorizationStatusName(authStatus),
            bundleId: bundleId(),
            appPath: appPath(),
            calendarCount: count
        )
    )
}

func printUsage() {
    fputs(
        """
        Usage:
          calendar-reader authorize [--output <path>]
          calendar-reader status [--output <path>]
          calendar-reader calendars [--output <path>]
          calendar-reader events --start <ISO8601> --end <ISO8601> [--output <path>]

        """,
        stderr
    )
}

func extractOutputFlag(_ args: inout [String]) {
    if let idx = args.firstIndex(of: "--output"), idx + 1 < args.count {
        outputPath = args[idx + 1]
        args.removeSubrange(idx...(idx + 1))
    }
}

func main() {
    var args = Array(CommandLine.arguments.dropFirst())
    extractOutputFlag(&args)

    // Finder / `open -a` often passes -psn_... or no useful args; default to authorize UI.
    let filtered = args.filter { !$0.hasPrefix("-psn_") }
    let command = filtered.first ?? "authorize"

    switch command {
    case "authorize":
        runAuthorizeWithAppKit()
    case "status":
        status()
    case "calendars":
        listCalendars(store: EKEventStore())
    case "events":
        var start: String?
        var end: String?
        var i = 1
        while i < filtered.count {
            let arg = filtered[i]
            if arg == "--start", i + 1 < filtered.count {
                start = filtered[i + 1]
                i += 2
                continue
            }
            if arg == "--end", i + 1 < filtered.count {
                end = filtered[i + 1]
                i += 2
                continue
            }
            emitError(code: "invalid_args", message: "Unknown argument: \(arg)", exitCode: .invalidArgs)
        }
        guard let startISO = start, let endISO = end else {
            emitError(
                code: "invalid_args",
                message: "events requires --start and --end",
                exitCode: .invalidArgs
            )
        }
        listEvents(store: EKEventStore(), startISO: startISO, endISO: endISO)
    case "-h", "--help", "help":
        printUsage()
        exit(ExitCode.success.rawValue)
    default:
        if filtered.contains(where: { $0.hasPrefix("-") }) && !filtered.contains("authorize") {
            runAuthorizeWithAppKit()
            return
        }
        printUsage()
        exit(ExitCode.usage.rawValue)
    }
}

main()
