#!/usr/bin/env node
import { mkdirSync, existsSync, copyFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";
import { fileURLToPath } from "node:url";
import { Command } from "commander";
import {
  fetchLocalCalendarView,
  listLocalCalendars,
  localCalendarStatus,
} from "./calendar/reader.js";
import { loadConfig } from "./config.js";
import { deleteSecret, homeRelative, SECRET_ACCOUNTS } from "./keychain.js";
import { createLogger } from "./logger.js";
import {
  defaultConfigPath,
  defaultDataDir,
  defaultStatePath,
} from "./paths.js";
import { storeSlackToken } from "./slack/client.js";
import { runLoop, syncOnce } from "./sync/runner.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

function resolveConfigPath(explicit?: string): string {
  return resolve(explicit ?? process.env.SLACK_STATUS_SYNC_CONFIG ?? defaultConfigPath());
}

function ensureDataDir(): void {
  mkdirSync(defaultDataDir(), { recursive: true, mode: 0o700 });
}

function getGlobalOpts(command: Command): {
  config?: string;
  verbose?: boolean;
  logFile?: string;
} {
  let current: Command | null = command;
  while (current.parent) {
    current = current.parent;
  }
  return current.opts() as {
    config?: string;
    verbose?: boolean;
    logFile?: string;
  };
}

async function promptHidden(question: string): Promise<string> {
  if (input.isTTY) {
    return await new Promise((resolvePromise, reject) => {
      output.write(question);
      const chunks: Buffer[] = [];
      const wasRaw = input.isRaw;
      input.setRawMode?.(true);
      input.resume();
      const onData = (chunk: Buffer) => {
        const str = chunk.toString("utf8");
        if (str === "\n" || str === "\r" || str === "\u0004") {
          input.setRawMode?.(wasRaw ?? false);
          input.pause();
          input.removeListener("data", onData);
          output.write("\n");
          resolvePromise(Buffer.concat(chunks).toString("utf8").trim());
          return;
        }
        if (str === "\u0003") {
          input.setRawMode?.(wasRaw ?? false);
          input.pause();
          input.removeListener("data", onData);
          reject(new Error("Interrupted"));
          return;
        }
        if (str === "\u007f") {
          chunks.pop();
          return;
        }
        chunks.push(chunk);
      };
      input.on("data", onData);
    });
  }

  const rl = createInterface({ input, output });
  try {
    return (await rl.question(question)).trim();
  } finally {
    rl.close();
  }
}

const program = new Command();

program
  .name("slack-status-sync")
  .description("Sync Slack status and DND from local Calendar.app event titles")
  .option("-c, --config <path>", "Path to config.yaml")
  .option("-v, --verbose", "Debug logging", false)
  .option("--log-file <path>", "Also append logs to a file");

const calendar = program
  .command("calendar")
  .description("Local macOS Calendar (EventKit) helpers");

calendar
  .command("authorize")
  .description("Request Calendar access via the helper .app (shows a small window)")
  .option("--open-settings", "Open System Settings → Calendars", false)
  .action(async (opts: { openSettings?: boolean }, command) => {
    const global = getGlobalOpts(command);
    const logger = createLogger({
      level: global.verbose ? "debug" : "info",
      logFile: global.logFile,

    });
    ensureDataDir();

    const { defaultCalendarAppPath } = await import("./calendar/reader.js");
    const appPath = defaultCalendarAppPath();

    console.log(
      [
        "Opening Slack Status Sync Calendar.app to request access…",
        `App: ${appPath}`,
        "Look for a small window titled “Slack Status Sync — Calendar Access”.",
        "After allowing access, enable Full Access for “Slack Status Sync Calendar” in:",
        "  System Settings → Privacy & Security → Calendars",
        "Important: after every npm run build, you may need to toggle that permission off/on",
        "because the app is ad-hoc signed and macOS ties access to the binary hash.",
      ].join("\n"),
    );

    if (opts.openSettings) {
      const { spawn } = await import("node:child_process");
      spawn("open", ["x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"], {
        detached: true,
        stdio: "ignore",
      }).unref();
    }

    try {
      // Launch as an Application so TCC registers the .app, not the terminal host.
      const { spawn } = await import("node:child_process");
      await new Promise<void>((resolvePromise, reject) => {
        const child = spawn("open", ["-W", "-n", "-a", appPath, "--args", "authorize"], {
          stdio: "inherit",
        });
        child.on("error", reject);
        child.on("close", (code) => {
          if (code === 0) {
            resolvePromise();
          } else {
            reject(new Error(`Helper app exited with code ${code ?? "unknown"}`));
          }
        });
      });

      const result = await localCalendarStatus();
      logger.info("Calendar authorization result", result);
      console.log(
        result.authorized
          ? `Calendar access granted (${result.status})`
          : `Calendar access still not granted (${result.status}). Open System Settings → Privacy & Security → Calendars and enable “Slack Status Sync Calendar”.`,
      );
      if (!result.authorized) {
        process.exitCode = 1;
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(message);
      console.error("Tip: npm run build && npm run calendar:authorize -- --open-settings");
      process.exitCode = 1;
    }
  });

calendar
  .command("status")
  .description("Show current Calendar permission status")
  .action(async () => {
    const { helperAppFingerprint } = await import("./calendar/reader.js");
    const fingerprint = helperAppFingerprint();
    try {
      const result = await localCalendarStatus();
      console.log(JSON.stringify({ ...result, launchedApp: fingerprint.appPath }, null, 2));
      if (!result.authorized) {
        console.error(
          [
            "",
            "Calendar access is not active for the current helper app.",
            "The toggle in System Settings may be for an older build.",
            "Fix:",
            "  1. npm run build",
            "  2. tccutil reset Calendar com.slack-status-sync.calendar-reader",
            "  3. open \"$HOME/Applications/Slack Status Sync Calendar.app\"",
            "  4. Allow Full Access, confirm the window shows a calendar count > 0",
            "  5. npm run calendar:list",
            "Do not rebuild between steps 3 and 5.",
          ].join("\n"),
        );
        process.exitCode = 1;
      }
    } catch (error) {
      console.error(error instanceof Error ? error.message : String(error));
      console.error(`Helper app: ${fingerprint.appPath}`);
      process.exitCode = 1;
    }
  });

calendar
  .command("list")
  .description("List visible calendars and upcoming events")
  .option("--hours <n>", "Look-ahead window in hours", "24")
  .action(async (opts: { hours?: string }, command) => {
    const global = getGlobalOpts(command);
    const logger = createLogger({
      level: global.verbose ? "debug" : "info",
      logFile: global.logFile,

    });
    ensureDataDir();

    const calendars = await listLocalCalendars();
    console.log("Calendars:");
    for (const cal of calendars) {
      console.log(`- ${cal.title} [${cal.type}]${cal.source ? ` (${cal.source})` : ""}`);
    }

    const hours = Number(opts.hours ?? 24);
    const now = new Date();
    const end = new Date(now.getTime() + hours * 60 * 60 * 1000);
    const configPath = resolveConfigPath(global.config);
    const calendarNames = existsSync(configPath)
      ? loadConfig(configPath).calendarNames
      : undefined;

    const events = await fetchLocalCalendarView(now, end, logger, { calendarNames });
    console.log(`\nEvents in next ${hours}h${calendarNames?.length ? " (filtered)" : ""}:`);
    if (events.length === 0) {
      console.log("(none)");
      return;
    }
    for (const event of events) {
      // Titles are shown here intentionally so the user can craft match rules.
      console.log(
        `- ${event.start.toISOString()} → ${event.end.toISOString()} | ${event.calendarName} | ${event.title}`,
      );
    }
  });

program
  .command("auth")
  .description("Authenticate providers")
  .argument("<provider>", "slack")
  .action(async (provider: string, _opts, command) => {
    const global = getGlobalOpts(command);
    const logger = createLogger({
      level: global.verbose ? "debug" : "info",
      logFile: global.logFile,

    });
    ensureDataDir();

    if (provider === "slack") {
      const token =
        process.env.SLACK_USER_TOKEN?.trim() ||
        (await promptHidden("Paste Slack user token (xoxp-...): "));
      await storeSlackToken(token, logger);
      return;
    }
    if (provider === "microsoft") {
      throw new Error(
        "Microsoft Graph auth was removed. Use local Calendar.app instead: slack-status-sync calendar authorize",
      );
    }
    throw new Error(`Unknown provider: ${provider}. Use slack (and calendar authorize for Calendar access).`);
  });

program
  .command("sync")
  .description("Run a single sync iteration")
  .option("--once", "Run once (default)", true)
  .option("--dry-run", "Select an event but do not call Slack", false)
  .action(async (opts: { dryRun?: boolean }, command) => {
    const global = getGlobalOpts(command);
    const logger = createLogger({
      level: global.verbose ? "debug" : "info",
      logFile: global.logFile,

    });
    ensureDataDir();
    const configPath = resolveConfigPath(global.config);
    const config = loadConfig(configPath);
    const result = await syncOnce({
      config,
      logger,
      paths: { statePath: defaultStatePath() },
      dryRun: Boolean(opts.dryRun),
    });
    console.log(JSON.stringify(result));
  });

program
  .command("run")
  .description("Run the continuous polling loop")
  .action(async (_opts, command) => {
    const global = getGlobalOpts(command);
    const logger = createLogger({
      level: global.verbose ? "debug" : "info",
      logFile: global.logFile,

    });
    ensureDataDir();
    const configPath = resolveConfigPath(global.config);
    const config = loadConfig(configPath);

    const controller = new AbortController();
    const stop = () => controller.abort();
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);

    await runLoop({
      config,
      logger,
      paths: { statePath: defaultStatePath() },
      signal: controller.signal,
    });
  });

program
  .command("init")
  .description("Create ~/.slack-status-sync and copy example config")
  .action(() => {
    ensureDataDir();
    const target = defaultConfigPath();
    if (existsSync(target)) {
      console.log(`Config already exists at ${homeRelative(target)}`);
      return;
    }
    const example = resolve(__dirname, "../config.example.yaml");
    const repoExample = resolve(process.cwd(), "config.example.yaml");
    const source = existsSync(example) ? example : repoExample;
    if (!existsSync(source)) {
      throw new Error("Could not find config.example.yaml");
    }
    copyFileSync(source, target);
    console.log(`Wrote ${homeRelative(target)}`);
    console.log(
      "Edit the file, then run: slack-status-sync calendar authorize && slack-status-sync auth slack",
    );
  });

program
  .command("logout")
  .description("Remove stored credentials")
  .argument("[provider]", "slack | all", "all")
  .action((provider: string) => {
    if (provider === "microsoft") {
      console.log("Microsoft credentials are no longer used.");
      return;
    }
    if (provider === "slack" || provider === "all") {
      deleteSecret(SECRET_ACCOUNTS.slackToken);
      console.log("Removed Slack token");
    }
  });

program.parseAsync(process.argv).catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(message);
  process.exitCode = 1;
});
