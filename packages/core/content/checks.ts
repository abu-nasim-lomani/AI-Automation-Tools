/**
 * The deterministic critic — Layer 1 of docs/CONTENT_ENGINE.md §6.
 *
 * Free, no AI call. Catches the mechanical violations: length, Bangla ratio,
 * hashtag count, emoji policy, excluded terms, and a wrapped/prefixed shape.
 * The semantic R8 critic (Layer 2) is a separate provider call and lives in
 * the generate orchestrator.
 */

import { type PostCounts } from "./counting.ts";
import { type BrandVoice } from "./prompt.ts";

export interface CheckFailure {
  check: "length" | "ratio" | "hashtags" | "emoji" | "exclusions" | "shape";
  detail: string;
}

export interface CheckResult {
  ok: boolean;
  failures: CheckFailure[];
}

// Count '#tag' occurrences: a '#' that starts a word (not mid-token).
function hashtagCount(body: string): number {
  const m = body.match(/(^|\s)#[^\s#]+/gu);
  return m ? m.length : 0;
}

// Approximate emoji presence via the Emoji property. Enough for a policy gate;
// not a grapheme-perfect count.
const EMOJI_RE = /\p{Extended_Pictographic}/gu;
function emojiCount(body: string): number {
  const m = body.match(EMOJI_RE);
  return m ? m.length : 0;
}

function hasExcluded(body: string, terms: string[]): string | null {
  const hay = body.toLowerCase();
  for (const t of terms) {
    const needle = t.trim().toLowerCase();
    if (needle && hay.includes(needle)) return t;
  }
  return null;
}

// A well-formed body is the post itself: not wrapped in quotes or a code fence,
// not introduced by a "Here is…" preamble.
function badShape(body: string): string | null {
  const t = body.trim();
  if (/^```/.test(t)) return "wrapped in a code fence";
  if (/^["'“”']/.test(t) && /["'“”']$/.test(t)) return "wrapped in quotes";
  if (/^(here('?s| is)|sure[,!]|certainly[,!])/i.test(t)) return "starts with a preamble";
  return null;
}

export function runDeterministicChecks(
  body: string,
  counts: PostCounts,
  voice: BrandVoice,
): CheckResult {
  const failures: CheckFailure[] = [];

  if (counts.grapheme_count < voice.min_graphemes || counts.grapheme_count > voice.max_graphemes) {
    failures.push({
      check: "length",
      detail: `${counts.grapheme_count} graphemes, want ${voice.min_graphemes}–${voice.max_graphemes}`,
    });
  }

  const lo = voice.bangla_ratio_target - voice.ratio_tolerance;
  const hi = voice.bangla_ratio_target + voice.ratio_tolerance;
  if (counts.bangla_ratio < lo || counts.bangla_ratio > hi) {
    failures.push({
      check: "ratio",
      detail: `bangla_ratio ${counts.bangla_ratio}, want ${lo.toFixed(3)}–${hi.toFixed(3)}`,
    });
  }

  const tags = hashtagCount(body);
  if (tags > voice.hashtag_max) {
    failures.push({ check: "hashtags", detail: `${tags} hashtags, max ${voice.hashtag_max}` });
  }

  const emojis = emojiCount(body);
  if (voice.emoji_pref === "none" && emojis > 0) {
    failures.push({ check: "emoji", detail: `${emojis} emoji, policy is none` });
  } else if (voice.emoji_pref === "minimal" && emojis > 2) {
    failures.push({ check: "emoji", detail: `${emojis} emoji, policy is minimal` });
  }

  const banned = hasExcluded(body, voice.exclusions);
  if (banned) failures.push({ check: "exclusions", detail: `contains excluded term: ${banned}` });

  const shape = badShape(body);
  if (shape) failures.push({ check: "shape", detail: shape });

  return { ok: failures.length === 0, failures };
}
