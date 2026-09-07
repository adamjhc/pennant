import Foundation

public enum MenuSyncState: String, Equatable, Sendable {
    case setupRequired
    case idle
    case syncing
    case active
    case paused
    case error
}

public struct MenuSnapshot: Equatable, Sendable {
    public var state: MenuSyncState
    public var controllingSummary: String?
    public var controllingEndsAt: Date?
    public var lastSuccessfulSyncAt: Date?
    public var lastError: String?
    public var isPaused: Bool
    public var hasToken: Bool
    public var calendarAuthorized: Bool

    public init(
        state: MenuSyncState,
        controllingSummary: String? = nil,
        controllingEndsAt: Date? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        lastError: String? = nil,
        isPaused: Bool = false,
        hasToken: Bool = false,
        calendarAuthorized: Bool = false
    ) {
        self.state = state
        self.controllingSummary = controllingSummary
        self.controllingEndsAt = controllingEndsAt
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.lastError = lastError
        self.isPaused = isPaused
        self.hasToken = hasToken
        self.calendarAuthorized = calendarAuthorized
    }
}

public final class SyncCoordinator: @unchecked Sendable {
    public static let safetyPollInterval: TimeInterval = 60
    public static let activeLookBehind: TimeInterval = 15 * 60
    public static let activeLookAhead: TimeInterval = 24 * 60 * 60
    public static let previewLookAhead: TimeInterval = 7 * 24 * 60 * 60

    private let calendar: CalendarServiceProtocol
    private let slack: SlackClientProtocol
    private let settingsStore: SettingsStoreProtocol
    private let runtimeStore: RuntimeStateStoreProtocol
    private let tokenStore: TokenStoreProtocol
    private let dateProvider: DateProviding
    private let scheduler: SchedulerProtocol
    private let engine = DecisionEngine()
    private let lock = NSLock()

    private var isStarted = false
    private var isSyncing = false
    private var retryAttempt = 0
    private var cachedSettings: AppSettings
    private var cachedRuntime: RuntimeState
    private var lastMenuSnapshot: MenuSnapshot
    public var onMenuSnapshotChange: ((MenuSnapshot) -> Void)?

    public init(
        calendar: CalendarServiceProtocol,
        slack: SlackClientProtocol,
        settingsStore: SettingsStoreProtocol,
        runtimeStore: RuntimeStateStoreProtocol,
        tokenStore: TokenStoreProtocol,
        dateProvider: DateProviding = SystemDateProvider(),
        scheduler: SchedulerProtocol = ImmediateScheduler()
    ) {
        self.calendar = calendar
        self.slack = slack
        self.settingsStore = settingsStore
        self.runtimeStore = runtimeStore
        self.tokenStore = tokenStore
        self.dateProvider = dateProvider
        self.scheduler = scheduler
        self.cachedSettings = (try? settingsStore.load()) ?? .freshDefaults()
        self.cachedRuntime = (try? runtimeStore.load()) ?? .empty()
        self.lastMenuSnapshot = MenuSnapshot(state: .setupRequired)
    }

