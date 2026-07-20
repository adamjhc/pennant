import { readFileSync } from "node:fs";
import { parse as parseYaml } from "yaml";
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
  timezone: z.string().default("UTC"),
  /** Optional allowlist of Calendar.app calendar titles. Empty/omitted = all calendars. */
  calendarNames: z.array(z.string().min(1)).optional(),
  rules: z.array(TitleRuleSchema).min(1),
});

export type TitleRule = z.infer<typeof TitleRuleSchema>;
export type AppConfig = z.infer<typeof ConfigSchema>;

export function loadConfig(path: string): AppConfig {
  const raw = readFileSync(path, "utf8");
  const parsed = parseYaml(raw);
  return ConfigSchema.parse(parsed);
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
