import Foundation

public struct RuleDraft: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var titleRegex: String
    public var statusText: String
    public var statusEmoji: String
    public var enableDND: Bool

    public init(
        id: UUID = UUID(),
        titleRegex: String = "",
        statusText: String = "",
        statusEmoji: String = ":calendar:",
        enableDND: Bool = false
    ) {
        self.id = id
        self.titleRegex = titleRegex
        self.statusText = statusText
        self.statusEmoji = statusEmoji
        self.enableDND = enableDND
    }

    public init(_ rule: StatusRule) {
        self.id = rule.id
        self.titleRegex = rule.titleRegex
        self.statusText = rule.statusText
        self.statusEmoji = rule.statusEmoji
        self.enableDND = rule.enableDND
    }

    public func asRule() -> StatusRule {
        StatusRule(
            id: id,
            titleRegex: titleRegex,
            statusText: statusText,
            statusEmoji: statusEmoji,
            enableDND: enableDND
        )
    }
}

public struct SettingsDraft: Equatable, Sendable {
    public var rules: [RuleDraft]
    public var disabledCalendarIDs: Set<String>
    public var launchAtLoginDesired: Bool
    public var replacementToken: String

    public init(
        rules: [RuleDraft] = [],
        disabledCalendarIDs: Set<String> = [],
        launchAtLoginDesired: Bool = true,
        replacementToken: String = ""
    ) {
        self.rules = rules
        self.disabledCalendarIDs = disabledCalendarIDs
        self.launchAtLoginDesired = launchAtLoginDesired
        self.replacementToken = replacementToken
    }

    public static func from(settings: AppSettings) -> SettingsDraft {
        SettingsDraft(
            rules: settings.rules.map(RuleDraft.init),
            disabledCalendarIDs: settings.disabledCalendarIDSet,
            launchAtLoginDesired: settings.launchAtLoginDesired,
            replacementToken: ""
        )
    }

    public func toSettings(hasCompletedSetup: Bool) -> AppSettings {
        AppSettings(
            rules: rules.map { $0.asRule() },
            disabledCalendarIDs: disabledCalendarIDs.sorted(),
            isPaused: false, // pause is menu-only; preserved separately by caller
            launchAtLoginDesired: launchAtLoginDesired,
            hasCompletedSetup: hasCompletedSetup
        )
    }
}

public enum SettingsValidationError: Error, Equatable, Sendable {
    case rule(Int, RuleValidationError)
    case tokenRequired
    case tokenInvalid
    case tokenMissingScopes(Set<String>)
    case tokenOffline
    case calendarAccessRequired
}

public final class SettingsViewModel: @unchecked Sendable {
    public private(set) var draft: SettingsDraft
    public private(set) var saved: AppSettings
    public private(set) var hasToken: Bool
    public private(set) var calendars: [CalendarDescriptor]
    public private(set) var isDirty: Bool = false
    public private(set) var lastValidationError: SettingsValidationError?
    public private(set) var connectionLabel: String

    private let settingsStore: SettingsStoreProtocol
    private let runtimeStore: RuntimeStateStoreProtocol
    private let tokenStore: TokenStoreProtocol
    private let calendar: CalendarServiceProtocol
    private let slack: SlackClientProtocol
    private let launchAtLogin: LaunchAtLoginServiceProtocol
    private let engine = DecisionEngine()

    public init(
        settingsStore: SettingsStoreProtocol,
        runtimeStore: RuntimeStateStoreProtocol,
        tokenStore: TokenStoreProtocol,
        calendar: CalendarServiceProtocol,
        slack: SlackClientProtocol,
        launchAtLogin: LaunchAtLoginServiceProtocol = FakeLaunchAtLoginService()
    ) {
        self.settingsStore = settingsStore
        self.runtimeStore = runtimeStore
        self.tokenStore = tokenStore
        self.calendar = calendar
        self.slack = slack
        self.launchAtLogin = launchAtLogin
        let loaded = (try? settingsStore.load()) ?? .freshDefaults()
        self.saved = loaded
        // First-run default: launch at login desired preselected.
        var initial = SettingsDraft.from(settings: loaded)
        if !loaded.hasCompletedSetup {
            initial.launchAtLoginDesired = true
        }
        self.draft = initial
        self.hasToken = (try? tokenStore.hasToken()) ?? false
        self.calendars = (try? calendar.listCalendars()) ?? []
        self.connectionLabel = hasToken ? "Token stored" : "Missing token"
    }

    public func reloadCalendars() {
        calendars = (try? calendar.listCalendars()) ?? []
    }

    public func updateDraft(_ mutate: (inout SettingsDraft) -> Void) {
        mutate(&draft)
        isDirty = computeDirty()
    }

    private func computeDirty() -> Bool {
        if !draft.replacementToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if draft.launchAtLoginDesired != saved.launchAtLoginDesired { return true }
        if draft.disabledCalendarIDs != saved.disabledCalendarIDSet { return true }
        if draft.rules.map({ $0.asRule() }) != saved.rules { return true }
        return false
    }

