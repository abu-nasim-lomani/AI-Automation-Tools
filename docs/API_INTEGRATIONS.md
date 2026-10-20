# API_INTEGRATIONS.md

The Meta Graph API publishing contract and the authoritative error-classification table that
`docs/JOBS_AND_SCHEDULING.md` §9.2 and §17 A2 identified as a **mandatory blocker before publish
implementation**.

Status: **draft for approval.** Created 2026-10-20. No code, migration, or test exists.
Scope of this revision: **Meta Graph API only.** AI provider contracts are deferred — §12.

---

## 0. Marker legend

Same legend as `CLAUDE.md` §0 and `docs/JOBS_AND_SCHEDULING.md` §0:

| Marker | Meaning |
|---|---|
| `[V]` | **Verified** against official Meta documentation, with the URL and the date checked |
| `[A]` | **Assumption** — an inference, not a documented statement. Confirm before relying on it |
| `[D]` | **Decision** recorded, with rationale |
| `[?]` | **Open question** — §13 |
| `[F]` | **Frozen requirement** inherited from a frozen specification; restated, not re-litigated |
| `[P]` | **Proposal awaiting approval** — §14 |

**The distinction that matters most in this document:** a code's *documented meaning* is `[V]`.
The inference from that meaning to "therefore the post was not created" is usually `[A]`, because
Meta does not publish such a guarantee. §8 explains why this distinction is the whole substance of
the A2 blocker.

---

## 1. Purpose, and what this document does and does not settle

**Settles:** the publishing endpoint and its requirements; the ordered procedure for interpreting
a response; a classification for every error code Meta documents that can plausibly arise on the
publish path, each with its source; the special handling of error 506; the conflicts with frozen
text and the resolution each requires.

**Does not settle:** whether any HTTP status or error code *proves* a post was not created. No
official source establishes that, and §8 says so plainly rather than papering over it. The
practical consequence is that `failed` is permitted only for a narrow, explicitly justified
allow-list, and everything else routes to `needs_verification` — which is a **policy decision
(§14 P1) that needs approval**, not a fact the vendor supplies.

---

## 2. Sources consulted

Every `[V]` in this document traces to one of these. Pages were read on the dates shown; Meta
changes documentation without notice, so re-verify quarterly per `CLAUDE.md` §8.

| # | Source | Checked | What it established here |
|---|---|---|---|
| S1 | `developers.facebook.com/docs/graph-api/guides/error-handling/` | **2026-10-20** | The error-code table (1, 2, 3, 4, 10, 17, 102, 190, 200–299, 341, 368, 506, 1609005) and the authentication subcode table (458, 459, 460, 463, 464, 467, 492), each with its recommended action |
| S2 | `developers.facebook.com/docs/marketing-api/error-reference/` | **2026-10-20** | Exact titles for 1, 4, 17, 102, 190, 200; and the rule that error handling must key on **numeric codes**, because description strings may change without notice |
| S3 | `developers.facebook.com/docs/graph-api/overview/rate-limiting/` | 2026-10-20 | Page-token Business Use Case limit `4800 × engaged users / 24h`; error **80001**; errors **4**, **17**, **32**; guidance to stop calling once limited; the `X-App-Usage` and `X-Business-Use-Case-Usage` headers |
| S4 | `developers.facebook.com/docs/graph-api/reference/page/feed/` | 2026-10-20 | `POST /v26.0/{page-id}/feed`; *"Either `link` or `message` must be supplied"*; required permissions; Page access token from a user who can perform `CREATE_CONTENT` |
| S5 | `developers.facebook.com/docs/graph-api/changelog/` | 2026-10-20 | v26.0 is the current version (introduced 2026-07-29) |
| S6 | `developers.facebook.com/docs/facebook-login/guides/access-tokens/get-long-lived` | 2026-10-20 | *"Long-lived Page access token do not have an expiration date and only expire or are invalidated under certain conditions"* |

