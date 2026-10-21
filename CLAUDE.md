# CLAUDE.md — Project context and working rules

> Working name: **Postplan** (placeholder — rename on approval).
> An AI-assisted, text-only social publishing tool. Stage 1 target: one Facebook Page,
> **"You Know MD Abu Nasim"**. Designed multi-tenant from day one, operated single-tenant until
> Meta Advanced Access is granted.

**Status: specifications complete. M1 (data layer) is implemented and applied to the hosted
development project** `[V] 2026-10-22` — five forward-only migrations, envelope encryption, and a
107-assertion security suite that runs in CI on every change. No job engine, no UI, no Meta call.
Last updated: 2026-10-22.

---

## 0. Verification legend

Every factual claim in this repository's docs carries one of these markers. Do not remove them,
and do not promote a marker without re-checking the source.

| Marker | Meaning |
|---|---|
| `[V]` | **Verified** against official vendor documentation, with the date it was checked. |
| `[A]` | **Assumption** — plausible, not verified. Must be confirmed before anything depends on it. |
| `[D]` | **Decision** — a choice we made. Has a recorded rationale and a revisit trigger. |
| `[?]` | **Open question** — blocks something. Listed in the doc's "Open questions" section. |

Unmarked prose is narrative or instruction, not a factual claim.

---

## 1. Fixed requirements (do not silently change)

1. **Budget is strictly $0** until the project earns its first revenue. No paid hosting, no paid
   database plan, no paid AI tier, no paid domain. If a task cannot be done for $0, say so and stop.
2. **Personal Page first.** Stage 1 publishes only to the owner's own Page. No customer onboarding.
3. **BYOK** for AI providers. The platform does not supply AI keys to other people.
4. **Official Meta Graph API only.** No browser automation, no unofficial endpoints, no engagement
   manipulation.
5. **Text-only MVP.** No image generation.
6. **Central Supabase**, multi-tenant with database-enforced isolation. We never ask a customer for
   their own Supabase service-role key.
7. **EU/UK is a future consideration.** Never assume an unpaid AI tier is eligible for EU/UK users
   (see §4).
8. **No secrets in this repository**, in client bundles, in logs, or in chat.

Conflicts between a requirement and feasibility, vendor terms, or security must be raised
explicitly, with alternatives — never resolved by quietly dropping the requirement.

---

## 2. Hard rules (non-negotiable, enforced by tests)

Each rule exists because its failure mode is expensive or irreversible.

| # | Rule | Enforced by |
|---|---|---|
| R1 | **No table holding tenant data without RLS enabled and at least one policy.** No `anon` policy, ever. | SEC-01 asserts RLS, policies and cross-tenant denial on every tenant table; run in CI by `.github/workflows/tests.yml` `[V] 2026-10-22`. `[?]` The matrix-completeness check — CI failing when a tenant table has *no* entry in `docs/DATABASE.md`'s isolation matrix — is **not** implemented |
| R2 | **Secrets never reach the client.** No secret in `NEXT_PUBLIC_*`, none in an API response, none in a build artifact. APIs return masks only (`AIza…7f2c`). **No client role holds a `select` grant on a ciphertext column** — RLS filters rows, not columns, so this needs column privileges, not a policy. | CI grep over build output (SEC-04) + column-privilege suite (SEC-16) |
| R3 | **Secrets never reach logs.** All logging goes through one redaction helper with a deny-list. | Unit test on the redactor + CI grep forbidding raw error logging on provider paths |
| R4 | **Never republish on an ambiguous publish outcome.** Timeout, 5xx, or unparseable response ⇒ `needs_verification`. **No automatic transition from `needs_verification` to `pending` exists** — a clean read that finds nothing is evidence of absence, not proof, so exhausting the read-back schedule leads to `unresolved` and a human decides. A crashed worker returns to `pending` **only when no request has ever been issued for the job** (`request_sent_at IS NULL`) `[K16]` — a marker that is merely stale for the *current* attempt proves nothing about earlier attempts. `failed` means **"no request was ever issued"** `[K18]`; `unresolved` means "unknown" — never conflate them. The application issues **at most one request per job**, plus at most one more after a guarded human attestation of absence. That is an **application-level limit, not a guarantee against duplicate publication** `[K22]` — see `docs/SECURITY.md` R-A10. | Fault-injection suite (SEC-05), crash classification (SEC-18), human resolution (SEC-24), blocking in CI |
| R5 | **The service-role key lives only in server-side job runtimes.** Never in the browser, never in a client-callable route, never in CI logs. | Code review + secret scanning |
| R6 | **Long work never runs in a request handler.** Generation and publishing run on the job clock. Request handlers may only enqueue and read. | Architecture review |
| R7 | **Plaintext credentials are never stored.** AI keys and Page tokens are encrypted with app-layer AES-256-GCM before they reach Postgres. | `pg_dump` grep test |
| R8 | **No fabrication in generated content.** Prompts forbid invented facts, statistics, quotations, news, and first-person experience; a critic pass rejects violations. | Content eval harness |
| R9 | **The kill switch is checked first** by **every** job that makes an outbound request, immediately before the request — generation, publishing, **verification/read-back**, and token health checks alike. No job is exempt because its call is "only a read". `kill_switch` stops all outbound traffic; `paused` stops publishing and generation but lets verification keep reconciling. | SEC-09 asserts zero outbound calls per job type while the switch is on (`docs/DATABASE.md` §11.7) |
| R10 | **Every migration is forward-only and in version control.** No ad-hoc schema change in the Supabase dashboard. | Migration policy in `docs/DATABASE.md` |
| R11 | **Owner-only actions are enforced in the database, not the UI.** Connecting a Page, changing credentials, editing the schedule, and changing membership require `app.has_role(org_id,'owner')`. A role column that no policy reads is decoration. The one deliberate exception is the emergency stop, available to any member. | Role matrix in `docs/SECURITY.md` §7.1; test suite SEC-22 in `docs/DATABASE.md` §11.3; run in CI `[V] 2026-10-22` |
| R12 | **Every tenant foreign key carries `org_id`.** Single-column references constrain existence, not ownership, and the service role bypasses RLS entirely. | Composite FKs in `docs/DATABASE.md` §4.1; test suite SEC-17 §11.2; run in CI `[V] 2026-10-22` |

