import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { APP_NAME, defaultDataDir } from "./paths.js";

const SERVICE = APP_NAME;

function isMac(): boolean {
  return process.platform === "darwin";
}

function fallbackPath(account: string): string {
  return join(defaultDataDir(), "secrets", `${account}.txt`);
}

export function setSecret(account: string, secret: string): void {
  if (isMac()) {
    try {
      // Delete any existing item first to avoid interactive update prompts.
      try {
        execFileSync(
          "security",
          ["delete-generic-password", "-s", SERVICE, "-a", account],
          { stdio: "ignore" },
        );
      } catch {
        // Item may not exist.
      }
      execFileSync(
        "security",
        [
          "add-generic-password",
          "-U",
          "-s",
          SERVICE,
          "-a",
          account,
          "-w",
          secret,
          "-T",
          "",
        ],
        { stdio: "ignore" },
      );
      return;
    } catch {
      // Fall through to file-based storage.
    }
  }

  const path = fallbackPath(account);
  mkdirSync(join(defaultDataDir(), "secrets"), { recursive: true, mode: 0o700 });
  writeFileSync(path, secret, { encoding: "utf8", mode: 0o600 });
}

export function getSecret(account: string): string | null {
  if (isMac()) {
    try {
      const value = execFileSync(
        "security",
        ["find-generic-password", "-s", SERVICE, "-a", account, "-w"],
        { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
      ).trim();
      return value.length > 0 ? value : null;
    } catch {
      // Fall through.
    }
  }

  const path = fallbackPath(account);
  if (!existsSync(path)) {
    return null;
  }
  return readFileSync(path, "utf8").trim() || null;
}

export function deleteSecret(account: string): void {
  if (isMac()) {
    try {
      execFileSync(
        "security",
        ["delete-generic-password", "-s", SERVICE, "-a", account],
        { stdio: "ignore" },
      );
    } catch {
      // Ignore missing item.
    }
  }

  const path = fallbackPath(account);
  if (existsSync(path)) {
    unlinkSync(path);
  }
}

export const SECRET_ACCOUNTS = {
  slackToken: "slack-user-token",
} as const;

export function homeRelative(path: string): string {
  const home = homedir();
  return path.startsWith(home) ? `~${path.slice(home.length)}` : path;
}