**Source that could not be read:** `developers.facebook.com/docs/facebook-login/guides/access-tokens/debugging`
returned **HTTP 404** on 2026-10-20. The subcode meanings in §6 therefore come from S1, not from a
dedicated token-debugging page. `[?]` A canonical `debug_token` reference has not been located;
see §13 Q6.

---

## 3. The publishing contract `[V]` S4, S5

| Item | Value |
|---|---|
| Endpoint | `POST https://graph.facebook.com/v26.0/{page-id}/feed` |
| Version | **v26.0**, current as of 2026-07-29 `[V]` S5 |
| Body | `message=<text>` — `[V]` *"Either `link` or `message` must be supplied"* |
| Token | A **Page access token** held by a user who can perform the `CREATE_CONTENT` task on that Page `[V]` S4 |
| Permissions | `pages_manage_posts`, `pages_read_engagement`, `pages_show_list` `[V]` S4 |
| Success response | The created post's id |
| Idempotency key | **None documented** `[V]` S4 — which is why read-back verification exists (`ARCHITECTURE.md` §3.3 `[F]`) |

`[F]` Text-only MVP: `message` only. `link` is not used, which makes error **1609005**
(link scraping) inapplicable — recorded in §7 for completeness, not as live handling.

**Read-back endpoint** (verification, `ARCHITECTURE.md` §3.3 `[F]`):
`GET /v26.0/{page-id}/published_posts?fields=id,message,created_time&since=…`, requiring
`pages_read_engagement` `[V]` S4.

---

## 4. Response-handling procedure

Ordered, and the order is load-bearing. `[P]` P2.

```
1. Transport failure (timeout, connection reset, TLS failure)
     -> needs_verification                                  [F] R4
2. HTTP 5xx, or any response that is not parseable JSON
     -> needs_verification                                  [F] R4
3. HTTP 2xx with a post id
     -> app.finalize_publish(job, id) -> published          [F] J8
4. HTTP 2xx without a parseable id
     -> needs_verification        (success is unconfirmed, not disproved)
5. A structured Graph error body: read error.code, then error.error_subcode
     -> classify by §5. Key on the NUMERIC code only.       [V] S2
6. A structured error whose code is NOT in the §5 tables
     -> needs_verification        (never failed)            [P] P1
```

`[V]` S2 states error handling must rely on numeric codes because description strings may change
without notice. **No string matching on `error.message` anywhere.**

`[A]` Step 5 assumes that receiving a *structured* Graph error body means Meta rejected the request
rather than applied it. This is the single most consequential assumption in the document and it is
**not documented by Meta**. It is why §8 keeps part of the blocker open, and why step 6 defaults to
`needs_verification`.

---

## 5. Classification

Four classes, as required. Every row names its source. Where the documented meaning supports
"not created" the row says so; where it does not, the row says `[A]` and routes conservatively.

### 5.1 Class A — Refused by Meta; **no `failed` permitted** `[K12 D-1]`

`[F]` `failed` now asserts *"no request was ever issued"* (`DATABASE.md` §5.2.1, amended by K6).
**No API error response can satisfy that**, because a response proves a request *was* issued. So
Class A no longer grants `failed` to anything. It groups the errors whose documented meaning is a
refusal of the caller or the content — all of which are **configuration faults** that pause the
org rather than content faults that fail a job.

| Code | Documented meaning `[V]` S1 | Action | Retry safe? |
|---|---|---|---|
| **506** | "Duplicate Post" — *"Change the post content, then try again. Consecutive duplicates are not allowed."* | **→ `needs_verification`, always.** See §6 | No. Retrying the identical body cannot succeed |
| **3** | "API Method" — the app lacks the required capability or permission | **Pause the org**, alert once, stop attempting. Job → `needs_verification` with a configuration-fault reason `[F]` K7 | No, until the app's permissions change |
| **10** | "API Permission Denied" — permission missing or removed; *"Handle the missing permissions"* | Pause + alert + stop; likely needs re-consent | No |
| **200–299** | "API Permission" — permission missing or removed; *"The exact meaning depends on the permission"* | Pause + alert + stop. The range is **not uniform** by Meta's own wording, so it is never treated as a single verdict | No |
| **1609005** | "Error Posting Link" — the link could not be scraped | N/A to the text-only MVP (§3) | N/A |

