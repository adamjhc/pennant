import { describe, expect, it, vi } from "vitest";
import type { CalendarEvent } from "../src/calendar/types.js";
import { createLogger } from "../src/logger.js";
import type { SlackClient } from "../src/slack/client.js";
import { applyDecision } from "../src/sync/engine.js";

describe("applyDecision", () => {
  it("sets status and snooze for snooze mappings", async () => {
    const setStatus = vi.fn().mockResolvedValue(undefined);
    const setSnooze = vi.fn().mockResolvedValue(undefined);
    const endSnooze = vi.fn().mockResolvedValue(undefined);
    const slack = { setStatus, setSnooze, endSnooze } as unknown as SlackClient;

    const event: CalendarEvent = {
      id: "e1",
      iCalUId: "ical",
      changeKey: "ck",
      title: "Deep Focus",
      start: new Date("2026-07-20T12:00:00Z"),
      end: new Date("2026-07-20T13:00:00Z"),
      isAllDay: false,
      isCancelled: false,
      response: "accepted",
      showAs: "busy",
      calendarName: "Work",
      calendarId: "cal",
    };

    const now = new Date("2026-07-20T12:05:00Z");
    const { result, nextStatePatch } = await applyDecision(
      {
        action: "apply",
        reason: "event_started",
        selected: {
          event,
          rule: {
            eventNameContains: "Focus",
            status: "Focusing",
            emoji: ":dart:",
            notifications: "snooze",
            priority: 10,
          },
        },
      },
      slack,
      createLogger({ level: "error" }),
      now,
    );

    expect(result.applied).toBe(true);
    expect(result.rule).toBe("Focus");
    expect(setStatus).toHaveBeenCalledWith({
      statusText: "Focusing",
      statusEmoji: ":dart:",
      statusExpiration: Math.floor(event.end.getTime() / 1000),
    });
    expect(setSnooze).toHaveBeenCalledWith(55);
    expect(endSnooze).not.toHaveBeenCalled();
    expect(nextStatePatch.lastHandledEventId).toBe("e1");
    expect(nextStatePatch.lastHandledRule).toBe("Focus");
  });

  it("ends snooze for normal notification mappings", async () => {
    const setStatus = vi.fn().mockResolvedValue(undefined);
    const setSnooze = vi.fn().mockResolvedValue(undefined);
    const endSnooze = vi.fn().mockResolvedValue(undefined);
    const slack = { setStatus, setSnooze, endSnooze } as unknown as SlackClient;

    const event: CalendarEvent = {
      id: "e2",
      iCalUId: "ical2",
      changeKey: "ck2",
      title: "Open office hours",
      start: new Date("2026-07-20T12:00:00Z"),
      end: new Date("2026-07-20T13:00:00Z"),
      isAllDay: false,
      isCancelled: false,
      response: "accepted",
      showAs: "free",
      calendarName: "Work",
      calendarId: "cal",
    };

    await applyDecision(
      {
        action: "apply",
        reason: "event_started",
        selected: {
          event,
          rule: {
            eventNameContains: "office",
            status: "Available",
            emoji: ":large_green_circle:",
            notifications: "normal",
            priority: 30,
          },
        },
      },
      slack,
      createLogger({ level: "error" }),
      new Date("2026-07-20T12:00:00Z"),
    );

    expect(endSnooze).toHaveBeenCalled();
    expect(setSnooze).not.toHaveBeenCalled();
  });
});
