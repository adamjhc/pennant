import { describe, expect, it } from "vitest";
import type { CalendarEvent } from "../src/calendar/types.js";
import type { AppConfig } from "../src/config.js";
import { emptyState, type SyncState } from "../src/state.js";
import {
  isEventEligible,
  selectEventToApply,
  snoozeMinutesRemaining,
  statusExpirationUnix,
  wasAlreadyHandled,
} from "../src/sync/engine.js";

function event(
  partial: Partial<CalendarEvent> & Pick<CalendarEvent, "id" | "start" | "end" | "title">,
): CalendarEvent {
  return {
    iCalUId: partial.iCalUId ?? partial.id,
    changeKey: partial.changeKey ?? "ck1",
    isAllDay: partial.isAllDay ?? false,
    isCancelled: partial.isCancelled ?? false,
    response: partial.response ?? "accepted",
    showAs: partial.showAs ?? "busy",
    calendarName: partial.calendarName ?? "Work",
    calendarId: partial.calendarId ?? "cal-1",
    ...partial,
  };
}

const config: AppConfig = {
  pollIntervalSeconds: 30,
  lookAheadMinutes: 15,
  lookBehindMinutes: 5,
  rules: [
    {
      eventNameContains: "Focus",
      status: "Focusing",
      emoji: ":dart:",
      notifications: "snooze",
      priority: 10,
    },
    {
      eventNameContains: "1:1",
      status: "In a 1:1",
      emoji: ":speech_balloon:",
      notifications: "snooze",
      priority: 20,
    },
    {
      eventNameContains: "Standup",
      status: "In standup",
      emoji: ":calendar:",
      notifications: "snooze",
      priority: 30,
    },
  ],
};

describe("isEventEligible", () => {
  const now = new Date("2026-07-20T12:00:00Z");

  it("rejects cancelled events", () => {
    expect(
      isEventEligible(
        event({
          id: "1",
          title: "Focus block",
          start: new Date("2026-07-20T11:00:00Z"),
          end: new Date("2026-07-20T13:00:00Z"),
          isCancelled: true,
        }),
        now,
      ),
    ).toBe(false);
  });

  it("rejects declined events", () => {
    expect(
      isEventEligible(
        event({
          id: "1",
          title: "Focus block",
          start: new Date("2026-07-20T11:00:00Z"),
          end: new Date("2026-07-20T13:00:00Z"),
          response: "declined",
        }),
        now,
      ),
    ).toBe(false);
  });

  it("rejects ended events", () => {
    expect(
      isEventEligible(
        event({
          id: "1",
          title: "Focus block",
          start: new Date("2026-07-20T10:00:00Z"),
          end: new Date("2026-07-20T11:00:00Z"),
        }),
        now,
      ),
    ).toBe(false);
  });

  it("accepts active accepted events", () => {
    expect(
      isEventEligible(
        event({
          id: "1",
          title: "Focus block",
          start: new Date("2026-07-20T11:00:00Z"),
          end: new Date("2026-07-20T13:00:00Z"),
        }),
        now,
      ),
    ).toBe(true);
  });
});

