import Foundation

#if canImport(SlackStatusSyncCore)
import SlackStatusSyncCore
#elseif canImport(SlackStatusSync)
@testable import SlackStatusSync
#endif

#if canImport(XCTest)
import XCTest
#endif

final class CalendarMappingTests: XCTestCase {
    func testPersonalEventsMapToNoneOrganizerOwned() {
        let mapped = CalendarMapping.attendance(
            isCancelled: false,
            currentUserStatus: nil,
            eventStatus: "confirmed",
            hasAttendees: false,
            isOrganizer: true
        )
        XCTAssertEqual(mapped.0, .none)
        XCTAssertTrue(mapped.isOrganizerOwned)
    }

    func testDeclinedAttendee() {
        let mapped = CalendarMapping.attendance(
            isCancelled: false,
            currentUserStatus: "declined",
            eventStatus: "confirmed",
            hasAttendees: true,
            isOrganizer: false
        )
        XCTAssertEqual(mapped.0, .declined)
    }

    func testNewCalendarsAutoIncluded() {
        let available = [
            CalendarDescriptor(id: "a", title: "A", sourceTitle: "iCloud"),
            CalendarDescriptor(id: "b", title: "B", sourceTitle: "iCloud"),
            CalendarDescriptor(id: "c", title: "C", sourceTitle: "Exchange"),
        ]
        let enabled = CalendarMapping.enabledCalendarIDs(available: available, disabledIDs: ["b"])
        XCTAssertEqual(enabled, Set(["a", "c"]))
    }

    func testGroupedBySource() {
        let available = [
            CalendarDescriptor(id: "a", title: "Work", sourceTitle: "Exchange"),
            CalendarDescriptor(id: "b", title: "Home", sourceTitle: "iCloud"),
            CalendarDescriptor(id: "c", title: "Team", sourceTitle: "Exchange"),
        ]
        let grouped = CalendarMapping.groupedBySource(available)
        XCTAssertEqual(grouped.map(\.source), ["Exchange", "iCloud"])
        XCTAssertEqual(grouped[0].calendars.map(\.title), ["Team", "Work"])
    }

    func testFakeCalendarAuthAndFetch() async throws {
        let cal = FakeCalendarService(status: .notDetermined)
        XCTAssertEqual(cal.authorizationStatus(), .notDetermined)
        let granted = try await cal.requestFullAccess()
        XCTAssertTrue(granted)
        XCTAssertEqual(cal.authorizationStatus(), .fullAccess)

        let f = ISO8601DateFormatter()
        cal.occurrences = [
            CalendarOccurrence(
                id: "1",
                calendarId: "c",
                calendarTitle: "W",
                title: "Focus",
                start: f.date(from: "2026-07-20T11:00:00Z")!,
                end: f.date(from: "2026-07-20T13:00:00Z")!
            )
        ]
        let start = f.date(from: "2026-07-20T10:00:00Z")!
        let end = f.date(from: "2026-07-20T14:00:00Z")!
        XCTAssertEqual(try cal.fetchOccurrences(start: start, end: end).count, 1)
    }
}
