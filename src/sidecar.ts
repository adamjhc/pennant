import { createInterface } from "node:readline";
import { mkdirSync } from "node:fs";
import { mapWireEvent } from "./calendar/map-event.js";
import { createLogger } from "./logger.js";
import { defaultDataDir, defaultLogPath, defaultStatePath } from "./paths.js";
import {
  PROTOCOL_VERSION,
  RequestSchema,
  SettingsValidateParamsSchema,
  SyncParamsSchema,
  TokenValidateParamsSchema,
  type SidecarResponse,
} from "./protocol.js";
import {
  loadSettingsOrDefault,
  validateSettingsPayload,
  validateSlackToken,
} from "./settings-service.js";
import { loadState } from "./state.js";
import { syncOnce } from "./sync/runner.js";

mkdirSync(defaultDataDir(), { recursive: true, mode: 0o700 });

const logger = createLogger({
  level: (process.env.SLACK_STATUS_SYNC_LOG_LEVEL as "debug" | "info" | "warn" | "error") ?? "info",
  logFile: defaultLogPath(),
  json: true,
  // stdout is reserved for the NDJSON protocol.
  stdoutAsStderr: true,
});
const MAX_REQUEST_BYTES = 8 * 1024 * 1024;

function safeMessage(error: unknown, fallback = "The request failed"): string {
  const raw = error instanceof Error ? error.message : String(error);
  const redacted = raw
    .replace(/xox(?:p|b|e)[A-Za-z0-9._-]*/gi, "[redacted]")
    .replace(/[A-Za-z0-9._-]{40,}/g, "[redacted]");
  return redacted.length <= 500 ? redacted : fallback;
}

function respond(response: SidecarResponse): void {
  process.stdout.write(`${JSON.stringify(response)}\n`);
}

function fail(
  id: string,
  code: string,
  message: string,
  fields?: Record<string, string>,
): void {
  respond({
    v: PROTOCOL_VERSION,
    id,
    ok: false,
    error: { code, message, fields },
  });
}

function ok(id: string, result: unknown): void {
  respond({ v: PROTOCOL_VERSION, id, ok: true, result });
}

async function handleRequest(raw: unknown): Promise<void> {
  const parsed = RequestSchema.safeParse(raw);
  if (!parsed.success) {
    const id =
      raw && typeof raw === "object" && "id" in raw && typeof (raw as { id: unknown }).id === "string"
        ? (raw as { id: string }).id
        : "unknown";
    fail(id, "invalid_request", "Malformed sidecar request", {
      details: parsed.error.message,
    });
    return;
  }

  const { id, method, params } = parsed.data;

  try {
    switch (method) {
      case "ping":
        ok(id, { pong: true });
        return;

      case "settings.get": {
        const settings = loadSettingsOrDefault();
        const state = loadState(defaultStatePath());
        ok(id, {
          settings,
          lastPollAt: state.lastPollAt,
          lastSlackUpdateAt: state.lastAppliedAt,
        });
        return;
      }

      case "settings.validate": {
        const body = SettingsValidateParamsSchema.parse(params ?? {});
        const validated = validateSettingsPayload(body.settings);
        if (!validated.ok) {
          fail(id, "validation_failed", validated.message ?? "Invalid settings", validated.fields);
          return;
        }
        if (body.slackToken) {
          const tokenCheck = await validateSlackToken(body.slackToken, logger);
          if (!tokenCheck.ok) {
            fail(id, "token_invalid", tokenCheck.message, { slackToken: tokenCheck.message });
            return;
          }
        }
        ok(id, { settings: validated.settings });
        return;
      }

      case "token.validate": {
        const body = TokenValidateParamsSchema.parse(params ?? {});
        const tokenCheck = await validateSlackToken(body.slackToken, logger);
        if (!tokenCheck.ok) {
          fail(id, "token_invalid", tokenCheck.message, { slackToken: tokenCheck.message });
          return;
        }
        ok(id, { userId: tokenCheck.userId, team: tokenCheck.team });
        return;
      }

      case "sync": {
        const body = SyncParamsSchema.parse(params ?? {});
        const now = body.now ? new Date(body.now) : new Date();
        const events = body.events.map(mapWireEvent);
        const result = await syncOnce({
          config: body.settings,
          events,
          slackToken: body.slackToken,
          logger,
          paths: { statePath: defaultStatePath() },
          dryRun: body.dryRun,
          now,
        });
        ok(id, {
          applied: result.applied,
          reason: result.reason,
          eventId: result.eventId,
          rule: result.rule,
          lastPollAt: result.lastPollAt,
          lastSlackUpdateAt: result.lastSlackUpdateAt,
        });
        return;
      }

      case "shutdown":
        ok(id, { shuttingDown: true });
        // Allow the response to flush before exiting.
        setImmediate(() => process.exit(0));
        return;

      default:
        fail(id, "unknown_method", `Unknown method: ${method}`);
    }
  } catch (error) {
    const message = safeMessage(error);
    logger.error("Sidecar request failed", { method, error: message });
    fail(id, "runtime_error", message);
  }
}

function main(): void {
  logger.info("Sidecar started");

  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });

  let requestQueue = Promise.resolve();

  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) {
      return;
    }
    if (Buffer.byteLength(trimmed, "utf8") > MAX_REQUEST_BYTES) {
      fail("unknown", "request_too_large", "Request exceeds the 8 MB limit");
      return;
    }
    let raw: unknown;
    try {
      raw = JSON.parse(trimmed);
    } catch {
      fail("unknown", "invalid_json", "Request line is not valid JSON");
      return;
    }
    requestQueue = requestQueue
      .then(() => handleRequest(raw))
      .catch((error) => {
        logger.error("Sidecar request queue failed", { error: safeMessage(error) });
      });
  });

  rl.on("close", () => {
    logger.info("Sidecar stdin closed");
    process.exit(0);
  });

  process.on("SIGTERM", () => process.exit(0));
  process.on("SIGINT", () => process.exit(0));
}

main();
