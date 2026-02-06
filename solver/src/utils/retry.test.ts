import { describe, it, expect, vi } from "vitest";
import { withRetry } from "./retry.js";

describe("withRetry", () => {
  it("returns result on first success", async () => {
    const fn = vi.fn().mockResolvedValue(42);
    const result = await withRetry(fn);
    expect(result).toBe(42);
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("retries on failure and returns eventual success", async () => {
    const fn = vi
      .fn()
      .mockRejectedValueOnce(new Error("fail 1"))
      .mockRejectedValueOnce(new Error("fail 2"))
      .mockResolvedValue("success");

    const result = await withRetry(fn, { maxRetries: 3, baseDelayMs: 1 });
    expect(result).toBe("success");
    expect(fn).toHaveBeenCalledTimes(3);
  });

  it("throws after exhausting all retries", async () => {
    const fn = vi.fn().mockRejectedValue(new Error("persistent"));

    await expect(
      withRetry(fn, { maxRetries: 2, baseDelayMs: 1 })
    ).rejects.toThrow("persistent");

    // 1 initial + 2 retries = 3 total
    expect(fn).toHaveBeenCalledTimes(3);
  });

  it("respects maxRetries=0 (no retries)", async () => {
    const fn = vi.fn().mockRejectedValue(new Error("fail"));
    await expect(
      withRetry(fn, { maxRetries: 0, baseDelayMs: 1 })
    ).rejects.toThrow("fail");
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("uses exponential backoff (2^attempt * base)", async () => {
    const start = Date.now();
    const fn = vi
      .fn()
      .mockRejectedValueOnce(new Error("fail"))
      .mockResolvedValue("ok");

    await withRetry(fn, { maxRetries: 1, baseDelayMs: 50 });
    const elapsed = Date.now() - start;

    // First retry delay = 50 * 2^0 = 50ms
    expect(elapsed).toBeGreaterThanOrEqual(40); // allow some timing slack
  });

  it("calls logger.warn on retry", async () => {
    const warn = vi.fn();
    const logger = { warn } as any;

    const fn = vi
      .fn()
      .mockRejectedValueOnce(new Error("oops"))
      .mockResolvedValue("ok");

    await withRetry(fn, { maxRetries: 1, baseDelayMs: 1, logger });
    expect(warn).toHaveBeenCalledTimes(1);
    expect(warn).toHaveBeenCalledWith(
      expect.objectContaining({ attempt: 0, delay: 1 }),
      "Retrying after error"
    );
  });
});
