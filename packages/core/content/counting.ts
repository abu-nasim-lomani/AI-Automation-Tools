/**
 * The authoritative text counts for a post (docs/CONTENT_ENGINE.md §2).
 *
 * The database recomputes only the two hashes; these four counts are the Edge
 * Functions' responsibility, and `generate` and `update-post-body` MUST agree,
 * so the definitions live here in one place. Intl.Segmenter only, which exists
 * in Deno and Node — no dependency, runs in both.
 */

const BENGALI_START = 0x0980;
const BENGALI_END = 0x09ff;

const graphemeSeg = new Intl.Segmenter(undefined, { granularity: "grapheme" });

export interface PostCounts {
  grapheme_count: number;
  codepoint_count: number;
  word_count: number;
  bangla_ratio: number; // [0,1], rounded to 3 decimals (numeric(4,3))
}

/** Unicode code points, not UTF-16 units. */
export function codepointCount(body: string): number {
  return [...body].length;
}

/** Grapheme clusters — what a reader counts as one character. */
export function graphemeCount(body: string): number {
  let n = 0;
  for (const _ of graphemeSeg.segment(body)) n++;
  return n;
}

/**
 * Word-like segments for the given locale. The locale matters for scripts
 * without spaces; for Bangla it is "bn".
 */
export function wordCount(body: string, locale: string): number {
  const seg = new Intl.Segmenter(locale, { granularity: "word" });
  let n = 0;
  for (const s of seg.segment(body)) if (s.isWordLike) n++;
  return n;
}

/**
 * Bengali letter graphemes over all letter graphemes. A grapheme counts if its
 * first code point is a Unicode letter; it counts as Bengali if that code point
 * is in U+0980–U+09FF. Non-letters (space, punctuation, digits, emoji) are
 * ignored by both sides. No letters at all ⇒ 0. Rounded to 3 decimals.
 */
export function banglaRatio(body: string): number {
  let letters = 0;
  let bengali = 0;
  for (const { segment } of graphemeSeg.segment(body)) {
    const cp = segment.codePointAt(0);
    if (cp === undefined) continue;
    const first = String.fromCodePoint(cp);
    if (!/\p{L}/u.test(first)) continue;
    letters++;
    if (cp >= BENGALI_START && cp <= BENGALI_END) bengali++;
  }
  if (letters === 0) return 0;
  return Math.round((bengali / letters) * 1000) / 1000;
}

export function countPost(body: string, locale: string): PostCounts {
  return {
    grapheme_count: graphemeCount(body),
    codepoint_count: codepointCount(body),
    word_count: wordCount(body, locale),
    bangla_ratio: banglaRatio(body),
  };
}