    public func cancel() {
        draft = SettingsDraft.from(settings: saved)
        lastValidationError = nil
        isDirty = false
    }

    public func needsDiscardConfirmation() -> Bool {
        computeDirty()
    }

    public func validateLocal() -> SettingsValidationError? {
        for (index, rule) in draft.rules.enumerated() {
            if let error = RuleValidator.validate(rule.asRule()) {
                return .rule(index, error)
            }
        }
        if calendar.authorizationStatus() != .fullAccess {
            return .calendarAccessRequired
        }
        let trimmed = draft.replacementToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasToken && trimmed.isEmpty {
            return .tokenRequired
        }
        if !trimmed.isEmpty && !SlackClient.validateTokenFormat(trimmed) {
            return .tokenInvalid
        }
        return nil
    }

    public func sampleMatches(rule: RuleDraft, sampleTitle: String) -> Bool {
        RuleValidator.matches(title: sampleTitle, pattern: rule.titleRegex)
    }

    public func previewEvents(for rule: RuleDraft, now: Date = Date()) -> [CalendarOccurrence] {
        let end = now.addingTimeInterval(SyncCoordinator.previewLookAhead)
        let start = now.addingTimeInterval(-60)
        let occurrences = (try? calendar.fetchOccurrences(start: start, end: end)) ?? []
        return engine.previewMatches(
            occurrences: occurrences,
            rule: rule.asRule(),
            now: now,
            disabledCalendarIDs: draft.disabledCalendarIDs
        )
    }

    @discardableResult
    public func save() async -> SettingsValidationError? {
        if let local = validateLocal() {
            lastValidationError = local
            return local
        }

        let trimmed = draft.replacementToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousToken = try? tokenStore.readToken()

        if !trimmed.isEmpty {
            do {
                guard SlackClient.validateTokenFormat(trimmed) else {
                    lastValidationError = .tokenInvalid
                    return lastValidationError
                }
                let result = try await slack.authTest(token: trimmed)
                let missing = SlackRequiredScopes.all.subtracting(result.scopes)
                if !missing.isEmpty {
                    lastValidationError = .tokenMissingScopes(missing)
                    return lastValidationError
                }
                connectionLabel = "Token verified"
            } catch let error as SlackClientError {
                switch error {
                case .missingScopes(let scopes):
                    lastValidationError = .tokenMissingScopes(scopes)
                case .invalidTokenFormat:
                    lastValidationError = .tokenInvalid
                case .transport, .rateLimited, .httpStatus:
                    lastValidationError = .tokenOffline
                default:
                    lastValidationError = .tokenInvalid
                }
                return lastValidationError
            } catch {
                lastValidationError = .tokenOffline
                return lastValidationError
            }
        }

        var next = draft.toSettings(hasCompletedSetup: true)
        // Preserve pause from saved settings (menu-owned).
        next.isPaused = saved.isPaused

        do {
            if !trimmed.isEmpty {
                try tokenStore.saveToken(trimmed)
            }
            try settingsStore.save(next)
            if next.launchAtLoginDesired {
                try? launchAtLogin.setEnabled(true)
            } else if launchAtLogin.status() == .enabled {
                try? launchAtLogin.setEnabled(false)
            }
            saved = next
            hasToken = (try? tokenStore.hasToken()) ?? false
            draft.replacementToken = ""
            draft = SettingsDraft.from(settings: saved)
            isDirty = false
            lastValidationError = nil
            connectionLabel = hasToken ? "Token stored" : "Missing token"
            return nil
        } catch {
            // Best-effort rollback of token.
            if !trimmed.isEmpty {
                if let previousToken {
                    try? tokenStore.saveToken(previousToken)
                } else {
                    try? tokenStore.deleteToken()
                }
            }
            lastValidationError = .tokenOffline
            return lastValidationError
        }
    }

    public func deleteToken() throws {
        try tokenStore.deleteToken()
        hasToken = false
        connectionLabel = "Missing token"
    }

    public func resetApp() throws {
        try AppResetService().reset(settings: settingsStore, runtime: runtimeStore, tokens: tokenStore)
        try? launchAtLogin.setEnabled(false)
        saved = .freshDefaults()
        draft = SettingsDraft.from(settings: saved)
        draft.launchAtLoginDesired = true
        hasToken = false
        isDirty = false
        connectionLabel = "Missing token"
    }

    public func requestCalendarAccess() async -> Bool {
        (try? await calendar.requestFullAccess()) ?? false
    }

    public var setupComplete: Bool {
        calendar.authorizationStatus() == .fullAccess && hasToken
    }

    public var groupedCalendars: [(source: String, calendars: [CalendarDescriptor])] {
        CalendarMapping.groupedBySource(calendars)
    }
}

private extension SettingsDraft {
    func withToken(_ token: String) -> SettingsDraft {
        var copy = self
        copy.replacementToken = token
        return copy
    }
}
