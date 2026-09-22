#if canImport(EventKit)
import EventKit
import AppKit
import Foundation

public final class EventKitCalendarService: CalendarServiceProtocol, @unchecked Sendable {
    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    public var onStoreChanged: (() -> Void)?

    public init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            self?.onStoreChanged?()
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    public func authorizationStatus() -> CalendarAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        @unknown default: return .unknown
        }
    }

    public func requestFullAccess() async throws -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            throw CalendarServiceError.requestFailed(error.localizedDescription)
        }
    }

    public func openSystemCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    public func listCalendars() throws -> [CalendarDescriptor] {
        guard authorizationStatus() == .fullAccess else {
            throw CalendarServiceError.notAuthorized
        }
        return store.calendars(for: .event).map { cal in
            CalendarDescriptor(
                id: cal.calendarIdentifier,
                title: cal.title,
                sourceTitle: cal.source.title
            )
        }
    }

    public func fetchOccurrences(start: Date, end: Date) throws -> [CalendarOccurrence] {
        guard authorizationStatus() == .fullAccess else {
            throw CalendarServiceError.notAuthorized
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        return events.map { Self.mapEvent($0) }
    }

    public static func mapEvent(_ event: EKEvent) -> CalendarOccurrence {
        let attendees = event.attendees ?? []
        let me = attendees.first(where: { $0.isCurrentUser })
        let statusRaw: String? = {
            guard let me else { return nil }
            switch me.participantStatus {
            case .accepted, .completed: return "accepted"
            case .declined: return "declined"
            case .tentative, .inProcess: return "tentative"
            case .pending: return "pending"
            case .unknown, .delegated: return "unknown"
            @unknown default: return "unknown"
            }
        }()
        let eventStatus: String = {
            switch event.status {
            case .canceled: return "canceled"
            case .confirmed: return "confirmed"
            case .tentative: return "tentative"
            case .none: return "none"
            @unknown default: return "unknown"
            }
        }()
        let isOrganizer = event.organizer?.isCurrentUser == true || attendees.isEmpty
        let mapped = CalendarMapping.attendance(
            isCancelled: event.status == .canceled,
            currentUserStatus: statusRaw,
            eventStatus: eventStatus,
            hasAttendees: !attendees.isEmpty,
            isOrganizer: isOrganizer
        )
        let availability: EventAvailability = {
            switch event.availability {
            case .busy: return .busy
            case .free: return .free
            case .tentative: return .tentative
            case .unavailable: return .unavailable
            case .notSupported: return .notSupported
            @unknown default: return .unknown
            }
        }()

        return CalendarOccurrence(
            id: event.eventIdentifier ?? event.calendarItemIdentifier,
            seriesIdentifier: event.calendarItemExternalIdentifier,
            calendarId: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled,
            attendance: mapped.0,
            availability: availability,
            isOrganizerOwned: mapped.isOrganizerOwned
        )
    }
}
#endif
