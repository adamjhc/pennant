import { WebClient } from "@slack/web-api";
import type { Logger } from "../logger.js";

export interface SlackStatusUpdate {
  statusText: string;
  statusEmoji: string;
  /** Unix timestamp seconds; 0 means no expiry */
  statusExpiration: number;
}

export class SlackClient {
  private readonly client: WebClient;
  private readonly logger: Logger;

  constructor(token: string, logger: Logger) {
    this.client = new WebClient(token);
    this.logger = logger;
  }

  async validate(): Promise<{ userId: string; team?: string }> {
    const auth = await this.client.auth.test();
    if (!auth.ok || !auth.user_id) {
      throw new Error("Slack auth.test failed");
    }
    return { userId: auth.user_id, team: auth.team as string | undefined };
  }

  async setStatus(update: SlackStatusUpdate): Promise<void> {
    this.logger.info("Setting Slack status", {
      statusText: update.statusText,
      statusEmoji: update.statusEmoji,
      statusExpiration: update.statusExpiration,
    });
    await this.client.users.profile.set({
      profile: {
        status_text: update.statusText,
        status_emoji: update.statusEmoji,
        status_expiration: update.statusExpiration,
      },
    });
  }

  async setSnooze(numMinutes: number): Promise<void> {
    const minutes = Math.max(1, Math.ceil(numMinutes));
    this.logger.info("Setting Slack DND snooze", { numMinutes: minutes });
    await this.client.dnd.setSnooze({ num_minutes: minutes });
  }

  async endSnooze(): Promise<void> {
    this.logger.info("Ending Slack DND snooze");
    try {
      await this.client.dnd.endSnooze();
    } catch (error) {
      // Slack returns an error if snooze is not active; treat as success.
      const message = error instanceof Error ? error.message : String(error);
      if (message.includes("snooze_end_failed") || message.includes("not_snoozed")) {
        this.logger.debug("No active snooze to end", { message });
        return;
      }
      throw error;
    }
  }
}