`[A]` For 3, 10 and 200–299 the inference "refused ⇒ not created" is strong — a permission refusal
occurring *after* a successful write has no plausible mechanism — but it remains an inference.
Meta documents the cause, never the absence of a side effect (§8.1). Pausing the org bounds the
cost: one escalation per fault instead of one per slot.

### 5.2 Class B — Volumetric throttles `[K12 D-2, D-3]`

**No automatic retry.** A vendor retry recommendation is advice for API use in general —
overwhelmingly idempotent reads — and says nothing about a non-idempotent write (§8.7). These
codes are **deferred to the next slot** and, more importantly, **avoided pre-flight** (§5.5).

| Code | Documented meaning `[V]` | Action | Auto-retry? |
|---|---|---|---|
| **4** | "API Too Many Calls" / *"Application request limit reached"* S1, S2 | Defer; avoid via §5.5 | **No** |
| **17** | "API User Too Many Calls" / *"User request limit reached"* S1, S2 | Defer; avoid via §5.5 | **No** |
| **80001** | Page-level Business Use Case limit: *"There have been too many calls to this Page account"* S3 | **Stop calling** — S3 advises that continuing extends the wait. Defer to the next slot | **No** |
| **368** | "Temporarily blocked for policy violations" — *"Wait, then retry."* S1 | Defer **and alert the owner.** Repeated 368 means the Page is being restricted — a human problem, not a retry problem | **No** |

**Moved out of this class `[K12 D-2]`:** codes **1** ("API Unknown"), **2** ("API Service") and
**341** (documented as downtime *or* throttling) are now **Class D**. Grouping them with throttles
was a category error: code 1 means the API cannot say what happened, which is the ambiguous case
wearing a client-error label. They carry the same risk as a 5xx, which `[F]` R4 already routes to
`needs_verification`.

A Class B code that cannot be deferred within the slot window routes to **`needs_verification`**,
never `failed`.

`[?]` **Error 32** appears in S3 as the Pages throttle returned when calls use a **user** access
token. Our path uses a **Page** token, whose Pages throttle is 80001, so 32 is probably unreachable
here — §13 Q3, `[K3]`. Treated as Class B if ever seen.

### 5.5 Pre-flight throttle avoidance `[K12 D-6]`

This is what makes "no automatic retry" affordable. `[V]` S3 exposes `X-App-Usage` and
`X-Business-Use-Case-Usage` on every response. Read both, store them, and when usage approaches the
ceiling **do not send at all**: the job stays `pending`, no marker is written, no request goes out,
and the slot expires to `skipped` if its window passes.

Deferring *before* sending is completely safe and needs no inference about side effects. Retrying
*after* an error is neither. `[A]` At five posts a day against `4800 × engaged users`, a throttle
should essentially never occur, which is why avoidance costs nothing and recovery is not needed.

### 5.6 The request-marker invariant `[K12 D-7]`

Stated here because the classification above depends on it. `[F]` `request_sent_at` is write-once
and trigger-enforced (`DATABASE.md` §4, §8); `request_sent_at IS NULL` is the **only** evidence
that permits an automatic requeue; and a job that has sent returns for another attempt only through
an accepted human attestation. Two things break the invariant and both are forbidden:
**transport-level HTTP retries** (`JOBS_AND_SCHEDULING.md` §6.3) and any future automatic
`needs_verification → pending` path (`[F]` R4).

### 5.3 Class C — Re-authentication required

