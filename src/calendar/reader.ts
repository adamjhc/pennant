import { spawn } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import type { Logger } from "../logger.js";
import type { CalendarEvent, LocalCalendar } from "./types.js";

const EventPayloadSchema = z.object({
  events: z.array(
    z.object({
      id: z.string(),
      eventIdentifier: z.string(),
      calendarItemExternalIdentifier: z.string().nullable().optional(),
      title: z.string(),
      start: z.string(),
      end: z.string(),
      isAllDay: z.boolean(),
      isCancelled: z.boolean(),
      response: z.string(),
      availability: z.string(),
      calendarName: z.string(),
      calendarId: z.string(),
    }),
  ),
});

const CalendarsPayloadSchema = z.object({
  calendars: z.array(
    z.object({
      id: z.string(),
      title: z.string(),
      source: z.string().nullable().optional(),
      type: z.string(),
    }),
  ),
});

const StatusPayloadSchema = z.object({
  authorized: z.boolean(),
  status: z.string(),
  bundleId: z.string().optional(),
  appPath: z.string().optional(),
  calendarCount: z.number().nullable().optional(),
});

const ErrorPayloadSchema = z.object({
  error: z.string(),
  code: z.string(),
  bundleId: z.string().optional(),
});

export class CalendarReaderError extends Error {
  readonly code: string;
  readonly exitCode: number | null;

  constructor(message: string, code: string, exitCode: number | null = null) {
    super(message);
    this.name = "CalendarReaderError";
    this.code = code;
    this.exitCode = exitCode;
  }
}

const APP_NAME = "Slack Status Sync Calendar.app";

/** Prefer a stable ~/Applications install so TCC grants survive dist/ rebuilds. */
export function defaultCalendarAppPath(): string {
  const homeApp = resolve(process.env.HOME ?? "", "Applications", APP_NAME);
  if (existsSync(homeApp)) {
    return homeApp;
  }

  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [
    resolve(here, `../../dist/${APP_NAME}`),
    resolve(here, `../${APP_NAME}`),
    resolve(process.cwd(), `dist/${APP_NAME}`),
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  return candidates[0];
}

export function defaultHelperPath(): string {
  return join(defaultCalendarAppPath(), "Contents/MacOS/calendar-reader");
}

export interface HelperRunResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

async function waitForOutputFile(
  outFile: string,
  timeoutMs: number,
): Promise<string> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    if (existsSync(outFile)) {
      const raw = readFileSync(outFile, "utf8").trim();
      if (raw.length > 0) {
        return raw;
      }
    }
    await sleep(150);
  }
  throw new CalendarReaderError(
    "Timed out waiting for calendar helper app output. Re-run calendar authorize for ~/Applications/Slack Status Sync Calendar.app and ensure Full Access is enabled.",
    "helper_timeout",
  );
}

/**
 * Run EventKit commands via LaunchServices (`open -a`) so macOS attributes
 * Calendar TCC to the helper .app, not to Node/Cursor/Terminal.
 */
