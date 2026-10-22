/**
 * Groq adapter. Contract verified against console.groq.com on 2026-10-22:
 *   POST https://api.groq.com/openai/v1/chat/completions  (OpenAI-compatible)
 *   Bearer key, `messages` array, `{ error: { message, type } }` on failure,
 *   a `retry-after` header on a 429.
 * The free line is the fallback for Bangla when Gemini is throttled or down.
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

const ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";

function classify(status: number, type: string | undefined): ProviderErrorClass {
  if (type === "invalid_request_error") return "invalid";
  switch (status) {
    case 400: return "invalid";
    case 401:
    case 403: return "auth";
    case 429: return "rate_limited";
    case 498: return "quota";          // capacity_exceeded (flex, paid) — treat as no-capacity
    case 500:
    case 502:
    case 503:
    case 504: return "transient";
    default:  return status >= 500 ? "transient" : "terminal";
  }
}

export function createGroqProvider(fetchImpl: FetchLike = fetch): TextProvider {
  return {
    name: "groq",
    async generate(input: GenerateInput, apiKey: string): Promise<GenerateOutput> {
      const messages: Array<{ role: string; content: string }> = [];
      if (input.system) messages.push({ role: "system", content: input.system });
      messages.push({ role: "user", content: input.prompt });

      const body: Record<string, unknown> = {
        model: input.model,
        messages,
        ...(input.temperature !== undefined ? { temperature: input.temperature } : {}),
        ...(input.maxOutputTokens !== undefined ? { max_tokens: input.maxOutputTokens } : {}),
      };

      let res: Response;
      try {
        res = await fetchImpl(ENDPOINT, {
          method: "POST",
          headers: { "content-type": "application/json", authorization: `Bearer ${apiKey}` },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(15000),
        });
      } catch (e) {
        throw new ProviderError(`groq request failed: ${(e as Error).message}`, {
          provider: "groq",
          errorClass: "transient",
        });
      }

      if (!res.ok) {
        let type: string | undefined;
        try {
          type = (await res.json())?.error?.type;
        } catch { /* body not JSON */ }
        throw new ProviderError(`groq error ${res.status}`, {
          provider: "groq",
          errorClass: classify(res.status, type),
          status: res.status,
          providerCode: type,
          retryAfterMs: retryAfterMs(res.headers.get("retry-after")),
        });
      }

      const data = await res.json();
      const choice = data?.choices?.[0];
      const text = choice?.message?.content ?? "";
      if (!text) {
        throw new ProviderError(`groq returned no text (finish_reason=${choice?.finish_reason})`, {
          provider: "groq",
          errorClass: "blocked",
          providerCode: choice?.finish_reason ? String(choice.finish_reason) : undefined,
        });
      }

      return { provider: "groq", model: input.model, text, finishReason: choice?.finish_reason };
    },
  };
}
