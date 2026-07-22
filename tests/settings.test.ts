import { describe, expect, it } from "vitest";
import { validateSettingsPayload } from "../src/settings-service.js";

describe("validateSettingsPayload", () => {
  it("accepts a complete settings object and rewrites priorities", () => {
    const result = validateSettingsPayload({
      pollIntervalSeconds: 45,
      lookAheadMinutes: 10,
      lookBehindMinutes: 2,
      calendarNames: ["Work"],
      rules: [
        {
          eventNameContains: "Standup",
          status: "In standup",
          emoji: ":calendar:",
          notifications: "snooze",
          priority: 99,
        },
        {
          eventNameContains: "Focus",
          status: "Focusing",
          emoji: ":dart:",
          notifications: "snooze",
          priority: 1,
        },
      ],
    });
    expect(result.ok).toBe(true);
    expect(result.settings?.pollIntervalSeconds).toBe(45);
    expect(result.settings?.calendarNames).toEqual(["Work"]);
    expect(result.settings?.rules.map((r) => r.priority)).toEqual([10, 20]);
    expect(result.settings?.rules[0].eventNameContains).toBe("Standup");
  });

  it("rejects invalid notification values", () => {
    const result = validateSettingsPayload({
      rules: [
        {
          eventNameContains: "X",
          status: "Y",
          emoji: ":x:",
          notifications: "loud",
          priority: 1,
        },
      ],
    });
    expect(result.ok).toBe(false);
    expect(result.fields).toBeDefined();
  });
});