    public func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        refreshCaches()
        publishMenu()
        scheduleSafetyPoll()
        Task { await sync(force: false, ignorePause: false) }
    }

    public func stop() {
        lock.lock()
        isStarted = false
        lock.unlock()
        scheduler.cancelAll()
    }

    public func togglePause() {
        lock.lock()
        cachedSettings.isPaused.toggle()
        let settings = cachedSettings
        lock.unlock()
        try? settingsStore.save(settings)
        publishMenu()
        if !settings.isPaused {
            Task { await sync(force: false, ignorePause: false) }
        }
    }

    public func syncNow() async {
        await sync(force: true, ignorePause: true)
    }

    public func settingsDidSave() async {
        refreshCaches()
        await sync(force: true, ignorePause: false)
    }

    public func calendarDidChange() async {
        await sync(force: false, ignorePause: false)
    }

    public func systemDidWake() async {
        scheduleSafetyPoll()
        await sync(force: false, ignorePause: false)
    }

    public func currentMenuSnapshot() -> MenuSnapshot {
        lock.lock(); defer { lock.unlock() }
        return lastMenuSnapshot
    }

    public func currentSettings() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        return cachedSettings
    }

    public func currentRuntime() -> RuntimeState {
        lock.lock(); defer { lock.unlock() }
        return cachedRuntime
    }

    // MARK: - Sync

    private func sync(force: Bool, ignorePause: Bool) async {
        lock.lock()
        if isSyncing {
            lock.unlock()
            AppLogger.info("sync skipped reason=already_syncing", category: "sync")
            return
        }
        isSyncing = true
        let settings = cachedSettings
        var runtime = cachedRuntime
        lock.unlock()
        AppLogger.info(
            "sync started force=\(force) ignorePause=\(ignorePause) paused=\(settings.isPaused)",
            category: "sync"
        )

        defer {
            lock.lock()
            isSyncing = false
            lock.unlock()
            publishMenu()
        }

        let calendarOK = calendar.authorizationStatus() == .fullAccess
        let hasToken = (try? tokenStore.hasToken()) ?? false

        if !calendarOK || !hasToken {
            AppLogger.error(
                "sync blocked calendarAuthorized=\(calendarOK) hasToken=\(hasToken)",
                category: "sync"
            )
            publishMenu()
            scheduleSafetyPoll()
            return
        }

        if settings.isPaused && !ignorePause {
            AppLogger.info("sync skipped reason=paused", category: "sync")
            publishMenu()
            scheduleSafetyPoll()
            return
        }

        publishMenu(syncing: true)

        guard let token = try? tokenStore.readToken() else {
            AppLogger.error("sync failed reason=token_read_failed", category: "sync")
            runtime.lastError = "missing_token"
            persistRuntime(runtime)
            scheduleSafetyPoll()
            return
        }

        let now = dateProvider.now
        let executor = SlackActionExecutor(client: slack, dateProvider: dateProvider)

        // Exact DND boundary cleanup while awake.
        let dndResult = await executor.endOwnedDNDIfDue(token: token, ownedDND: runtime.ownedDND)
        if dndResult.ended {
            runtime.ownedDND = dndResult.ownedDND
        }

        // Retry pending DND without re-setting status.
        if let pendingKey = runtime.pendingDNDRetryOccurrenceKey,
           let fingerprint = runtime.lastFingerprint,
           fingerprint.occurrenceKey == pendingKey,
           let ownedStatus = runtime.ownedStatus,
           fingerprint.enableDND
        {
            AppLogger.info("sync retrying pending DND", category: "sync")
            let outcome = await executor.retryDND(
                eventEnd: fingerprint.eventEnd,
                token: token,
                ownedStatus: ownedStatus,
                previousOwnedDND: runtime.ownedDND,
                fingerprint: fingerprint
            )
            applyOutcome(outcome, to: &runtime, preserveFingerprintOnSkip: true)
            if !outcome.pendingDNDRetry {
                runtime.pendingDNDRetryOccurrenceKey = nil
                retryAttempt = 0
            } else {
                scheduleRetry(eventEnd: fingerprint.eventEnd)
            }
            persistRuntime(runtime)
            scheduleBoundaryTimers(occurrences: [], now: now)
            scheduleSafetyPoll()
            return
        }

        let start = now.addingTimeInterval(-Self.activeLookBehind)
        let end = now.addingTimeInterval(Self.activeLookAhead)
        let occurrences: [CalendarOccurrence]
        do {
            occurrences = try calendar.fetchOccurrences(start: start, end: end)
            AppLogger.info(
                "calendar fetch succeeded occurrences=\(occurrences.count) rules=\(settings.rules.count) disabledCalendars=\(settings.disabledCalendarIDs.count)",
                category: "sync"
            )
        } catch {
            let errorCode = error as NSError
            AppLogger.error(
                "calendar fetch failed error=\(errorCode.domain):\(errorCode.code)",
                category: "sync"
            )
            runtime.lastError = "calendar_fetch_failed"
            persistRuntime(runtime)
            scheduleSafetyPoll()
            return
        }

        let previousFingerprint: ControllingFingerprint?
        if let ownedStatus = runtime.ownedStatus, ownedStatus.expiration <= now {
            previousFingerprint = nil
            AppLogger.info(
                "expired owned status invalidated previous fingerprint",
                category: "sync"
            )
        } else {
            previousFingerprint = runtime.lastFingerprint
        }

        let decision = engine.decide(
            occurrences: occurrences,
            rules: settings.rules,
            now: now,
            disabledCalendarIDs: settings.disabledCalendarIDSet,
            previousFingerprint: previousFingerprint,
            force: force
        )
        let selectedDetails: String
        if let selected = decision.selected {
            let endsIn = Int(selected.occurrence.end.timeIntervalSince(now))
            selectedDetails = "selected=true ruleIndex=\(selected.ruleIndex) enableDND=\(selected.rule.enableDND) endsInSeconds=\(endsIn)"
        } else {
            selectedDetails = "selected=false"
        }
        AppLogger.info(
            "decision action=\(decision.action.rawValue) reason=\(decision.reason) \(selectedDetails)",
            category: "sync"
        )

        // When skipping because already applied, still schedule boundaries.
        if decision.action == .skip && decision.reason == "already_applied" {
            AppLogger.info(
                "Slack update skipped because controlling fingerprint is unchanged",
                category: "sync"
            )
            runtime.lastError = nil
            runtime.lastSuccessfulSyncAt = now
            persistRuntime(runtime)
            scheduleBoundaryTimers(occurrences: occurrences, now: now)
            scheduleSafetyPoll()
            return
        }

        let outcome = await executor.reconcileClearOrUpdate(
            decision: decision,
            token: token,
            previousOwnedStatus: runtime.ownedStatus,
            previousOwnedDND: runtime.ownedDND,
            force: force
        )

        applyOutcome(outcome, to: &runtime, preserveFingerprintOnSkip: false)

        switch outcome.result {
        case .failed(let message):
            AppLogger.error("Slack outcome=failed reason=\(message)", category: "sync")
            runtime.lastError = message
            if let selected = decision.selected {
                scheduleRetry(eventEnd: selected.occurrence.end)
            }
        case .partialDNDFailure:
            AppLogger.error("Slack outcome=partial_dnd_failure", category: "sync")
            runtime.lastError = "dnd_partial_failure"
            if let fp = runtime.lastFingerprint {
                runtime.pendingDNDRetryOccurrenceKey = fp.occurrenceKey
                scheduleRetry(eventEnd: fp.eventEnd)
            }
        case .applied, .cleared:
            AppLogger.info("Slack outcome=\(String(describing: outcome.result))", category: "sync")
            runtime.lastError = nil
            runtime.lastSuccessfulSyncAt = now
            runtime.pendingDNDRetryOccurrenceKey = nil
            retryAttempt = 0
            AppLogger.syncEvent(decision.reason, applied: true)
        case .preservedManualOverride:
            AppLogger.info("Slack outcome=preserved_manual_override", category: "sync")
            runtime.lastError = nil
            runtime.lastSuccessfulSyncAt = now
            // Remember fingerprint so we don't keep fighting the override until change/force.
            if let selected = decision.selected {
                runtime.lastFingerprint = ControllingFingerprint.from(match: selected)
            }
            retryAttempt = 0
        case .skipped(let reason):
            AppLogger.info("Slack outcome=skipped reason=\(reason)", category: "sync")
            runtime.lastError = nil
            runtime.lastSuccessfulSyncAt = now
        }

        persistRuntime(runtime)
        scheduleBoundaryTimers(occurrences: occurrences, now: now)
        scheduleSafetyPoll()
    }

    private func applyOutcome(
        _ outcome: SlackActionOutcome,
        to runtime: inout RuntimeState,
        preserveFingerprintOnSkip: Bool
    ) {
        switch outcome.result {
        case .applied, .partialDNDFailure:
            runtime.ownedStatus = outcome.ownedStatus
            runtime.ownedDND = outcome.ownedDND
            if let fp = outcome.fingerprint {
                runtime.lastFingerprint = fp
            }
        case .cleared:
            runtime.ownedStatus = outcome.ownedStatus
            runtime.ownedDND = outcome.ownedDND
            runtime.lastFingerprint = nil
        case .preservedManualOverride:
            runtime.ownedStatus = outcome.ownedStatus
            runtime.ownedDND = outcome.ownedDND
        case .skipped:
            if !preserveFingerprintOnSkip {
                // leave fingerprint
            }
        case .failed:
            break
        }
    }

    private func scheduleRetry(eventEnd: Date) {
        let now = dateProvider.now
        guard eventEnd > now else {
            retryAttempt = 0
            return
        }
        retryAttempt += 1
        let delay = min(300.0, pow(2.0, Double(min(retryAttempt, 8))))
        let remaining = eventEnd.timeIntervalSince(now)
        let actual = min(delay, remaining)
        scheduler.cancel(id: "retry")
        scheduler.schedule(after: actual, id: "retry") { [weak self] in
            Task { await self?.sync(force: false, ignorePause: false) }
        }
    }

    private func scheduleSafetyPoll() {
        lock.lock()
        let shouldSchedule = isStarted
        lock.unlock()
        guard shouldSchedule else { return }

        scheduler.cancel(id: "safety")
        scheduler.schedule(after: Self.safetyPollInterval, id: "safety") { [weak self] in
            Task {
                await self?.sync(force: false, ignorePause: false)
                self?.scheduleSafetyPoll()
            }
        }
    }

    private func scheduleBoundaryTimers(occurrences: [CalendarOccurrence], now: Date) {
        scheduler.cancel(id: "boundary")
        let settings = currentSettings()
        let future = occurrences
            .filter { !settings.disabledCalendarIDSet.contains($0.calendarId) }
            .flatMap { occ -> [Date] in
                var dates: [Date] = []
                if occ.start > now { dates.append(occ.start) }
                if occ.end > now { dates.append(occ.end) }
                return dates
            }
            .sorted()
        guard let next = future.first else { return }
        let interval = max(0.5, next.timeIntervalSince(now))
        scheduler.schedule(after: interval, id: "boundary") { [weak self] in
            Task { await self?.sync(force: false, ignorePause: false) }
        }

        // Also schedule exact owned DND end if present.
        if let dndEnd = currentRuntime().ownedDND?.expectedEnd, dndEnd > now {
            let dndInterval = max(0.5, dndEnd.timeIntervalSince(now))
            scheduler.cancel(id: "dnd-end")
            scheduler.schedule(after: dndInterval, id: "dnd-end") { [weak self] in
                Task { await self?.sync(force: false, ignorePause: false) }
            }
        }
    }

    private func refreshCaches() {
        lock.lock()
        cachedSettings = (try? settingsStore.load()) ?? .freshDefaults()
        cachedRuntime = (try? runtimeStore.load()) ?? .empty()
        lock.unlock()
    }

    private func persistRuntime(_ runtime: RuntimeState) {
        lock.lock()
        cachedRuntime = runtime
        lock.unlock()
        try? runtimeStore.save(runtime)
    }

    private func publishMenu(syncing: Bool = false) {
        let settings = currentSettings()
        let runtime = currentRuntime()
        let calendarOK = calendar.authorizationStatus() == .fullAccess
        let hasToken = (try? tokenStore.hasToken()) ?? false

        let state: MenuSyncState
        if !calendarOK || !hasToken {
            state = .setupRequired
        } else if syncing {
            state = .syncing
        } else if settings.isPaused {
            state = .paused
        } else if runtime.lastError != nil {
            state = .error
        } else if let fp = runtime.lastFingerprint, fp.eventEnd > dateProvider.now {
            state = .active
        } else {
            state = .idle
        }

        let snapshot = MenuSnapshot(
            state: state,
            controllingSummary: runtime.lastFingerprint.map { _ in "Rule active until end" },
            controllingEndsAt: runtime.lastFingerprint?.eventEnd,
            lastSuccessfulSyncAt: runtime.lastSuccessfulSyncAt,
            lastError: runtime.lastError,
            isPaused: settings.isPaused,
            hasToken: hasToken,
            calendarAuthorized: calendarOK
        )
        lock.lock()
        lastMenuSnapshot = snapshot
        lock.unlock()
        onMenuSnapshotChange?(snapshot)
    }
}
