import {
  type AppConfig,
  type TitleRule,
  findMatchingRules,
  pickHighestPriorityRule,
} from "../config.js";
import type { CalendarEvent } from "../calendar/types.js";
import type { Logger } from "../logger.js";
import { withRetry } from "../retry.js";
import type { SlackClient } from "../slack/client.js";
import type { SyncState } from "../state.js";

export interface SelectableEvent {
  event: CalendarEvent;
  rule: TitleRule;
}

export interface SyncDecision {
  action: "apply" | "skip";
  reason: string;
  selected?: SelectableEvent;
}

export function isEventEligible(event: CalendarEvent, now: Date = new Date()): boolean {
  if (event.isCancelled) {
    return false;
  }
  const response = (event.response ?? "").toLowerCase();
  if (response === "declined") {
    return false;
  }
  if (event.end.getTime() <= now.getTime()) {
    return false;
  }
  return true;
}

export function isEventActive(event: CalendarEvent, now: Date = new Date()): boolean {
  return (
    isEventEligible(event, now) &&
    event.start.getTime() <= now.getTime() &&
    event.end.getTime() > now.getTime()
  );
}

export function eventIdentityKey(event: CalendarEvent): string {
  return event.iCalUId ?? event.id;
}

export function wasAlreadyHandled(event: CalendarEvent, state: SyncState): boolean {
  const identity = eventIdentityKey(event);
  if (state.lastHandledICalUId && state.lastHandledICalUId === identity) {
    if (state.lastHandledStart && state.lastHandledStart === event.start.toISOString()) {
      return true;
    }
  }
  if (state.lastHandledEventId === event.id) {
    if (
      state.lastHandledChangeKey &&
      event.changeKey &&
      state.lastHandledChangeKey === event.changeKey
    ) {
      return true;
    }
    if (state.lastHandledStart && state.lastHandledStart === event.start.toISOString()) {
      return true;
    }
  }
  return false;
}

/**
 * Select the event that should trigger a Slack update.
 *
 * Rules:
 * - Only title-matched, eligible events
 * - Prefer newly starting events (crossed start since last poll)
 * - On startup / first poll, apply highest-priority currently active matched event
 *   if it has not already been handled
 * - Overlaps resolve by configured priority (lower number wins), then start time, then rule text
 */
export function selectEventToApply(
  events: CalendarEvent[],
  config: AppConfig,
  state: SyncState,
  now: Date = new Date(),
  previousPollAt: Date | null = null,
): SyncDecision {
  const mapped: SelectableEvent[] = [];

  for (const event of events) {
    if (!isEventEligible(event, now)) {
      continue;
    }
    const matching = findMatchingRules(event.title, config.rules);
    const rule = pickHighestPriorityRule(matching);
    if (!rule) {
      continue;
    }
    mapped.push({ event, rule });
  }

  if (mapped.length === 0) {
    return { action: "skip", reason: "no_mapped_events" };
  }

  const sortMapped = (items: SelectableEvent[]): SelectableEvent[] =>
    [...items].sort((a, b) => {
      if (a.rule.priority !== b.rule.priority) {
        return a.rule.priority - b.rule.priority;
      }
      const startDiff = a.event.start.getTime() - b.event.start.getTime();
      if (startDiff !== 0) {
        return startDiff;
      }
      return a.rule.eventNameContains.localeCompare(b.rule.eventNameContains);
    });

  const newlyStarting = mapped.filter(({ event }) => {
    if (wasAlreadyHandled(event, state)) {
      return false;
    }
    if (event.start.getTime() > now.getTime()) {
      return false;
    }
    if (previousPollAt) {
      return event.start.getTime() > previousPollAt.getTime();
    }
    return isEventActive(event, now);
  });

  if (newlyStarting.length > 0) {
    const selected = sortMapped(newlyStarting)[0];
    return {
      action: "apply",
      reason: previousPollAt ? "event_started" : "startup_active",
      selected,
    };
  }

  return { action: "skip", reason: "no_new_starts" };
}

export function snoozeMinutesRemaining(end: Date, now: Date = new Date()): number {
  const ms = end.getTime() - now.getTime();
  return Math.max(1, Math.ceil(ms / 60_000));
}

export function statusExpirationUnix(end: Date): number {
  return Math.floor(end.getTime() / 1000);
}

export interface ApplyResult {
  applied: boolean;
  reason: string;
  eventId?: string;
  rule?: string;
}

export async function applyDecision(
  decision: SyncDecision,
  slack: SlackClient,
  logger: Logger,
  now: Date = new Date(),
): Promise<{ result: ApplyResult; nextStatePatch: Partial<SyncState> }> {
  if (decision.action !== "apply" || !decision.selected) {
    return {
      result: { applied: false, reason: decision.reason },
      nextStatePatch: { lastPollAt: now.toISOString() },
    };
  }

  const { event, rule } = decision.selected;

  await withRetry(
    async () => {
      await slack.setStatus({
        statusText: rule.status,
        statusEmoji: rule.emoji,
        statusExpiration: statusExpirationUnix(event.end),
      });

      if (rule.notifications === "snooze") {
        await slack.setSnooze(snoozeMinutesRemaining(event.end, now));
      } else {
        await slack.endSnooze();
      }
    },
    {
      onRetry: (error, attempt, delayMs) => {
        logger.warn("Retrying Slack API call", {
          attempt,
          delayMs,
          error: error instanceof Error ? error.message : String(error),
        });
      },
    },
  );

  logger.info("Applied Slack update from calendar event", {
    eventId: event.id,
    iCalUId: event.iCalUId,
    changeKey: event.changeKey,
    rule: rule.eventNameContains,
    status: rule.status,
    emoji: rule.emoji,
    notifications: rule.notifications,
    reason: decision.reason,
    start: event.start.toISOString(),
    end: event.end.toISOString(),
    calendarName: event.calendarName,
  });

  return {
    result: {
      applied: true,
      reason: decision.reason,
      eventId: event.id,
      rule: rule.eventNameContains,
    },
    nextStatePatch: {
      lastHandledEventId: event.id,
      lastHandledChangeKey: event.changeKey,
      lastHandledICalUId: eventIdentityKey(event),
      lastHandledStart: event.start.toISOString(),
      lastHandledEnd: event.end.toISOString(),
      lastHandledRule: rule.eventNameContains,
      lastAppliedAt: now.toISOString(),
      lastPollAt: now.toISOString(),
    },
  };
}
