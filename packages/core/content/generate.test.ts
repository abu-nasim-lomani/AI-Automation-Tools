/**
 * Orchestrator tests. All provider calls are mocked — no network, no secret,
 * no live call. The mock tells a critic call from a generation call by the
 * fact-checker sentinel in the request body.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { generateDraft } from "./generate.ts";
import { type BrandVoice } from "./prompt.ts";
import { ProviderError, type FetchLike } from "../providers/index.ts";

// Permissive voice: Layer-1 specifics are covered in content.test.ts, so here
// a plain body clears length and ratio and we exercise the critic loop.
const VOICE: BrandVoice = {
  tone: "conversational",
  language_primary: "en",
  bangla_ratio_target: 0,
  ratio_tolerance: 1,
  min_graphemes: 5,
  max_graphemes: 2000,
  hashtag_max: 10,
  emoji_pref: "moderate",
  opening_style: null,
  closing_style: null,
  custom_instructions: null,
  exclusions: [],
};

const TOPIC = { title: "the value of patience" };
const GEMINI: ReadonlyArray<{ provider: "gemini"; model: string; apiKey: string }> = [
  { provider: "gemini", model: "gemini-flash-latest", apiKey: "AIza-EXAMPLE-NOT-REAL" },
];

/**
 * Scripted mock. `gen` supplies generation bodies in order; `critic` supplies
 * verdict strings in order. A 403 generation can be requested with {authFail}.
 */
function scripted(opts: { gen: string[]; critic?: string[]; genStatus?: number; criticThrows?: boolean }): FetchLike {
  const gen = [...opts.gen];
  const critic = [...(opts.critic ?? [])];
  const geminiReply = (text: string) =>
    new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text }] }, finishReason: "STOP" }] }), { status: 200 });

  return (async (_url: string | URL | Request, init?: RequestInit) => {
    const body = String(init?.body ?? "");
    const isCritic = body.includes("fact-checker");
    if (isCritic) {
      if (opts.criticThrows) return new Response(JSON.stringify({ error: { code: 503 } }), { status: 503 });
      return geminiReply(critic.shift() ?? "PASS");
    }
    if (opts.genStatus && opts.genStatus >= 400) {
      return new Response(JSON.stringify({ error: { code: opts.genStatus } }), { status: opts.genStatus });
    }
    return geminiReply(gen.shift() ?? "a perfectly ordinary and sufficiently long test post body");
  }) as unknown as FetchLike;
}

test("happy path: a good draft that the critic passes is accepted on attempt 0", async () => {
  const fetch = scripted({ gen: ["patience is a quiet strength worth practising daily"], critic: ["PASS"] });
  const d = await generateDraft({ voice: VOICE, topic: TOPIC, attempts: GEMINI }, fetch);
  assert.equal(d.accepted, true);
  assert.equal(d.attempt, 0);
  assert.equal(d.notes, null);
  assert.equal(d.critique.layer, "ok");
  assert.ok(d.counts.grapheme_count > 0);
});

test("a Layer-1 failure regenerates, then accepts", async () => {
  // First body is too short (fails length), second is fine; critic passes.
  const fetch = scripted({ gen: ["x", "a sufficiently long and clean second attempt body"], critic: ["PASS"] });
  const d = await generateDraft({ voice: VOICE, topic: TOPIC, attempts: GEMINI }, fetch);
  assert.equal(d.accepted, true);
  assert.equal(d.attempt, 1);
});

test("the critic can reject twice and accept on the third attempt", async () => {
  const fetch = scripted({
    gen: ["first body long enough to pass layer one", "second body long enough", "third body long enough"],
    critic: ["FAIL: invented a statistic", "FAIL: a quotation", "PASS"],
  });
  const d = await generateDraft({ voice: VOICE, topic: TOPIC, attempts: GEMINI }, fetch);
  assert.equal(d.accepted, true);
  assert.equal(d.attempt, 2);
});

test("when every attempt is rejected, the last draft is returned unaccepted with notes", async () => {
  const fetch = scripted({
    gen: ["one body long enough", "two body long enough", "three body long enough"],
    critic: ["FAIL: invented a statistic", "FAIL: invented a statistic", "FAIL: still invented a statistic"],
  });
  const d = await generateDraft({ voice: VOICE, topic: TOPIC, attempts: GEMINI }, fetch);
  assert.equal(d.accepted, false);
  assert.equal(d.attempt, 2);
  assert.ok(d.notes && d.notes.includes("invented a statistic"));
});

test("a critic that cannot run leaves the draft unaccepted, never auto-passed", async () => {
  const fetch = scripted({ gen: ["a clean draft long enough to pass layer one"], criticThrows: true });
  const d = await generateDraft({ voice: VOICE, topic: TOPIC, attempts: GEMINI, maxRegenerations: 0 }, fetch);
  assert.equal(d.accepted, false);
  assert.equal(d.critique.layer, "fabrication");
  assert.ok(d.notes && d.notes.includes("critic could not run"));
});

test("a generation auth failure propagates rather than becoming a draft", async () => {
  const fetch = scripted({ gen: [], genStatus: 403 });
  await assert.rejects(
    generateDraft({ voice: VOICE, topic: TOPIC, attempts: GEMINI }, fetch),
    (e: unknown) => e instanceof ProviderError && e.errorClass === "auth",
  );
});

test("skipCritic: one call, no critic, accepted when layer 1 passes", async () => {
  let criticCalls = 0;
  const fetch = (async (_url: string | URL | Request, init?: RequestInit) => {
    const body = String(init?.body ?? "");
    if (body.includes("fact-checker")) { criticCalls++; }
    return new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: "a clean short sample post body" }] } }] }), { status: 200 });
  }) as unknown as FetchLike;
  const d = await generateDraft(
    { voice: VOICE, topic: TOPIC, attempts: GEMINI, skipCritic: true, maxOutputTokens: 400, maxRegenerations: 0 },
    fetch);
  assert.equal(d.accepted, true);
  assert.equal(d.critique.layer, "ok");
  assert.equal(criticCalls, 0); // the critic is never called
});
