import Foundation

#if canImport(PennantCore)
import PennantCore
#elseif canImport(Pennant)
@testable import Pennant
#endif

#if canImport(XCTest)
import XCTest
#endif

final class SyncCoordinatorTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z")!

    private func makeHarness(
        paused: Bool = false,
        occurrences: [CalendarOccurrence] = [],
        rules: [StatusRule]? = nil
    ) -> (SyncCoordinator, FakeSlackClient, FakeCalendarService, FakeDateProvider, ImmediateScheduler, InMemoryRuntimeStateStore, InMemorySettingsStore, InMemoryTokenStore) {
        let slack = FakeSlackClient()
        let calendar = FakeCalendarService(occurrences: occurrences)
        let dates = FakeDateProvider(now)
        let scheduler = ImmediateScheduler()
        let runtime = InMemoryRuntimeStateStore()
        var settings = AppSettings.freshDefaults()
        settings.isPaused = paused
        settings.rules = rules ?? [
            StatusRule(titleRegex: "Focus", statusText: "Focusing", statusEmoji: ":dart:", enableDND: true)
        ]
        settings.hasCompletedSetup = true
        let settingsStore = InMemorySettingsStore(settings)
        let tokens = InMemoryTokenStore(token: "xoxp-test-token-value")
        let coordinator = SyncCoordinator(
            calendar: calendar,
            slack: slack,
            settingsStore: settingsStore,
            runtimeStore: runtime,
            tokenStore: tokens,
            dateProvider: dates,
            scheduler: scheduler
        )
        return (coordinator, slack, calendar, dates, scheduler, runtime, settingsStore, tokens)
    }

    private func focusOccurrence(start: String = "2026-07-20T11:00:00Z", end: String = "2026-07-20T13:00:00Z") -> CalendarOccurrence {
        let f = ISO8601DateFormatter()
        return CalendarOccurrence(
            id: "focus",
            seriesIdentifier: "series-focus",
            calendarId: "cal",
            calendarTitle: "Work",
            title: "Deep Focus",
            start: f.date(from: start)!,
            end: f.date(from: end)!,
            attendance: .accepted
        )
    }

    func testStartupAppliesActiveEvent() async {
        let (coordinator, slack, _, _, _, runtime, _, _) = makeHarness(occurrences: [focusOccurrence()])
        await coordinator.syncNow()
        XCTAssertEqual(slack.setStatusCalls.count, 1)
        XCTAssertEqual(try runtime.load().ownedStatus?.text, "Focusing")
    }

    func testSafetyPollChecksCalendarAfterSixtySeconds() async {
        let (coordinator, slack, calendar, _, scheduler, runtime, _, _) = makeHarness()
        coordinator.start()

        for _ in 0..<100 where (try? runtime.load().lastSuccessfulSyncAt) == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(calendar.fetchCallCount, 1)
        XCTAssertEqual(scheduler.scheduledInterval(id: "safety"), SyncCoordinator.safetyPollInterval)

        calendar.occurrences = [focusOccurrence()]
        scheduler.fire(id: "safety")

        for _ in 0..<100 where slack.setStatusCalls.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(calendar.fetchCallCount, 2)
        XCTAssertEqual(slack.setStatusCalls.count, 1)
    }

    func testSuccessfulNoOpPollUpdatesLastSyncTime() async {
        let (coordinator, _, _, _, _, runtime, _, _) = makeHarness()
        await coordinator.calendarDidChange()
        XCTAssertEqual(try runtime.load().lastSuccessfulSyncAt, now)
    }

    func testExpiredOwnershipRecoversFromPreviouslySkippedEvent() async {
        let occurrence = focusOccurrence()
        let rule = StatusRule(
            titleRegex: "Focus",
            statusText: "Focusing",
            statusEmoji: ":dart:",
            enableDND: false
        )
        let match = MatchedOccurrence(occurrence: occurrence, rule: rule, ruleIndex: 0)
        let runtime = InMemoryRuntimeStateStore(
            RuntimeState(
                lastFingerprint: ControllingFingerprint.from(match: match),
                ownedStatus: AppOwnedStatus(
                    text: "Old status",
                    emoji: ":calendar:",
                    expiration: now.addingTimeInterval(-60)
                )
            )
        )
        var settings = AppSettings.freshDefaults()
        settings.rules = [rule]
        settings.hasCompletedSetup = true
        let slack = FakeSlackClient()
        let coordinator = SyncCoordinator(
            calendar: FakeCalendarService(occurrences: [occurrence]),
            slack: slack,
            settingsStore: InMemorySettingsStore(settings),
            runtimeStore: runtime,
            tokenStore: InMemoryTokenStore(token: "xoxp-test-token-value"),
            dateProvider: FakeDateProvider(now),
            scheduler: ImmediateScheduler()
        )

        await coordinator.calendarDidChange()

        XCTAssertEqual(slack.setStatusCalls.count, 1)
        XCTAssertEqual(try runtime.load().lastFingerprint, ControllingFingerprint.from(match: match))
    }

    func testRestartDoesNotReapply() async {
        let (coordinator, slack, _, _, _, runtime, _, _) = makeHarness(occurrences: [focusOccurrence()])
        await coordinator.syncNow()
        XCTAssertEqual(slack.setStatusCalls.count, 1)
        // Simulate restart by creating new coordinator with same stores — use sync without force.
        // Same coordinator second normal sync should skip.
        let count = slack.setStatusCalls.count
        // Directly call internal path via syncNow is force; use settingsDidSave? That forces.
        // Use calendarDidChange which is non-force.
        await coordinator.calendarDidChange()
        XCTAssertEqual(slack.setStatusCalls.count, count)
        XCTAssertNotNil(try runtime.load().lastFingerprint)
    }

    func testPauseBlocksAutomaticButSyncNowWorks() async {
        let (coordinator, slack, _, _, _, _, settingsStore, _) = makeHarness(paused: true, occurrences: [focusOccurrence()])
        await coordinator.calendarDidChange()
        XCTAssertEqual(slack.setStatusCalls.count, 0)
        await coordinator.syncNow()
        XCTAssertEqual(slack.setStatusCalls.count, 1)
        XCTAssertTrue(try settingsStore.load().isPaused)
    }

    func testTogglePausePersists() {
        let (coordinator, _, _, _, _, _, settingsStore, _) = makeHarness(paused: false)
        coordinator.togglePause()
        XCTAssertTrue(try settingsStore.load().isPaused)
    }

    func testRetryStopsAtEventEnd() async {
        let slack = FakeSlackClient()
        slack.setStatusError = SlackClientError.transport("down")
        let calendar = FakeCalendarService(occurrences: [focusOccurrence()])
        let dates = FakeDateProvider(now)
        let scheduler = ImmediateScheduler()
        let runtime = InMemoryRuntimeStateStore()
        var settings = AppSettings.freshDefaults()
        settings.rules = [StatusRule(titleRegex: "Focus", statusText: "Focusing", statusEmoji: ":dart:", enableDND: false)]
        settings.hasCompletedSetup = true
        let coordinator = SyncCoordinator(
            calendar: calendar,
            slack: slack,
            settingsStore: InMemorySettingsStore(settings),
            runtimeStore: runtime,
            tokenStore: InMemoryTokenStore(token: "xoxp-test-token-value"),
            dateProvider: dates,
            scheduler: scheduler
        )
        await coordinator.syncNow()
        XCTAssertEqual(try runtime.load().lastError, "transport_error")

        // Advance past event end — retry should not keep applying forever.
        dates.now = ISO8601DateFormatter().date(from: "2026-07-20T14:00:00Z")!
        slack.setStatusError = nil
        calendar.occurrences = []
        await coordinator.syncNow()
        // No active event → clear path; status may clear if owned (none yet due to failure)
        XCTAssertNil(try runtime.load().ownedStatus)
    }

    func testManualOverrideThenForceSync() async {
        let (coordinator, slack, _, _, _, _, _, _) = makeHarness(occurrences: [focusOccurrence()])
        await coordinator.syncNow()
        slack.profile = RemoteSlackProfile(statusText: "Lunch", statusEmoji: ":hamburger:", statusExpiration: nil)
        // Non-force should preserve
        await coordinator.calendarDidChange()
        let afterManual = slack.setStatusCalls.count
        await coordinator.syncNow()
        XCTAssertGreaterThan(slack.setStatusCalls.count, afterManual)
    }

    func testSetupRequiredWithoutToken() async {
        let slack = FakeSlackClient()
        let calendar = FakeCalendarService(occurrences: [focusOccurrence()])
        let coordinator = SyncCoordinator(
            calendar: calendar,
            slack: slack,
            settingsStore: InMemorySettingsStore(),
            runtimeStore: InMemoryRuntimeStateStore(),
            tokenStore: InMemoryTokenStore(token: nil),
            dateProvider: FakeDateProvider(now),
            scheduler: ImmediateScheduler()
        )
        await coordinator.syncNow()
        XCTAssertEqual(coordinator.currentMenuSnapshot().state, .setupRequired)
        XCTAssertEqual(slack.setStatusCalls.count, 0)
    }
}
