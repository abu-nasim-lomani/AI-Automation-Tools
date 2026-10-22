/**
 * Provider factory and the primary → fallback runner.
 *
 * The generation job holds, per org, an ordered list of credentials (Gemini
 * primary, Groq fallback). It calls `generateWithFallback`, which tries each in
 * turn and falls through ONLY on a retryable class (quota, rate_limited,
 * transient). An `auth`, `invalid` or `blocked` failure is not something a
 * different provider fixes — it is surfaced at once so the owner sees a bad key
 * or a blocked prompt rather than a silent downgrade.
 */

import {
  type FetchLike,
  type GenerateInput,
  type GenerateOutput,
  type ProviderName,
  type ProviderErrorClass,
  ProviderError,
  RETRYABLE,
  type TextProvider,
} from "./types.ts";
import { createGeminiProvider } from "./gemini.ts";
import { createGroqProvider } from "./groq.ts";

export * from "./types.ts";
export { createGeminiProvider } from "./gemini.ts";
export { createGroqProvider } from "./groq.ts";

export function providerFor(name: ProviderName, fetchImpl: FetchLike = fetch): TextProvider {
  switch (name) {
    case "gemini": return createGeminiProvider(fetchImpl);
    case "groq":   return createGroqProvider(fetchImpl);
  }
}

export interface Attempt {
  provider: ProviderName;
  model: string;
  apiKey: string;
}

export interface FallbackResult extends GenerateOutput {
  /** Which attempt index (0-based) succeeded. */
  attempt: number;
}

export interface FallbackOptions {
  /** Extra tries per attempt on a transient / throttled failure. Default 2. */
  maxRetries?: number;
  /** Base backoff in ms (doubles each retry, capped at 4s). Default 600. */
  retryBaseMs?: number;
}

// Only a 503 is retried in place — it clears in seconds. A 429 is NOT: on the
// free tier it is a real rate/quota limit that an in-request retry cannot clear,
// and sleeping on it pushes the Edge Function past its time limit (a 546). A 429
// fails fast with a clear message so the user waits and retries the whole run.
const RETRY_IN_PLACE: ReadonlySet<ProviderErrorClass> = new Set<ProviderErrorClass>([
  "transient",
]);

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/** Call one provider, retrying in place on a transient / throttled failure. */
async function callWithRetry(
  provider: TextProvider,
  input: GenerateInput,
  apiKey: string,
  maxRetries: number,
  baseMs: number,
): Promise<GenerateOutput> {
  let last: ProviderError | undefined;
  for (let i = 0; i <= maxRetries; i++) {
    try {
      return await provider.generate(input, apiKey);
    } catch (e) {
      const err = e instanceof ProviderError
        ? e
        : new ProviderError((e as Error).message, { provider: provider.name, errorClass: "transient" });
      if (!RETRY_IN_PLACE.has(err.errorClass)) throw err; // not worth waiting out
      last = err;
      if (i < maxRetries) {
        const delay = Math.min(err.retryAfterMs ?? baseMs * 2 ** i, 4000);
        await sleep(delay);
      }
    }
  }
  throw last;
}

/**
 * Try each attempt in order. Each is retried in place on a transient / throttled
 * failure (a 503 or a 429 passes before it fails for good). Falls through to the
 * next attempt only on a retryable class; re-throws anything terminal at once.
 * If every attempt is retryable-but-failed, throws the LAST error.
 */
export async function generateWithFallback(
  input: Omit<GenerateInput, "model">,
  attempts: readonly Attempt[],
  fetchImpl: FetchLike = fetch,
  opts: FallbackOptions = {},
): Promise<FallbackResult> {
  if (attempts.length === 0) {
    throw new ProviderError("no provider credentials supplied", {
      provider: "gemini",
      errorClass: "terminal",
    });
  }
  const maxRetries = opts.maxRetries ?? 1;
  const baseMs = opts.retryBaseMs ?? 600;

  const failures: ProviderError[] = [];
  for (let i = 0; i < attempts.length; i++) {
    const a = attempts[i];
    const provider = providerFor(a.provider, fetchImpl);
    try {
      const out = await callWithRetry(provider, { ...input, model: a.model }, a.apiKey, maxRetries, baseMs);
      return { ...out, attempt: i };
    } catch (e) {
      const err = e instanceof ProviderError
        ? e
        : new ProviderError((e as Error).message, { provider: a.provider, errorClass: "transient" });
      // Terminal for this provider AND not something a different key fixes.
      if (!RETRYABLE.has(err.errorClass)) throw err;
      failures.push(err);
    }
  }
  const last = failures[failures.length - 1];
  (last as { priorFailures?: ProviderError[] }).priorFailures = failures.slice(0, -1);
  throw last;
}
