import { describe, expect, it } from "vitest";
import {
  ConfigSchema,
  findMatchingRules,
  pickHighestPriorityRule,
  titleMatchesRule,
} from "../src/config.js";

describe("ConfigSchema", () => {
  it("applies defaults", () => {
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
