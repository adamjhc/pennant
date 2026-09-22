import Foundation

public struct DecisionEngine: Sendable {
    public init() {}

    /// Whether an occurrence is eligible for matching at `now`.
    public func isEligible(
        _ occurrence: CalendarOccurrence,
        now: Date,
        disabledCalendarIDs: Set<String>
    ) -> Bool {
        if disabledCalendarIDs.contains(occurrence.calendarId) {
            return false
        }
        if occurrence.isCancelled {
            return false
        }
        if occurrence.isAllDay {
            return false
        }
        if occurrence.end <= now {
            return false
        }
        switch occurrence.attendance {
        case .accepted, .none:
            break
        case .tentative, .declined, .pending, .unknown:
            // Personal/organizer-owned events with no attendee metadata map to `.none`
            // and are included. Explicit tentative/declined/pending are excluded.
            // `.unknown` with organizer ownership is treated as accepted-equivalent.
            if occurrence.attendance == .unknown && occurrence.isOrganizerOwned {
                break
            }
            if occurrence.attendance == .none {
                break
            }
            return false
        }
        // Free events are included (availability is intentionally not filtered).
        return true
    }

    public func isActive(
        _ occurrence: CalendarOccurrence,
        now: Date,
        disabledCalendarIDs: Set<String>
    ) -> Bool {
        isEligible(occurrence, now: now, disabledCalendarIDs: disabledCalendarIDs)
            && occurrence.start <= now
            && occurrence.end > now
    }

    /// First matching rule in list order wins for a single event.
    public func firstMatchingRule(
        for title: String,
        rules: [StatusRule]
    ) -> (rule: StatusRule, index: Int)? {
        for (index, rule) in rules.enumerated() {
            if RuleValidator.matches(title: title, pattern: rule.titleRegex) {
                return (rule, index)
            }
        }
        return nil
    }

    /// Among active matched events: earliest rule index wins, then most recently started, then id.
    public func selectControllingMatch(
        occurrences: [CalendarOccurrence],
        rules: [StatusRule],
        now: Date,
        disabledCalendarIDs: Set<String>
    ) -> MatchedOccurrence? {
        guard !rules.isEmpty else { return nil }

        var matches: [MatchedOccurrence] = []
        for occurrence in occurrences {
            guard isActive(occurrence, now: now, disabledCalendarIDs: disabledCalendarIDs) else {
                continue
            }
            guard let matched = firstMatchingRule(for: occurrence.title, rules: rules) else {
                continue
            }
            matches.append(
                MatchedOccurrence(
                    occurrence: occurrence,
                    rule: matched.rule,
                    ruleIndex: matched.index
                )
            )
        }

        guard !matches.isEmpty else { return nil }

        return matches.sorted { a, b in
            if a.ruleIndex != b.ruleIndex {
                return a.ruleIndex < b.ruleIndex
            }
            if a.occurrence.start != b.occurrence.start {
                return a.occurrence.start > b.occurrence.start
            }
            return a.occurrence.id < b.occurrence.id
        }.first
    }

    /// Decide whether to apply/skip given prior fingerprint.
    public func decide(
        occurrences: [CalendarOccurrence],
        rules: [StatusRule],
        now: Date,
        disabledCalendarIDs: Set<String>,
        previousFingerprint: ControllingFingerprint?,
        force: Bool
    ) -> SyncDecision {
        let selected = selectControllingMatch(
            occurrences: occurrences,
            rules: rules,
            now: now,
            disabledCalendarIDs: disabledCalendarIDs
        )

        guard let selected else {
            if previousFingerprint != nil {
                return SyncDecision(action: .clear, reason: "no_controlling_event")
            }
            return SyncDecision(action: .skip, reason: "no_matched_events")
        }

        let fingerprint = ControllingFingerprint.from(match: selected)
        if !force, let previous = previousFingerprint {
            if previous.occurrenceKey == fingerprint.occurrenceKey
                && previous.ruleID == fingerprint.ruleID
                && previous.statusText == fingerprint.statusText
                && previous.statusEmoji == fingerprint.statusEmoji
                && previous.enableDND == fingerprint.enableDND
                && previous.eventEnd == fingerprint.eventEnd
                && previous.eventTitleHash == fingerprint.eventTitleHash
            {
                return SyncDecision(action: .skip, reason: "already_applied", selected: selected)
            }
            // Same occurrence but changed title/end/rule → apply (safe update path).
            if previous.occurrenceKey == fingerprint.occurrenceKey {
                return SyncDecision(action: .apply, reason: "controlling_event_changed", selected: selected)
            }
        }

        return SyncDecision(action: .apply, reason: force ? "force_sync" : "new_controlling_event", selected: selected)
    }

    /// Upcoming matches for rule preview (next N days).
    public func previewMatches(
        occurrences: [CalendarOccurrence],
        rule: StatusRule,
        now: Date,
        disabledCalendarIDs: Set<String>,
        lookAhead: TimeInterval = 7 * 24 * 60 * 60,
        limit: Int = 10
    ) -> [CalendarOccurrence] {
        let end = now.addingTimeInterval(lookAhead)
        var results: [CalendarOccurrence] = []
        for occurrence in occurrences {
            if occurrence.start >= end { continue }
            if occurrence.end <= now { continue }
            guard isEligible(occurrence, now: now, disabledCalendarIDs: disabledCalendarIDs) else {
                continue
            }
            // For preview of future events, allow not-yet-started eligible events.
            if occurrence.isAllDay || occurrence.isCancelled { continue }
            if disabledCalendarIDs.contains(occurrence.calendarId) { continue }
            if !RuleValidator.matches(title: occurrence.title, pattern: rule.titleRegex) {
                continue
            }
            // Attendance filter for not-yet-active: reuse eligibility but relax "end > now" already done.
            switch occurrence.attendance {
            case .accepted, .none:
                break
            case .unknown where occurrence.isOrganizerOwned:
                break
            default:
                continue
            }
            results.append(occurrence)
            if results.count >= limit { break }
        }
        return results.sorted { $0.start < $1.start }
    }

    public static func statusExpirationUnix(end: Date) -> Int {
        Int(floor(end.timeIntervalSince1970))
    }

    public static func snoozeMinutesRemaining(end: Date, now: Date) -> Int {
        let ms = end.timeIntervalSince(now)
        return max(1, Int(ceil(ms / 60.0)))
    }
}
