import Foundation

public enum SlackActionResult: Equatable, Sendable {
    case applied
    case skipped(String)
    case cleared
    case partialDNDFailure
    case preservedManualOverride
    case failed(String)
}

public struct SlackActionOutcome: Equatable, Sendable {
    public var result: SlackActionResult
    public var ownedStatus: AppOwnedStatus?
    public var ownedDND: AppOwnedDND?
    public var fingerprint: ControllingFingerprint?
    public var pendingDNDRetry: Bool

    public init(
        result: SlackActionResult,
        ownedStatus: AppOwnedStatus? = nil,
        ownedDND: AppOwnedDND? = nil,
        fingerprint: ControllingFingerprint? = nil,
        pendingDNDRetry: Bool = false
    ) {
        self.result = result
        self.ownedStatus = ownedStatus
        self.ownedDND = ownedDND
        self.fingerprint = fingerprint
        self.pendingDNDRetry = pendingDNDRetry
    }
}

public struct SlackActionExecutor: Sendable {
    private let client: SlackClientProtocol
    private let dateProvider: DateProviding

    public init(client: SlackClientProtocol, dateProvider: DateProviding = SystemDateProvider()) {
        self.client = client
        self.dateProvider = dateProvider
    }

    /// Apply a controlling match. Status first; DND second with safety checks.
    public func apply(
        match: MatchedOccurrence,
        token: String,
        previousOwnedStatus: AppOwnedStatus?,
        previousOwnedDND: AppOwnedDND?,
        force: Bool
    ) async -> SlackActionOutcome {
        let now = dateProvider.now
        let fingerprint = ControllingFingerprint.from(match: match)

        // Respect manual override unless force.
        if !force, let owned = previousOwnedStatus, owned.expiration > now {
            do {
                let remote = try await client.getProfile(token: token)
                if !remote.matches(owned) {
                    return SlackActionOutcome(
                        result: .preservedManualOverride,
                        ownedStatus: previousOwnedStatus,
                        ownedDND: previousOwnedDND,
                        fingerprint: fingerprint
                    )
                }
            } catch {
                // If we cannot read profile, proceed with apply on force paths only.
                // For normal apply after we own status, treat as failure to be safe.
                return SlackActionOutcome(
                    result: .failed(SlackClientError.transport("profile_read").redactedDescription),
                    ownedStatus: previousOwnedStatus,
                    ownedDND: previousOwnedDND
                )
            }
        } else if !force, previousOwnedStatus != nil {
            AppLogger.info(
                "expired owned status ignored for manual override check",
                category: "sync"
            )
        }

        do {
            try await client.setStatus(
                token: token,
                text: match.rule.statusText,
                emoji: match.rule.statusEmoji,
                expiration: match.occurrence.end
            )
        } catch {
            let message = (error as? SlackClientError)?.redactedDescription ?? "status_set_failed"
            return SlackActionOutcome(result: .failed(message), ownedStatus: previousOwnedStatus, ownedDND: previousOwnedDND)
        }

        let ownedStatus = AppOwnedStatus(
            text: match.rule.statusText,
            emoji: match.rule.statusEmoji,
            expiration: match.occurrence.end
        )

        guard match.rule.enableDND else {
            // DND-off rules leave existing DND untouched.
            return SlackActionOutcome(
                result: .applied,
                ownedStatus: ownedStatus,
                ownedDND: previousOwnedDND,
                fingerprint: fingerprint
            )
        }

        return await applyDND(
            token: token,
            eventEnd: match.occurrence.end,
            now: now,
            ownedStatus: ownedStatus,
            previousOwnedDND: previousOwnedDND,
            fingerprint: fingerprint
        )
    }

    /// Retry only the DND step after a prior partial success.
    public func retryDND(
        eventEnd: Date,
        token: String,
        ownedStatus: AppOwnedStatus,
        previousOwnedDND: AppOwnedDND?,
        fingerprint: ControllingFingerprint
    ) async -> SlackActionOutcome {
        await applyDND(
            token: token,
            eventEnd: eventEnd,
            now: dateProvider.now,
            ownedStatus: ownedStatus,
            previousOwnedDND: previousOwnedDND,
            fingerprint: fingerprint
        )
    }