| Code / subcode | Documented meaning `[V]` S1 | Action | Retry safe? |
|---|---|---|---|
| **190** | "Access token has expired" — *"Get a new access token."* S1; *"Invalid OAuth 2.0 Access Token"* S2 | `social_accounts.status = 'reauth_required'`, pause that org, alert. **No retry** | No |
| **102** | "API Session" — without a subcode get a new token; with one, check the subcode S1 | Same as 190 | No |
| `OAuthException` without subcode | *"The token or login status is invalid, so get a new access token"* S1 | Same as 190 | No |
| subcode **458** | "App Not Installed" — *"Reauthenticate the User."* | Re-auth | No |
| subcode **459** | "User Checkpointed" — the user must log in on Facebook's website | Re-auth, owner action required | No |
| subcode **460** | "Password Changed" — the user must log in again | Re-auth | No |
| subcode **463** | "Expired" — token expired, revoked or invalid; get a new one | Re-auth | No |
| subcode **464** | "Unconfirmed User" — must log in on Facebook to fix an issue | Re-auth, owner action | No |
| subcode **467** | "Invalid Access Token" — expired, revoked or invalid | Re-auth | No |
| subcode **492** | *"The user behind the Page access token lacks an appropriate Page role."* | Re-auth **and** re-check the `CREATE_CONTENT` task before re-enabling (§3, `[V]` S4) | No |

Subcode **492** is the most project-specific of these: it is the documented signal that the person
whose token we hold has lost their Page role, which is exactly the `CREATE_CONTENT` precondition
§3 requires. `[P]` It must set `reauth_required` and additionally clear any cached task list.

`[A]` Class C members were almost certainly not created — an unauthorised call should not write.
`[P]` Still routed to re-auth rather than `failed`, because the operator action required is
"reconnect the Page", and marking the job `failed` would imply the content was the problem.
`[?]` Whether a token can be invalidated *mid-request*, after a write — §13 Q4.

### 5.4 Class D — Ambiguous or unknown (`needs_verification`)

| Condition | Why |
|---|---|
| Transport timeout, connection failure | `[F]` R4 |
| HTTP 5xx | `[F]` R4 — a 5xx does not prove the write did not land |
| Unparseable or non-JSON body | `[F]` R4 |
| HTTP 2xx with no readable post id | Success unconfirmed, not disproved |
| **Code 1** "API Unknown" | `[K12 D-2]` The API cannot say what happened — the ambiguous case by definition |
| **Code 2** "API Service" | `[K12 D-2]` Temporary downtime could occur after the write |
| **Code 341** | `[K12 D-2]` Documented as downtime **or** throttling; the downtime half carries code-2 risk |
| **Any structured error code absent from §5.1–5.3** | The conservative default |
| Any Class B code that could not be deferred in-window | §5.2 |
| **506, in every case** | **§6** — may be evidence of prior success |

`[F]` Class D is the only route into `unresolved`, and `unresolved` is the only state that asks a
human. The cost of Class D being generous is human review; the cost of it being stingy is a
duplicate post under the owner's name. `JOBS_AND_SCHEDULING.md` §8.2 `[F]` accepts the former.

---

## 6. Error 506 "Duplicate Post" — the case that changes the design

`[V]` S1, 2026-10-20: **506 "Duplicate Post" — *"Change the post content, then try again.
Consecutive duplicates are not allowed."***

This is the most important single finding in this document, because 506's meaning is
**context-dependent in a way the frozen state machine does not model.**

Consider the ambiguous-outcome sequence the whole design is built around: attempt 1 times out, so
the job goes to `needs_verification`; read-back finds nothing; the owner resolves it
`not_published`; the job requeues; attempt 2 returns **506**.

The naive reading — "duplicate, so reject, so `failed`" — is **exactly wrong**. 506 means an
identical post already exists on the Page. If our own attempt 1 in fact landed, 506 is **positive
evidence that it did.** Marking the job `failed` would record "definitely not created" about a post
that is live on the Page, and `fb_post_id` would never be captured.

**`[K12 D-4]` The first-attempt `failed` branch is withdrawn.** An earlier revision of this section
classified 506 as `failed` when it arrived on a first attempt "with no request marker". That
condition is **unsatisfiable**: `[F]` J4 commits the marker *before* every request, so by the time
any response is read the marker for the current attempt always exists. Reinterpreting it as
`attempts == 1` would still be unsafe, for three reasons — a transport-level retry inside one
attempt (now forbidden, §5.6); an earlier job for identical content whose `posts` row was deleted,
releasing the `content_hash` constraint; or the owner's own manual post, which is indistinguishable
from the first two from the response alone.

