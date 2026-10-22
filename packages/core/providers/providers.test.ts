/**
 * Provider adapter tests. All fetches are mocked — no network, no live call,
 * no real key (SECURITY.md: never a real credential in a test). Runs on Node
 * (node --test) and on Deno unchanged.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  createGeminiProvider,
  createGroqProvider,
  generateWithFallback,
  ProviderError,
  retryAfterMs,
  type FetchLike,
} from "./index.ts";

const FAKE_GEMINI_KEY = "AIza-EXAMPLE-NOT-REAL";
const FAKE_GROQ_KEY = "gsk-EXAMPLE-NOT-REAL";

type MockReply = { status: number; body?: unknown; headers?: Record<string, string> };

function mockFetch(reply: MockReply | ((url: string, init: RequestInit) => MockReply)): {
  fetch: FetchLike;
  calls: Array<{ url: string; init: RequestInit }>;
} {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fetchImpl = (async (url: string | URL | Request, init?: RequestInit) => {
    const u = String(url);
    calls.push({ url: u, init: init ?? {} });
    const r = typeof reply === "function" ? reply(u, init ?? {}) : reply;
    const body = r.body === undefined ? null : JSON.stringify(r.body);
    return new Response(body, { status: r.status, headers: r.headers });
  }) as unknown as FetchLike;
  return { fetch: fetchImpl, calls };
}

function geminiOk(text: string): MockReply {
  return { status: 200, body: { candidates: [{ content: { parts: [{ text }] }, finishReason: "STOP" }] } };
}
function groqOk(text: string): MockReply {
  return { status: 200, body: { choices: [{ message: { content: text }, finish_reason: "stop" }] } };
}

async function errorClassOf(p: Promise<unknown>): Promise<string> {
  try { await p; return "<no error>"; }
  catch (e) { return e instanceof ProviderError ? e.errorClass : `<${(e as Error).name}>`; }
}

// ── Gemini ────────────────────────────────────────────────────────────────

test("gemini: a 200 yields the joined candidate text", async () => {
  const { fetch } = mockFetch(geminiOk("আজকের post"));
  const out = await createGeminiProvider(fetch).generate(
    { prompt: "hi", model: "gemini-flash-latest" }, FAKE_GEMINI_KEY);
  assert.equal(out.text, "আজকের post");
  assert.equal(out.provider, "gemini");
  assert.equal(out.finishReason, "STOP");
});

test("gemini: the key travels in a header, never in the URL", async () => {
  const { fetch, calls } = mockFetch(geminiOk("x"));
  await createGeminiProvider(fetch).generate({ prompt: "hi", model: "m" }, FAKE_GEMINI_KEY);
  assert.ok(!calls[0].url.includes(FAKE_GEMINI_KEY), "key must not be in the URL");
  const headers = calls[0].init.headers as Record<string, string>;
  assert.equal(headers["x-goog-api-key"], FAKE_GEMINI_KEY);
});

test("gemini: a blocked prompt (200 + blockReason) is class blocked", async () => {
  const { fetch } = mockFetch({ status: 200, body: { promptFeedback: { blockReason: "SAFETY" } } });
  assert.equal(await errorClassOf(
    createGeminiProvider(fetch).generate({ prompt: "x", model: "m" }, FAKE_GEMINI_KEY)), "blocked");
});

test("gemini: a 200 with no text is class blocked", async () => {
  const { fetch } = mockFetch({ status: 200, body: { candidates: [{ content: { parts: [] }, finishReason: "MAX_TOKENS" }] } });
  assert.equal(await errorClassOf(
    createGeminiProvider(fetch).generate({ prompt: "x", model: "m" }, FAKE_GEMINI_KEY)), "blocked");
});

test("gemini: status mapping — 429 rate_limited, 403 auth, 402 quota, 503 transient", async () => {
  for (const [status, cls] of [[429, "rate_limited"], [403, "auth"], [402, "quota"], [503, "transient"]] as const) {
    const { fetch } = mockFetch({ status, body: { error: { code: status, message: "x" } } });
    assert.equal(
      await errorClassOf(createGeminiProvider(fetch).generate({ prompt: "x", model: "m" }, FAKE_GEMINI_KEY)),
      cls, `status ${status}`);
  }
});

test("gemini: 400 FAILED_PRECONDITION is terminal, INVALID_ARGUMENT is invalid", async () => {
  const fp = mockFetch({ status: 400, body: { error: { status: "FAILED_PRECONDITION", message: "no free tier" } } });
  assert.equal(await errorClassOf(
    createGeminiProvider(fp.fetch).generate({ prompt: "x", model: "m" }, FAKE_GEMINI_KEY)), "terminal");
  const ia = mockFetch({ status: 400, body: { error: { status: "INVALID_ARGUMENT", message: "bad" } } });
  assert.equal(await errorClassOf(
    createGeminiProvider(ia.fetch).generate({ prompt: "x", model: "m" }, FAKE_GEMINI_KEY)), "invalid");
});

test("gemini: a thrown fetch (network) is transient", async () => {
  const fetchImpl = (async () => { throw new Error("ECONNRESET"); }) as unknown as FetchLike;
  assert.equal(await errorClassOf(
    createGeminiProvider(fetchImpl).generate({ prompt: "x", model: "m" }, FAKE_GEMINI_KEY)), "transient");
});

// ── Groq ─────────────────────────────────────────────────────────────────

test("groq: a 200 yields the message content", async () => {
  const { fetch } = mockFetch(groqOk("fallback text"));
  const out = await createGroqProvider(fetch).generate(
    { prompt: "hi", system: "be brief", model: "llama-3.3-70b-versatile" }, FAKE_GROQ_KEY);
  assert.equal(out.text, "fallback text");
  assert.equal(out.provider, "groq");
});

test("groq: a system instruction becomes the first message", async () => {
  const { fetch, calls } = mockFetch(groqOk("x"));
  await createGroqProvider(fetch).generate({ prompt: "hi", system: "sys", model: "m" }, FAKE_GROQ_KEY);
  const sent = JSON.parse(calls[0].init.body as string);
  assert.equal(sent.messages[0].role, "system");
  assert.equal(sent.messages[0].content, "sys");
  assert.equal(sent.messages[1].role, "user");
});

test("groq: 401 is auth, 400 invalid_request_error is invalid", async () => {
  const a = mockFetch({ status: 401, body: { error: { message: "bad key", type: "authentication_error" } } });
  assert.equal(await errorClassOf(
    createGroqProvider(a.fetch).generate({ prompt: "x", model: "m" }, FAKE_GROQ_KEY)), "auth");
  const b = mockFetch({ status: 400, body: { error: { message: "bad", type: "invalid_request_error" } } });
  assert.equal(await errorClassOf(
    createGroqProvider(b.fetch).generate({ prompt: "x", model: "m" }, FAKE_GROQ_KEY)), "invalid");
});

test("groq: a 429 carries retry-after as milliseconds", async () => {
  const { fetch } = mockFetch({ status: 429, body: { error: { type: "rate_limit" } }, headers: { "retry-after": "2" } });
  try {
    await createGroqProvider(fetch).generate({ prompt: "x", model: "m" }, FAKE_GROQ_KEY);
    assert.fail("should have thrown");
  } catch (e) {
    assert.ok(e instanceof ProviderError);
    assert.equal(e.errorClass, "rate_limited");
    assert.equal(e.retryAfterMs, 2000);
  }
});

// ── Fallback ──────────────────────────────────────────────────────────────

test("fallback: a transient primary failure falls through to the fallback", async () => {
  let n = 0;
  const fetch = (async (url: string | URL | Request) => {
    n++;
    if (String(url).includes("googleapis")) return new Response(JSON.stringify({ error: { code: 503 } }), { status: 503 });
    return new Response(JSON.stringify({ choices: [{ message: { content: "from groq" } }] }), { status: 200 });
  }) as unknown as FetchLike;
  const out = await generateWithFallback(
    { prompt: "hi" },
    [{ provider: "gemini", model: "g", apiKey: FAKE_GEMINI_KEY },
     { provider: "groq", model: "l", apiKey: FAKE_GROQ_KEY }],
    fetch);
  assert.equal(out.text, "from groq");
  assert.equal(out.attempt, 1);
  assert.equal(n, 2);
});

test("fallback: an auth failure is surfaced at once, not retried elsewhere", async () => {
  let groqCalled = false;
  const fetch = (async (url: string | URL | Request) => {
    if (String(url).includes("googleapis")) return new Response(JSON.stringify({ error: { code: 403 } }), { status: 403 });
    groqCalled = true;
    return new Response(JSON.stringify({ choices: [{ message: { content: "x" } }] }), { status: 200 });
  }) as unknown as FetchLike;
  assert.equal(await errorClassOf(generateWithFallback(
    { prompt: "hi" },
    [{ provider: "gemini", model: "g", apiKey: FAKE_GEMINI_KEY },
     { provider: "groq", model: "l", apiKey: FAKE_GROQ_KEY }],
    fetch)), "auth");
  assert.equal(groqCalled, false, "fallback must not run after a terminal auth error");
});

test("fallback: when every attempt is retryable-but-failed, the last error is thrown", async () => {
  const fetch = (async () => new Response(JSON.stringify({ error: { code: 429 } }), { status: 429 })) as unknown as FetchLike;
  try {
    await generateWithFallback(
      { prompt: "hi" },
      [{ provider: "gemini", model: "g", apiKey: FAKE_GEMINI_KEY },
       { provider: "groq", model: "l", apiKey: FAKE_GROQ_KEY }],
      fetch);
    assert.fail("should have thrown");
  } catch (e) {
    assert.ok(e instanceof ProviderError);
    assert.equal(e.provider, "groq");
    assert.equal((e as { priorFailures?: ProviderError[] }).priorFailures?.length, 1);
  }
});

test("fallback: no credentials is a terminal error", async () => {
  assert.equal(await errorClassOf(generateWithFallback({ prompt: "hi" }, [])), "terminal");
});

// ── retry-after parsing ────────────────────────────────────────────────────

test("retryAfterMs: seconds and HTTP-date forms", () => {
  assert.equal(retryAfterMs("5"), 5000);
  assert.equal(retryAfterMs(null), undefined);
  const now = Date.now();
  const inTen = new Date(now + 10_000).toUTCString();
  const ms = retryAfterMs(inTen, now);
  assert.ok(ms !== undefined && Math.abs(ms - 10_000) < 1500);
});
