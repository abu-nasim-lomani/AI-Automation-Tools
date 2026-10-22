/**
 * The publish call: POST /v26.0/{page-id}/feed with `message` and the Page
 * token (API_INTEGRATIONS §3), and the §4 response-handling procedure whose
 * order is load-bearing. One fetch, no retry (ADR-018). Every ambiguous outcome
 * becomes `needs_verification`, never `failed` — a response proves a request was
 * issued, and `failed` asserts none ever was (R4, DATABASE §5.2.1).
 */

import {
  GRAPH_BASE,
  GRAPH_VERSION,
  type FetchLike,
  type PublishInput,
  type PublishOutcome,
} from "./types.ts";

/**
 * Classify a structured Graph error by its NUMERIC code only (§4, §5). An
 * unknown code is ambiguous — the side effect is unknown — so it verifies,
 * never fails.
 */
export function classifyGraphError(code: number): PublishOutcome {
  // Class A — permission / capability faults. Documented as a refusal of the
  // caller, so pause the org and stop; never `failed` (§5.1).
  if (code === 3 || code === 10 || (code >= 200 && code <= 299)) {
    return { kind: "config_fault", code, reason: `permission or capability fault (code ${code})` };
  }
  // Class B — volumetric throttles. Defer to the next slot; a 368 also alerts
  // the owner, because repeated 368 means the Page is being restricted (§5.2).
  if (code === 4 || code === 17 || code === 80001 || code === 368) {
    return { kind: "throttled", code, alert: code === 368, reason: `throttled (code ${code})` };
  }
  // 506 (duplicate), the Class D ambiguous codes (1, 2, 341), and every code
  // not in the tables: the side effect is unknown, so verify (§5.1 506, §5.4,
  // §4 step 6).
  return { kind: "needs_verification", code, reason: `unconfirmed Graph error (code ${code})` };
}

export async function publishToPage(
  input: PublishInput,
  fetchImpl: FetchLike = fetch,
  timeoutMs = 20000,
): Promise<PublishOutcome> {
  const url = `${GRAPH_BASE}/${GRAPH_VERSION}/${encodeURIComponent(input.pageId)}/feed`;
  const form = new URLSearchParams();
  form.set("message", input.message);
  form.set("access_token", input.pageToken);

  let res: Response;
  try {
    res = await fetchImpl(url, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: form.toString(),
      // A timeout aborts the one attempt; an abort is a transport failure, which
      // is ambiguous (the request may have been applied), so it verifies. The
      // non-pooling client is supplied by the caller (ADR-018); no retry here.
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    // Step 1: transport failure (timeout, connection reset, TLS) — unknown side effect.
    return { kind: "needs_verification", reason: "transport failure" };
  }

  // Step 2a: an HTTP 5xx is ambiguous.
  if (res.status >= 500) {
    return { kind: "needs_verification", reason: "server error", status: res.status };
  }

  // Step 2b: a body that is not parseable JSON is ambiguous.
  let data: Record<string, unknown>;
  try {
    data = ((await res.json()) ?? {}) as Record<string, unknown>;
  } catch {
    return { kind: "needs_verification", reason: "unparseable response", status: res.status };
  }

  // Steps 3 and 4: a 2xx is a success claim, but only an id confirms it.
  if (res.ok) {
    const id = typeof data.id === "string" ? data.id : undefined;
    if (id) return { kind: "published", fbPostId: id };
    return { kind: "needs_verification", reason: "2xx without a post id", status: res.status };
  }

  // Steps 5 and 6: a structured Graph error — classify on the numeric code only.
  const err = (data.error ?? {}) as Record<string, unknown>;
  const code = typeof err.code === "number" ? err.code : Number(err.code);
  if (Number.isFinite(code)) return classifyGraphError(code);

  // A non-2xx with no numeric code is ambiguous, never failed (step 6).
  return { kind: "needs_verification", reason: "error without a numeric code", status: res.status };
}
