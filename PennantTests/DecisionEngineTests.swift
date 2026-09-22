import Foundation

#if canImport(PennantCore)
import PennantCore
#elseif canImport(Pennant)
@testable import Pennant
#endif

#if canImport(XCTest)
import XCTest
#endif

final class DecisionEngineTests: XCTestCase {
    let engine = DecisionEngine()
    let now = ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z")!

    private func occurrence(
        id: String = "e1",
        title: String,
        start: String,
        end: String,
        calendarId: String = "cal-1",
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        attendance: AttendanceResponse = .accepted,
        availability: EventAvailability = .busy,
        isOrganizerOwned: Bool = false,
        series: String? = nil
    ) -> CalendarOccurrence {
        let f = ISO8601DateFormatter()
        return CalendarOccurrence(
            id: id,
            seriesIdentifier: series,
            calendarId: calendarId,
            calendarTitle: "Work",
            title: title,
            start: f.date(from: start)!,
            end: f.date(from: end)!,
            isAllDay: isAllDay,
            isCancelled: isCancelled,
            attendance: attendance,
            availability: availability,
            isOrganizerOwned: isOrganizerOwned
        )
    }

    private var rules: [StatusRule] {
        [
            StatusRule(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, titleRegex: "Focus", statusText: "Focusing", statusEmoji: ":dart:", enableDND: true),
            StatusRule(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, titleRegex: "1:1", statusText: "In a 1:1", statusEmoji: ":speech_balloon:", enableDND: true),
            StatusRule(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, titleRegex: "Standup", statusText: "In standup", statusEmoji: ":calendar:", enableDND: false),
        ]
    }

    func testRegexCaseInsensitiveAndAnchors() throws {
        XCTAssertTrue(RuleValidator.matches(title: "deep FOCUS time", pattern: "Focus"))
        XCTAssertTrue(RuleValidator.matches(title: "Daily Standup", pattern: "^Daily"))
        XCTAssertFalse(RuleValidator.matches(title: "Standup Daily", pattern: "^Daily"))
        XCTAssertThrowsError(try RuleValidator.compileRegex("("))
        XCTAssertThrowsError(try RuleValidator.compileRegex("  "))
    }

    func testEmojiValidation() {
        XCTAssertTrue(RuleValidator.validateEmoji(":dart:"))
        XCTAssertTrue(RuleValidator.validateEmoji(":skin-tone-2:"))
        XCTAssertFalse(RuleValidator.validateEmoji("dart"))
        XCTAssertFalse(RuleValidator.validateEmoji(":"))
        XCTAssertFalse(RuleValidator.validateEmoji(""))
    }

    func testExcludesAllDayCancelledDeclinedTentative() {
        XCTAssertFalse(engine.isEligible(occurrence(title: "Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T13:00:00Z", isAllDay: true), now: now, disabledCalendarIDs: []))
        XCTAssertFalse(engine.isEligible(occurrence(title: "Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T13:00:00Z", isCancelled: true), now: now, disabledCalendarIDs: []))
        XCTAssertFalse(engine.isEligible(occurrence(title: "Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T13:00:00Z", attendance: .declined), now: now, disabledCalendarIDs: []))
        XCTAssertFalse(engine.isEligible(occurrence(title: "Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T13:00:00Z", attendance: .tentative), now: now, disabledCalendarIDs: []))
    }

    func testIncludesFreeAndPersonalNone() {
        XCTAssertTrue(engine.isEligible(occurrence(title: "Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T13:00:00Z", availability: .free), now: now, disabledCalendarIDs: []))
        XCTAssertTrue(engine.isEligible(occurrence(title: "Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T13:00:00Z", attendance: .none, isOrganizerOwned: true), now: now, disabledCalendarIDs: []))
    }

    func testDisabledCalendarExcluded() {
        XCTAssertFalse(engine.isEligible(occurrence(title: "Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T13:00:00Z"), now: now, disabledCalendarIDs: ["cal-1"]))
    }

    func testFirstRuleWinsForSameEvent() {
        let match = engine.firstMatchingRule(for: "Focus 1:1 Standup", rules: rules)
        XCTAssertEqual(match?.rule.statusText, "Focusing")
        XCTAssertEqual(match?.index, 0)
    }

