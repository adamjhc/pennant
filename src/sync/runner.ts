import type { CalendarEvent } from "../calendar/types.js";
import { filterByCalendarNames, type AppConfig } from "../config.js";
import type { Logger } from "../logger.js";
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
  /** Pre-fetched calendar events from the native host. */
  events: CalendarEvent[];
  /** Slack user token from Keychain (passed by host). */
  slackToken: string;
  dryRun?: boolean;
  now?: Date;
}

export async function syncOnce(options: SyncOnceOptions): Promise<{
  applied: boolean;
  reason: string;
  eventId?: string;
  rule?: string;
  lastPollAt: string;
  lastSlackUpdateAt: string | null;
}> {
  const now = options.now ?? new Date();
  const state = loadState(options.paths.statePath);
  const previousPollAt = state.lastPollAt ? new Date(state.lastPollAt) : null;

  const events = filterByCalendarNames(options.events, options.config.calendarNames);

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
    return {
      applied: false,
      reason: decision.reason,
      lastPollAt: next.lastPollAt ?? now.toISOString(),
      lastSlackUpdateAt: state.lastAppliedAt,
    };
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
      lastPollAt: next.lastPollAt ?? now.toISOString(),
      lastSlackUpdateAt: state.lastAppliedAt,
    };
  }

  const slack = new SlackClient(options.slackToken, options.logger);
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
  return {
    ...result,
    lastPollAt: next.lastPollAt ?? now.toISOString(),
    lastSlackUpdateAt: next.lastAppliedAt,
  };
}
