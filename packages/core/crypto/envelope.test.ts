/**
 * Tests for the envelope encryption module.
 *
 * Covers SEC-02 (no plaintext recoverable from stored bytes) and the AAD
 * binding described in docs/SECURITY.md §5. Each assertion is written so that
 * removing the control it tests makes it fail — the meta-rule in SECURITY.md §1.
 *
 * Runs on Node (node --test) and on Deno unchanged: WebCrypto only.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  EnvelopeError,
  keyringFromEnv,
  maskSecret,
  openCredential,
  sealCredential,
  type MasterKeyring,
} from "./envelope.ts";

const ORG_A = "11111111-1111-4111-8111-111111111111";
const ORG_B = "22222222-2222-4222-8222-222222222222";
const CRED_1 = "33333333-3333-4333-8333-333333333333";
const CRED_2 = "44444444-4444-4444-8444-444444444444";

// An obviously fake value. Never a real key (CLAUDE.md §9).
const FAKE_KEY = "AIza-EXAMPLE-NOT-REAL-0123456789abcd";

function ring(): MasterKeyring {
  return new Map([
    [1, new Uint8Array(32).fill(7)],
    [2, new Uint8Array(32).fill(9)],
  ]);
}

test("round-trips a credential", async () => {
  const k = ring();
  const sealed = await sealCredential(k, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  const opened = await openCredential(k, { orgId: ORG_A, credentialId: CRED_1 }, sealed);
  assert.equal(opened, FAKE_KEY);
});

test("stored bytes contain no plaintext (SEC-02)", async () => {
  const k = ring();
  const sealed = await sealCredential(k, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  const asText = new TextDecoder().decode(sealed.ciphertext);
  assert.ok(!asText.includes("AIza"), "ciphertext must not contain the key prefix");
  assert.ok(!asText.includes(FAKE_KEY), "ciphertext must not contain the plaintext");
  // Belt and braces: search the raw bytes for the plaintext byte sequence.
  const needle = new TextEncoder().encode(FAKE_KEY);
  const hay = sealed.ciphertext;
  let found = false;
  outer: for (let i = 0; i + needle.length <= hay.length; i++) {
    for (let j = 0; j < needle.length; j++) if (hay[i + j] !== needle[j]) continue outer;
    found = true;
    break;
  }
  assert.ok(!found, "plaintext byte sequence must not appear in the ciphertext");
});

test("a record moved to another ORG fails to open (AAD + per-tenant DEK)", async () => {
  const k = ring();
  const sealed = await sealCredential(k, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  await assert.rejects(
    () => openCredential(k, { orgId: ORG_B, credentialId: CRED_1 }, sealed),
    EnvelopeError,
  );
});

test("a record moved to another ROW fails to open (AAD)", async () => {
  const k = ring();
  const sealed = await sealCredential(k, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  await assert.rejects(
    () => openCredential(k, { orgId: ORG_A, credentialId: CRED_2 }, sealed),
    EnvelopeError,
  );
});

test("the wrong key version fails to open", async () => {
  const k = ring();
  const sealed = await sealCredential(k, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  await assert.rejects(
    () =>
      openCredential(k, { orgId: ORG_A, credentialId: CRED_1 }, { ...sealed, keyVersion: 2 }),
    EnvelopeError,
  );
});

test("a tampered ciphertext fails the GCM tag", async () => {
  const k = ring();
  const sealed = await sealCredential(k, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  const tampered = Uint8Array.from(sealed.ciphertext);
  tampered[0] ^= 0x01;
  await assert.rejects(
    () => openCredential(k, { orgId: ORG_A, credentialId: CRED_1 }, { ...sealed, ciphertext: tampered }),
    EnvelopeError,
  );
});

test("a tampered tag fails", async () => {
  const k = ring();
  const sealed = await sealCredential(k, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  const tampered = Uint8Array.from(sealed.ciphertext);
  tampered[tampered.length - 1] ^= 0x01;
  await assert.rejects(
    () => openCredential(k, { orgId: ORG_A, credentialId: CRED_1 }, { ...sealed, ciphertext: tampered }),
    EnvelopeError,
  );
});

test("the IV is 96-bit and never repeats across seals", async () => {
  const k = ring();
  const seen = new Set<string>();
  for (let i = 0; i < 200; i++) {
    const s = await sealCredential(k, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
    assert.equal(s.iv.length, 12);
    const hex = Array.from(s.iv, (b) => b.toString(16).padStart(2, "0")).join("");
    assert.ok(!seen.has(hex), "IV reuse under one key would be catastrophic for GCM");
    seen.add(hex);
  }
});

test("the same plaintext seals to different ciphertexts", async () => {
  const k = ring();
  const a = await sealCredential(k, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  const b = await sealCredential(k, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  assert.notDeepEqual(a.ciphertext, b.ciphertext);
});

test("rotation: a v1 record still opens while v1 stays in the keyring", async () => {
  const k = ring();
  const old = await sealCredential(k, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  const fresh = await sealCredential(k, 2, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  assert.equal(await openCredential(k, { orgId: ORG_A, credentialId: CRED_1 }, old), FAKE_KEY);
  assert.equal(await openCredential(k, { orgId: ORG_A, credentialId: CRED_1 }, fresh), FAKE_KEY);
});

test("retiring a key version makes its records unopenable, with a clear error", async () => {
  const full = ring();
  const old = await sealCredential(full, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY);
  const retired: MasterKeyring = new Map([[2, new Uint8Array(32).fill(9)]]);
  await assert.rejects(
    () => openCredential(retired, { orgId: ORG_A, credentialId: CRED_1 }, old),
    /no master key for version 1/,
  );
});

test("the mask reveals at most the last 4 characters", async () => {
  assert.equal(maskSecret(FAKE_KEY), "AIza…abcd");
  assert.equal(maskSecret("short"), "…", "a short secret must reveal nothing");
  const m = maskSecret(FAKE_KEY);
  assert.ok(!m.includes(FAKE_KEY.slice(4, -4)), "the mask must not contain the middle");
});

test("an empty credential is refused", async () => {
  await assert.rejects(
    () => sealCredential(ring(), 1, { orgId: ORG_A, credentialId: CRED_1 }, ""),
    EnvelopeError,
  );
});

test("a malformed org id is refused rather than silently salted", async () => {
  await assert.rejects(
    () => sealCredential(ring(), 1, { orgId: "not-a-uuid", credentialId: CRED_1 }, FAKE_KEY),
    EnvelopeError,
  );
});

test("a wrong-length master key is refused", async () => {
  const bad: MasterKeyring = new Map([[1, new Uint8Array(16).fill(1)]]);
  await assert.rejects(
    () => sealCredential(bad, 1, { orgId: ORG_A, credentialId: CRED_1 }, FAKE_KEY),
    /expected 32/,
  );
});

test("keyringFromEnv reads base64 and rejects a short key", () => {
  const good = btoa(String.fromCharCode(...new Uint8Array(32).fill(5)));
  const ring1 = keyringFromEnv({ MASTER_KEY_V1: good }, [1, 2]);
  assert.equal(ring1.size, 1);
  assert.throws(
    () => keyringFromEnv({ MASTER_KEY_V1: btoa("too-short") }, [1]),
    /expected 32/,
  );
  assert.throws(() => keyringFromEnv({}, [1]), /no master key/);
});
