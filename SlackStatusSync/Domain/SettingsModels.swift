import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var rules: [StatusRule]
    public var disabledCalendarIDs: [String]
    public var isPaused: Bool
    public var launchAtLoginDesired: Bool
    public var hasCompletedSetup: Bool

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        rules: [StatusRule] = [],
        disabledCalendarIDs: [String] = [],
        isPaused: Bool = false,
        launchAtLoginDesired: Bool = true,
        hasCompletedSetup: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.rules = rules
        self.disabledCalendarIDs = disabledCalendarIDs
        self.isPaused = isPaused
        self.launchAtLoginDesired = launchAtLoginDesired
        self.hasCompletedSetup = hasCompletedSetup
    }

    public static func freshDefaults() -> AppSettings {
        AppSettings()
    }

    public var disabledCalendarIDSet: Set<String> {
        Set(disabledCalendarIDs)
    }
}

public struct RuntimeState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var lastFingerprint: ControllingFingerprint?
    public var ownedStatus: AppOwnedStatus?
    public var ownedDND: AppOwnedDND?
    public var lastSuccessfulSyncAt: Date?
    public var lastError: String?
    public var pendingDNDRetryOccurrenceKey: String?

    public init(
        schemaVersion: Int = RuntimeState.currentSchemaVersion,
        lastFingerprint: ControllingFingerprint? = nil,
        ownedStatus: AppOwnedStatus? = nil,
        ownedDND: AppOwnedDND? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        lastError: String? = nil,
        pendingDNDRetryOccurrenceKey: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.lastFingerprint = lastFingerprint
        self.ownedStatus = ownedStatus
        self.ownedDND = ownedDND
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.lastError = lastError
        self.pendingDNDRetryOccurrenceKey = pendingDNDRetryOccurrenceKey
    }

    public static func empty() -> RuntimeState {
        RuntimeState()
    }
}
