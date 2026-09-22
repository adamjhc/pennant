import Foundation

#if canImport(PennantCore)
import PennantCore
#elseif canImport(Pennant)
@testable import Pennant
#endif

#if canImport(XCTest)
import XCTest
#endif

final class SlackActionExecutorTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z")!

    private func match(enableDND: Bool = true, endOffset: TimeInterval = 3600) -> MatchedOccurrence {
        let end = now.addingTimeInterval(endOffset)
        let occ = CalendarOccurrence(
            id: "e1",
            calendarId: "c",
            calendarTitle: "W",
            title: "Focus",
            start: now.addingTimeInterval(-600),
            end: end,
            attendance: .accepted
        )
        let rule = StatusRule(titleRegex: "Focus", statusText: "Focusing", statusEmoji: ":dart:", enableDND: enableDND)
        return MatchedOccurrence(occurrence: occ, rule: rule, ruleIndex: 0)
    }

    func testApplyStatusAndDND() async {
        let slack = FakeSlackClient()
        let dates = FakeDateProvider(now)
        let executor = SlackActionExecutor(client: slack, dateProvider: dates)
        let outcome = await executor.apply(
            match: match(),
            token: "xoxp-t",
            previousOwnedStatus: nil,
            previousOwnedDND: nil,
            force: true
        )
        XCTAssertEqual(outcome.result, .applied)
        XCTAssertEqual(slack.setStatusCalls.count, 1)
        XCTAssertEqual(slack.setSnoozeCalls.first, 60)
        XCTAssertNotNil(outcome.ownedDND)
    }

    func testDNDOffLeavesExistingDND() async {
        let slack = FakeSlackClient()
        slack.dnd = RemoteDNDState(snoozeEnabled: true, snoozeEnd: now.addingTimeInterval(7200))
        let executor = SlackActionExecutor(client: slack, dateProvider: FakeDateProvider(now))
        let outcome = await executor.apply(
            match: match(enableDND: false),
            token: "xoxp-t",
            previousOwnedStatus: nil,
            previousOwnedDND: nil,
            force: true
        )
        XCTAssertEqual(outcome.result, .applied)
        XCTAssertEqual(slack.setSnoozeCalls.count, 0)
        XCTAssertEqual(slack.endSnoozeCalls, 0)
    }

    func testPreserveLongerExistingDND() async {
        let slack = FakeSlackClient()
        slack.dnd = RemoteDNDState(snoozeEnabled: true, snoozeEnd: now.addingTimeInterval(10_000))
        let executor = SlackActionExecutor(client: slack, dateProvider: FakeDateProvider(now))
        let outcome = await executor.apply(
            match: match(endOffset: 3600),
            token: "xoxp-t",
            previousOwnedStatus: nil,
            previousOwnedDND: nil,
            force: true
        )
        XCTAssertEqual(outcome.result, .applied)
        XCTAssertEqual(slack.setSnoozeCalls.count, 0)
    }

    func testFailedDNDReadSkipsAndRetries() async {
        let slack = FakeSlackClient()
        slack.getDNDError = SlackClientError.transport("down")
        let executor = SlackActionExecutor(client: slack, dateProvider: FakeDateProvider(now))
        let outcome = await executor.apply(
            match: match(),
            token: "xoxp-t",
            previousOwnedStatus: nil,
            previousOwnedDND: nil,
            force: true
        )
        XCTAssertEqual(outcome.result, .partialDNDFailure)
        XCTAssertTrue(outcome.pendingDNDRetry)
        XCTAssertEqual(slack.setStatusCalls.count, 1)
        XCTAssertEqual(slack.setSnoozeCalls.count, 0)
    }

    func testPartialDNDSetFailure() async {
        let slack = FakeSlackClient()
        slack.setSnoozeError = SlackClientError.apiError("snooze_failed")
        let executor = SlackActionExecutor(client: slack, dateProvider: FakeDateProvider(now))
        let outcome = await executor.apply(
            match: match(),
            token: "xoxp-t",
            previousOwnedStatus: nil,
            previousOwnedDND: nil,
            force: true
        )
        XCTAssertEqual(outcome.result, .partialDNDFailure)
        XCTAssertTrue(outcome.pendingDNDRetry)
    }

    func testManualOverridePreserved() async {
        let slack = FakeSlackClient()
        let owned = AppOwnedStatus(text: "Focusing", emoji: ":dart:", expiration: now.addingTimeInterval(3600))
        slack.profile = RemoteSlackProfile(statusText: "Manual", statusEmoji: ":wave:", statusExpiration: nil)
        let executor = SlackActionExecutor(client: slack, dateProvider: FakeDateProvider(now))
        let outcome = await executor.apply(
            match: match(),
            token: "xoxp-t",
            previousOwnedStatus: owned,
            previousOwnedDND: nil,
            force: false
        )
        XCTAssertEqual(outcome.result, .preservedManualOverride)
        XCTAssertEqual(slack.setStatusCalls.count, 0)
    }

    func testExpiredOwnedStatusDoesNotBlockNextEvent() async {
        let slack = FakeSlackClient()
        let expired = AppOwnedStatus(
            text: "Previous status",
            emoji: ":calendar:",
            expiration: now.addingTimeInterval(-60)
        )
        slack.profile = RemoteSlackProfile(statusText: "", statusEmoji: "", statusExpiration: nil)
        let executor = SlackActionExecutor(client: slack, dateProvider: FakeDateProvider(now))

        let outcome = await executor.apply(
            match: match(enableDND: false),
            token: "xoxp-t",
            previousOwnedStatus: expired,
            previousOwnedDND: nil,
            force: false
        )

        XCTAssertEqual(outcome.result, .applied)
        XCTAssertEqual(slack.setStatusCalls.count, 1)
    }

    func testClearIfOwned() async {
        let slack = FakeSlackClient()
        let end = now.addingTimeInterval(3600)
        let owned = AppOwnedStatus(text: "Focusing", emoji: ":dart:", expiration: end)
        slack.profile = RemoteSlackProfile(statusText: "Focusing", statusEmoji: ":dart:", statusExpiration: end)
        slack.dnd = RemoteDNDState(snoozeEnabled: true, snoozeEnd: end)
        let ownedDND = AppOwnedDND(expectedEnd: end, setAt: now)
        let executor = SlackActionExecutor(client: slack, dateProvider: FakeDateProvider(now))
        let outcome = await executor.clearIfOwned(token: "xoxp-t", previousOwnedStatus: owned, previousOwnedDND: ownedDND)
        XCTAssertEqual(outcome.result, .cleared)
        XCTAssertTrue(slack.clearStatusCalls >= 1 || slack.setStatusCalls.contains(where: { $0.0.isEmpty }))
        XCTAssertEqual(slack.endSnoozeCalls, 1)
        XCTAssertNil(outcome.ownedStatus)
        XCTAssertNil(outcome.ownedDND)
    }

    func testEndOwnedDNDAtBoundary() async {
        let slack = FakeSlackClient()
        let end = now
        slack.dnd = RemoteDNDState(snoozeEnabled: true, snoozeEnd: end.addingTimeInterval(30))
        let owned = AppOwnedDND(expectedEnd: end, setAt: now.addingTimeInterval(-3600))
        let executor = SlackActionExecutor(client: slack, dateProvider: FakeDateProvider(now))
        let result = await executor.endOwnedDNDIfDue(token: "xoxp-t", ownedDND: owned)
        XCTAssertTrue(result.ended)
        XCTAssertNil(result.ownedDND)
        XCTAssertEqual(slack.endSnoozeCalls, 1)
    }
}