    private func applyDND(
        token: String,
        eventEnd: Date,
        now: Date,
        ownedStatus: AppOwnedStatus,
        previousOwnedDND: AppOwnedDND?,
        fingerprint: ControllingFingerprint
    ) async -> SlackActionOutcome {
        let remote: RemoteDNDState
        do {
            remote = try await client.getDND(token: token)
        } catch {
            return SlackActionOutcome(
                result: .partialDNDFailure,
                ownedStatus: ownedStatus,
                ownedDND: previousOwnedDND,
                fingerprint: fingerprint,
                pendingDNDRetry: true
            )
        }

        if remote.snoozeEnabled, let existingEnd = remote.snoozeEnd, existingEnd > eventEnd {
            // Preserve longer existing DND; do not own it.
            return SlackActionOutcome(
                result: .applied,
                ownedStatus: ownedStatus,
                ownedDND: previousOwnedDND,
                fingerprint: fingerprint
            )
        }

        let minutes = DecisionEngine.snoozeMinutesRemaining(end: eventEnd, now: now)
        do {
            let setEnd = try await client.setSnooze(token: token, numMinutes: minutes)
            // Prefer exact event end for ownership tracking; API may round up.
            let owned = AppOwnedDND(expectedEnd: eventEnd, setAt: now)
            _ = setEnd
            return SlackActionOutcome(
                result: .applied,
                ownedStatus: ownedStatus,
                ownedDND: owned,
                fingerprint: fingerprint
            )
        } catch {
            return SlackActionOutcome(
                result: .partialDNDFailure,
                ownedStatus: ownedStatus,
                ownedDND: previousOwnedDND,
                fingerprint: fingerprint,
                pendingDNDRetry: true
            )
        }
    }

    /// Clear or update when controlling event ends/changes — only if remote still matches owned.
    public func reconcileClearOrUpdate(
        decision: SyncDecision,
        token: String,
        previousOwnedStatus: AppOwnedStatus?,
        previousOwnedDND: AppOwnedDND?,
        force: Bool
    ) async -> SlackActionOutcome {
        switch decision.action {
        case .apply:
            guard let selected = decision.selected else {
                return SlackActionOutcome(result: .skipped("missing_selection"))
            }
            return await apply(
                match: selected,
                token: token,
                previousOwnedStatus: previousOwnedStatus,
                previousOwnedDND: previousOwnedDND,
                force: force
            )
        case .skip:
            return SlackActionOutcome(
                result: .skipped(decision.reason),
                ownedStatus: previousOwnedStatus,
                ownedDND: previousOwnedDND,
                fingerprint: nil
            )
        case .clear:
            return await clearIfOwned(
                token: token,
                previousOwnedStatus: previousOwnedStatus,
                previousOwnedDND: previousOwnedDND
            )
        }
    }

    public func clearIfOwned(
        token: String,
        previousOwnedStatus: AppOwnedStatus?,
        previousOwnedDND: AppOwnedDND?
    ) async -> SlackActionOutcome {
        var keptStatus = previousOwnedStatus
        var keptDND = previousOwnedDND

        if let owned = previousOwnedStatus {
            do {
                let remote = try await client.getProfile(token: token)
                if remote.matches(owned) {
                    try await client.clearStatus(token: token)
                    keptStatus = nil
                } else {
                    return SlackActionOutcome(
                        result: .preservedManualOverride,
                        ownedStatus: previousOwnedStatus,
                        ownedDND: previousOwnedDND
                    )
                }
            } catch {
                return SlackActionOutcome(
                    result: .failed((error as? SlackClientError)?.redactedDescription ?? "clear_failed"),
                    ownedStatus: previousOwnedStatus,
                    ownedDND: previousOwnedDND
                )
            }
        }

        if let ownedDND = previousOwnedDND {
            do {
                let remote = try await client.getDND(token: token)
                let stillOurs = remote.snoozeEnabled
                    && remote.snoozeEnd.map { abs($0.timeIntervalSince(ownedDND.expectedEnd)) < 120 } == true
                if stillOurs {
                    try await client.endSnooze(token: token)
                    keptDND = nil
                }
                // If not ours / longer / changed — leave untouched.
            } catch {
                // Status may already be cleared; report partial.
                return SlackActionOutcome(
                    result: .partialDNDFailure,
                    ownedStatus: keptStatus,
                    ownedDND: keptDND,
                    pendingDNDRetry: false
                )
            }
        }

        return SlackActionOutcome(result: .cleared, ownedStatus: keptStatus, ownedDND: keptDND)
    }

    /// End app-owned DND at exact boundary when awake (after rounded API duration).
    public func endOwnedDNDIfDue(
        token: String,
        ownedDND: AppOwnedDND?
    ) async -> (ended: Bool, ownedDND: AppOwnedDND?) {
        guard let ownedDND else { return (false, nil) }
        let now = dateProvider.now
        guard now >= ownedDND.expectedEnd else { return (false, ownedDND) }
        do {
            let remote = try await client.getDND(token: token)
            let stillOurs = remote.snoozeEnabled
                && remote.snoozeEnd.map { $0 >= ownedDND.expectedEnd.addingTimeInterval(-120) } == true
            if stillOurs {
                try await client.endSnooze(token: token)
                return (true, nil)
            }
            return (false, nil)
        } catch {
            return (false, ownedDND)
        }
    }
}
