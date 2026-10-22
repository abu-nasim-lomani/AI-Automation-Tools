/**
 * Gemini adapter. Contract verified against ai.google.dev on 2026-10-22:
 *   POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
 *   key in the `x-goog-api-key` header (never in the URL, so it cannot land in
 *   a proxy log), body of `contents` / `parts`, optional `systemInstruction`.
 * Errors return `{ error: { code, message, status, details:[{reason}] } }`.
 */

import {
  type FetchLike,
  type GenerateInput,
  type GenerateOutput,
  type ProviderErrorClass,
  ProviderError,
  type TextProvider,
  retryAfterMs,
} from "./types.ts";

const ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models";

function classify(status: number, apiStatus: string | undefined): ProviderErrorClass {
  // Google sends a gRPC status string alongside the HTTP code; prefer it.
  if (apiStatus === "FAILED_PRECONDITION") return "terminal"; // free tier not available / billing
  if (apiStatus === "INVALID_ARGUMENT") return "invalid";
  switch (status) {
    case 400: return "invalid";
    case 401:
    case 403: return "auth";
    case 402: return "quota";
    case 404: return "terminal";
    case 429: return "rate_limited";
    case 500:
    case 503:
    case 504: return "transient";
    default:  return status >= 500 ? "transient" : "terminal";
  }
}

export function createGeminiProvider(fetchImpl: FetchLike = fetch): TextProvider {
  return {
    name: "gemini",
    async generate(input: GenerateInput, apiKey: string): Promise<GenerateOutput> {
      // The 2.5+/3.x flash models "think" before answering, which is slow and
      // can spend the whole output budget before any post text is produced.
      // For a short social post we do not need it, so switch it off on the flash
      // models that support a zero budget (not 2.0/1.5 flash, which reject the
      // field, and not pro, which requires a non-zero budget).
      const disableThinking = /flash/i.test(input.model) && !/(2\.0|1\.5)/.test(input.model);
      const body: Record<string, unknown> = {
        contents: [{ role: "user", parts: [{ text: input.prompt }] }],
        generationConfig: {
          ...(input.temperature !== undefined ? { temperature: input.temperature } : {}),
          ...(input.maxOutputTokens !== undefined ? { maxOutputTokens: input.maxOutputTokens } : {}),
          ...(disableThinking ? { thinkingConfig: { thinkingBudget: 0 } } : {}),
        },
      };
      if (input.system) body.systemInstruction = { parts: [{ text: input.system }] };

      let res: Response;
      try {
        res = await fetchImpl(`${ENDPOINT}/${encodeURIComponent(input.model)}:generateContent`, {
          method: "POST",
          headers: { "content-type": "application/json", "x-goog-api-key": apiKey },
          body: JSON.stringify(body),
          // Give a thinking-capable model room to answer, but still bound the
          // wait so the Edge Function does not run past its wall-clock limit.
          signal: AbortSignal.timeout(45000),
        });
      } catch (e) {
        // A network-level failure: no response at all.
        throw new ProviderError(`gemini request failed: ${(e as Error).message}`, {
          provider: "gemini",
          errorClass: "transient",
        });
      }

      if (!res.ok) {
        let apiStatus: string | undefined;
        let code: number | undefined;
        try {
          const err = (await res.json())?.error;
          apiStatus = err?.status;
          code = err?.code;
        } catch { /* body not JSON; fall through on the HTTP status */ }
        throw new ProviderError(`gemini error ${res.status}`, {
          provider: "gemini",
          errorClass: classify(res.status, apiStatus),
          status: res.status,
          providerCode: apiStatus ?? (code !== undefined ? String(code) : undefined),
          retryAfterMs: retryAfterMs(res.headers.get("retry-after")),
        });
      }

      const data = await res.json();

      // A prompt refused on safety grounds returns 200 with a blockReason and
      // no candidate. That is terminal for this prompt, not a transient fault.
      const blockReason = data?.promptFeedback?.blockReason;
      if (blockReason) {
        throw new ProviderError(`gemini blocked the prompt: ${blockReason}`, {
          provider: "gemini",
          errorClass: "blocked",
          providerCode: String(blockReason),
        });
      }

      const cand = data?.candidates?.[0];
      const parts = cand?.content?.parts;
      const text = Array.isArray(parts)
        ? parts.map((p: { text?: string }) => p?.text ?? "").join("")
        : "";
      if (!text) {
        throw new ProviderError(`gemini returned no text (finishReason=${cand?.finishReason})`, {
          provider: "gemini",
          errorClass: "blocked",
          providerCode: cand?.finishReason ? String(cand.finishReason) : undefined,
        });
      }

      return { provider: "gemini", model: input.model, text, finishReason: cand?.finishReason };
    },
  };
}
