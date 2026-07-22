import { existsSync, readFileSync } from "node:fs";
import {
  assignPrioritiesFromOrder,
  ConfigSchema,
  defaultConfig,
  type AppConfig,
} from "./config.js";
import type { Logger } from "./logger.js";
import { defaultSettingsPath } from "./paths.js";
import { SlackClient } from "./slack/client.js";

export function loadSettings(path: string = defaultSettingsPath()): AppConfig | null {
  if (!existsSync(path)) {
    return null;
  }
  const raw = JSON.parse(readFileSync(path, "utf8")) as unknown;
  return ConfigSchema.parse(raw);
}

export function loadSettingsOrDefault(path: string = defaultSettingsPath()): AppConfig {
  return loadSettings(path) ?? defaultConfig();
}

export interface ValidateSettingsResult {
  ok: boolean;
  settings?: AppConfig;
  fields?: Record<string, string>;
  message?: string;
}

export function validateSettingsPayload(raw: unknown): ValidateSettingsResult {
  const parsed = ConfigSchema.safeParse(raw);
  if (!parsed.success) {
    const fields: Record<string, string> = {};
    for (const issue of parsed.error.issues) {
      const key = issue.path.join(".") || "settings";
      if (!fields[key]) {
        fields[key] = issue.message;
      }
    }
    return { ok: false, fields, message: "Invalid settings" };
  }

  const withOrder = {
    ...parsed.data,
    rules: assignPrioritiesFromOrder(parsed.data.rules),
  };

  return { ok: true, settings: withOrder };
}

export async function validateSlackToken(
  token: string,
  logger: Logger,
): Promise<{ ok: true; userId: string; team?: string } | { ok: false; message: string }> {
  const trimmed = token.trim();
  if (!trimmed.startsWith("xoxp-") && !trimmed.startsWith("xoxe.xoxp-")) {
    return { ok: false, message: "Expected a Slack user token (xoxp-...)" };
  }
  try {
    const client = new SlackClient(trimmed, logger);
    const identity = await client.validate();
    return { ok: true, userId: identity.userId, team: identity.team };
  } catch (error) {
    const raw = error instanceof Error ? error.message : String(error);
    return {
      ok: false,
      message: raw
        .replace(/xox(?:p|b|e)[A-Za-z0-9._-]*/gi, "[redacted]")
        .replace(/[A-Za-z0-9._-]{40,}/g, "[redacted]")
        .slice(0, 500),
    };
  }
}