---

## 3. Architecture in one page

Detail lives in `docs/ARCHITECTURE.md`. The short version:

```
UI (disposable)        Next.js / React / TS / Tailwind / shadcn-ui
                       Holds NO secrets. Enqueues and reads only.
      |
CORE (permanent)       Supabase: Postgres + RLS + Auth
      |                pg_cron  ->  Edge Functions (generate, publish, verify, health)
      |                Edge Functions hold the only decryption keys
      +--> AI provider (BYOK)
      +--> Meta Graph API v26.0
WATCHDOG (independent) Cloudflare Worker cron: external heartbeat + overdue-job alarm
```

**Why the layers split this way:** the job engine is the part that would hurt to migrate, so it
lives where vendor terms are friendliest; the UI host is treated as replaceable. `[D]` ADR-002,
ADR-003.

---

## 4. Stage model — what is allowed when

| Stage | Users | Meta access | Vendor-terms constraints | Cost |
|---|---|---|---|---|
| **S1 Local dev** | Owner, localhost | Standard Access `[V]` | none | $0 |
| **S2 Personal** | Owner only, own Page | Standard Access needs **no App Review and no Business Verification** `[V] 2026-10-20` | Vercel Hobby permissible *only* while non-commercial `[V]` | $0 |
| **S3 Limited pilot** | 3–5 people added as **Meta app testers** `[V]` | Still Standard Access (role-holders only) | Move off Vercel Hobby first `[D]` — a free pilot is arguably non-commercial, but do not rest a product on "arguably" | $0 |
| **S4 Commercial** | Public, paid | **Advanced Access** ⇒ App Review + Business Verification + annual Data Use Checkup `[V]` | Vercel Pro, or Cloudflare Workers Paid | $5–30/mo |

**Do not implement an S4 feature while the project is in S2.** Billing, public sign-up, and a
marketing landing page are out of scope until the stage gate is passed.

**EU/UK constraint `[V] 2026-10-20`.** Google's Gemini API terms state: *"You may use only Paid
Services when making API Clients available to users in the European Economic Area."* Consequences,
binding from the first migration:

- A provider credential row carries `tier` (`unpaid` | `paid`).
- Generation refuses to run on an `unpaid` credential for an org marked EU/UK.
- The unpaid tier also carries a disclosure duty: Google states *"Google uses the content you
  submit to the Services and any generated responses to provide, improve, and develop"*, that
  *"human reviewers may read, annotate, and process your API input and output"*, and *"Do not
  submit sensitive, confidential, or personal information to the Unpaid Services."* `[V]`
- `[?]` Whether a Bangladesh-based operator serving EU users incurs obligations beyond this needs
  real legal review before any EU launch. Not an engineering question.

---

## 5. Technology choices

