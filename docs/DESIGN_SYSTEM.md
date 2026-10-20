# DESIGN_SYSTEM.md

The normative reference for Postplan's interface: tokens, dual-script
typography, component inventory, required states, and accessibility.

Status: **draft for review.** Created 2026-10-20. No UI code exists.
Markers follow `CLAUDE.md` §0. `[P]` items need approval before they are built on.

> **Single source of truth.** Token *values* live here and nowhere else.
> `.claude/skills/saas-ui-standards/SKILL.md` carries the triggers and the review
> checklist and points here for values, deliberately duplicating nothing — two
> copies of a spacing scale is how design systems drift.

---

## 1. What this product actually looks like

Three surface types, three densities, one token set.

| Surface | Density | Why |
|---|---|---|
| **Data** — queue, logs, published history, audit | Compact | Operational scanning. Row height 36–40px, 13–14px text |
| **Composer / preview** — the post body | Comfortable | Long-form Bangla reading. Generous line-height, measured width, 16–18px text |
| **Settings / onboarding / connections** | Calm | Consequential, irreversible-feeling actions. Generous spacing, one decision per screen region |

**Direction `[D]`: light-first and institutional, not clever.** Within five
minutes this product asks a stranger to hand over Facebook publishing rights and
an API key. The visual language has to read as trustworthy and boring in the way
a bank statement is boring. No gradients beyond a single flat marketing hero, no
glassmorphism, no decorative motion, no oversized cards.

---

## 2. Typography — the part most competitors get wrong

Postplan's content is **80–90% Bangla with Latin mixed inline**. Latin UI fonts
render Bangla conjuncts badly or fall back inconsistently mid-sentence. This is
the single highest-leverage design decision in the product.

### 2.1 Stacks

| Role | Stack `[P]` |
|---|---|
| UI chrome, Latin, numerals | `Inter`, then system sans |
| Bangla content | `Noto Sans Bengali` **or** `Hind Siliguri`, then system Bengali |
| Code, ids, hashes | `ui-monospace`, `SFMono-Regular`, `Menlo`, monospace |

`[A]` All three faces are believed to be SIL Open Font License and free via
Google Fonts. **Verify the licence text before shipping** — a licence assumption
is not a licence.

`[?]` **Noto Sans Bengali vs Hind Siliguri is not yet decided.** It must be
settled by a rendering test, not preference. Required test sheet: conjuncts
`ক্ষ স্ত্র ঙ্গ র‍্য ত্ত্ব`, matras above and below the baseline, Bengali numerals
`০১২৩৪৫৬৭৮৯`, and a mixed run such as `আজকের post-টি schedule করা হয়েছে` checked
for baseline jump and for a font-fallback seam mid-word.

### 2.2 Dual-script rules `[D]`

1. **Line-height differs by script**: Bangla `1.75`, Latin `1.5`. Bangla stacks
   matras above and below the baseline; Latin leading crowds them.
2. **Bangla runs one optical step larger** than equivalent Latin text.
3. **`lang="bn"` on every Bangla text node.** Two reasons, both real: correct
   screen-reader pronunciation, and correct font selection by the browser.
4. **A mixed-script run must not shift the baseline.** This is a visual
   regression test, not an aspiration.
5. `font-display: swap`, subset to the ranges actually used. A 400KB Bengali
   webfont on a Bangladeshi mobile connection is a usability bug.

### 2.3 Scale

`12 · 14 · 16 · 18 · 24 · 30 · 38` px. Two weights in UI (400/500), a third
(600) for headings only. Never more than three on a screen.

---

## 3. Tokens

Defined as CSS custom properties on `:root`, so they work with Tailwind's
`@theme`, with plain CSS, or with any component library. **No component library
API is assumed** — ADR-004 is open (`ARCHITECTURE.md`).

### 3.1 Spacing

