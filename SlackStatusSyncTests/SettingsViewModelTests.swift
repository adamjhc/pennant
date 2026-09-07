import Foundation

#if canImport(SlackStatusSyncCore)
import SlackStatusSyncCore
#elseif canImport(SlackStatusSync)
@testable import SlackStatusSync
#endif

#if canImport(XCTest)
import XCTest
#endif

final class SettingsViewModelTests: XCTestCase {
    func testValidationAndSave() async throws {
        let calendar = FakeCalendarService(status: .fullAccess)
        let slack = FakeSlackClient()
        slack.authResult = SlackAuthTestResult(userID: "U", team: "T", scopes: SlackRequiredScopes.all)
        let settingsStore = InMemorySettingsStore()
        let runtime = InMemoryRuntimeStateStore()
        let tokens = InMemoryTokenStore()
        let launch = FakeLaunchAtLoginService()
        let vm = SettingsViewModel(
            settingsStore: settingsStore,
            runtimeStore: runtime,
            tokenStore: tokens,
            calendar: calendar,
            slack: slack,
            launchAtLogin: launch
        )

        vm.updateDraft { draft in
            draft.rules = [
                RuleDraft(titleRegex: "Focus", statusText: "Focusing", statusEmoji: ":dart:", enableDND: true)
            ]
            draft.replacementToken = "xoxp-valid-token-here"
            draft.launchAtLoginDesired = true
        }
        let error = await vm.save()
        XCTAssertNil(error)
        XCTAssertTrue(vm.hasToken)
        XCTAssertEqual(try settingsStore.load().rules.count, 1)
        XCTAssertEqual(launch.status(), .enabled)
    }

    func testRejectsOfflineTokenReplacement() async {
        let calendar = FakeCalendarService(status: .fullAccess)
        let slack = FakeSlackClient()
        slack.authError = SlackClientError.transport("offline")
        let tokens = InMemoryTokenStore(token: "xoxp-existing-token")
        let vm = SettingsViewModel(
            settingsStore: InMemorySettingsStore(AppSettings(hasCompletedSetup: true)),
            runtimeStore: InMemoryRuntimeStateStore(),
            tokenStore: tokens,
            calendar: calendar,
            slack: slack,
            launchAtLogin: FakeLaunchAtLoginService()
        )
        vm.updateDraft { $0.replacementToken = "xoxp-new-token-value" }
        let error = await vm.save()
        XCTAssertEqual(error, .tokenOffline)
        XCTAssertEqual(try tokens.readToken(), "xoxp-existing-token")
    }

    func testMissingScopesRejected() async {
        let calendar = FakeCalendarService(status: .fullAccess)
        let slack = FakeSlackClient()
        slack.authResult = SlackAuthTestResult(userID: "U", team: "T", scopes: ["users.profile:write"])
        let vm = SettingsViewModel(
            settingsStore: InMemorySettingsStore(),
            runtimeStore: InMemoryRuntimeStateStore(),
            tokenStore: InMemoryTokenStore(),
            calendar: calendar,
            slack: slack,
            launchAtLogin: FakeLaunchAtLoginService()
        )
        vm.updateDraft { $0.replacementToken = "xoxp-valid-token-here" }
        let error = await vm.save()
        guard case .tokenMissingScopes = error else {
            return XCTFail("expected missing scopes, got \(String(describing: error))")
        }
    }

    func testInvalidRuleRegex() {
        let vm = SettingsViewModel(
            settingsStore: InMemorySettingsStore(),
            runtimeStore: InMemoryRuntimeStateStore(),
            tokenStore: InMemoryTokenStore(token: "xoxp-token"),
            calendar: FakeCalendarService(status: .fullAccess),
            slack: FakeSlackClient(),
            launchAtLogin: FakeLaunchAtLoginService()
        )
        vm.updateDraft {
            $0.rules = [RuleDraft(titleRegex: "(", statusText: "X", statusEmoji: ":x:", enableDND: false)]
        }
        XCTAssertNotNil(vm.validateLocal())
    }

