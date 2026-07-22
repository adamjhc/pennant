import { z } from "zod";

export const TitleRuleSchema = z.object({
  eventNameContains: z.string().min(1),
  status: z.string().min(1),
  emoji: z.string().min(1),
  notifications: z.enum(["snooze", "normal"]),
  priority: z.number().int(),
});

export const ConfigSchema = z.object({
  pollIntervalSeconds: z.number().int().positive().default(30),
  lookAheadMinutes: z.number().int().positive().default(15),
  lookBehindMinutes: z.number().int().nonnegative().default(5),
  /** Calendar title allowlist. Omitted = all calendars; empty = calendar sync disabled. */
  calendarNames: z.array(z.string().min(1)).optional(),
  rules: z.array(TitleRuleSchema).min(1),
});

export type TitleRule = z.infer<typeof TitleRuleSchema>;
export type AppConfig = z.infer<typeof ConfigSchema>;

export const EXAMPLE_RULES: TitleRule[] = [
  {
    eventNameContains: "Focus",
    status: "Focusing",
    emoji: ":dart:",
    notifications: "snooze",
    priority: 10,
  },
  {
    eventNameContains: "1:1",
    status: "In a 1:1",
    emoji: ":speech_balloon:",
    notifications: "snooze",
    priority: 20,
  },
  {
    eventNameContains: "Standup",
    status: "In standup",
    emoji: ":calendar:",
    notifications: "snooze",
    priority: 30,
  },
];

export function defaultConfig(): AppConfig {
  return ConfigSchema.parse({ rules: EXAMPLE_RULES });
}

/**
 * Assign deterministic priorities from drag order (first = highest priority).
 * Priorities are 10, 20, 30, …
 */
export function assignPrioritiesFromOrder(
  rules: Array<Omit<TitleRule, "priority"> & { priority?: number }>,
): TitleRule[] {
  return rules.map((rule, index) => ({
    eventNameContains: rule.eventNameContains,
    status: rule.status,
    emoji: rule.emoji,
    notifications: rule.notifications,
    priority: (index + 1) * 10,
  }));
}

export function titleMatchesRule(title: string, rule: TitleRule): boolean {
  const haystack = title.trim().toLowerCase();
  const needle = rule.eventNameContains.trim().toLowerCase();
  if (!needle) {
    return false;
  }
  return haystack.includes(needle);
}

export function findMatchingRules(title: string, rules: TitleRule[]): TitleRule[] {
  return rules.filter((rule) => titleMatchesRule(title, rule));
}

export function pickHighestPriorityRule(rules: TitleRule[]): TitleRule | undefined {
  if (rules.length === 0) {
    return undefined;
  }
  return [...rules].sort((a, b) => {
    if (a.priority !== b.priority) {
      return a.priority - b.priority;
    }
    return a.eventNameContains.localeCompare(b.eventNameContains);
  })[0];
}

export function filterByCalendarNames<T extends { calendarName: string }>(
  events: T[],
  calendarNames: string[] | undefined,
): T[] {
  if (calendarNames === undefined) {
    return events;
  }
  if (calendarNames.length === 0) {
    return [];
  }
  const allowed = new Set(calendarNames.map((name) => name.toLowerCase()));
  return events.filter((event) => allowed.has(event.calendarName.toLowerCase()));
}
