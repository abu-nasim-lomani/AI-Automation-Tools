/**
 * Meta publish adapter tests. All fetches are mocked — no network, no live
 * publish, no real token (SECURITY.md: never a real credential in a test). Runs
 * on Node (node --test) and on Deno unchanged.
 *
 * The load-bearing assertion for ADR-018 is that the adapter makes EXACTLY ONE
 * fetch call per publish, whatever the outcome — the adapter never retries.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { classifyGraphError, publishToPage } from "./publish.ts";
import { type FetchLike } from "./types.ts";

const FAKE_PAGE_ID = "1234567890";
const FAKE_TOKEN = "EAAB-EXAMPLE-NOT-REAL";
const INPUT = { pageId: FAKE_PAGE_ID, message: "হ্যালো বিশ্ব", pageToken: FAKE_TOKEN };

type MockReply = { status: number; body?: unknown };

function mockFetch(reply: MockReply): { fetch: FetchLike; calls: Array<{ url: string; init: RequestInit }> } {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fetchImpl = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    const body = reply.body === undefined ? null : JSON.stringify(reply.body);
    return new Response(body, { status: reply.status });
  }) as unknown as FetchLike;
  return { fetch: fetchImpl, calls };
}

function throwingFetch(): { fetch: FetchLike; calls: number[] } {
  const calls: number[] = [];
  const fetchImpl = (async () => {
    calls.push(1);
    throw new TypeError("connection reset");
  }) as unknown as FetchLike;
  return { fetch: fetchImpl, calls };
}

test("2xx with an id is published, in exactly one call", async () => {
  const { fetch, calls } = mockFetch({ status: 200, body: { id: "1234567890_99887766" } });
  const out = await publishToPage(INPUT, fetch);
  assert.deepEqual(out, { kind: "published", fbPostId: "1234567890_99887766" });
  assert.equal(calls.length, 1); // never retried — ADR-018
});

test("the request is a form POST to the v26.0 feed edge with message and token", async () => {
  const { fetch, calls } = mockFetch({ status: 200, body: { id: "x_y" } });
  await publishToPage(INPUT, fetch);
  const { url, init } = calls[0];
  assert.equal(url, "https://graph.facebook.com/v26.0/1234567890/feed");
  assert.equal(init.method, "POST");
  const body = String(init.body);
  assert.match(body, /message=/);
  assert.match(body, /access_token=/);
});

test("2xx without an id is unconfirmed, not published", async () => {
  const { fetch } = mockFetch({ status: 200, body: { not_an_id: true } });
  const out = await publishToPage(INPUT, fetch);
  assert.equal(out.kind, "needs_verification");
});

test("a 5xx is ambiguous -> needs_verification", async () => {
  const { fetch } = mockFetch({ status: 503, body: { error: { code: 2 } } });
  const out = await publishToPage(INPUT, fetch);
  assert.equal(out.kind, "needs_verification");
  assert.equal(out.status, 503);
});

test("a transport failure is ambiguous -> needs_verification, one attempt", async () => {
  const { fetch, calls } = throwingFetch();
  const out = await publishToPage(INPUT, fetch);
  assert.equal(out.kind, "needs_verification");
  assert.equal(calls.length, 1); // one attempt, no retry on a reset — ADR-018
});

test("error 506 (duplicate) always verifies, never fails", async () => {
  const { fetch } = mockFetch({ status: 400, body: { error: { code: 506, message: "Duplicate Post" } } });
  const out = await publishToPage(INPUT, fetch);
  assert.equal(out.kind, "needs_verification");
  assert.equal(out.code, 506);
});

test("error 3 is a config fault (pause the org)", async () => {
  const { fetch } = mockFetch({ status: 403, body: { error: { code: 3 } } });
  const out = await publishToPage(INPUT, fetch);
  assert.equal(out.kind, "config_fault");
});

test("an unknown error code verifies, never fails (step 6)", async () => {
  const { fetch } = mockFetch({ status: 400, body: { error: { code: 190 } } }); // not in the tables
  const out = await publishToPage(INPUT, fetch);
  assert.equal(out.kind, "needs_verification");
  assert.equal(out.code, 190);
});

test("throttles defer; 368 also alerts", () => {
  for (const code of [4, 17, 80001]) {
    const out = classifyGraphError(code);
    assert.equal(out.kind, "throttled");
    assert.equal(out.kind === "throttled" && out.alert, false);
  }
  const out368 = classifyGraphError(368);
  assert.equal(out368.kind, "throttled");
  assert.equal(out368.kind === "throttled" && out368.alert, true);
});

test("config-fault range 200–299 and codes 3, 10", () => {
  for (const code of [3, 10, 200, 250, 299]) {
    assert.equal(classifyGraphError(code).kind, "config_fault");
  }
});

test("no outcome reason leaks the token or the message", async () => {
  const { fetch } = mockFetch({ status: 400, body: { error: { code: 506, message: FAKE_TOKEN } } });
  const out = await publishToPage(INPUT, fetch);
  const text = JSON.stringify(out);
  assert.ok(!text.includes(FAKE_TOKEN));
  assert.ok(!text.includes("হ্যালো"));
});
