---
name: saas-ui-standards
description: Postplan's UI standards — dual-script Bangla/Latin typography, design tokens, required component states, accessibility, and the pre-merge UI review checklist. Use before writing or changing any interface code, component, style, token, or user-facing copy; before a design review; and when deciding how a job state, a secret input, a counter, or an empty/error/loading state should look or read.
argument-hint: "[review <component|screen>] | [check <token|type|a11y|copy>]"
---

# Postplan UI standards

Token **values**, the component inventory and the accessibility targets live in
**`docs/DESIGN_SYSTEM.md`**. Read it before using this skill. This file carries
only what that document cannot: when to apply it, the rules that are
non-negotiable, and the checklist a change must pass.

Nothing here locks the framework. **ADR-004 is open** — Next.js versus a Vite
SPA is undecided — so write tokens as CSS custom properties and do not assume a
component library's API, including shadcn/ui.

---

## Use this skill when

- Writing or changing any component, screen, style, token, or layout.
- Choosing how a **job state** should be presented (`unresolved`, `failed`,
  `skipped`, `needs_verification`, `reauth_required`).
- Writing user-facing copy, including error, empty and disabled messages.
- Reviewing a UI change before merge.
- Deciding anything about Bangla text rendering, counting or labelling.

**Do not** use it to generate a whole interface in one pass. It guides
implementation; it does not replace it.

---

## Ten rules that are not negotiable

1. **Count graphemes, never `.length`.** `ক্ষ` is one character to a reader, and
   so is a multi-code-point emoji. `DATABASE.md` §7 is authoritative. A naive
   length is visibly wrong to a Bangla reader.
2. **`lang="bn"` on every Bangla text node** — screen-reader pronunciation and
   browser font selection both depend on it.
3. **Bangla line-height 1.75, Latin 1.5.** Mixed runs must not shift the
   baseline. That is a visual regression test, not a preference.
4. **`failed` and `unresolved` never share a visual.** `failed` means *no
   request was ever issued*; `unresolved` means *we do not know whether it
   published*. `unresolved` is a request for a human decision, not an error —
   it gets its own affordance to the resolution screen, never a red error badge.
5. **The automation status pill is on every screen**, and the emergency stop is
   two clicks from anywhere and available to **any member**, not only owners.
6. **Status is never colour-only.** Icon + text + colour, always.
7. **Secrets: masked, reveal-once, no copy affordance, never echoed in an
   error.** After the first save there is nothing to reveal — no endpoint
   returns a stored credential — so the UI must not imply there is.
8. **The post preview is always labelled a preview.** It must never be
   presentable as a real post.
9. **One focus token, applied via `:focus-visible`, never removed.**
10. **Nothing off the 4px spacing scale and nothing off the type scale.** A
    one-off `13px` is a bug.

---

## Review checklist

Run this before merging any UI change. A change that cannot pass it is not done.

**Tokens and layout**
- [ ] No hardcoded colour, spacing, radius, shadow or duration — tokens only
- [ ] Spacing on the 4px scale; type on the scale; ≤ 3 weights on screen
- [ ] Density matches the surface type (data / composer / settings)
- [ ] No horizontal scroll at 320px; 16px side gutter held

**Dual-script typography**
- [ ] `lang="bn"` present on Bangla nodes
- [ ] Bangla line-height and optical size correct
- [ ] A mixed Bangla/Latin run shows no baseline jump and no fallback seam
- [ ] Conjuncts render correctly (`ক্ষ স্ত্র ঙ্গ র‍্য`) and Bengali numerals display

**States — all eight, or it is not done**
- [ ] default, hover, active, disabled, loading, empty, error, success
- [ ] Empty state carries the next action, not an illustration
- [ ] Error says what happened and what to do next, with no upstream body in it
- [ ] Disabled explains why, adjacently
- [ ] Skeletons where layout is known; spinners only where it is not

**Accessibility**
- [ ] Text contrast ≥ 4.5:1 (≥ 3:1 large); UI components ≥ 3:1
- [ ] Fully keyboard operable, logical order, focus always visible
- [ ] Inputs labelled; errors associated via `aria-describedby`
- [ ] Status changes announced in a live region — publish, pause, reauth
- [ ] Touch targets ≥ 44×44 px
- [ ] `prefers-reduced-motion` honoured

**Copy**
- [ ] Plain, specific, no jargon, no cheerfulness about failures
- [ ] Destructive actions name the consequence before the verb
- [ ] Bangla-facing strings reviewed by a Bangla reader, not machine-translated

**Product truthfulness**
- [ ] Automation status is unambiguous on this screen
- [ ] Nothing implies a guarantee the system does not provide — publishing is
      at-most-once at the application level, **not** a guarantee against
      duplicates (`SECURITY.md` R-A10)

---

## Pointers, so nothing is duplicated here

| For | Read |
|---|---|
| Token values, type scale, colour roles, component inventory, responsive rules, a11y targets | `docs/DESIGN_SYSTEM.md` |
| Grapheme / codepoint / word counting rules | `docs/DATABASE.md` §7 |
| Job states and what each asserts | `docs/DATABASE.md` §5.2.1 |
| Role matrix — who may pause, who may connect a Page | `docs/SECURITY.md` §7.1 |
| Secret handling and masking | `docs/SECURITY.md` §5, §6 |
| Open UI decisions (font choice, licences, colour ramp, library, dark mode) | `docs/DESIGN_SYSTEM.md` §9 |
