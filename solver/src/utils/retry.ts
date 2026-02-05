import type { Logger } from "./logger.js";

/**
 * Retry a function with exponential backoff.
 */
export async function withRetry<T>(
  fn: () => Promise<T>,
  opts: { maxRetries?: number; baseDelayMs?: number; logger?: Logger } = {}
): Promise<T> {
  const { maxRetries = 3, baseDelayMs = 1000, logger } = opts;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (attempt === maxRetries) throw err;
      const delay = baseDelayMs * 2 ** attempt;
      logger?.warn({ attempt, delay, err }, "Retrying after error");
      await new Promise((r) => setTimeout(r, delay));
    }
  }

  // Unreachable
  throw new Error("withRetry: unreachable");
}