4px base: `4 · 8 · 12 · 16 · 24 · 32 · 48 · 64`. Nothing off-scale. A one-off
`13px` is a bug, not a refinement.

### 3.2 Colour `[P]`

Semantic, never raw. Every pairing below must be contrast-checked (§6).

| Token | Role |
|---|---|
| `--bg`, `--surface`, `--surface-raised` | Page, card, popover |
| `--border`, `--border-strong` | Hairlines; 1px, not 2 |
| `--text`, `--text-muted`, `--text-subtle` | Three levels, no more |
| `--primary`, `--primary-on` | Indigo family; the single accent |
| `--success`, `--warning`, `--danger`, `--info` + each `-on` and `-subtle` | Semantic states |
| `--focus` | One focus ring colour, used everywhere |

Dark mode: redefine the same tokens under `@media (prefers-color-scheme: dark)`
guarded so an explicit light choice wins, plus a `[data-theme="dark"]` override.
`body` always gets an explicit background.

### 3.3 Shape, elevation, motion

Radius `6 / 8 / 12`. Three elevation levels, no more. Motion `150ms` for
micro-interactions and `200ms` for surfaces, standard easing, and **every
transition honours `prefers-reduced-motion`**.

### 3.4 Focus

**One** token, a 2px ring with 2px offset, applied via `:focus-visible`. It is
never removed, never restyled per component, and must be visible on every
background including `--primary`.

---

## 4. Component inventory

Minimum set for the MVP. Each must ship all eight states in §5.

**Shell** — app frame, sidebar (collapses to a bottom tab bar under 768px), org
switcher, header, **automation status pill**, **emergency stop**.

**The status pill and emergency stop are the two most important components in
the product.** `[D]` The pill (Active / Paused / Needs attention) is present in
the header on every screen, because the one thing a user must never be uncertain
about is whether the robot is currently posting. The stop is reachable in two
clicks from anywhere, with a confirm dialog, and is available to **any member,
not just owners** — `SECURITY.md` §7.1 makes that explicit, and an emergency stop
that requires the right role is one that fails when it is needed.

**Data** — table (sort, filter, paginate), stat tile, quota meter, audit log
viewer, status badge.

**Content** — post card, **post preview**, composer with live counters, topic
editor, brand-voice editor, schedule slot editor with timezone picker, calendar
(Phase 2; degrades to an agenda list on mobile — never a month grid on a phone).

**Forms** — text field, textarea, select, switch, radio group, **secret input**,
wizard stepper.

**Feedback** — toast, inline message, confirm dialog, skeleton, empty state.

### 4.1 Components with product-specific rules

**Post preview.** Styled to resemble a Facebook post for honest fidelity, and
**always labelled as a preview**. It must never be presentable as a real post or
screenshot-able as one.

**Secret input.** Masked by default; reveals once on explicit action and never
again; **no copy affordance**; shows only the stored mask (`AIza…7f2c`) after
save; never echoes the value in an error message. `SECURITY.md` §5 forbids any
endpoint that returns a stored credential, so the UI has nothing to reveal after
the first save — the component must not imply otherwise.

**Composer counters.** Count **grapheme clusters**, per `DATABASE.md` §7 — a
conjunct like `ক্ষ` and a multi-code-point emoji each count as **one**. Show the
grapheme count against the brand voice's min/max, plus a Bangla/Latin ratio meter
against its target ± tolerance. A naive `.length` here is wrong and will be
visibly wrong to a Bangla reader.

**Job status badge.** The job machine's states mean different things and must not
share a visual. In particular `failed` means *"no request was ever issued"* while
`unresolved` means *"we do not know whether it published"* — see `DATABASE.md`
§5.2.1. `unresolved` is **not an error state**: it is a request for a human
decision, and it needs its own affordance leading to the resolution screen, not a
red error badge.

---

## 5. Required states

Every interactive component ships all eight. A component without them is not
done.

`default · hover · active/pressed · disabled · loading (skeleton, not a spinner, where layout is known) · empty · error · success`

