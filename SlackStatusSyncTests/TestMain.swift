import Foundation
#if canImport(SlackStatusSyncCore)
import SlackStatusSyncCore
#elseif canImport(SlackStatusSync)
@testable import SlackStatusSync
#endif

@main
enum TestMain {
    static func main() async {
        var passed = 0
        var failed = 0

        func run(_ name: String, _ body: () async throws -> Void) async {
            #if !canImport(XCTest)
            TestRuntime.currentTest = name
            let before = TestRuntime.failures.count
            #endif
            do {
                try await body()
                #if !canImport(XCTest)
                if TestRuntime.failures.count == before {
                    print("PASS \(name)")
                    passed += 1
                } else {
                    failed += 1
                }
                #else
                print("PASS \(name)")
                passed += 1
                #endif
            } catch {
                print("FAIL \(name): \(error)")
                failed += 1
            }
        }

        print("== DecisionEngineTests ==")
        do {
            let t = DecisionEngineTests()
            await run("testRegexCaseInsensitiveAndAnchors") { try t.testRegexCaseInsensitiveAndAnchors() }
            await run("testEmojiValidation") { t.testEmojiValidation() }
            await run("testExcludesAllDayCancelledDeclinedTentative") { t.testExcludesAllDayCancelledDeclinedTentative() }
            await run("testIncludesFreeAndPersonalNone") { t.testIncludesFreeAndPersonalNone() }
            await run("testDisabledCalendarExcluded") { t.testDisabledCalendarExcluded() }
            await run("testFirstRuleWinsForSameEvent") { t.testFirstRuleWinsForSameEvent() }
            await run("testOverlapPrefersHigherPriorityThenLatestStart") { t.testOverlapPrefersHigherPriorityThenLatestStart() }
            await run("testZeroRulesSkips") { t.testZeroRulesSkips() }
            await run("testAlreadyAppliedSkipsUnlessForceOrChanged") { t.testAlreadyAppliedSkipsUnlessForceOrChanged() }
            await run("testClearWhenNoLongerControlling") { t.testClearWhenNoLongerControlling() }
            await run("testRecurringOccurrenceKeysDifferByStart") { t.testRecurringOccurrenceKeysDifferByStart() }
            await run("testExactBoundaryActive") { t.testExactBoundaryActive() }
            await run("testSnoozeRounding") { t.testSnoozeRounding() }
        }

        print("== PersistenceTests ==")
        do {
            let t = PersistenceTests()
            await run("testSettingsRoundTripAndAtomicWrite") { try t.testSettingsRoundTripAndAtomicWrite() }
            await run("testMissingFileReturnsDefaults") { try t.testMissingFileReturnsDefaults() }
            await run("testCorruptDataThrows") { try t.testCorruptDataThrows() }
            await run("testUnsupportedSchemaThrows") { try t.testUnsupportedSchemaThrows() }
            await run("testRuntimeStateRoundTrip") { try t.testRuntimeStateRoundTrip() }
            await run("testInMemoryTokenAndReset") { try t.testInMemoryTokenAndReset() }
            await run("testTokenStoreErrors") { try t.testTokenStoreErrors() }
        }

        print("== CalendarMappingTests ==")
        do {
            let t = CalendarMappingTests()
            await run("testPersonalEventsMapToNoneOrganizerOwned") { t.testPersonalEventsMapToNoneOrganizerOwned() }
            await run("testDeclinedAttendee") { t.testDeclinedAttendee() }
            await run("testNewCalendarsAutoIncluded") { t.testNewCalendarsAutoIncluded() }
            await run("testGroupedBySource") { t.testGroupedBySource() }
            await run("testFakeCalendarAuthAndFetch") { try await t.testFakeCalendarAuthAndFetch() }
        }

        print("== SlackClientTests ==")
        do {
            let t = SlackClientTests()
            await run("testTokenFormat") { t.testTokenFormat() }
            await run("testParseScopesHeader") { t.testParseScopesHeader() }
            await run("testURLProtocolAuthAndMissingScopes") { try await t.testURLProtocolAuthAndMissingScopes() }
            await run("testSetStatusEncodingAndProfileGet") { try await t.testSetStatusEncodingAndProfileGet() }
            await run("testRateLimitAndAuthErrors") { try await t.testRateLimitAndAuthErrors() }
        }

        print("== SlackActionExecutorTests ==")
        do {
            let t = SlackActionExecutorTests()
            await run("testApplyStatusAndDND") { await t.testApplyStatusAndDND() }
            await run("testDNDOffLeavesExistingDND") { await t.testDNDOffLeavesExistingDND() }
            await run("testPreserveLongerExistingDND") { await t.testPreserveLongerExistingDND() }
            await run("testFailedDNDReadSkipsAndRetries") { await t.testFailedDNDReadSkipsAndRetries() }
            await run("testPartialDNDSetFailure") { await t.testPartialDNDSetFailure() }
            await run("testManualOverridePreserved") { await t.testManualOverridePreserved() }
            await run("testExpiredOwnedStatusDoesNotBlockNextEvent") { await t.testExpiredOwnedStatusDoesNotBlockNextEvent() }
            await run("testClearIfOwned") { await t.testClearIfOwned() }
            await run("testEndOwnedDNDAtBoundary") { await t.testEndOwnedDNDAtBoundary() }
        }

        print("== SyncCoordinatorTests ==")
        do {
            let t = SyncCoordinatorTests()
            await run("testStartupAppliesActiveEvent") { await t.testStartupAppliesActiveEvent() }
            await run("testSafetyPollChecksCalendarAfterSixtySeconds") { await t.testSafetyPollChecksCalendarAfterSixtySeconds() }
            await run("testSuccessfulNoOpPollUpdatesLastSyncTime") { await t.testSuccessfulNoOpPollUpdatesLastSyncTime() }
            await run("testExpiredOwnershipRecoversFromPreviouslySkippedEvent") { await t.testExpiredOwnershipRecoversFromPreviouslySkippedEvent() }
            await run("testRestartDoesNotReapply") { await t.testRestartDoesNotReapply() }
            await run("testPauseBlocksAutomaticButSyncNowWorks") { await t.testPauseBlocksAutomaticButSyncNowWorks() }
            await run("testTogglePausePersists") { t.testTogglePausePersists() }
            await run("testRetryStopsAtEventEnd") { await t.testRetryStopsAtEventEnd() }
            await run("testManualOverrideThenForceSync") { await t.testManualOverrideThenForceSync() }
            await run("testSetupRequiredWithoutToken") { await t.testSetupRequiredWithoutToken() }
        }

        print("== SettingsViewModelTests ==")
        do {
            let t = SettingsViewModelTests()
            await run("testValidationAndSave") { try await t.testValidationAndSave() }
            await run("testRejectsOfflineTokenReplacement") { await t.testRejectsOfflineTokenReplacement() }
            await run("testMissingScopesRejected") { await t.testMissingScopesRejected() }
            await run("testInvalidRuleRegex") { t.testInvalidRuleRegex() }
            await run("testDirtyAndCancel") { t.testDirtyAndCancel() }
            await run("testResetApp") { try t.testResetApp() }
            await run("testSampleMatchAndPreview") { t.testSampleMatchAndPreview() }
            await run("testCalendarAccessRequired") { t.testCalendarAccessRequired() }
        }

        print("Finished: \(passed) passed, \(failed) failed")
        if failed > 0 {
            exit(1)
        }
    }
}
