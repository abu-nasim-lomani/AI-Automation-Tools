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

/**
 * Try each attempt in order. Returns the first success. Falls through only on a
 * retryable class; re-throws anything terminal immediately. If every attempt is
 * retryable-but-failed, throws the LAST error, with the earlier ones attached.
 */
export async function generateWithFallback(
  input: Omit<GenerateInput, "model">,
  attempts: readonly Attempt[],
  fetchImpl: FetchLike = fetch,
): Promise<FallbackResult> {
  if (attempts.length === 0) {
    throw new ProviderError("no provider credentials supplied", {
      provider: "gemini",
      errorClass: "terminal",
    });
  }

  const failures: ProviderError[] = [];
  for (let i = 0; i < attempts.length; i++) {
    const a = attempts[i];
    const provider = providerFor(a.provider, fetchImpl);
    try {
      const out = await provider.generate({ ...input, model: a.model }, a.apiKey);
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