    func testOverlapPrefersHigherPriorityThenLatestStart() {
        let focus = occurrence(id: "focus", title: "Deep Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T14:00:00Z")
        let standup = occurrence(id: "standup", title: "Team Standup", start: "2026-07-20T12:00:00Z", end: "2026-07-20T12:30:00Z")
        // Focus rule is index 0 (higher priority); should win over Standup even if standup started later.
        let selected = engine.selectControllingMatch(occurrences: [focus, standup], rules: rules, now: now, disabledCalendarIDs: [])
        XCTAssertEqual(selected?.occurrence.id, "focus")

        // Two events matching same rule — most recently started wins.
        let a = occurrence(id: "a", title: "Focus A", start: "2026-07-20T11:00:00Z", end: "2026-07-20T13:00:00Z")
        let b = occurrence(id: "b", title: "Focus B", start: "2026-07-20T11:30:00Z", end: "2026-07-20T13:00:00Z")
        let sameRule = engine.selectControllingMatch(occurrences: [a, b], rules: rules, now: now, disabledCalendarIDs: [])
        XCTAssertEqual(sameRule?.occurrence.id, "b")
    }

    func testZeroRulesSkips() {
        let decision = engine.decide(
            occurrences: [occurrence(title: "Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T13:00:00Z")],
            rules: [],
            now: now,
            disabledCalendarIDs: [],
            previousFingerprint: nil,
            force: false
        )
        XCTAssertEqual(decision.action, .skip)
    }

    func testAlreadyAppliedSkipsUnlessForceOrChanged() {
        let occ = occurrence(title: "Deep Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T13:00:00Z")
        let match = engine.selectControllingMatch(occurrences: [occ], rules: rules, now: now, disabledCalendarIDs: [])!
        let fp = ControllingFingerprint.from(match: match)

        let skip = engine.decide(occurrences: [occ], rules: rules, now: now, disabledCalendarIDs: [], previousFingerprint: fp, force: false)
        XCTAssertEqual(skip.action, .skip)
        XCTAssertEqual(skip.reason, "already_applied")

        let forced = engine.decide(occurrences: [occ], rules: rules, now: now, disabledCalendarIDs: [], previousFingerprint: fp, force: true)
        XCTAssertEqual(forced.action, .apply)

        var changed = occ
        changed.title = "Focus changed"
        // Still matches Focus rule; title hash changes → apply
        let changedDecision = engine.decide(occurrences: [changed], rules: rules, now: now, disabledCalendarIDs: [], previousFingerprint: fp, force: false)
        XCTAssertEqual(changedDecision.action, .apply)
        XCTAssertEqual(changedDecision.reason, "controlling_event_changed")
    }

    func testClearWhenNoLongerControlling() {
        let occ = occurrence(title: "Deep Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T13:00:00Z")
        let match = engine.selectControllingMatch(occurrences: [occ], rules: rules, now: now, disabledCalendarIDs: [])!
        let fp = ControllingFingerprint.from(match: match)
        let decision = engine.decide(occurrences: [], rules: rules, now: now, disabledCalendarIDs: [], previousFingerprint: fp, force: false)
        XCTAssertEqual(decision.action, .clear)
    }

    func testRecurringOccurrenceKeysDifferByStart() {
        let a = occurrence(id: "1", title: "Focus", start: "2026-07-20T11:00:00Z", end: "2026-07-20T12:00:00Z", series: "series-1")
        let b = occurrence(id: "2", title: "Focus", start: "2026-07-21T11:00:00Z", end: "2026-07-21T12:00:00Z", series: "series-1")
        XCTAssertNotEqual(a.occurrenceKey, b.occurrenceKey)
    }

    func testExactBoundaryActive() {
        let occ = occurrence(title: "Focus", start: "2026-07-20T12:00:00Z", end: "2026-07-20T13:00:00Z")
        XCTAssertTrue(engine.isActive(occ, now: now, disabledCalendarIDs: []))
        let afterEnd = ISO8601DateFormatter().date(from: "2026-07-20T13:00:00Z")!
        XCTAssertFalse(engine.isActive(occ, now: afterEnd, disabledCalendarIDs: []))
    }

    func testSnoozeRounding() {
        XCTAssertEqual(DecisionEngine.snoozeMinutesRemaining(end: now.addingTimeInterval(30), now: now), 1)
        XCTAssertEqual(DecisionEngine.snoozeMinutesRemaining(end: now.addingTimeInterval(601), now: now), 11)
    }
}
