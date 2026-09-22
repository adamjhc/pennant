import Foundation

public enum CalendarAuthorizationStatus: String, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case writeOnly
    case fullAccess
    case unknown
}

public protocol CalendarServiceProtocol: Sendable {
    func authorizationStatus() -> CalendarAuthorizationStatus
    func requestFullAccess() async throws -> Bool
    func openSystemCalendarSettings()
    func listCalendars() throws -> [CalendarDescriptor]
    func fetchOccurrences(start: Date, end: Date) throws -> [CalendarOccurrence]
}

public enum CalendarServiceError: Error, Equatable, Sendable {
    case notAuthorized
    case requestFailed(String)
}

/// Maps EventKit-like attendee data into domain attendance.
public enum CalendarMapping {
    public static func attendance(
        isCancelled: Bool,
        currentUserStatus: String?,
        eventStatus: String?,
        hasAttendees: Bool,
        isOrganizer: Bool
    ) -> (AttendanceResponse, isOrganizerOwned: Bool) {
        if isCancelled {
            return (.declined, isOrganizer)
        }
        if let currentUserStatus {
            switch currentUserStatus.lowercased() {
            case "accepted", "completed":
                return (.accepted, isOrganizer)
            case "declined":
                return (.declined, isOrganizer)
            case "tentative", "inprocess":
                return (.tentative, isOrganizer)
            case "pending", "notresponded":
                return (.pending, isOrganizer)
            default:
                break
            }
        }
        if !hasAttendees || isOrganizer {
            // Personal / organizer-owned without explicit attendee response.
            return (.none, true)
        }
        if let eventStatus {
            switch eventStatus.lowercased() {
            case "confirmed":
                return (.accepted, isOrganizer)
            case "tentative":
                return (.tentative, isOrganizer)
            case "canceled", "cancelled":
                return (.declined, isOrganizer)
            default:
                break
            }
        }
        return (.unknown, isOrganizer)
    }

    public static func availability(from raw: String?) -> EventAvailability {
        switch (raw ?? "").lowercased() {
        case "busy": return .busy
        case "free": return .free
        case "tentative": return .tentative
        case "oof", "unavailable": return .unavailable
        case "notsupported": return .notSupported
        default: return .unknown
        }
    }

    /// Enabled calendars = all listed minus disabled IDs. New calendars are included by default.
    public static func enabledCalendarIDs(
        available: [CalendarDescriptor],
        disabledIDs: Set<String>
    ) -> Set<String> {
        Set(available.map(\.id)).subtracting(disabledIDs)
    }

    public static func groupedBySource(
        _ calendars: [CalendarDescriptor]
    ) -> [(source: String, calendars: [CalendarDescriptor])] {
        let grouped = Dictionary(grouping: calendars, by: \.sourceTitle)
        return grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { source in
                let cals = (grouped[source] ?? []).sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return (source, cals)
            }
    }
}

/// In-memory calendar service for tests.
public final class FakeCalendarService: CalendarServiceProtocol, @unchecked Sendable {
    public var status: CalendarAuthorizationStatus
    public var calendars: [CalendarDescriptor]
    public var occurrences: [CalendarOccurrence]
    public var requestResult: Bool
    public var didOpenSettings = false
    public var requestError: Error?
    public private(set) var fetchCallCount = 0

    public init(
        status: CalendarAuthorizationStatus = .fullAccess,
        calendars: [CalendarDescriptor] = [],
        occurrences: [CalendarOccurrence] = [],
        requestResult: Bool = true
    ) {
        self.status = status
        self.calendars = calendars
        self.occurrences = occurrences
        self.requestResult = requestResult
    }

    public func authorizationStatus() -> CalendarAuthorizationStatus { status }

    public func requestFullAccess() async throws -> Bool {
        if let requestError { throw requestError }
        if requestResult {
            status = .fullAccess
        } else {
            status = .denied
        }
        return requestResult
    }

    public func openSystemCalendarSettings() {
        didOpenSettings = true
    }

    public func listCalendars() throws -> [CalendarDescriptor] {
        guard status == .fullAccess else { throw CalendarServiceError.notAuthorized }
        return calendars
    }

    public func fetchOccurrences(start: Date, end: Date) throws -> [CalendarOccurrence] {
        guard status == .fullAccess else { throw CalendarServiceError.notAuthorized }
        fetchCallCount += 1
        return occurrences.filter { $0.start < end && $0.end > start }
    }
}
