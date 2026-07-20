import { fetchLocalCalendarView } from "../calendar/reader.js";
import type { AppConfig } from "../config.js";
import type { Logger } from "../logger.js";
import { withRetry } from "../retry.js";
import { SlackClient } from "../slack/client.js";
import { loadState, saveState, type SyncState } from "../state.js";
import { applyDecision, selectEventToApply } from "./engine.js";

export interface SyncPaths {
  statePath: string;
}

export interface SyncOnceOptions {
  config: AppConfig;
  logger: Logger;
  paths: SyncPaths;
  dryRun?: boolean;
  now?: Date;
  helperPath?: string;
}

export async function syncOnce(options: SyncOnceOptions): Promise<{
  applied: boolean;
  reason: string;
  eventId?: string;
  rule?: string;
}> {
  const now = options.now ?? new Date();
  const state = loadState(options.paths.statePath);
  const previousPollAt = state.lastPollAt ? new Date(state.lastPollAt) : null;

  const lookBehindMs = options.config.lookBehindMinutes * 60_000;
  const lookAheadMs = options.config.lookAheadMinutes * 60_000;
  const windowStart = new Date(now.getTime() - lookBehindMs);
  const windowEnd = new Date(now.getTime() + lookAheadMs);

  const events = await withRetry(
    () =>
      fetchLocalCalendarView(windowStart, windowEnd, options.logger, {
        helperPath: options.helperPath,
        calendarNames: options.config.calendarNames,
      }),
    {
      onRetry: (error, attempt, delayMs) => {
        options.logger.warn("Retrying calendar fetch", {
          attempt,
          delayMs,
          error: error instanceof Error ? error.message : String(error),
        });
      },
    },
  );

  const decision = selectEventToApply(
    events,
    options.config,
    state,
    now,
    previousPollAt,
  );

  if (decision.action !== "apply" || !decision.selected) {
    const next: SyncState = {
      ...state,
      lastPollAt: now.toISOString(),
    };
    saveState(options.paths.statePath, next);
    options.logger.info("Sync poll complete", { applied: false, reason: decision.reason });
    return { applied: false, reason: decision.reason };
  }

  if (options.dryRun) {
    options.logger.info("Dry-run: would apply Slack update", {
      eventId: decision.selected.event.id,
      rule: decision.selected.rule.eventNameContains,
      status: decision.selected.rule.status,
      emoji: decision.selected.rule.emoji,
      notifications: decision.selected.rule.notifications,
      reason: decision.reason,
      calendarName: decision.selected.event.calendarName,
    });
    const next: SyncState = {
      ...state,
      lastPollAt: now.toISOString(),
    };
    saveState(options.paths.statePath, next);
    return {
      applied: false,
      reason: `dry_run:${decision.reason}`,
      eventId: decision.selected.event.id,
      rule: decision.selected.rule.eventNameContains,
    };
  }

  const slack = SlackClient.fromKeychain(options.logger);
  const { result, nextStatePatch } = await applyDecision(
    decision,
    slack,
    options.logger,
    now,
  );

  const next: SyncState = {
    ...state,
    ...nextStatePatch,
  };
  saveState(options.paths.statePath, next);
  return result;
}

export interface RunLoopOptions extends SyncOnceOptions {
  signal?: AbortSignal;
}

export async function runLoop(options: RunLoopOptions): Promise<void> {
  const intervalMs = options.config.pollIntervalSeconds * 1000;
  options.logger.info("Starting sync loop", {
    pollIntervalSeconds: options.config.pollIntervalSeconds,
  });

  while (!options.signal?.aborted) {
    try {
      await syncOnce(options);
    } catch (error) {
      options.logger.error("Sync iteration failed", {
        error: error instanceof Error ? error.message : String(error),
      });
    }

    await wait(intervalMs, options.signal);
  }

  options.logger.info("Sync loop stopped");
}

function wait(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal?.aborted) {
      resolve();
      return;
    }
    const timer = setTimeout(() => {
      cleanup();
      resolve();
    }, ms);
    const onAbort = () => {
      cleanup();
      resolve();
    };
    const cleanup = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}
