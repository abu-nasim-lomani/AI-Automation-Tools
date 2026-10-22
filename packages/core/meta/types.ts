/**
 * The Meta Graph publishing contract — one adapter, portable across Deno (Edge
 * Functions) and Node. docs/API_INTEGRATIONS.md §3–§5 is authoritative.
 *
 * No token lives here. Every call takes the Page token as an argument, and the
 * tests use obviously fake placeholders. WebCrypto/standard only.
 *
 * This adapter does NOT retry and holds NO Deno API: the one attempt is one
 * fetch call, and the non-pooling client that makes "one attempt = one network
 * request" hold (ADR-018) is supplied by the Edge Function as the FetchLike.
 */

export const GRAPH_BASE = "https://graph.facebook.com";
export const GRAPH_VERSION = "v26.0"; // [V] current as of 2026-07-29 (API_INTEGRATIONS §3)

/** Injected in tests; defaults to the global `fetch` in production. */
export type FetchLike = typeof fetch;

export interface PublishInput {
  pageId: string;
  message: string;
  pageToken: string;
}

/**
 * The outcome of one publish attempt, already mapped to what the job runner
 * must do (API_INTEGRATIONS §4, §5). Never carries the upstream message or any
 * token — only the numeric Graph code, which is safe and is the ONLY thing the
 * classification keys on (§4: "No string matching on error.message anywhere").
 *
 *  - published          → finalize_publish(job, fbPostId)
 *  - needs_verification → read-back verification decides (R4); never `failed`
 *  - config_fault       → pause the org, alert once, stop attempting
 *  - throttled          → defer to the next slot; `alert` marks a 368 for the owner
 */
export type PublishOutcome =
  | { kind: "published"; fbPostId: string }
  | { kind: "needs_verification"; reason: string; status?: number; code?: number }
  | { kind: "config_fault"; reason: string; code: number }
  | { kind: "throttled"; reason: string; code: number; alert: boolean };
