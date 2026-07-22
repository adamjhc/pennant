import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CalendarEvent } from "../src/calendar/types.js";
import { defaultConfig } from "../src/config.js";
import { createLogger } from "../src/logger.js";
import { syncOnce } from "../src/sync/runner.js";

describe("syncOnce with injected events", () => {
  const dirs: string[] = [];

  afterEach(() => {
    for (const dir of dirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    dirs.length = 0;
  });

  it("skips when no mapped events and records lastPollAt", async () => {
    const dir = mkdtempSync(join(tmpdir(), "sss-sync-"));
    dirs.push(dir);
    const statePath = join(dir, "state.json");

    const result = await syncOnce({
      config: defaultConfig(),
      events: [],
      slackToken: "xoxp-test",
      logger: createLogger({ level: "error" }),
      paths: { statePath },
      now: new Date("2026-07-20T12:00:00Z"),
    });

    expect(result.applied).toBe(false);
    expect(result.reason).toBe("no_mapped_events");
    expect(result.lastPollAt).toBe("2026-07-20T12:00:00.000Z");
    const state = JSON.parse(readFileSync(statePath, "utf8")) as { lastPollAt: string };
    expect(state.lastPollAt).toBe("2026-07-20T12:00:00.000Z");
  });

  it("dry-run selects a matching active event without calling Slack", async () => {
    const dir = mkdtempSync(join(tmpdir(), "sss-sync-"));
    dirs.push(dir);

    const events: CalendarEvent[] = [
      {
        id: "e1",
        iCalUId: "ical",
        changeKey: null,
        title: "Deep Focus",
        start: new Date("2026-07-20T11:00:00Z"),
        end: new Date("2026-07-20T13:00:00Z"),
        isAllDay: false,
        isCancelled: false,
        response: "accepted",
        showAs: "busy",
        calendarName: "Work",
        calendarId: "c",
      },
    ];

    const result = await syncOnce({
      config: defaultConfig(),
      events,
      slackToken: "xoxp-test",
      logger: createLogger({ level: "error" }),
      paths: { statePath: join(dir, "state.json") },
      dryRun: true,
      now: new Date("2026-07-20T12:00:00Z"),
    });

    expect(result.applied).toBe(false);
    expect(result.reason).toContain("dry_run");
    expect(result.rule).toBe("Focus");
  });
});

describe("logger token redaction", () => {
  it("redacts slack tokens in structured logs", () => {
    const chunks: string[] = [];
    const originalWrite = process.stdout.write.bind(process.stdout);
    process.stdout.write = ((chunk: string | Uint8Array) => {
      chunks.push(typeof chunk === "string" ? chunk : Buffer.from(chunk).toString("utf8"));
      return true;
    }) as typeof process.stdout.write;

    try {
      const logger = createLogger({ level: "info", json: true });
      logger.info("auth", { token: "xoxp-secret-value-abcdef", slackToken: "xoxp-another" });
    } finally {
      process.stdout.write = originalWrite;
    }

    const line = chunks.join("");
    expect(line).not.toContain("xoxp-secret");
    expect(line).toContain("[redacted]");
  });
});

// Silence unused import warning in case vitest tree-shakes differently.
void vi;
