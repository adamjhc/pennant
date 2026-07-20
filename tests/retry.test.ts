import { describe, expect, it, vi } from "vitest";
import { defaultIsRetryable, withRetry } from "../src/retry.js";

describe("withRetry", () => {
  it("returns on first success", async () => {
    const fn = vi.fn().mockResolvedValue("ok");
    await expect(withRetry(fn, { attempts: 3, baseDelayMs: 1 })).resolves.toBe("ok");
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("retries retryable errors then succeeds", async () => {
    const fn = vi
      .fn()
      .mockRejectedValueOnce(Object.assign(new Error("rate limited"), { status: 429 }))
      .mockResolvedValue("done");
    await expect(withRetry(fn, { attempts: 3, baseDelayMs: 1 })).resolves.toBe("done");
    expect(fn).toHaveBeenCalledTimes(2);
  });

  it("does not retry non-retryable errors", async () => {
    const fn = vi.fn().mockRejectedValue(Object.assign(new Error("nope"), { status: 401 }));
    await expect(withRetry(fn, { attempts: 3, baseDelayMs: 1 })).rejects.toThrow("nope");
    expect(fn).toHaveBeenCalledTimes(1);
  });
});

describe("defaultIsRetryable", () => {
  it("detects rate limits and timeouts", () => {
    expect(defaultIsRetryable({ status: 429 })).toBe(true);
    expect(defaultIsRetryable({ code: "ETIMEDOUT" })).toBe(true);
    expect(defaultIsRetryable({ status: 401 })).toBe(false);
  });
});
