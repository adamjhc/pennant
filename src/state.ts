import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { z } from "zod";

export const SyncStateSchema = z.object({
  version: z.literal(1).default(1),
  lastHandledEventId: z.string().nullable().default(null),
  lastHandledChangeKey: z.string().nullable().default(null),
  lastHandledICalUId: z.string().nullable().default(null),
  lastHandledStart: z.string().nullable().default(null),
  lastHandledEnd: z.string().nullable().default(null),
  lastHandledRule: z.string().nullable().default(null),
  lastAppliedAt: z.string().nullable().default(null),
  lastPollAt: z.string().nullable().default(null),
});

export type SyncState = z.infer<typeof SyncStateSchema>;

export function emptyState(): SyncState {
  return SyncStateSchema.parse({});
}

export function loadState(path: string): SyncState {
  if (!existsSync(path)) {
    return emptyState();
  }
  const raw = JSON.parse(readFileSync(path, "utf8")) as unknown;
  // Accept older state files that used lastHandledCategory.
  if (raw && typeof raw === "object" && !("lastHandledRule" in (raw as object))) {
    const legacy = raw as { lastHandledCategory?: string | null };
    (raw as { lastHandledRule?: string | null }).lastHandledRule =
      legacy.lastHandledCategory ?? null;
  }
  return SyncStateSchema.parse(raw);
}

export function saveState(path: string, state: SyncState): void {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  writeFileSync(path, `${JSON.stringify(state, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  chmodSync(path, 0o600);
}