export async function runCalendarHelper(
  args: string[],
  _helperPath?: string,
  options: { forwardStderr?: boolean; timeoutMs?: number } = {},
): Promise<HelperRunResult> {
  const appPath = defaultCalendarAppPath();
  if (!existsSync(appPath)) {
    throw new CalendarReaderError(
      `Calendar helper app not found at ${appPath}. Run npm run build.`,
      "helper_missing",
    );
  }

  const dir = mkdtempSync(join(tmpdir(), "slack-status-sync-"));
  const outFile = join(dir, "out.json");
  writeFileSync(outFile, "", "utf8");

  // Do not use `open -W`: it is unreliable for short-lived helper invocations.
  const openArgs = ["-n", "-a", appPath, "--args", ...args, "--output", outFile];
  const timeoutMs = options.timeoutMs ?? (args[0] === "authorize" ? 300_000 : 30_000);

  try {
    await new Promise<void>((resolvePromise, reject) => {
      const child = spawn("open", openArgs, {
        stdio: ["ignore", "pipe", "pipe"],
      });
      let stderr = "";
      child.stderr.on("data", (chunk: Buffer) => {
        const text = chunk.toString("utf8");
        stderr += text;
        if (options.forwardStderr) {
          process.stderr.write(text);
        }
      });
      child.on("error", (error) => {
        reject(
          new CalendarReaderError(
            `Failed to launch calendar helper app: ${error.message}`,
            "helper_spawn_failed",
          ),
        );
      });
      child.on("close", (code) => {
        if (code === 0) {
          resolvePromise();
        } else {
          reject(
            new CalendarReaderError(
              stderr || `open exited with code ${code ?? "unknown"}`,
              "helper_open_failed",
              code,
            ),
          );
        }
      });
    });

    const raw = await waitForOutputFile(outFile, timeoutMs);

    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      throw new CalendarReaderError(
        `Calendar helper returned invalid JSON: ${raw.slice(0, 200)}`,
        "helper_invalid_json",
      );
    }

    const maybeError = ErrorPayloadSchema.safeParse(parsed);
    if (maybeError.success && maybeError.data.code) {
      return {
        stdout: raw,
        stderr: "",
        exitCode: maybeError.data.code === "permission_denied" ? 3 : 1,
      };
    }

    return {
      stdout: raw,
      stderr: "",
      exitCode: 0,
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function parseHelperJson<T>(result: HelperRunResult, schema: z.ZodType<T>): T {
  if (!result.stdout) {
    throw new CalendarReaderError(
      result.stderr || "Calendar helper returned no output",
      "helper_empty",
      result.exitCode,
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    throw new CalendarReaderError(
      `Calendar helper returned invalid JSON: ${result.stdout.slice(0, 200)}`,
      "helper_invalid_json",
      result.exitCode,
    );
  }

  if (result.exitCode !== 0) {
    const err = ErrorPayloadSchema.safeParse(parsed);
    if (err.success) {
      throw new CalendarReaderError(err.data.error, err.data.code, result.exitCode);
    }
    throw new CalendarReaderError(
      result.stderr || `Calendar helper exited with code ${result.exitCode}`,
      "helper_failed",
      result.exitCode,
    );
  }

  return schema.parse(parsed);
}

export function mapHelperEvent(
  raw: z.infer<typeof EventPayloadSchema>["events"][number],
): CalendarEvent {
  return {
    id: raw.eventIdentifier || raw.id,
    iCalUId: raw.calendarItemExternalIdentifier ?? raw.eventIdentifier ?? raw.id,
    changeKey: null,
    title: raw.title,
    start: new Date(raw.start),
    end: new Date(raw.end),
    isAllDay: raw.isAllDay,
    isCancelled: raw.isCancelled,
    response: raw.response,
    showAs: raw.availability,
    calendarName: raw.calendarName,
    calendarId: raw.calendarId,
  };
}

export function filterByCalendarNames(
  events: CalendarEvent[],
  calendarNames: string[] | undefined,
): CalendarEvent[] {
  if (!calendarNames || calendarNames.length === 0) {
    return events;
  }
  const allowed = new Set(calendarNames.map((name) => name.toLowerCase()));
  return events.filter((event) => allowed.has(event.calendarName.toLowerCase()));
}

export async function fetchLocalCalendarView(
  start: Date,
  end: Date,
  logger: Logger,
  options: {
    helperPath?: string;
    calendarNames?: string[];
  } = {},
): Promise<CalendarEvent[]> {
  const result = await runCalendarHelper(
    ["events", "--start", start.toISOString(), "--end", end.toISOString()],
    options.helperPath,
  );
  const payload = parseHelperJson(result, EventPayloadSchema);
  const events = filterByCalendarNames(
    payload.events.map(mapHelperEvent),
    options.calendarNames,
  );

  logger.debug("Fetched local calendar view", {
    count: events.length,
    start: start.toISOString(),
    end: end.toISOString(),
    calendarFilter: options.calendarNames ?? null,
  });

  return events;
}

export async function listLocalCalendars(
  helperPath?: string,
): Promise<LocalCalendar[]> {
  const result = await runCalendarHelper(["calendars"], helperPath);
  const payload = parseHelperJson(result, CalendarsPayloadSchema);
  return payload.calendars.map((calendar) => ({
    id: calendar.id,
    title: calendar.title,
    source: calendar.source ?? null,
    type: calendar.type,
  }));
}

export async function authorizeLocalCalendar(
  helperPath?: string,
): Promise<{ authorized: boolean; status: string }> {
  const result = await runCalendarHelper(["authorize"], helperPath, {
    forwardStderr: true,
    timeoutMs: 300_000,
  });
  return parseHelperJson(result, StatusPayloadSchema);
}

export async function localCalendarStatus(
  helperPath?: string,
): Promise<{ authorized: boolean; status: string; appPath?: string; calendarCount?: number | null }> {
  const result = await runCalendarHelper(["status"], helperPath);
  return parseHelperJson(result, StatusPayloadSchema);
}

export function helperAppFingerprint(): { appPath: string; mtimeMs: number | null } {
  const appPath = defaultCalendarAppPath();
  try {
    return { appPath, mtimeMs: statSync(appPath).mtimeMs };
  } catch {
    return { appPath, mtimeMs: null };
  }
}