| Area | Choice | Note |
|---|---|---|
| Language | TypeScript, `strict: true` | Non-negotiable; the app is schema-driven |
| UI | React + Next.js (App Router) | `[?]` If the Cloudflare/OpenNext spike shows friction, fall back to a Vite SPA — ADR-004 |
| Styling | Tailwind CSS + shadcn/ui (Radix) | Components owned as source rather than an unpatchable dependency; accessible primitives by default |
| DB / Auth | Supabase Postgres + Supabase Auth | `[V]` Free plan: 500 MB DB, 5 GB egress + 5 GB cached, 500k Edge invocations/mo, 2 active projects, **paused after 1 week of inactivity**, **no automatic backups** |
| Jobs | Supabase `pg_cron` → Edge Functions (Deno) | `[V]` Supabase Cron is built on pg_cron, supports sub-minute granularity, and can invoke an Edge Function |
| Watchdog | Cloudflare Worker cron | `[V]` Free: 100k req/day, **10 ms CPU per invocation**, **5 cron triggers per account**, 50 subrequests per invocation |
| AI | Gemini primary, Groq fallback, one adapter | `[V]` Gemini free tier exists for the Flash line; `[V]` Google publishes no free-tier RPM/TPM/RPD figures — they are visible per project in AI Studio only; `[A]` Gemini writes better Bangla than Groq's free models — to be proven by the eval harness, not assumed |
| CI | GitHub Actions — **CI/CD only** | `[V]` GitHub's terms forbid using Actions *"as part of a serverless application"* or for *"any other activity unrelated to the production, testing, deployment, or publication of the software project"*. Actions must never be the production scheduler |

---

## 6. Repository layout (planned — not yet created)

```
CLAUDE.md                 this file
docs/                     specifications (§7)
.claude/skills/           project skills — NOT YET APPROVED, do not create
supabase/migrations/      forward-only SQL
supabase/functions/       Edge Functions (Deno): generate, publish, verify, health
apps/web/                 UI
packages/core/            shared types, text counting, prompt assembly, provider adapters
workers/watchdog/         Cloudflare Worker
```

Nothing under `supabase/`, `apps/`, `packages/`, or `workers/` exists. Do not create it without
explicit approval.

---

## 7. Document map

| File | Holds | State |
|---|---|---|
| `CLAUDE.md` | Context, fixed requirements, hard rules, stage model | **written** |
| `docs/ARCHITECTURE.md` | Boundaries, data flow, ADR log, free-tier limits | **written** |
| `docs/SECURITY.md` | Threat model, crypto design, required tests | **written** |
| `docs/DATABASE.md` | Schema, RLS, state machines, isolation matrix | **written** |
| `docs/PRD.md` | User stories and done-conditions | planned |
| `docs/JOBS_AND_SCHEDULING.md` | Clocks, leases, retry, recovery, the `unresolved` escalation workflow | **written (draft).** Not yet reconciled with ADR-015 |
| `docs/CONTENT_ENGINE.md` | Prompts, counting rules, Bangla eval rubric | planned |
| `docs/API_INTEGRATIONS.md` | Meta and provider contracts, error tables | **written (draft)** |
| `docs/DESIGN_SYSTEM.md` | Tokens, dual-script typography, states, a11y | **written (draft).** Token values live here only; `.claude/skills/saas-ui-standards` points at them |
| `docs/TESTING.md` | Pyramid, fixtures, CI gates | planned |
| `docs/ROADMAP.md` | Stage gates and cost triggers | planned |

Read `CLAUDE.md` plus the document covering your task before changing code. When a document and
the code disagree, the document is wrong until someone fixes it — say so rather than coding
around it.

---

## 8. Conventions

- **SQL**: `snake_case`; every tenant table has `org_id uuid not null`; timestamps are
  `timestamptz` named `*_at`; enums are explicit Postgres types, not text plus a check constraint.
- **TypeScript**: database-generated types are the source of truth; no hand-written duplicate of a
  row type; no `any` on a data boundary.
- **Time**: store and compute in UTC, convert at the UI edge only. Default display timezone
  `Asia/Dhaka` (UTC+6, no DST — so cron maths needs no DST handling).
- **Free-tier figures** are facts with a date attached. Re-verify quarterly; vendors change them
  without notice.
- **Errors**: a user-visible error says what happened and what to do next, and never contains an
  upstream response body.
- **Commits**: imperative subject, one logical change. A merged migration is never edited.

---

## 9. Working agreements

- **Do not scaffold.** Stage 0 created documents only; implementation is approved one milestone at
  a time. M1 (data layer) is approved and done. Nothing outside an approved milestone gets built.
- **Do not add a dependency** without naming it and its purpose first.
- **Do not enable a plugin, skill, or MCP connector** without explicit approval.
- **Never request, display, or write a real credential** — API key, Page token, database URL,
  password. Examples use obviously fake placeholders such as `AIza-EXAMPLE-NOT-REAL`.
- **Never call a live external API** during Stage 0, and never publish to Facebook in any stage
  without an instruction for that specific run.
- **Report failures honestly**, including "I could not verify this."
- **Mark every factual claim** with the §0 legend.

---

## 10. The one question that gates everything

`[?]` **Does the owner have, or can the owner register, a legal business entity?**

Meta Business Verification is required for Advanced Access `[V]`, and without Advanced Access the
product can never publish to anyone else's Page — it remains a single-tenant personal tool. Every
S3 and S4 item depends on this answer. `[A]` The document list for a Bangladesh-based applicant is
unverified; Meta defers to its Business Help Center.

Remaining open questions live in `docs/ARCHITECTURE.md` §9, `docs/SECURITY.md` §12, and
`docs/DATABASE.md` §10.
