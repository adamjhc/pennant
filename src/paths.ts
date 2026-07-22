import { homedir } from "node:os";
import { join } from "node:path";

export const APP_NAME = "Slack Status Sync";
export const APP_BUNDLE_ID = "com.slack-status-sync.app";

export function defaultDataDir(): string {
  return join(homedir(), "Library", "Application Support", APP_NAME);
}

export function defaultSettingsPath(): string {
  return join(defaultDataDir(), "settings.json");
}

export function defaultStatePath(): string {
  return join(defaultDataDir(), "state.json");
}

export function defaultLogPath(): string {
  return join(defaultDataDir(), "sync.log");
}