**All 506 responses are therefore Class D.** 506 never, by itself, justifies `failed`.

| Situation | Classification |
|---|---|
| 506, any attempt, any marker state | **Class D → `needs_verification`**, then the recovery procedure below |
| 506 after the owner resolved a job `not_published` | Class D **and raise the alert severity** — the human attestation and the API disagree, so a person must look again |

### 6.1 Recovering the post ID without guessing `[K12 D-5]`

**506 carries no reference to the post it duplicated** — no id, no timestamp, no author. `[V]` S1
documents only the message and the recommended action. So correlation from the error alone is
impossible, and the only non-guessing route is a read:

1. Read `published_posts`, window anchored at the job's **first** `request_sent_at − 120s` `[F]` K5.
2. Prove coverage `[F]` K9 — the oldest post returned must predate the window start, or there must
   be no further page. Otherwise the read is a **failure, not an absence**.
3. **Exactly one text match → record that `id` as published.** The only case where an ID is
   established rather than chosen.
4. Zero matches, more than one match, or incomplete coverage → **`unresolved`**, human decides.
5. Never retry the same body: `[V]` S1 says consecutive duplicates are refused, so a retry cannot
   succeed anyway.

`[A]` "Consecutive duplicates are not allowed" is not defined precisely in S1: the window, the
comparison scope (same Page? same actor?), and whether near-identical text counts are all
undocumented. `[?]` §13 Q1.

**Interaction with our own duplicate prevention.** `DATABASE.md` §4 `[F]` enforces
`unique (org_id, content_hash)`, so *we* cannot store the same body twice in an org. 506 is
therefore expected to arise only from (a) a recovered-but-unrecorded prior attempt, which §6 now
handles, or (b) content the owner published outside this system. Neither is a bug in our dedup;
both need the handling above.

---

## 7. Codes recorded but not expected on this path

Kept so a future reader does not mistake absence for oversight: **1609005** (link scraping —
inapplicable while text-only, §3); **32** (user-token Pages throttle — §5.2, §13 Q3); the
Marketing-API-specific subcodes in S2 (1870034, 1870047, and subcode 99 of code 1), which concern
ads objects this product does not touch.

---

## 8. What official documentation does NOT establish

This section is the honest core of the A2 blocker, and it is why A2 is **not fully dissolved** by
this document.

1. **No documented guarantee that any status or code proves non-creation.** Neither S1 nor S2 nor
   S4 states that a given HTTP status or error code means the post was not created. S1 gives
   *causes* and *recommended actions* only. Every "therefore not created" in §5 is `[A]`.
2. **No idempotency mechanism.** `[V]` S4 documents no idempotency key, so a retry cannot be made
   safe at the protocol level. Read-back is evidence, not proof.
3. **No read-after-write consistency statement** for `published_posts`. `[A]` — which is why the
   backoff and `unresolved` exist (`JOBS_AND_SCHEDULING.md` §10 `[F]`).
4. **No `is_transient` field documented.** S1 describes `error_subcode` and does not mention
   `is_transient`. `[?]` Q2 — do not key behaviour on a field whose existence is unverified.
5. **506's semantics are under-specified** (§6, Q1).
6. **The token-debugging page 404'd** (§2), so Class C subcodes rest on S1 alone.
7. **A retry recommendation is not a side-effect guarantee.** `[K12 D-8]` S1's *"Wait and retry the
   operation"* is advice for API use in general, which is overwhelmingly idempotent **reads**. Our
   call is a non-idempotent **write** with no idempotency key (`[V]` S4). Importing Meta's
   recommended action as if it were a safety property was the specific error that produced the
   earlier Class B auto-retry policy, and it is the reason §5.2 now retries nothing.

**Consequence, resolved by decision 3 `[D]`:** the frozen instruction "4xx definite → `failed`"
could not be satisfied as written, because its premise — that a client error is definitive — is not
documented. Rather than replacing certainty with a weaker inference, the approved policy removes the
dependency entirely: **no API error response yields `failed`**, and `failed` means only "no request
was ever issued" (§14, decision 3; applied by K6 and K18).