**Rules `[D]`:**
- **Empty states carry the next action**, not an illustration. "No posts yet —
  generate your first" beats an empty box.
- **Error states say what happened and what to do next**, and never contain an
  upstream response body (`CLAUDE.md` §8).
- **Disabled controls explain why**, adjacently. A disabled Publish button with
  no reason is a support ticket.
- **Status is never colour-only.** Icon + text + colour, always (§6).

### 5.1 Product states the UI must handle

These exist because the job machine produces them, so the interface cannot omit
them:

| State | Surface |
|---|---|
| `unresolved` publish job | Dedicated resolution screen: post body, Page link, `request_sent_at`, read-back history, three outcome choices |
| `reauth_required` account | Unmissable banner; automation paused for that org until reconnected |
| Buffer empty | Warning on the dashboard; a repeated slot skip means generation or approval has stalled |
| `kill_switch` / `paused` | Reflected in the status pill within seconds, with who changed it and when |

---

## 6. Accessibility — WCAG 2.1 AA as a CI gate

| Requirement | Target |
|---|---|
| Text contrast | ≥ 4.5:1; ≥ 3:1 for large text (SC 1.4.3) |
| Non-text / UI component contrast | ≥ 3:1 (SC 1.4.11) |
| Keyboard | Every function reachable; logical order; visible focus (SC 2.1.1, 2.4.3, 2.4.7) |
| Labels and errors | Programmatic label; error associated via `aria-describedby` (SC 3.3.1, 3.3.2) |
| Name, role, value | Correct for every custom control (SC 4.1.2) |
| Status changes | Announced in an `aria-live` region — especially "post published" and "automation paused" |
| Touch targets | **44×44 px minimum** |
| Language | `lang="bn"` on Bangla nodes (§2.2) |
| Motion | `prefers-reduced-motion` honoured everywhere |

`[A]` **Caveat on the touch-target citation:** in WCAG 2.1, Target Size (2.5.5)
is Level **AAA**; WCAG 2.2 added 2.5.8 Target Size (Minimum) at AA with a 24×24
floor. We adopt **44×44 as a product standard**, which exceeds both — but verify
the success-criterion numbering against the W3C specification before using it in
any compliance claim.

---

## 7. Responsive behaviour

| Breakpoint | Behaviour |
|---|---|
| < 768px | Sidebar → bottom tab bar; tables → stacked cards; calendar → agenda list |
| 768–1024px | Sidebar collapses to icons; two-column forms become one |
| > 1024px | Full shell |

16px side gutter minimum. No horizontal page scroll at any width. The composer
caps its measure for readability rather than filling an ultrawide monitor.

---

## 8. Information architecture

`Dashboard · Content (Queue, Calendar, Drafts, Published) · Topics & Voice ·
Connections (Facebook, AI provider) · Schedule · Logs · Settings`

Org switcher top of sidebar; status pill and emergency stop in the header on
every screen.

**Core journeys:** (1) onboarding wizard — connect Facebook → pick Page → add AI
key with live validation → topics → voice and language ratio → schedule →
generate 3 samples → approve → arm automation, each step validated before the
next unlocks; (2) daily queue review — edit, approve, reject; (3) failure
recovery — banner → logs → resolve; (4) emergency stop from anywhere.

---

## 9. Open decisions

| # | Decision | Needs |
|---|---|---|
| UI-1 | Noto Sans Bengali vs Hind Siliguri | The §2.1 rendering test |
| UI-2 | Confirm all three font licences are OFL | Licence text, not assumption |
| UI-3 | Colour ramp values | A pass with real contrast numbers against §6 |
| UI-4 | Component library (shadcn/ui is a candidate in `CLAUDE.md` §5) | **Blocked on ADR-004** — do not assume an API until the framework is settled |
| UI-5 | Dark mode in the MVP, or light-only first? | Product call |