    func testDirtyAndCancel() {
        let settings = AppSettings(
            rules: [StatusRule(titleRegex: "A", statusText: "B", statusEmoji: ":c:", enableDND: false)],
            hasCompletedSetup: true
        )
        let vm = SettingsViewModel(
            settingsStore: InMemorySettingsStore(settings),
            runtimeStore: InMemoryRuntimeStateStore(),
            tokenStore: InMemoryTokenStore(token: "xoxp-token"),
            calendar: FakeCalendarService(status: .fullAccess),
            slack: FakeSlackClient(),
            launchAtLogin: FakeLaunchAtLoginService()
        )
        vm.updateDraft { $0.rules[0].statusText = "Changed" }
        XCTAssertTrue(vm.needsDiscardConfirmation())
        vm.cancel()
        XCTAssertEqual(vm.draft.rules[0].statusText, "B")
        XCTAssertFalse(vm.needsDiscardConfirmation())
    }

    func testResetApp() throws {
        let tokens = InMemoryTokenStore(token: "xoxp-token")
        let settingsStore = InMemorySettingsStore(AppSettings(
            rules: [StatusRule(titleRegex: "A", statusText: "B", statusEmoji: ":c:", enableDND: false)],
            hasCompletedSetup: true
        ))
        let launch = FakeLaunchAtLoginService()
        launch.current = .enabled
        let vm = SettingsViewModel(
            settingsStore: settingsStore,
            runtimeStore: InMemoryRuntimeStateStore(RuntimeState(lastError: "x")),
            tokenStore: tokens,
            calendar: FakeCalendarService(status: .fullAccess),
            slack: FakeSlackClient(),
            launchAtLogin: launch
        )
        try vm.resetApp()
        XCTAssertFalse(try tokens.hasToken())
        XCTAssertTrue(try settingsStore.load().rules.isEmpty)
        XCTAssertEqual(launch.status(), .notRegistered)
    }

    func testSampleMatchAndPreview() {
        let f = ISO8601DateFormatter()
        let calendar = FakeCalendarService(
            status: .fullAccess,
            occurrences: [
                CalendarOccurrence(
                    id: "1",
                    calendarId: "c",
                    calendarTitle: "W",
                    title: "Deep Focus",
                    start: f.date(from: "2026-07-21T11:00:00Z")!,
                    end: f.date(from: "2026-07-21T12:00:00Z")!,
                    attendance: .accepted
                )
            ]
        )
        let vm = SettingsViewModel(
            settingsStore: InMemorySettingsStore(),
            runtimeStore: InMemoryRuntimeStateStore(),
            tokenStore: InMemoryTokenStore(token: "xoxp-t"),
            calendar: calendar,
            slack: FakeSlackClient(),
            launchAtLogin: FakeLaunchAtLoginService()
        )
        let rule = RuleDraft(titleRegex: "Focus", statusText: "Focusing", statusEmoji: ":dart:", enableDND: false)
        XCTAssertTrue(vm.sampleMatches(rule: rule, sampleTitle: "My Focus Time"))
        let now = f.date(from: "2026-07-20T12:00:00Z")!
        XCTAssertEqual(vm.previewEvents(for: rule, now: now).count, 1)
    }

    func testCalendarAccessRequired() {
        let vm = SettingsViewModel(
            settingsStore: InMemorySettingsStore(),
            runtimeStore: InMemoryRuntimeStateStore(),
            tokenStore: InMemoryTokenStore(token: "xoxp-t"),
            calendar: FakeCalendarService(status: .denied),
            slack: FakeSlackClient(),
            launchAtLogin: FakeLaunchAtLoginService()
        )
        XCTAssertEqual(vm.validateLocal(), .calendarAccessRequired)
    }
}
