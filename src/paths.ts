import { homedir } from "node:os";
import { join } from "node:path";

export const APP_NAME = "slack-status-sync";

export function defaultDataDir(): string {
  return join(homedir(), `.${APP_NAME}`);
}

export function defaultConfigPath(): string {
  return join(defaultDataDir(), "config.yaml");
}

export function defaultStatePath(): string {
  return join(defaultDataDir(), "state.json");
}

export function defaultLogPath(): string {
  return join(defaultDataDir(), "sync.log");
}
