import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { defaultConfig } from "../src/config.js";

const tempHomes: string[] = [];

afterEach(() => {
  for (const dir of tempHomes) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempHomes.length = 0;
});

async function runSidecar(lines: string[], expectedResponses: number): Promise<Record<string, unknown>[]> {
  const home = mkdtempSync(join(tmpdir(), "sss-sidecar-home-"));
  tempHomes.push(home);

  const child = spawn(resolve("node_modules/.bin/tsx"), ["src/sidecar.ts"], {
    cwd: resolve("."),
    env: { ...process.env, HOME: home },
    stdio: ["pipe", "pipe", "pipe"],
  });

  const responses: Record<string, unknown>[] = [];
  let buffer = "";

  const completed = new Promise<Record<string, unknown>[]>((resolvePromise, reject) => {
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`Timed out waiting for ${expectedResponses} sidecar responses`));
    }, 15_000);

    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });

    child.stdout.on("data", (chunk: Buffer) => {
      buffer += chunk.toString("utf8");
      while (buffer.includes("\n")) {
        const newline = buffer.indexOf("\n");
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (line) {
          responses.push(JSON.parse(line) as Record<string, unknown>);
        }
      }
      if (responses.length >= expectedResponses) {
        clearTimeout(timer);
        resolvePromise(responses);
      }
    });
  });

  for (const line of lines) {
    child.stdin.write(`${line}\n`);
  }

  const result = await completed;
  child.stdin.end();
  child.kill("SIGTERM");
  return result;
}

describe("sidecar NDJSON protocol", () => {
  it("survives malformed JSON and correlates queued responses", async () => {
    const responses = await runSidecar(
      [
        "{not-json",
        JSON.stringify({ v: 1, id: "first", method: "ping" }),
        JSON.stringify({ v: 1, id: "second", method: "ping" }),
      ],
      3,
    );

    expect(responses[0]).toMatchObject({
      id: "unknown",
      ok: false,
      error: { code: "invalid_json" },
    });
    expect(responses[1]).toMatchObject({ id: "first", ok: true, result: { pong: true } });
    expect(responses[2]).toMatchObject({ id: "second", ok: true, result: { pong: true } });
  });

  it("returns sync telemetry for an injected dry-run event", async () => {
    const settings = defaultConfig();
    const responses = await runSidecar(
      [
        JSON.stringify({
          v: 1,
          id: "sync",
          method: "sync",
          params: {
            settings,
            slackToken: "xoxp-test-token",
            dryRun: true,
            now: "2026-07-20T12:00:00.000Z",
            events: [
              {
                id: "event-1",
                iCalUId: "event-1",
                changeKey: null,
                title: "Deep Focus",
                start: "2026-07-20T11:30:00.000Z",
                end: "2026-07-20T13:00:00.000Z",
                isAllDay: false,
                isCancelled: false,
                response: "accepted",
                showAs: "busy",
                calendarName: "Work",
                calendarId: "work",
              },
            ],
          },
        }),
      ],
      1,
    );

    expect(responses[0]).toMatchObject({
      id: "sync",
      ok: true,
      result: {
        applied: false,
        reason: "dry_run:startup_active",
        eventId: "event-1",
        rule: "Focus",
        lastPollAt: "2026-07-20T12:00:00.000Z",
      },
    });
  });
});
