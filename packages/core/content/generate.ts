/**
 * The generate orchestrator (docs/CONTENT_ENGINE.md §6).
 *
 * Ties the pieces together: assemble the prompt, call the provider adapter for
 * a draft, run the free deterministic checks, then the AI fabrication critic,
 * regenerating up to twice with the critic's reason fed back. Pure — it takes a
 * fetch, so it is fully testable with mocked providers and makes no live call
 * on its own. The Edge Function handler supplies the real fetch, the decrypted
 * keys, and the database write.
 */

import {
  type Attempt,
  type FallbackResult,
  type FetchLike,
  type ProviderName,
  ProviderError,
  generateWithFallback,
} from "../providers/index.ts";
import { countPost, type PostCounts } from "./counting.ts";
import { buildSystemPrompt, buildUserPrompt, R8_RULES, type BrandVoice, type Topic } from "./prompt.ts";
import { runDeterministicChecks } from "./checks.ts";

export interface CriticVerdict {
  ok: boolean;
  layer: "deterministic" | "fabrication" | "ok";
  reason?: string;
}

export interface GeneratedDraft {
  body: string;
  counts: PostCounts;
  provider: ProviderName;
  model: string;
  attempt: number;        // 0-based generation attempt that produced this body
  critique: CriticVerdict;
  accepted: boolean;      // passed both layers
  notes: string | null;   // critic_notes text when not accepted
}

export interface GenerateDraftInput {
  voice: BrandVoice;
  topic: Topic;
  attempts: readonly Attempt[];   // provider credentials, default-first
  maxRegenerations?: number;      // default 2 => up to 3 attempts
}

// A marker the critic prompt carries so a test harness can tell a critic call
// from a generation call. Harmless in production.
const CRITIC_SENTINEL = "You are a strict fact-checker for a social media post.";

export function buildCriticPrompt(): string {
  return (
    CRITIC_SENTINEL + "\n" +
    "Decide whether the post below breaks any of these rules:\n- " + R8_RULES + "\n\n" +
    'Reply with exactly "PASS" if it breaks none. If it breaks one, reply "FAIL: " ' +
    "followed by the rule and the offending text. Reply with nothing else."
  );
}

/**
 * The semantic R8 critic — a second provider call. A critic that cannot run
 * does NOT pass by default: we cannot assert R8 compliance, so the draft is
 * left unaccepted for a human rather than approved unseen.
 */
async function runFabricationCritic(
  body: string,
  attempts: readonly Attempt[],
  fetchImpl: FetchLike,
): Promise<CriticVerdict> {
  let out: FallbackResult;
  try {
    out = await generateWithFallback(
      { system: buildCriticPrompt(), prompt: body, temperature: 0 },
      attempts,
      fetchImpl,
    );
  } catch (e) {
    const cls = e instanceof ProviderError ? e.errorClass : "transient";
    return { ok: false, layer: "fabrication", reason: `critic could not run (${cls})` };
  }
  const verdict = out.text.trim();
  if (/^pass\b/i.test(verdict)) return { ok: true, layer: "ok" };
  const reason = verdict.replace(/^fail:?\s*/i, "").trim() || "fabrication critic rejected the draft";
  return { ok: false, layer: "fabrication", reason };
}

export async function generateDraft(
  input: GenerateDraftInput,
  fetchImpl: FetchLike = fetch,
): Promise<GeneratedDraft> {
  const maxRegen = input.maxRegenerations ?? 2;
  const baseSystem = buildSystemPrompt(input.voice);
  const user = buildUserPrompt(input.topic);
  let last: GeneratedDraft | null = null;

  for (let i = 0; i <= maxRegen; i++) {
    const system = last?.critique.reason
      ? `${baseSystem}\n\nA previous attempt was rejected because: ${last.critique.reason}. Avoid that.`
      : baseSystem;

    // A generation failure (auth, all-retryable-exhausted, blocked) is a
    // provider/config problem, not a content one — let it propagate so the
    // handler can pause the org or back off. The critic's own failure is
    // handled inside runFabricationCritic.
    const gen = await generateWithFallback(
      { system, prompt: user, temperature: 0.9 },
      input.attempts,
      fetchImpl,
    );
    const body = gen.text.trim();
    const counts = countPost(body, input.voice.language_primary);

    const det = runDeterministicChecks(body, counts, input.voice);
    if (!det.ok) {
      const reason = det.failures.map((f) => `${f.check}: ${f.detail}`).join("; ");
      last = {
        body, counts, provider: gen.provider, model: gen.model, attempt: i,
        critique: { ok: false, layer: "deterministic", reason }, accepted: false, notes: reason,
      };
      continue;
    }

    const crit = await runFabricationCritic(body, input.attempts, fetchImpl);
    last = {
      body, counts, provider: gen.provider, model: gen.model, attempt: i,
      critique: crit, accepted: crit.ok, notes: crit.ok ? null : (crit.reason ?? null),
    };
    if (crit.ok) return last;
  }

  // Exhausted: the last draft, unaccepted, with the reason in notes. A draft a
  // human can see beats a silent gap (CONTENT_ENGINE §6).
  return last as GeneratedDraft;
}