---

## 9. Conflicts with frozen specifications

Recorded, **not resolved unilaterally.** No frozen file was modified.

| # | Frozen text | Conflict | Required resolution |
|---|---|---|---|
**All four are now RESOLVED by the approved amendment pass of 2026-10-20.** Kept as a record of
what was wrong and how it was closed; the register is in `JOBS_AND_SCHEDULING.md` §17.2.

| # | Conflict | Resolution `[D] 2026-10-20` |
|---|---|---|
| **K1** | `DATABASE.md` §5.2 and `ARCHITECTURE.md` §3.2 — *"4xx definite → `failed`"*, which would mark retryable and re-auth conditions terminally `failed` | **Closed.** Absorbed into **K6**: the edge was deleted in both files and `failed` narrowed to "no request was ever issued" |
| **K2** | `DATABASE.md` §5.2 had no edge for "the error is evidence of prior success" | **Closed by K2 as applied** — `DATABASE.md` §5.2.2 now records 506 as evidence of prior success, routed to `needs_verification` |
| **K3** | `JOBS_AND_SCHEDULING.md` cited error **32** as retryable on the publish path, but `[V]` S3 pairs 32 with **user** tokens and 80001 with **Page** tokens | **Closed by K3 as applied** — the citation is narrowed and 32 marked probably unreachable here (§13 Q3) |
| **K4** | `failed` was defined by certainty while Class A assigned it on inference | **Closed by K6/K18.** The resolution went further than this entry proposed: rather than accepting an `[A]`-grade `failed`, **no API error response yields `failed` at all** |

---

## 10. Rate limits and pacing `[V]` S3

| Item | Value |
|---|---|
| Page-token limit | `4800 × Number of Engaged Users` per 24 hours, where engaged users are those who engaged with the Page in the past 24 h |
| Throttle error | **80001** — *"There have been too many calls to this Page account"* |
| On throttle | S3 advises ceasing calls, since continuing extends the wait |
| Headers | `X-App-Usage`, `X-Business-Use-Case-Usage` — read and log on every response |

`[A]` At 5 posts/day the volume is negligible against this formula. **But** the formula multiplies
by engaged users, so a new Page with near-zero engagement may have a very low effective ceiling —
flagged in `SECURITY.md` §9 `[F]` and unquantified. `[?]` Q5.

`[P]` P5: log both usage headers on every call so the actual ceiling is observed rather than
assumed before volume increases.

---

## 11. Token lifecycle

`[V]` S6: *"Long-lived Page access token do not have an expiration date and only expire or are
invalidated under certain conditions"* — so invalidation is an **event**, not a schedule, which is
why §5.3 and the daily health check exist rather than a refresh timer.

`[P]` P6: a daily token check per connected Page; on any Class C result, set `reauth_required`,
pause that org, alert, and stop attempting (`JOBS_AND_SCHEDULING.md` §9.4 `[F]`).

`[?]` Q6: no canonical `debug_token` reference was located (§2), so the exact health-check call is
unspecified.

---

## 12. AI provider contracts — deliberately deferred

This revision covers **Meta only**. Gemini and Groq error contracts, retry semantics and quota
responses are **not** specified here and were **not** verified in this session.

Deferring rather than guessing, because: `[F]` BYOK means provider failures affect generation, not
publishing, and `ARCHITECTURE.md` ADR-008 `[F]` decouples the two through the buffer — so an
unspecified provider error contract cannot cause a bad publish. The publish path was the blocker;
generation is not.

`[?]` Q7: a provider section is needed before the generation path is built, covering at minimum
quota-exhaustion responses, retryable vs terminal errors, and the documented free-tier rate-limit
behaviour of each provider.

---

## 13. Open questions

