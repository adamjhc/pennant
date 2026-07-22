import AppKit
import EventKit
import Foundation

@MainActor
final class EventKitService: ObservableObject {
    private let store = EKEventStore()

    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var calendars: [LocalCalendarInfo] = []
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var authorizationError: String?

    func refreshStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if isAuthorized {
            authorizationError = nil
            reloadCalendars()
        } else {
            calendars = []
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .fullAccess
    }

    var statusLabel: String {
        switch authorizationStatus {
        case .fullAccess: return "Full Access"
        case .writeOnly: return "Write Only (need Full Access)"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Determined"
        @unknown default: return "Unknown"
        }
    }

    func requestAccess() async -> Bool {
        guard !isRequestingAccess else {
            return false
        }

        NSApp.activate(ignoringOtherApps: true)
        isRequestingAccess = true
        authorizationError = nil
        defer { isRequestingAccess = false }

        refreshStatus()
        if isAuthorized {
            return true
        }

        if authorizationStatus == .denied || authorizationStatus == .restricted {
            authorizationError = authorizationStatus == .denied
                ? "Calendar access was denied. Enable Full Access in System Settings."
                : "Calendar access is restricted by macOS or device policy."
            return false
        }

        do {
            let granted = try await store.requestFullAccessToEvents()
            refreshStatus()
            if !granted || !isAuthorized {
                authorizationError = "Calendar Full Access was not granted. Use Open System Settings and enable it manually."
                return false
            }
            return true
        } catch {
            refreshStatus()
            authorizationError = "Calendar access request failed: \(error.localizedDescription)"
            return false
        }
    }

    func openSystemCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func reloadCalendars() {
        guard isAuthorized else {
            calendars = []
            return
        }
        calendars = store.calendars(for: .event)
            .map { cal in
                LocalCalendarInfo(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    source: cal.source?.title
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func fetchEvents(lookBehindMinutes: Int, lookAheadMinutes: Int, now: Date = Date()) throws -> [CalendarWireEvent] {
        guard isAuthorized else {
            throw EventKitError.notAuthorized
        }

        let start = now.addingTimeInterval(TimeInterval(-lookBehindMinutes * 60))
        let end = now.addingTimeInterval(TimeInterval(lookAheadMinutes * 60))
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return events.map { event in
            CalendarWireEvent(
                id: event.eventIdentifier ?? event.calendarItemIdentifier,
                iCalUId: event.calendarItemExternalIdentifier,
                changeKey: nil,
                title: event.title ?? "",
                start: formatter.string(from: event.startDate),
                end: formatter.string(from: event.endDate),
                isAllDay: event.isAllDay,
                isCancelled: event.status == .canceled,
                response: Self.currentUserResponse(for: event),
                showAs: Self.availabilityName(event.availability),
                calendarName: event.calendar?.title ?? "",
                calendarId: event.calendar?.calendarIdentifier ?? ""
            )
        }
        .sorted { $0.start < $1.start }
    }

    private static func currentUserResponse(for event: EKEvent) -> String {
        if event.status == .canceled {
            return "declined"
        }
        if let attendees = event.attendees,
           let me = attendees.first(where: { $0.isCurrentUser }) {
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
        switch event.status {
        case .canceled: return "declined"
        case .confirmed: return "accepted"
        case .tentative: return "tentative"
        case .none: return "none"
        @unknown default: return "unknown"
        }
    }

    private static func availabilityName(_ value: EKEventAvailability) -> String {
        switch value {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "oof"
        case .notSupported: return "notSupported"
        @unknown default: return "unknown"
        }
    }
}

enum EventKitError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Calendar Full Access is not granted"
        }
    }
}