describe("selectEventToApply", () => {
  const now = new Date("2026-07-20T12:00:00.500Z");

  it("applies highest-priority active event on startup when unhandled", () => {
    const events = [
      event({
        id: "meeting",
        title: "Weekly Standup",
        start: new Date("2026-07-20T11:30:00Z"),
        end: new Date("2026-07-20T12:30:00Z"),
      }),
      event({
        id: "focus",
        title: "Deep Focus",
        start: new Date("2026-07-20T11:00:00Z"),
        end: new Date("2026-07-20T13:00:00Z"),
      }),
    ];

    const decision = selectEventToApply(events, config, emptyState(), now, null);
    expect(decision.action).toBe("apply");
    expect(decision.reason).toBe("startup_active");
    expect(decision.selected?.event.id).toBe("focus");
  });

  it("does not reapply an already handled active event on startup", () => {
    const focus = event({
      id: "focus",
      title: "Deep Focus",
      start: new Date("2026-07-20T11:00:00Z"),
      end: new Date("2026-07-20T13:00:00Z"),
      changeKey: "ck-focus",
    });
    const state: SyncState = {
      ...emptyState(),
      lastHandledEventId: focus.id,
      lastHandledChangeKey: focus.changeKey,
      lastHandledICalUId: focus.iCalUId,
      lastHandledStart: focus.start.toISOString(),
      lastHandledEnd: focus.end.toISOString(),
      lastHandledRule: "Focus",
      lastAppliedAt: "2026-07-20T11:00:05Z",
    };

    const decision = selectEventToApply([focus], config, state, now, null);
    expect(decision.action).toBe("skip");
    expect(decision.reason).toBe("no_new_starts");
  });

  it("applies when a matched event start is crossed since last poll", () => {
    const previousPollAt = new Date("2026-07-20T11:59:40Z");
    const starting = event({
      id: "meeting",
      title: "Product 1:1",
      start: new Date("2026-07-20T12:00:00Z"),
      end: new Date("2026-07-20T13:00:00Z"),
    });

    const decision = selectEventToApply(
      [starting],
      config,
      emptyState(),
      now,
      previousPollAt,
    );
    expect(decision.action).toBe("apply");
    expect(decision.reason).toBe("event_started");
    expect(decision.selected?.rule.eventNameContains).toBe("1:1");
  });

  it("does not overwrite during an active event when no new start occurs", () => {
    const previousPollAt = new Date("2026-07-20T11:59:40Z");
    const active = event({
      id: "focus",
      title: "Deep Focus",
      start: new Date("2026-07-20T11:00:00Z"),
      end: new Date("2026-07-20T13:00:00Z"),
    });
    const state: SyncState = {
      ...emptyState(),
      lastHandledEventId: active.id,
      lastHandledICalUId: active.iCalUId,
      lastHandledStart: active.start.toISOString(),
      lastHandledChangeKey: active.changeKey,
      lastPollAt: previousPollAt.toISOString(),
    };

    const decision = selectEventToApply([active], config, state, now, previousPollAt);
    expect(decision.action).toBe("skip");
    expect(decision.reason).toBe("no_new_starts");
  });

  it("allows a later overlapping event start to override", () => {
    const previousPollAt = new Date("2026-07-20T11:59:40Z");
    const focus = event({
      id: "focus",
      title: "Deep Focus",
      start: new Date("2026-07-20T11:00:00Z"),
      end: new Date("2026-07-20T14:00:00Z"),
    });
    const meeting = event({
      id: "meeting",
      title: "Team Standup",
      start: new Date("2026-07-20T12:00:00Z"),
      end: new Date("2026-07-20T12:30:00Z"),
    });
    const state: SyncState = {
      ...emptyState(),
      lastHandledEventId: focus.id,
      lastHandledICalUId: focus.iCalUId,
      lastHandledStart: focus.start.toISOString(),
      lastHandledChangeKey: focus.changeKey,
    };

    const decision = selectEventToApply(
      [focus, meeting],
      config,
      state,
      now,
      previousPollAt,
    );
    expect(decision.action).toBe("apply");
    expect(decision.selected?.event.id).toBe("meeting");
  });

  it("ignores unmatched titles", () => {
    const decision = selectEventToApply(
      [
        event({
          id: "other",
          title: "Lunch with friends",
          start: new Date("2026-07-20T11:00:00Z"),
          end: new Date("2026-07-20T13:00:00Z"),
        }),
      ],
      config,
      emptyState(),
      now,
      null,
    );
    expect(decision.action).toBe("skip");
    expect(decision.reason).toBe("no_mapped_events");
  });

  it("matches titles case-insensitively by substring", () => {
    const decision = selectEventToApply(
      [
        event({
          id: "focus",
          title: "deep FOCUS time",
          start: new Date("2026-07-20T11:00:00Z"),
          end: new Date("2026-07-20T13:00:00Z"),
        }),
      ],
      config,
      emptyState(),
      now,
      null,
    );
    expect(decision.action).toBe("apply");
    expect(decision.selected?.rule.eventNameContains).toBe("Focus");
  });
});

describe("wasAlreadyHandled", () => {
  it("matches by iCalUId and start", () => {
    const ev = event({
      id: "instance-1",
      iCalUId: "series-1",
      title: "Focus",
      start: new Date("2026-07-20T11:00:00Z"),
      end: new Date("2026-07-20T12:00:00Z"),
    });
    const state: SyncState = {
      ...emptyState(),
      lastHandledICalUId: "series-1",
      lastHandledStart: "2026-07-20T11:00:00.000Z",
    };
    expect(wasAlreadyHandled(ev, state)).toBe(true);
  });

  it("treats next occurrence of a series as new", () => {
    const ev = event({
      id: "instance-2",
      iCalUId: "series-1",
      title: "Focus",
      start: new Date("2026-07-21T11:00:00Z"),
      end: new Date("2026-07-21T12:00:00Z"),
    });
    const state: SyncState = {
      ...emptyState(),
      lastHandledICalUId: "series-1",
      lastHandledStart: "2026-07-20T11:00:00.000Z",
    };
    expect(wasAlreadyHandled(ev, state)).toBe(false);
  });
});

describe("timing helpers", () => {
  it("rounds snooze minutes up and never below 1", () => {
    const now = new Date("2026-07-20T12:00:00Z");
    expect(snoozeMinutesRemaining(new Date("2026-07-20T12:00:30Z"), now)).toBe(1);
    expect(snoozeMinutesRemaining(new Date("2026-07-20T12:10:01Z"), now)).toBe(11);
  });

  it("computes unix status expiration", () => {
    const end = new Date("2026-07-20T13:00:00Z");
    expect(statusExpirationUnix(end)).toBe(Math.floor(end.getTime() / 1000));
  });
});