| # | Question | Blocks |
|---|---|---|
| **Q1** | What exactly are 506's semantics — the duplicate-detection window, comparison scope, and whether near-identical text counts? | Confidence in §6's first-attempt `failed` branch |
| **Q2** | Does a Graph error body carry an `is_transient` field? S1 does not mention it | Nothing — behaviour must not key on it until verified |
| **Q3** | Can error **32** occur on a Page-token publish, or is 80001 the only Pages throttle there? | K3 precision |
| **Q4** | Can a token be invalidated mid-request, after a write has been applied? | Whether Class C is ever genuinely ambiguous |
| **Q5** | What is the effective Page-token ceiling for a Page with near-zero engaged users? | Volume planning, not the MVP |
| **Q6** | Where is the canonical `debug_token` / token-debugging reference? The expected URL 404'd | §11's health-check specification |
| **Q7** | AI provider error contracts | The generation path (§12) |
| **Q8** | Does Meta document *anywhere* a status-to-side-effect guarantee that would let `failed` rest on `[V]` rather than `[A]`? | Fully dissolving A2 rather than deciding it by policy |

---

## 14. Proposals awaiting approval

`[K12 D-9]` P1–P6 were approved on 2026-10-20 and **superseded by the 15 approved policy decisions**
applied in the same pass. Recorded here as settled, not pending:

| # | Decision `[D] 2026-10-20` |
|---|---|
| 1 | No automatic retry after **any** response is received; the only automatic requeue is the never-sent path |
| 2 | Throttles avoided pre-flight (§5.5), not recovered from afterwards |
| 3 | `failed` **only** from the never-sent path; no API error response ever yields it |
| 4 | Codes 1, 2, 341 are ambiguous, not retryable (§5.4) |
| 5 | All 506 → verification; the first-attempt `failed` branch withdrawn (§6) |
| 6 | Auth and permission errors pause the org, alert once, stop; job keeps a configuration-fault reason |
| 7 | Transport-level HTTP retries **disabled** on the publish POST — mandatory precondition |
| 8 | Verification proves its own coverage; prefix matches need corroborating `created_time`; multiple matches → `unresolved` |
| 9 | The marker invariant is written down with both breaking conditions (§5.6) |
| 10 | `not_published` guarded by a confirmation read; a match overrides the human; a failed or incomplete read refuses it |
| 11 | One attestation per job — at most two POSTs per job |
| 12 | Reclaim keyed on `request_sent_at IS NULL`, not marker staleness |
| 13 | Marker-write failure ⇒ do not send; ambiguity ⇒ the database decides |
| 14 | Attestations audited with their corroborating read and covered window |
| 15 | "At-most-once" is an application-level property, not a guarantee; duplicate publication recorded as `SECURITY.md` R-A10 |

Still genuinely open: §4's ordered procedure and the numeric-codes-only rule stand as specified;
everything in §13 remains unresolved.

---

## 15. Blocker status

`[D] 2026-10-20` **A2 is closed. D6 is decided. The publish blocker remains ACTIVE.**

`[K12 D-10]` The distinction matters: **this blocker was never going to be lifted by discovery.**
No further reading will produce a Meta guarantee that an error response means no post was created
(§8.1, §13 Q8). It was closed by *deciding* a policy that does not need that guarantee.

Resolved:

- The authoritative classification exists, sourced from S1–S6 with per-row citations.
- A2's conflict is gone from the frozen files: the "4xx definite → `failed`" rule was deleted by
  K6, `failed` was narrowed by K6/K18, the reclaim test was corrected by K16, and the overstated
  at-most-once claim by K22. All four frozen documents were reopened in one approved pass; the
  register is in `JOBS_AND_SCHEDULING.md` §17.2.
- Q1 no longer gates anything: §6 routes **all** 506s to verification, so the under-specified
  "consecutive duplicates" semantics can stay open safely.

**Still blocking implementation — one item:**

`[?]` **Zero transport-level HTTP retries are not technically verified.** Decisions 7, 11, 12 and
the §5.6 invariant all rest on one attempt meaning one request. Until that is demonstrated on the
chosen client, the publish path must not be built, and a client that cannot guarantee it must not
be used for publishing.
