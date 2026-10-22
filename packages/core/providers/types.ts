/**
 * The AI provider contract — one adapter interface, two implementations
 * (Gemini primary, Groq fallback), per CLAUDE.md §5.
 *
 * This is the "provider section" docs/API_INTEGRATIONS.md §12 (Q7) said had to
 * exist before the generation path is built: it fixes the request/response
 * shapes and, more importantly, the error classification the generation job
 * reacts to. BYOK means these failures affect generation only, never
 * publishing (ADR-008 decouples them through the buffer).
 *
 * No key lives here. Every call takes the org's key as an argument, and the
 * tests use obviously fake placeholders. WebCrypto/standard only, so it runs
 * unchanged on Deno (Edge Functions) and Node.
 */

export type ProviderName = "gemini" | "groq";

/**
 * How the generation job must treat a failure. The HTTP status alone is not
 * enough — a 400 we caused is a bug, a 429 is a wait, a 403 is the owner's key.
 */
export type ProviderErrorClass =
  | "auth"          // key invalid / permission denied — surface to the owner, do not retry
  | "quota"         // free-tier or spend exhausted — nothing more this run
  | "rate_limited"  // transient throttle — retry with backoff (honour retry-after)
  | "transient"     // 5xx / network — retry with backoff
  | "invalid"       // a request WE built was rejected — a bug, never retry blindly
  | "blocked"       // the model refused on safety grounds — terminal for this prompt
  | "terminal";     // anything else non-retryable

export const RETRYABLE: ReadonlySet<ProviderErrorClass> = new Set<ProviderErrorClass>([
  "quota",
  "rate_limited",
  "transient",
]);

/** A normalised provider failure. Never carries the key or a raw response body. */
export class ProviderError extends Error {
  // `declare` fields: type-only, so they satisfy the checker without emitting a
  // class field that `useDefineForClassFields` would reset to undefined after
  // the constructor assigns it. Node's type-stripping removes them; Deno's
  // type-check reads them.
  declare readonly provider: ProviderName;
  declare readonly errorClass: ProviderErrorClass;
  declare readonly status?: number;
  declare readonly providerCode?: string;
  declare readonly retryAfterMs?: number;

  constructor(
    message: string,
    opts: {
      provider: ProviderName;
      errorClass: ProviderErrorClass;
      status?: number;
      providerCode?: string;
      retryAfterMs?: number;
    },
  ) {
    super(message);
    this.name = "ProviderError";
    this.provider = opts.provider;
    this.errorClass = opts.errorClass;
    this.status = opts.status;
    this.providerCode = opts.providerCode;
    this.retryAfterMs = opts.retryAfterMs;
  }
}

export interface GenerateInput {
  /** Optional system instruction. */
  system?: string;
  /** The user prompt. */
  prompt: string;
  /** The model id, e.g. "gemini-flash-latest" or "llama-3.3-70b-versatile". */
  model: string;
  temperature?: number;
  maxOutputTokens?: number;
}

export interface GenerateOutput {
  provider: ProviderName;
  model: string;
  text: string;
  finishReason?: string;
}

/** Injected in tests; defaults to the global `fetch` in production. */
export type FetchLike = typeof fetch;

export interface TextProvider {
  readonly name: ProviderName;
  generate(input: GenerateInput, apiKey: string): Promise<GenerateOutput>;
}

/** Parse a Retry-After header (seconds, or an HTTP date) into milliseconds. */
export function retryAfterMs(h: string | null, now: number = Date.now()): number | undefined {
  if (!h) return undefined;
  const secs = Number(h);
  if (Number.isFinite(secs)) return Math.max(0, secs * 1000);
  const when = Date.parse(h);
  if (Number.isFinite(when)) return Math.max(0, when - now);
  return undefined;
}
