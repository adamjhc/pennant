import { z } from "zod";
import { ConfigSchema, TitleRuleSchema } from "./config.js";

export const PROTOCOL_VERSION = 1 as const;

export const CalendarEventWireSchema = z.object({
  id: z.string(),
  iCalUId: z.string().nullable(),
  changeKey: z.string().nullable(),
  title: z.string(),
  start: z.string(),
  end: z.string(),
  isAllDay: z.boolean(),
  isCancelled: z.boolean(),
  response: z.string().nullable(),
  showAs: z.string().nullable(),
  calendarName: z.string(),
  calendarId: z.string(),
});

export type CalendarEventWire = z.infer<typeof CalendarEventWireSchema>;

export const SettingsPayloadSchema = ConfigSchema;

export const RequestSchema = z.object({
  v: z.literal(PROTOCOL_VERSION),
  id: z.string().min(1),
  method: z.enum([
    "ping",
    "settings.get",
    "settings.validate",
    "token.validate",
    "sync",
    "shutdown",
  ]),
  params: z.record(z.unknown()).optional(),
});

export type SidecarRequest = z.infer<typeof RequestSchema>;

export const TelemetrySchema = z.object({
  lastPollAt: z.string().nullable().optional(),
  lastSlackUpdateAt: z.string().nullable().optional(),
  applied: z.boolean().optional(),
  reason: z.string().optional(),
  eventId: z.string().optional(),
  rule: z.string().optional(),
});

export type SyncTelemetry = z.infer<typeof TelemetrySchema>;

export interface SidecarSuccess {
  v: typeof PROTOCOL_VERSION;
  id: string;
  ok: true;
  result: unknown;
}

export interface SidecarFailure {
  v: typeof PROTOCOL_VERSION;
  id: string;
  ok: false;
  error: {
    code: string;
    message: string;
    fields?: Record<string, string>;
  };
}

export type SidecarResponse = SidecarSuccess | SidecarFailure;

export const SettingsValidateParamsSchema = z.object({
  settings: SettingsPayloadSchema,
  slackToken: z.string().optional(),
});

export const TokenValidateParamsSchema = z.object({
  slackToken: z.string().min(1),
});

export const SyncParamsSchema = z.object({
  settings: SettingsPayloadSchema,
  events: z.array(CalendarEventWireSchema),
  now: z.string().optional(),
  /** Slack token from Keychain; required for apply. */
  slackToken: z.string().min(1),
  dryRun: z.boolean().optional(),
});

export { TitleRuleSchema };
