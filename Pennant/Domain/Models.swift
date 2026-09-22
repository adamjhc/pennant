import Foundation

/// Ordered title-matching rule that drives Slack status updates.
public struct StatusRule: Codable, Identifiable, Equatable, Sendable, Hashable {
    public var id: UUID
    public var titleRegex: String
    public var statusText: String
    public var statusEmoji: String
    public var enableDND: Bool

    public init(
        id: UUID = UUID(),
        titleRegex: String,
        statusText: String,
        statusEmoji: String,
        enableDND: Bool
    ) {
        self.id = id
        self.titleRegex = titleRegex
        self.statusText = statusText
        self.statusEmoji = statusEmoji
        self.enableDND = enableDND
    }
}

/// Calendar metadata used for selection UI and filtering.
public struct CalendarDescriptor: Codable, Identifiable, Equatable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var sourceTitle: String

    public init(id: String, title: String, sourceTitle: String) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
    }
}

public enum AttendanceResponse: String, Codable, Equatable, Sendable {
    case accepted
    case tentative
    case declined
    case pending
    case none
    case unknown
}

public enum EventAvailability: String, Codable, Equatable, Sendable {
    case busy
    case free
    case tentative
    case unavailable
    case notSupported
    case unknown
}

/// Domain representation of a calendar occurrence independent of EventKit.
public struct CalendarOccurrence: Codable, Identifiable, Equatable, Sendable, Hashable {
    public var id: String
    public var seriesIdentifier: String?
    public var calendarId: String
    public var calendarTitle: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isCancelled: Bool
    public var attendance: AttendanceResponse
    public var availability: EventAvailability
    public var isOrganizerOwned: Bool

    public init(
        id: String,
        seriesIdentifier: String? = nil,
        calendarId: String,
        calendarTitle: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        attendance: AttendanceResponse = .none,
        availability: EventAvailability = .busy,
        isOrganizerOwned: Bool = false
    ) {
        self.id = id
        self.seriesIdentifier = seriesIdentifier
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
        self.attendance = attendance
        self.availability = availability
        self.isOrganizerOwned = isOrganizerOwned
    }

    /// Stable fingerprint for a specific occurrence (series + start).
    public var occurrenceKey: String {
        let series = seriesIdentifier ?? id
        return "\(series)|\(ISO8601DateFormatter.sss.string(from: start))"
    }

    public var stableTitleHash: Int {
        var hasher = Hasher()
        hasher.combine(title)
        // Hasher is not stable across processes; use unicode scalars sum instead.
        return title.unicodeScalars.reduce(0) { partial, scalar in
            partial &+ Int(scalar.value)
        }
    }
}

public struct MatchedOccurrence: Equatable, Sendable {
    public var occurrence: CalendarOccurrence
    public var rule: StatusRule
    public var ruleIndex: Int

    public init(occurrence: CalendarOccurrence, rule: StatusRule, ruleIndex: Int) {
        self.occurrence = occurrence
        self.rule = rule
        self.ruleIndex = ruleIndex
    }
}

public enum SyncDecisionAction: String, Equatable, Sendable {
    case apply
    case skip
    case clear
}

public struct SyncDecision: Equatable, Sendable {
    public var action: SyncDecisionAction
    public var reason: String
    public var selected: MatchedOccurrence?

    public init(action: SyncDecisionAction, reason: String, selected: MatchedOccurrence? = nil) {
        self.action = action
        self.reason = reason
        self.selected = selected
    }
}

/// Fingerprint of the last successfully applied controlling event.
public struct ControllingFingerprint: Codable, Equatable, Sendable {
    public var occurrenceKey: String
    public var ruleID: UUID
    public var statusText: String
    public var statusEmoji: String
    public var statusExpiration: Date
    public var enableDND: Bool
    public var eventEnd: Date
    public var eventStart: Date
    public var eventTitleHash: Int

    public init(
        occurrenceKey: String,
        ruleID: UUID,
        statusText: String,
        statusEmoji: String,
        statusExpiration: Date,
        enableDND: Bool,
        eventEnd: Date,
        eventStart: Date,
        eventTitleHash: Int
    ) {
        self.occurrenceKey = occurrenceKey
        self.ruleID = ruleID
        self.statusText = statusText
        self.statusEmoji = statusEmoji
        self.statusExpiration = statusExpiration
        self.enableDND = enableDND
        self.eventEnd = eventEnd
        self.eventStart = eventStart
        self.eventTitleHash = eventTitleHash
    }

    public static func from(match: MatchedOccurrence) -> ControllingFingerprint {
        ControllingFingerprint(
            occurrenceKey: match.occurrence.occurrenceKey,
            ruleID: match.rule.id,
            statusText: match.rule.statusText,
            statusEmoji: match.rule.statusEmoji,
            statusExpiration: match.occurrence.end,
            enableDND: match.rule.enableDND,
            eventEnd: match.occurrence.end,
            eventStart: match.occurrence.start,
            eventTitleHash: match.occurrence.stableTitleHash
        )
    }
}

/// App-owned Slack status we last successfully set.
public struct AppOwnedStatus: Codable, Equatable, Sendable {
    public var text: String
    public var emoji: String
    public var expiration: Date

    public init(text: String, emoji: String, expiration: Date) {
        self.text = text
        self.emoji = emoji
        self.expiration = expiration
    }
}

/// App-owned DND snooze we last successfully set.
public struct AppOwnedDND: Codable, Equatable, Sendable {
    public var expectedEnd: Date
    public var setAt: Date

    public init(expectedEnd: Date, setAt: Date) {
        self.expectedEnd = expectedEnd
        self.setAt = setAt
    }
}

public struct RemoteSlackProfile: Equatable, Sendable {
    public var statusText: String
    public var statusEmoji: String
    public var statusExpiration: Date?

    public init(statusText: String, statusEmoji: String, statusExpiration: Date?) {
        self.statusText = statusText
        self.statusEmoji = statusEmoji
        self.statusExpiration = statusExpiration
    }

    public func matches(_ owned: AppOwnedStatus) -> Bool {
        let remoteExp = statusExpiration.map { Int($0.timeIntervalSince1970) }
        let ownedExp = Int(owned.expiration.timeIntervalSince1970)
        return statusText == owned.text
            && statusEmoji == owned.emoji
            && remoteExp == ownedExp
    }
}

public struct RemoteDNDState: Equatable, Sendable {
    public var snoozeEnabled: Bool
    public var snoozeEnd: Date?

    public init(snoozeEnabled: Bool, snoozeEnd: Date?) {
        self.snoozeEnabled = snoozeEnabled
        self.snoozeEnd = snoozeEnd
    }
}

extension ISO8601DateFormatter {
    static let sss: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
