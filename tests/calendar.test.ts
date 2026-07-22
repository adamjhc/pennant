import { describe, expect, it } from "vitest";
import { filterByCalendarNames } from "../src/config.js";
import type { CalendarEvent } from "../src/calendar/types.js";
import { mapWireEvent } from "../src/calendar/map-event.js";
import { createLogger } from "../src/logger.js";

describe("mapWireEvent", () => {
  it("maps wire payload fields", () => {
    const mapped = mapWireEvent({
      id: "evt-1",
      iCalUId: "ext-1",
      changeKey: null,
      title: "Deep Focus",
      start: "2026-07-20T11:00:00.000Z",
      end: "2026-07-20T12:00:00.000Z",
      isAllDay: false,
      isCancelled: false,
      response: "accepted",
      showAs: "busy",
      calendarName: "Work",
      calendarId: "cal-1",
    });

    expect(mapped.id).toBe("evt-1");
    expect(mapped.iCalUId).toBe("ext-1");
    expect(mapped.title).toBe("Deep Focus");
    expect(mapped.start.toISOString()).toBe("2026-07-20T11:00:00.000Z");
    expect(mapped.end.toISOString()).toBe("2026-07-20T12:00:00.000Z");
    expect(mapped.calendarName).toBe("Work");
    expect(mapped.response).toBe("accepted");
  });
});

describe("filterByCalendarNames", () => {
  const events: CalendarEvent[] = [
    {
      id: "1",
      iCalUId: "1",
      changeKey: null,
      title: "A",
      start: new Date(),
      end: new Date(),
      isAllDay: false,
      isCancelled: false,
      response: "accepted",
      showAs: "busy",
      calendarName: "Work",
      calendarId: "w",
    },
    {
      id: "2",
      iCalUId: "2",
      changeKey: null,
      title: "B",
      start: new Date(),
      end: new Date(),
      isAllDay: false,
      isCancelled: false,
      response: "accepted",
      showAs: "busy",
      calendarName: "Personal",
      calendarId: "p",
    },
  ];

  it("returns all events when the allowlist is omitted", () => {
    expect(filterByCalendarNames(events, undefined)).toHaveLength(2);
  });

  it("returns no events when the allowlist is explicitly empty", () => {
    expect(filterByCalendarNames(events, [])).toHaveLength(0);
  });

  it("filters by calendar title case-insensitively", () => {
    expect(filterByCalendarNames(events, ["work"]).map((e) => e.id)).toEqual(["1"]);
  });
});

describe("logger title privacy", () => {
  it("omits title fields from structured logs", () => {
    const chunks: string[] = [];
    const originalWrite = process.stdout.write.bind(process.stdout);
    process.stdout.write = ((chunk: string | Uint8Array) => {
      chunks.push(typeof chunk === "string" ? chunk : Buffer.from(chunk).toString("utf8"));
      return true;
    }) as typeof process.stdout.write;

    try {
      const logger = createLogger({ level: "info", json: true });
      logger.info("test", { title: "Secret Meeting", eventId: "abc" });
    } finally {
      process.stdout.write = originalWrite;
    }

    const line = chunks.join("");
    expect(line).toContain('"title":"[omitted]"');
    expect(line).not.toContain("Secret Meeting");
    expect(line).toContain('"eventId":"abc"');
  });
});
