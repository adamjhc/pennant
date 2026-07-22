import { describe, expect, it } from "vitest";
import {
  assignPrioritiesFromOrder,
  ConfigSchema,
  defaultConfig,
  findMatchingRules,
  pickHighestPriorityRule,
  titleMatchesRule,
} from "../src/config.js";
import { validateSettingsPayload } from "../src/settings-service.js";
import { PROTOCOL_VERSION, RequestSchema, SyncParamsSchema } from "../src/protocol.js";

describe("ConfigSchema", () => {
  it("applies defaults without timezone", () => {
    const config = ConfigSchema.parse({
      rules: [
        {
          eventNameContains: "Focus",
          status: "Focusing",
          emoji: ":dart:",
          notifications: "snooze",
          priority: 1,
        },
      ],
    });
    expect(config.pollIntervalSeconds).toBe(30);
    expect(config.calendarNames).toBeUndefined();
    expect((config as { timezone?: string }).timezone).toBeUndefined();
  });

  it("provides example defaults", () => {
    const config = defaultConfig();
    expect(config.rules).toHaveLength(3);
    expect(config.rules[0].eventNameContains).toBe("Focus");
  });
});

describe("assignPrioritiesFromOrder", () => {
  it("writes 10, 20, 30 from drag order", () => {
    const rules = assignPrioritiesFromOrder([
      {
        eventNameContains: "Standup",
        status: "In standup",
        emoji: ":calendar:",
        notifications: "snooze",
      },
      {
        eventNameContains: "Focus",
        status: "Focusing",
        emoji: ":dart:",
        notifications: "snooze",
        priority: 999,
      },
    ]);
    expect(rules.map((r) => r.priority)).toEqual([10, 20]);
    expect(rules[0].eventNameContains).toBe("Standup");
  });
});

describe("title matching", () => {
  const rules = [
    {
      eventNameContains: "Focus",
      status: "Focusing",
      emoji: ":dart:",
      notifications: "snooze" as const,
      priority: 10,
    },
    {
      eventNameContains: "1:1",
      status: "In a 1:1",
      emoji: ":speech_balloon:",
      notifications: "snooze" as const,
      priority: 20,
    },
  ];

  it("matches substrings case-insensitively", () => {
    expect(titleMatchesRule("Morning focus block", rules[0])).toBe(true);
    expect(titleMatchesRule("FOCUS", rules[0])).toBe(true);
    expect(titleMatchesRule("Lunch", rules[0])).toBe(false);
  });

  it("finds matching rules", () => {
    expect(findMatchingRules("Weekly 1:1 with Sam", rules).map((r) => r.eventNameContains)).toEqual([
      "1:1",
    ]);
  });

  it("picks highest priority (lowest number)", () => {
    expect(pickHighestPriorityRule(rules)?.eventNameContains).toBe("Focus");
  });
});

describe("settings validation", () => {
  it("rejects empty rules", () => {
    const result = validateSettingsPayload({
      pollIntervalSeconds: 30,
      lookAheadMinutes: 15,
      lookBehindMinutes: 5,
      rules: [],
    });
    expect(result.ok).toBe(false);
  });

  it("normalizes priorities from order", () => {
    const result = validateSettingsPayload({
      rules: [
        {
          eventNameContains: "B",
          status: "B",
          emoji: ":b:",
          notifications: "normal",
          priority: 99,
        },
        {
          eventNameContains: "A",
          status: "A",
          emoji: ":a:",
          notifications: "snooze",
          priority: 1,
        },
      ],
    });
    expect(result.ok).toBe(true);
    expect(result.settings?.rules.map((r) => r.priority)).toEqual([10, 20]);
  });
});

describe("protocol schemas", () => {
  it("accepts a sync request envelope", () => {
    const req = RequestSchema.parse({
      v: PROTOCOL_VERSION,
      id: "abc",
      method: "sync",
      params: {},
    });
    expect(req.method).toBe("sync");
  });

  it("accepts sync params with events", () => {
    const params = SyncParamsSchema.parse({
      settings: defaultConfig(),
      slackToken: "xoxp-test-token-value-here",
      events: [
        {
          id: "1",
          iCalUId: "1",
          changeKey: null,
          title: "Focus",
          start: "2026-07-20T12:00:00.000Z",
          end: "2026-07-20T13:00:00.000Z",
          isAllDay: false,
          isCancelled: false,
          response: "accepted",
          showAs: "busy",
          calendarName: "Work",
          calendarId: "c",
        },
      ],
    });
    expect(params.events).toHaveLength(1);
  });

  it("rejects unknown methods", () => {
    expect(() =>
      RequestSchema.parse({ v: 1, id: "x", method: "explode" }),
    ).toThrow();
  });
});
