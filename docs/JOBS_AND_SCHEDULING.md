# JOBS_AND_SCHEDULING.md

Everything between a configured schedule and a published post: which clocks run, how job rows come
into existence, how local time becomes a UTC instant, and how the system behaves when a publish
attempt crashes, times out, or cannot be resolved without a human.

Status: **draft for approval.** Created 2026-10-20, revised the same day with the D9 and amendment
decisions. No code, migration, or test exists.

Two gates are recorded here and apply to implementation, not to this document's approval:

- `[D]` **Unattended S2 publishing stays disabled** until the email alert channel is configured and
  end-to-end delivery is verified (§12.3, §16 D9).
- `[D]` **The publish path may not be implemented** until the authoritative Graph error table
  exists in `docs/API_INTEGRATIONS.md` (§9.2, §17 A2).

---

## 0. How to read the markers

This document uses the `CLAUDE.md` §0 legend, plus one addition declared here:

| Marker | Meaning |
|---|---|
| `[V]` | **Verified** against official vendor documentation, with the date checked |
| `[A]` | **Assumption** — plausible, not verified; confirm before anything depends on it |
| `[D]` | **Decision** already made and recorded, with rationale and a revisit trigger |
| `[?]` | **Open question** — listed in §16 |
| `[F]` | **Frozen requirement** inherited from a frozen specification. Restated here for readability, **not re-litigated.** If this document appears to contradict an `[F]` item, the frozen file wins and this document is wrong |
| `[P]` | **Proposal awaiting approval** — a decision this document recommends but does **not** treat as settled. Every `[P]` has an entry in §16 |

Nothing in this document resolves an open decision. Proposals are marked `[P]` and listed for
approval; the rationale is given so the choice can be judged rather than taken on trust.

---

## 1. Scope and the frozen contract

**In scope:** the clocks; materialization of `publish_jobs` rows; local-time-to-UTC resolution;
reconciliation after a schedule change; idempotency; the job lifecycle; crash recovery; retry and
failure classification; read-back verification and human escalation; pause and kill-switch
behaviour; alerting; auditability; the test plan for all of the above.

**Out of scope:** content generation quality and prompt assembly (`docs/CONTENT_ENGINE.md`, not
yet written); the Graph API and provider request/response contracts
(`docs/API_INTEGRATIONS.md`, not yet written); schema definition (`docs/DATABASE.md`, frozen);
threat model (`docs/SECURITY.md`, frozen).

### 1.1 Inherited invariants this document may not contradict

| ID | Invariant | Source |
|---|---|---|
| `[F]` R4 | No automatic transition from `needs_verification` to `pending`. Exhausting the read-back schedule leads to `unresolved` and a human decides. A crashed worker returns to `pending` **only when `request_sent_at IS NULL`** — no request has ever been issued `[K16]`. `failed` means **"no request was ever issued"** `[K6]`; `unresolved` means "unknown". The application issues at most one request per job, plus one more after a guarded attestation — an **application-level limit, not a guarantee against duplicate publication** `[K22]`, see `SECURITY.md` R-A10 | `CLAUDE.md` R4 |
| `[F]` R6 | Long work never runs in a request handler; request handlers may only enqueue and read | `CLAUDE.md` R6 |
| `[F]` R9 | Every job making an outbound request checks the kill switch immediately before the request — generation, publishing, **verification**, token health alike. `kill_switch` stops all outbound traffic; `paused` stops publish and generate but lets verification keep reconciling | `CLAUDE.md` R9, `DATABASE.md` §5.5 |
| `[F]` R12 | Every tenant foreign key carries `org_id` | `CLAUDE.md` R12 |
| `[F]` J1 | `unique (org_id, run_date, slot_id)` — a slot can hold at most one job per local date | `DATABASE.md` §4 |
| `[F]` J2 | `publish_jobs_post_unique` — a post can be attached to at most one job | `DATABASE.md` §4 |
| `[F]` J3 | Claim is atomic via `for update skip locked` with a **5-minute** lease | `DATABASE.md` §5.3 |
| `[F]` J4 | `request_sent_at` (**write-once**, the job's first send, trigger-enforced `[K21]`) and `request_sent_attempt` (overwritten each attempt, **not** the basis of any requeue decision `[K16]`) are committed in their own statement **before** the outbound request, and are **never reset by any path**. A failed or ambiguous marker write means **the request is not sent at all** `[K14]` | `DATABASE.md` §4, §5.2.3, §5.3 |
| `[F]` J5 | A `pending` job whose `scheduled_at` is more than **45 minutes** in the past becomes `skipped`, not published late | `DATABASE.md` §5.2 |
| `[F]` J6 | `verify_attempts` is capped at **4** on a backoff of roughly +1, +5, +15, +60 minutes; exhaustion routes to `unresolved` | `DATABASE.md` §5.4 |
| `[F]` J7 | `attempts >= 3 ⇒ failed` applies **only** when `request_sent_at IS NULL` `[K6]` `[K16]`. A job that has sent can never become `failed`; it ends `published` or `unresolved` | `DATABASE.md` §5.2.2 |
| `[F]` J8 | `app.finalize_publish` updates `publish_jobs` + `posts` + `usage_counters` in one transaction and is idempotent; a second call with the same `fb_post_id` is a no-op including **no second counter increment** | `DATABASE.md` §6.1 |
| `[F]` J9 | Official Meta Graph API only: `POST /v26.0/{page-id}/feed` with `message`. `[V] 2026-10-20` | `ARCHITECTURE.md` §3.2 |
| `[F]` J10 | Strict $0 budget; every clock's cost must fit documented free-tier allowances | `CLAUDE.md` §1 |

---

## 2. The clocks

Four clocks. Only one runs inside Supabase; the other three fire from Cloudflare.

That split is `ARCHITECTURE.md` ADR-017, and it is a consequence of ADR-015. Anything invoking an
Edge Function must send an `Authorization` header, `pg_net` stores that header in
`net.http_request_queue`, and PUBLIC can read that table on a grant that cannot be revoked. So the
clocks that carry a credential moved out of the database, and `pg_cron` keeps only the work that
makes no outbound call.

| Clock | Schedule | Triggered by | Invokes | Runtime | Why this cadence |
|---|---|---|---|---|---|
| **publish** (verification runs as its pre-pass) | `* * * * *` | Cloudflare Worker cron | Edge Function `publish` | Deno | One minute is the finest useful granularity: a slot's effective precision is then under a minute, well inside the `[F]` J5 45-minute window, and a dropped run self-heals on the next tick |
| **materialize** | `0 * * * *` | `pg_cron` | `app.materialize_jobs()` — **a Postgres function, not an Edge Function** | Postgres | Hourly re-runs are free and idempotent (`[F]` J1), so a missed run self-heals without a catch-up path. No network call, so ADR-015 does not reach it |
| **generate** | `30 2 * * *` (02:30 UTC ≈ 08:30 Asia/Dhaka) | Cloudflare Worker cron | Edge Function `generate` | Deno | Daily is enough to hold a 2–3 day buffer (`ARCHITECTURE.md` ADR-008). Chosen off-peak so a slow provider never collides with a publish slot |
| **health** | `*/15` | Cloudflare Worker cron | Edge Function `health` | Deno | External by design (`ARCHITECTURE.md` ADR-003): a scheduler cannot detect its own death, and the traffic also keeps the project out of inactivity pause |

(The `health` row previously had one cell fewer than the header. Rebuilt here with the trigger made
explicit for every clock.)

`[D]` **What this costs.** ADR-003 chose Cloudflare as an *independent* observer. Three of the four
clocks now live there, so that independence is largely spent: if Cloudflare stops, publishing stops
and nothing raises an alarm. The compensation is an in-database overdue detector — pure SQL on
`pg_cron`, no network — recording lateness for whoever next asks. It cannot reach out on its own.
`[?]` A genuinely independent watch over the primary clock needs a third free observer, and that is
an open decision (§16).

`[P]` **Materialization is a Postgres function rather than an Edge Function.** Rationale: it needs
no `Intl.Segmenter` and no outbound call, so it is pure SQL. Keeping it in-database removes one
runtime from the critical path, costs zero Edge invocations, and means the job queue can still be
replenished even if Edge Function deployment is broken. (§16 D11.)

### 2.1 Free-tier invocation budget `[F]` J10

| Clock | Invocations / month | Notes |
|---|---|---|
| publish (incl. verify pre-pass) | ≈ 43,200 | 60 × 24 × 30 |
| generate | 30 | |
| health | ≈ 2,880 | Driven by the Cloudflare clock, as publish and generate now are |
| materialize | **0** | `[A]` A pg_cron job calling a SQL function consumes no Edge Function invocation |
| **Total** | **≈ 46,100 of 500,000** `[V]` | ≈ 9% of the free monthly allowance |

Cloudflare side: ≈ 2,880 requests/month against `[V]` 100,000/day, using 1 of `[V]` 5 free cron
triggers, and the Worker stays trivial because of the `[V]` 10 ms CPU ceiling.

~~`[?]` Whether a pg_cron job that invokes an Edge Function over `pg_net` counts as one Edge
invocation per fire is unverified.~~ **Moot under ADR-017:** no clock reaches an Edge Function
through `pg_net` any more. The three Edge-invoking clocks fire from Cloudflare, where each fire is
plainly one invocation, and `materialize` calls a SQL function and invokes nothing.

**First lever if invocations ever tighten** (multi-tenant scale): move `publish` to `*/5` and widen
the claim window. That costs slot precision, which is why it is not the default.

---

## 3. Publish-job materialization

This is the step `docs/DATABASE.md` referenced but never specified: nothing said what creates
`publish_jobs` rows. The dangerous failure modes are already closed by `[F]` J1 and `[F]` J2, so
what follows is a procedure, not a new safety property.

### 3.1 Signature and authorization

`app.materialize_jobs(p_horizon_days int default 2)`, `security definer`,
`set search_path = ''`, `execute` revoked from `public`, `anon` and `authenticated` and granted to
the cron role only — the §6.1 pattern in the frozen schema. It takes no caller identity because no
caller other than the clock may invoke it.

### 3.2 Algorithm

For each org where `orgs.deleted_at is null`:

1. Read `org_settings.timezone`.
2. For each local date `d` from today (in that timezone) through `today + p_horizon_days`:
3. For each `schedule_slots` row for the org with `enabled = true`:
4. Resolve `scheduled_at` from `d` + `local_time` + timezone (§4).
5. Skip if `scheduled_at` is already more than 45 minutes in the past (`[F]` J5 would only
   `skip` it immediately; creating it would be noise).
6. `insert … on conflict (org_id, run_date, slot_id) do nothing` — so re-running the clock is
   free, and two concurrent runs cannot duplicate a job.
7. Attach a post (§3.4).
8. Write one `audit_logs` row per run summarising counts created and attached, not one per job.

### 3.3 Horizon and cadence

`[P]` **2-day horizon, re-materialized hourly.** The trade-off runs in both directions: a longer
horizon pre-commits more rows that a schedule change then has to reconcile (§5) and holds more
posts hostage through `[F]` J2; a shorter one couples the queue tightly to cron reliability. Two
days is the smallest horizon that survives a full day of cron outage while still letting the
content calendar show a useful week-ahead view for the slots it has materialized. (§16 D2.)

### 3.4 Post attachment — early binding

`[P]` **Attach at materialization, not at claim.** (§16 D1.)

Selection rule: the oldest `posts` row in the same org with `status = 'approved'` that is not
already attached to a job. `[F]` J2 makes the "not already attached" condition an enforced
constraint rather than a query convention, so a race cannot double-attach.

**Rationale.** Late binding — attaching at claim time — is the simpler and slightly safer option:
it always publishes the freshest approved post and has no orphan problem. It was rejected because
the content calendar is a stated product requirement, and a calendar that cannot answer "what
posts at 19:00 tomorrow?" is not a calendar. Early binding also lets the owner review and reorder
upcoming content, which is the point of an approval workflow.

**Costs accepted with early binding, and how each is handled:**

- **Orphaned jobs.** If an attached post is deleted, `publish_jobs_post_same_org` nulls `post_id`
  and leaves `org_id` intact (`DATABASE.md` §4.1). The next hourly materialization re-attaches a
  replacement. No job is lost.
- **A rejected post.** `status` moves to `rejected` while still attached. `[P]` Materialization
  detaches any job whose post is no longer `approved` and re-attaches, because publishing a
  rejected post would be worse than missing a slot.
- **An empty buffer.** If no approved post is available, the job stays `pending` with
  `post_id is null`. §7.2 defines what the publisher does with it.

### 3.5 Bootstrap

A new org gets slots from `app.create_org` (`DATABASE.md` §6.1). No special bootstrap path is
needed: the next hourly materialization picks the org up. `app.set_schedule` should trigger a
re-materialization so a schedule edit is visible immediately rather than up to an hour later
(§5).

---

## 4. Timezone handling

### 4.1 Resolution

`scheduled_at` is derived, never entered. Illustrative expression, not a migration:

```
scheduled_at := (run_date + local_time) AT TIME ZONE <org_settings.timezone>
```

The result is a `timestamptz`, i.e. an absolute instant. `[F]` Storage and all logic are UTC
(`CLAUDE.md` §8); conversion happens only at the UI edge and here.

### 4.2 `run_date` is a local date

`run_date` is **the local date in the org's timezone**, as `DATABASE.md` §4 states. This must be
computed in that timezone, not in UTC. At `[V]` UTC+6 a UTC-derived date is wrong for every slot
before 06:00 local, which would silently shift a day's jobs. `[P]` Materialization therefore
computes `today` as `(now() AT TIME ZONE org_settings.timezone)::date`.

### 4.3 DST — unused today, must be defined before it is

`[V]` `Asia/Dhaka` is UTC+6 with no DST, so the MVP never exercises this. But `org_settings.
timezone` is free-form text, so the rules must exist before the first non-Dhaka tenant rather than
being discovered by a missed post.

Two cases arise where a local wall-clock time maps to zero or two instants:

| Case | Example | `[P]` Proposed rule |
|---|---|---|
| **Gap** (spring forward) — the local time does not exist | 02:30 on a day that jumps 02:00 → 03:00 | Schedule at the **first valid instant after the gap** |
| **Overlap** (fall back) — the local time occurs twice | 01:30 on a day that repeats 01:00–02:00 | Use the **earlier** instant; `[F]` J1 ensures the slot still produces only one job for that date |

`[?]` **PostgreSQL's own resolution of non-existent and ambiguous local times is not documented
here, because it has not been verified.** It must be confirmed empirically before a non-Dhaka
tenant is onboarded, and if Postgres resolves either case differently from the rule above, the
materializer must correct it explicitly rather than inherit the default. (§16 D5.)

### 4.4 Timezone validation

`[P]` `app.update_org_settings` rejects any timezone not present in `pg_timezone_names`. `[A]` That
catalog view is assumed available; confirm at implementation. Without validation, a typo stores a
value that `AT TIME ZONE` will later fail or misinterpret, and the failure surfaces as a missed
post rather than a rejected form.

### 4.5 Windows are measured in UTC

The `[F]` J5 45-minute window, the `[F]` J3 5-minute lease, and the `[F]` J6 verification backoff
are all measured against absolute instants. No comparison in the job path uses local time.

---

## 5. Schedule changes

### 5.1 Reconciliation policy by job state

`[P]` A configuration change may only touch jobs that have provably not been acted on.

| Job state | Effect of a schedule change | Why |
|---|---|---|
| `pending`, `scheduled_at` in the future | May be deleted or re-resolved | No request was issued; nothing is lost |
| `pending`, within the 45-minute window | Left alone | It may be claimed at any second; editing it races the publisher |
| `claimed` | **Never touched** | A request may be in flight |
| `needs_verification`, `unresolved` | **Never touched** | The outcome is unknown; deleting one destroys the evidence a human needs |
| `published`, `failed`, `skipped` | **Never touched** | History |

### 5.2 Operations

| Operation | `[P]` Behaviour |
|---|---|
| Add a slot | Next materialization creates its jobs; `app.set_schedule` triggers it immediately |
| Change a slot's `local_time` | Future `pending` jobs for that slot are deleted and re-created at the new instant |
| Disable a slot (`enabled = false`) | Future `pending` jobs for that slot are deleted. Jobs in any other state are retained |
| Change the org timezone | Future `pending` jobs are re-resolved against the new timezone (§16 D4) |
| Delete a slot | **See §5.3** |

Every reconciliation writes one `audit_logs` row recording the actor, the slot, and how many jobs
were deleted or re-created — otherwise a vanished job looks like a bug.

### 5.3 Slot deletion is unsafe against the frozen schema

`publish_jobs_slot_same_org` is declared `on delete cascade` (`DATABASE.md` §4). Deleting a
`schedule_slots` row would therefore delete **every** job that ever referenced it — including
`published` rows, erasing the record of posts that really went out, and including `unresolved`
rows, destroying evidence mid-investigation.

`[P]` **Slots are soft-disabled and never hard-deleted.** The schema already carries
`schedule_slots.enabled`, and `app.set_schedule` is the only write path, so this is enforceable in
one place. The UI's "remove slot" action sets `enabled = false`.

This leaves the cascade in place as a latent hazard for anyone who later deletes a slot directly in
SQL. Changing the foreign key to `on delete restrict` would remove the hazard, but that is a change
to a frozen file and is therefore recorded as an amendment candidate (§17 A1), not applied here.

---

## 6. Idempotency

Five layers, of which the first three are frozen constraints and the last two are this document's
obligations.

| Layer | Mechanism | Prevents |
|---|---|---|
| 1 | `[F]` J1 `unique (org_id, run_date, slot_id)` | Two jobs for one slot on one date |
| 2 | `[F]` J2 `unique (post_id)` | One post attached to two jobs, i.e. the same body published twice through different slots |
| 3 | `[F]` J3 atomic claim with `for update skip locked` + lease | Two workers holding one job |
| 4 | `[P]` Materializer uses `on conflict do nothing` | A re-run, or two concurrent runs, creating duplicates |
| 5 | `[F]` J8 `app.finalize_publish` is idempotent | A retried finalize double-counting a publish |

### 6.1 Duplicate and concurrent invocation

`[A]` If pg_cron reaches an Edge Function through `pg_net`, delivery is asynchronous and a fire may
be retried or duplicated. **No job may assume single delivery.** Layers 3 and 4 already make a
duplicate `publish` run harmless; the verification pass must be written to the same standard, so
two concurrent verifications of one job cannot both advance `verify_attempts` or both call
`finalize_publish` with different ids.

`[P]` Each run also bounds its own work — a maximum number of jobs per invocation — so a backlog
cannot make one run exceed the Edge Function execution limit and die in an indeterminate state.
`[?]` That limit is unverified (`ARCHITECTURE.md` §9), so the batch size cannot be chosen yet.

### 6.2 The two-phase marker discipline `[F]` J4

The marker write and the outbound request **must not share a transaction.** If they do, a rollback
erases the evidence that a request was sent, and the crash classification in §8 silently inverts:
jobs that did reach Facebook look untried and get republished. This is the single assumption the
at-most-once *property* rests on, and it is invisible in testing unless specifically checked
(`SECURITY.md` SEC-18).

**If the marker write fails, the request is not sent.** `[K14]` A definite failure leaves the job
untouched with `request_sent_at` NULL, so the reclaim sweep correctly requeues it. An **ambiguous**
marker write (timeout) also sends nothing, and the database arbitrates on reclaim: marker present
→ `needs_verification`, absent → `pending`. `[A]` This over-reports uncertainty in a rare case —
accepted, because the alternative is a request on the wire with no marker.

### 6.3 Transport-level HTTP retries are forbidden `[K8]`

The publish POST must be issued by a client configured for **zero** automatic retries. This is
mandatory, not advisory, and it is a precondition for everything else in this document.

If the client retries internally, two POSTs leave under a single `attempts` value. The marker is
per-attempt, so it cannot distinguish them, and both the crash classification (§8.1) and the
two-request ceiling (§10.4) silently void. `[?]` Whether retries can be guaranteed off in the
chosen client is **unverified**; until it is demonstrated, the publish path must not be built.
A client that cannot guarantee it must not be used for publishing.

---

## 7. Job lifecycle

### 7.1 States

The state machine is frozen (`DATABASE.md` §5.2). This document adds only the step before it:
**how a job comes to exist**, which the frozen diagram starts after.

```
(no row) ──app.materialize_jobs()──> pending ──> [frozen state machine, DATABASE.md §5.2]
```

Who may write each state:

| State | Written by | Terminal? |
|---|---|---|
| `pending` | materializer; reclaim sweep **only when `request_sent_at IS NULL`** `[K16]`; `app.resolve_job('not_published')` **after a successful guarded confirmation read** `[K15]` | no |
| `claimed` | `publish` claim | no |
| `needs_verification` | `publish` on an ambiguous outcome; reclaim sweep on a current marker | no |
| `unresolved` | `verify` on exhaustion | until a human acts |
| `published` | `app.finalize_publish`; `app.resolve_job('published')` | yes |
| `failed` | reclaim sweep at the attempt cap **when `request_sent_at IS NULL`**, or a pre-flight refusal where nothing was sent. **Never from an API error response** `[K6]` | yes |
| `skipped` | the 45-minute sweep | yes |

### 7.2 A due job with no attached post

Early binding (§3.4) means a job can reach its slot with `post_id is null` if the buffer was empty.
`[P]` The publisher treats this as **`skipped`, not `failed`**: nothing was wrong with the system,
there was simply nothing approved to say. It raises a **buffer-empty alert** (§12), because a
recurring skip means generation or approval has stalled and that is the real problem.

Rationale for `skipped` over `failed`: `[F]` R4 reserves `failed` for "no request was ever issued" `[K6]`,
which is true here, but `failed` also implies an attempt was made. Using `skipped` keeps the
failure counters meaningful as a signal of publishing problems rather than content shortages.

---

## 8. Crash recovery

### 8.1 The reclaim sweep

Specified in `DATABASE.md` §5.3 and restated here because it is the heart of this document.
`[P]` It runs as step 0 of every `publish` invocation, before any claim, so a crashed job is
reclassified before the queue moves on.

For every `claimed` job whose `lease_until` has passed:

| Marker state | Transition | Reasoning |
|---|---|---|
| `request_sent_at IS NOT NULL` | → `needs_verification` | A request was issued at some point and its outcome is unknown. **`request_sent_attempt` is deliberately not consulted** `[K16]` — a marker stale for the *current* attempt says nothing about earlier ones |
| `request_sent_at IS NULL`, `attempts < 3` | → `pending` | Never sent. The only safe automatic requeue in the system |
| `request_sent_at IS NULL`, `attempts >= 3` | → `failed` | `[F]` J7 — never sent, retries exhausted |

**Why this is safe, as an invariant.** `attempts` rises only on a claim; a claim requires
`pending`; and `[F]` R4 forbids any automatic `needs_verification → pending`. So a job that has
already sent can return for another attempt **only** through an accepted human attestation
(§10.4). The marker alone does not carry that weight — marker, R4 and the attestation guard
together do. Two things break the invariant, and both are now forbidden: transport-level HTTP
retries (§6.2) and any future automatic `needs_verification → pending` path.

### 8.2 Where a crash can occur, and what happens

| Crash point | Outcome |
|---|---|
| After claim, before the marker commits | Lease expires → `pending`. Correct: no request was issued |
| After the marker commits, before the request leaves | Lease expires → `needs_verification` → read-back finds nothing → eventually `unresolved`. **Conservative but correct**: we cannot distinguish this from a request that arrived |
| After the request, before the response | → `needs_verification`; read-back decides |
| After a 200 response, before `finalize_publish` | → `needs_verification`; read-back finds the post and recovers the id |
| After `finalize_publish` commits, before the function returns | Already `published`. A repeat call is a no-op (`[F]` J8) |

The second row is the cost of honesty: a crash in a sub-second window produces human work. `[P]`
Accepted rather than engineered away, because the alternative — assuming the request never left —
is exactly the blind retry `[F]` R4 forbids.

---

## 9. Retries and failure classification

### 9.1 The counters, reconciled

| Control | Value | Counts | Exhaustion |
|---|---|---|---|
| `attempts` | cap **3** (policy) | Publish claims | `failed` — **only** on the never-sent path `[F]` J7 |
| `verify_attempts` | cap **4** `[F]` J6 | Read-back attempts | `unresolved` |
| Lease | **5 min** `[F]` J3 | — | Reclaim sweep |
| Slot window | **45 min** `[F]` J5 | — | `skipped` |

**Which cap wins.** `[P]` The window does. A job cannot be retried past its 45-minute window even
with attempts remaining, so the retry budget is time-bound first and count-bound second. In
practice this makes `attempts = 3` reachable only when failures are fast.

`[A]` Observation, not a conflict: the schema's `check (attempts >= 0 and attempts <= 10)` is
looser than the policy cap of 3. The constraint is a backstop against runaway increments; the
policy is the rule. Anyone reading the constraint as the policy would be wrong (§17 A3).

### 9.2 Outcome classification

**This table is provisional and must not be treated as verified.** The authoritative error
reference belongs in `docs/API_INTEGRATIONS.md`, which does not yet exist.

| Outcome | `[P]` Transition | Status |
|---|---|---|
| HTTP 200 with a post id | `app.finalize_publish` → `published` | `[V]` `POST /v26.0/{page-id}/feed` returns the created post; `message` or `link` is required |
| Timeout, connection failure | `needs_verification` | `[F]` R4 |
| HTTP 5xx | `needs_verification` | `[F]` R4 — a 5xx does not prove the write did not land |
| Unparseable body | `needs_verification` | `[F]` R4 |
| Page-level throttle, **error 80001** | Retryable, **not** `failed`. Back off; do not retry within the same run | `[V] 2026-10-20` *"There have been too many calls to this Page account"*; `[V]` limit is `4800 × engaged users / 24h`; the documentation advises ceasing calls once limited, because continuing extends the wait |
| App-level **error 4**, user-level **error 17** | Retryable, not `failed` | `[V] 2026-10-20` Graph API rate-limiting reference |
| **error 32** | Retryable if seen, but `[?]` **probably not reachable here** `[K3]`: the rate-limiting reference pairs 32 with **user** access tokens, while our publish path uses a **Page** token, whose Pages throttle is 80001 | `[V] 2026-10-20` same reference |
| Invalid or revoked token | Set the account `reauth_required`, pause that org's automation, no retry storm | `[V] 2026-10-20` code **190** "Access token has expired" and subcodes 458/459/460/463/464/467/492 — now verified; see `API_INTEGRATIONS.md` §5.3 |
| Any other structured error | → `needs_verification`. **No error response ever yields `failed`** `[K6]` | Classified by `docs/API_INTEGRATIONS.md` §5, which supersedes this provisional table |

> **§17 A2 is a MANDATORY BLOCKER before any publish implementation. `[D] 2026-10-20`**
>
> The frozen documents simplify this to "4xx definite → `failed`". That is not safe as written,
> because `[V]` 80001, 4, 17 and 32 all arrive as client errors and are retryable or require
> re-authorisation rather than meaning "the post was not created". A publisher built to the frozen
> wording can therefore mark a job `failed` — asserting "definitely not created" — when the post
> may well exist, which is the exact confusion `[F]` R4 exists to prevent.
>
> **Consequences, binding:**
> 1. The authoritative error table in `docs/API_INTEGRATIONS.md` must exist and be sourced from
>    official Meta documentation **before** the publish path is implemented.
> 2. The provisional table in §9.2 is **not final** and must not be treated as the error reference.
>    It records only what was verified on 2026-10-20 and is incomplete by construction.
> 3. The frozen rules are **not silently overridden** by this document. A1 and A3 remain amendment
>    candidates (§17); A2 was **resolved by the approved amendment pass of 2026-10-20** (K6, K16,
>    K18, K19, K22), so the frozen files no longer contain the "4xx definite → `failed`" rule.
> 4. **Resolved as of the amendment pass:** no API error response yields `failed` at all `[K6]` —
>    stricter than the earlier allow-list stopgap. `failed` now means only "no request was ever
>    issued". `docs/API_INTEGRATIONS.md` §5 is the authoritative classification.
>
> **The blocker nevertheless remains ACTIVE**, for one reason only: `[?]` **zero transport-level
> HTTP retries are not yet technically verified** (§6.3). Until they are demonstrated on the chosen
> client, the publish path must not be implemented.

### 9.3 Retry pacing

`[P]` A requeued job waits a short fixed delay — on the order of one minute, i.e. the next clock
tick — rather than being re-claimed within the same run. Rationale: an immediate retry inside one
invocation would burn the attempt budget against a condition (throttle, provider outage) that has
had no time to clear, and the 45-minute window gives ample room for three paced attempts.
`[?]` No exponential backoff is proposed for the publish path, unlike verification; whether
throttle errors specifically need a longer pause depends on the error table (§17 A2).

### 9.4 Token invalidation

`[V] 2026-10-20` Long-lived Page tokens *"do not have an expiration date and only expire or are
invalidated under certain conditions"*, so invalidation is an event, not a schedule. `[P]` On
detection: mark `social_accounts.status = 'reauth_required'`, pause that org's publishing, surface
an unmissable banner and an alert (§12), and **stop attempting** — a dead token must never drain
the queue into `failed`.

---

## 10. Verification and escalation

### 10.1 Procedure

Inherited from `ARCHITECTURE.md` §3.3 `[F]`: read
`GET /v26.0/{page-id}/published_posts?fields=id,message,created_time&since={request_sent_at − 120s}`
— anchored at the job's **first** send, not `claimed_at` `[K5]`, so a post created on an earlier
attempt falls inside the window — following `paging.next` to at most 5 pages.

**Coverage must be proven, not assumed `[K9]`.** Coverage is complete only if the oldest post
returned predates the window start, or no further page cursor was returned. If the 5-page cap is
exhausted while more pages exist and the window has not been reached, the read is classified a
**read failure, never an absence**.

Matching: exact on the normalised text; or an identical first 100 graphemes **with a
`created_time` inside the attempt window**, which counts as a match and is flagged for review
`[K10]` — the corroboration is required because `unique (org_id, content_hash)` prevents two of our
posts sharing a body but not an opening. **More than one match → `unresolved`** `[K11]`; any
selection would be a guess.

`[A]` Meta publishes no read-after-write consistency guarantee for this edge, which is the entire
reason for the backoff and for `unresolved` existing. **A complete-coverage read that finds nothing
establishes "not found at time T", never "was not created"** `[K9]`, and is never grounds for
`failed`.

### 10.2 Who runs it

`[P]` **A pre-pass inside `publish`, not its own clock.** (§16 D8.) Rationale: it guarantees
ordering — verification completes before new claims, so an `unresolved` job is never competing for
its slot — and it costs zero additional Edge invocations (§2.1). A second cron entry would need its
own overlap handling and could interleave with a claim.

Order within each `publish` invocation: (0) reclaim sweep → (1) verification pass →
(2) kill-switch/pause check → (3) claim and publish. `[P]` The kill-switch check is re-read
immediately before **each** outbound call, not once per run, so flipping the switch takes effect
within seconds rather than at the next tick (§11).

### 10.3 Read-failure budget

`[F]` J6 caps `verify_attempts` at 4 on reads that *succeed with complete coverage* and find
nothing. A read that **fails** — token, network, throttle, **or incomplete coverage `[K9]`** — must
not consume that budget, otherwise a provider outage or a busy Page manufactures `unresolved` work.
`[P]` Read failures are counted separately; the job stays in `needs_verification` and becomes
`unresolved` only when its window closes while still indeterminate.

### 10.4 Human resolution

The three outcomes of `app.resolve_job` are frozen (`DATABASE.md` §5.2.3). The operator flow this
document owns:

1. The email alert — once the §12.3 channel is configured and verified — and the dashboard badge
   both name the org, slot, and scheduled time.
2. The resolution screen shows the post body, a link to the Page, `request_sent_at`, and the
   read-back history, so the operator can check the Page themselves.
3. They choose `published` (supplying the real id), `not_published`, or `indeterminate`.
4. **`not_published` is guarded, never taken on the operator's word `[K15]`.** Choosing it triggers
   a fresh confirmation read (§10.1, full coverage required), which decides:

   | Confirmation read result | Outcome |
   |---|---|
   | Exactly one match | **Attestation overridden** → `published`, real id recorded, operator shown the post |
   | Complete coverage, no match, `attestation_count = 0` | Accepted → `pending`, `attestation_count := 1` |
   | Complete coverage, no match, `attestation_count = 1` | **Refused** — one attestation per job; only `published` or `indeterminate` remain |
   | More than one match | Refused → stays `unresolved` |
   | Read failed, or coverage incomplete | Refused → stays `unresolved`; retry later |

5. **At most two requests per job `[K13]`** — the original plus one after an accepted attestation.
   An **application-level limit, not a guarantee against duplicate publication** `[K22]`; see
   `SECURITY.md` R-A10. If the attestation was wrong, the next request should meet Meta's documented
   refusal of consecutive duplicates (506), which routes to verification and recovers the real id
   instead of creating a second post — a net, not a guarantee, since 506's window and scope are
   undefined (`API_INTEGRATIONS.md` §6).
6. `[F]` The marker is never reset; a requeue works because a fresh claim increments `attempts`.
7. `[F]` A requeued job whose window has passed becomes `skipped`, not published late.
8. The settling delay is already guaranteed: `unresolved` is reachable only after the four-step
   backoff closes, so roughly an hour has passed since the first send. `[A]` Assert that lower
   bound in a test rather than assuming it.

`[P]` An `unresolved` job older than 24 hours escalates its alert severity, because the failure
mode of this design is a silent missed post rather than a duplicate, and an unresolved job nobody
looks at is exactly that.

---

## 11. Pause and kill-switch behaviour

`[F]` R9 and `DATABASE.md` §5.5 define the scopes. Restated with the per-job obligation:

| Job | `kill_switch = true` | `paused = true` |
|---|---|---|
| `generate` | No outbound calls | No outbound calls |
| `publish` (claim + POST) | No outbound calls; no claims | No outbound calls; no claims |
| `verify` (read-back) | **No outbound calls** | **Proceeds** — reconciliation must continue |
| token health check | No outbound calls | Proceeds |
| `materialize` | `[P]` Still runs — it makes no outbound call, and stopping it would leave a hole in the queue that unpausing could not fill | Still runs |

`[P]` Checks are read immediately before each outbound call, not cached for the run.

`[F]` Consequence restated plainly: while `kill_switch` is on, jobs already in
`needs_verification` are not reconciled and drift toward `unresolved` as their windows close. That
is the correct trade — an emergency stop that keeps calling the API is not a stop.

`[P]` Both flags are writable by **any** member (`SECURITY.md` §7.1) and every transition writes an
audit row naming the actor, because "who stopped the automation and when" is the first question
asked afterwards.

---

## 12. Alerts and observability

### 12.1 `/health` contract

`[P]` The `health` function returns, with no tenant content: database reachable; counts by job
status; age of the oldest overdue `pending` job; count of `needs_verification` older than 15
minutes; count of `unresolved`; count of `reauth_required` accounts; buffer depth per org; the
backup public-key fingerprint last used. Authenticated by the shared watchdog token
(`ARCHITECTURE.md` §2 `[F]`).

### 12.2 Alert matrix

`[P]` Severities are proposed. The **channel** is decided — email, with the badge as a supplement
only — but not yet built or verified; see §12.3 for what that does and does not mean.

| Condition | Severity | Why |
|---|---|---|
| `/health` unreachable, or 2 consecutive failures | **Critical** | Supabase may be paused; everything is stopped |
| Any `unresolved` job | **High** | Needs a human; this is the designed escalation path |
| `unresolved` older than 24 h | **Critical** | A missed post nobody looked at |
| Any `reauth_required` account | **High** | That org's publishing is stopped until re-auth |
| Oldest overdue `pending` > 45 min | **High** | The clock or the function is broken |
| `needs_verification` older than 15 min | Medium | Verification is not progressing |
| Buffer depth below 1 day for any org | Medium | Generation or approval has stalled (§7.2) |
| `failed` count > 0 in 24 h | Medium | Investigate, not urgent |
| `kill_switch` or `paused` toggled | Info | Confirms an intentional action took effect |

### 12.3 Delivery channel — D9 `[D]` approved in direction, unverified in fact

`[D] 2026-10-20` **Email is the approved alert channel.** Rationale: an alert that lands nowhere is
the same as no alert, and after the R4 correction this design's characteristic failure is a *silent
missed post* rather than a duplicate — so the channel has to reach the owner without the owner
choosing to look. Email is the only push mechanism that needs no app install, no second device, and
no paid plan to receive.

`[D]` **The dashboard badge is supplementary and may never be the sole mechanism.** It is the right
surface for Medium and Info conditions and for showing current state, but it requires someone to
open the dashboard, which is precisely the assumption that fails at 03:00.

**What is approved is the direction, not a working channel.** Nothing about email has been built or
tested:

| Aspect | Status |
|---|---|
| Channel choice (email, with badge as supplement) | `[D]` Approved |
| Provider | `[?]` **Not chosen.** No provider was evaluated or its free tier verified in this session |
| Sender identity, domain, SPF/DKIM/DMARC | `[?]` Unspecified |
| Whether a genuinely $0 tier covers the expected volume | `[?]` Unverified. `[F]` J10 applies — if no free tier is usable, D9 reopens rather than quietly acquiring a cost |
| Deliverability (that a sent alert actually arrives, and is not filed as spam) | `[?]` **Unverified.** Sending is not delivery |
| Failure of the alert channel itself | `[?]` Unresolved — see below |

> **Gate `[D]`: unattended S2 publishing stays DISABLED until the email channel is configured and
> end-to-end delivery has been verified by a real test alert the owner confirms receiving.**
> Until then, S2 runs only while someone is watching: publishing may be exercised attended, with
> the dashboard checked each day. This gate exists because `unresolved` and `reauth_required` are
> designed to stop and wait for a human, and a stop nobody hears about is indistinguishable from a
> silent outage.

`[?]` **Who alerts when the alerting fails?** If the Edge Function that sends mail is itself down,
the condition that most needs reporting cannot report itself. The `/health` watchdog partially
covers this — it runs on Cloudflare, outside Supabase — but the watchdog's own notification path is
the same unverified email channel. Not resolved here; it needs an answer before the gate above can
be lifted with confidence.

`[P]` Routing proposal, pending the provider decision: **Critical** and **High** conditions send
email immediately and also raise the badge; **Medium** raises the badge and is included in a daily
digest; **Info** is badge and audit log only. Deduplicate so one stuck job cannot send hourly mail.

---

## 13. Auditability

`[P]` Events this document's jobs must write to `audit_logs`:

| Event | Key fields |
|---|---|
| `jobs.materialized` | org, run window, counts created / attached / detached — one row per run, not per job |
| `jobs.reconciled` | actor, slot, counts deleted and re-created after a schedule change |
| `job.claimed` | job, attempt number |
| `job.request_sent` | job, attempt — the audit twin of the §6.2 marker |
| `job.published` | job, post, `fb_post_id` |
| `job.failed` | job, error **code** only |
| `job.needs_verification` | job, reason class (timeout / 5xx / unparseable) |
| `job.verify_attempt` | job, attempt, read outcome (one match / multiple matches / no-match / read-failed / **coverage-incomplete** `[K9]`), window start and the oldest post seen |
| `job.unresolved` | job, `escalated_at` |
| `job.resolved.*` | actor, outcome, prior `request_sent_at` `[F]`, **and the confirmation read's result plus the window it actually covered** `[K14]` `[K15]` |
| `job.attestation_accepted` | job, actor, `attestation_count` after the change — the audit twin of the one-shot guard `[K13]` |
| `job.attestation_overridden` | job, actor, the `fb_post_id` the confirmation read found instead `[K15]` |
| `job.marker_write_failed` | job, attempt, whether the failure was definite or ambiguous, and that **no request was sent** `[K14]` |
| `job.skipped` | job, reason (window passed / no post available) |
| `automation.kill_switch`, `automation.paused` | actor, new value |
| `account.reauth_required` | account, detection source |

`[F]` Constraints inherited: rows are append-only against the application
(`DATABASE.md` §6); redaction happens before insert, so **no token, no API key, no raw upstream
response body, no post body** appears in an audit row (`CLAUDE.md` R3). `last_error` stores a code
and a safe message only.

`[F]` The audit log is included in the automated backup export, and the export fails if any
`public` base table is missing from its manifest (`SECURITY.md` §10, `DATABASE.md` §11.9).

---

## 14. Test plan

New assertions this document introduces, prefixed `JOB-` to avoid renumbering the frozen `SEC-`
series. Existing coverage is referenced, not duplicated: `[F]` SEC-05 (fault injection), SEC-09
(kill-switch scope), SEC-18 (crash classification), SEC-24 (human resolution).

| ID | Assertion | Blocking? |
|---|---|---|
| **JOB-01** | Running `materialize_jobs` twice creates no duplicates; two concurrent runs likewise | yes |
| **JOB-02** | A job is created for every enabled slot across the horizon, and none for a disabled slot | yes |
| **JOB-03** | `run_date` and `scheduled_at` are correct for `Asia/Dhaka` at a slot before 06:00 local — the case a UTC-derived date gets wrong | yes |
| **JOB-04** | DST gap and overlap resolve per §4.3 for a DST-observing timezone; a non-existent local time never produces a NULL or a silently shifted instant | yes |
| **JOB-05** | An invalid timezone string is rejected at write time, not at materialization | no |
| **JOB-06** | Changing a slot's time deletes only future `pending` jobs; `claimed`, `needs_verification`, `unresolved`, `published`, `failed` and `skipped` jobs are untouched | yes |
| **JOB-07** | Disabling a slot retains its historical jobs. **And:** deleting a slot row directly cascades and destroys them — asserted as a *known hazard* so §5.3's soft-delete rule is visibly load-bearing rather than incidental | yes |
| **JOB-08** | A post deleted after attachment nulls only `post_id`; the next materialization re-attaches; a job whose post became `rejected` is detached and re-attached | yes |
| **JOB-09** | A due job with `post_id is null` becomes `skipped`, not `failed`, and raises a buffer-empty alert | no |
| **JOB-10** | Two jobs can never reference one post (`[F]` J2) — attempted directly as the service role | yes |
| **JOB-11** | A throttle (80001) and each `[V]` retryable code do **not** produce `failed`; an unrecognised client error routes to `needs_verification`, not `failed` | yes |
| **JOB-12** | A read-back failure does not consume `verify_attempts` | yes |
| **JOB-13** | Verification runs before any claim in the same invocation | yes |
| **JOB-14** | Flipping `kill_switch` mid-run stops the **next** outbound call, not merely the next invocation | no |
| **JOB-15** | `materialize` still runs under `kill_switch` and `paused` | no |
| **JOB-16** | A batch exceeding the per-run bound leaves no job in an indeterminate state | yes |
| **JOB-17** | Every transition in §13 writes exactly one audit row, containing no token, key, body, or raw upstream response | yes |
| **JOB-18** | `/health` returns no tenant content and no secret | yes |

`[F]` The meta-rule applies: each assertion must be verified to **fail** when its control is
removed (`SECURITY.md` §1).

---

## 15. Dependencies

### 15.1 Frozen specifications (read-only)

`CLAUDE.md` R4, R6, R9, R12, §8 conventions · `ARCHITECTURE.md` §3.1–3.4, ADR-003, ADR-008,
ADR-009, ADR-014, §5 free-tier table · `DATABASE.md` §4 (`publish_jobs`, `schedule_slots`,
`org_settings`), §5.2–5.5, §6.1, §8 · `SECURITY.md` T5, T18, T19, T24, SEC-05/09/18/24, §7.1,
§10.

### 15.2 Unverified vendor items that gate parts of this design

| Item | Gates |
|---|---|
| ~~`[?]` pg_cron and pg_net available on the free plan~~ — **resolved `[V] 2026-10-22`**, both installed; see `DATABASE.md` §10 and ADR-015 for the consequence | §2 no longer gated |
| `[?]` Edge Function execution limit | §6.1 batch size |
| `[?]` Whether an Edge Function's database client supports an explicit transaction (`ARCHITECTURE.md` §9 Q10) | `[F]` J8's atomic finalize |
| `[?]` PostgreSQL 15+ | Already gates the first migration |
| `[?]` `pg_timezone_names` availability | §4.4 validation |
| `[?]` Postgres DST gap/overlap resolution | §4.3 |

### 15.3 Documents not yet written

- **`docs/API_INTEGRATIONS.md` — now written** (2026-10-20). It owns the authoritative Graph error
  classification, and §5 of it supersedes the provisional table in §9.2. One gap it leaves open:
  `[?]` error 506's duplicate-detection window and comparison scope are under-specified by Meta.
- **`docs/CONTENT_ENGINE.md`** — still unwritten. Owns buffer depth and topic selection, which feed
  §3.4 attachment and the §12 buffer alert.

---

## 16. Open decisions

| # | Decision | Status | Recommendation or recorded decision |
|---|---|---|---|
| D1 | Post attachment: early (materialization) or late (claim)? | **Open** | Early — the content calendar requires it; §3.4 lists the accepted costs |
| D2 | Horizon and cadence | **Open** | 2 days, hourly |
| D3 | Slot deletion: soft-disable, or amend the FK? | **Open** | Soft-disable now; FK amendment recorded as §17 A1 |
| D4 | Timezone change with materialized jobs | **Open** | Re-resolve future `pending` only |
| D5 | DST gap/overlap rule | **Open** | Gap → first valid instant after; overlap → earlier instant. Needs empirical confirmation of Postgres behaviour |
| D6 | Which client errors are definitely "not created"? | `[D]` **RESOLVED 2026-10-20** — none of them. No API error response yields `failed`; `failed` means only "no request was ever issued". **The publish blocker nevertheless stays ACTIVE** until zero transport-level retries are verified (§6.3) | Classification in `API_INTEGRATIONS.md` §5; applied via K6, K16, K18, K19, K22 |
| D7 | Publish retry pacing | **Open** | One clock tick; no exponential backoff until the error table exists |
| D8 | Verification as a pre-pass or its own clock | **Open** | Pre-pass — ordering guarantee, zero extra invocations |
| D9 | **Alert channel** | `[D]` **Approved in direction: email, with the dashboard badge as a supplement only.** Provider, sender setup, $0 tier suitability and deliverability all remain `[?]` | **Gate:** unattended S2 publishing stays disabled until the channel is configured and end-to-end delivery is verified by a test alert the owner confirms receiving (§12.3) |
| D10 | Materialize for `paused` orgs? | **Open** | Yes; the publisher skips them |
| D11 | Materialization as a Postgres function rather than an Edge Function | `[D]` **RESOLVED 2026-10-22** — Postgres function. ADR-015 turned this from a preference into the only option for anything that must not carry a credential | Pure SQL, zero invocations, one less runtime in the critical path |
| D12 | **Which clock runs where** | `[D]` **RESOLVED 2026-10-22** — ADR-017. `publish`, `generate` and `health` fire from Cloudflare Worker cron; `pg_cron` keeps only `materialize` and the overdue detector, neither of which makes an outbound call | Forced by ADR-015: `pg_net` stores the `Authorization` header in a table PUBLIC can read and that cannot be closed |
| D13 | **Who watches the primary clock** | **Open** — created by D12 | ADR-003's independence is largely spent now that Cloudflare runs three of the four clocks. An in-database overdue detector records lateness but cannot reach out. A genuinely independent watch needs a third free observer; none chosen |

---

## 17. Amendment candidates against frozen specifications

### 17.1 Open candidates — recorded, not applied

| # | Frozen text | Issue | Disposition `[D] 2026-10-20` |
|---|---|---|---|
| **A1** | `DATABASE.md` §4 — `publish_jobs_slot_same_org … on delete cascade` | Deleting a slot would destroy its `published` history and any `unresolved` evidence | **Retained as a candidate; no frozen change.** The §5.3 rule stands: slots are soft-disabled via `schedule_slots.enabled` and **never hard-deleted**. `app.set_schedule` is the only write path, so the rule is enforceable in one place, and JOB-07 asserts the cascade hazard explicitly. The cleaner `on delete restrict` stays on the log for the next thaw |
| **A3** | `DATABASE.md` §4 — `check (attempts >= 0 and attempts <= 10)` | The constraint is looser than the policy cap of 3 | **Observation only; no schema change.** The constraint is a runaway-increment backstop, the policy cap of 3 is the rule. Recorded so nobody reads the constraint as the policy |
| **A4** | `DATABASE.md` §5.3 — the atomic claim SQL, which does not read `org_settings` | A paused org's jobs would be claimed, `attempts` incremented while the publisher declines to send, and after three ticks the reclaim sweep would mark them `failed` — the opposite of what §5.5 says pausing does | **Applied in code, candidate on the log `[D] 2026-10-22`.** `app.claim_due_job` (migration `20261022230000`) joins `org_settings` and filters `kill_switch = false and paused = false`, so a stopped org's job is never leased. This does **not** replace R9's authoritative kill check, which still runs in the publisher immediately before the request to catch a switch thrown after a claim. The frozen §5.3 illustrative SQL is left unchanged until the next thaw; JOBS-7 asserts both that paused and killed orgs are skipped and that a live org is claimed |
| **A5** | `DATABASE.md` §8 — `posts_hash_guard`, which calls `digest()` **unqualified** and sets no `search_path` | It resolves `digest` only when the pgcrypto schema happens to be on the caller's path (`public` locally, `extensions` on Supabase). A `SECURITY DEFINER` caller with `search_path = ''` — the house pattern — makes the trigger error on any post insert | **Worked around in code `[D] 2026-10-22`.** `app.record_generation` (migration `20261022250000`) runs with a fixed `search_path = pg_catalog, public, extensions` so the trigger's unqualified `digest` resolves in both environments; the path is fixed, not caller-controlled, so it is as safe as `''`. The durable fix — the trigger pinning its own `search_path` and qualifying `digest` like the other trigger functions do — stays on the log for the next thaw. GEN-1 covers the post-insert path |

### 17.2 Applied — the approved amendment pass of 2026-10-20

A2 is closed by this pass. The owner approved 15 policy decisions and a 20-entry register, and the
frozen freeze was lifted for that single controlled pass. All four frozen documents were reopened,
because `CLAUDE.md` R4 and `SECURITY.md` T18/T5 stated the superseded marker rule in normative text.

| # | Where | What changed |
|---|---|---|
| K2 | `DATABASE.md` §5.2.2 | 506 recorded as evidence of prior success, routed to `needs_verification`, never `failed` |
| K5 | `ARCHITECTURE.md` §3.3, §10.1 here | Read-back window anchored at the job's first `request_sent_at − 120s` |
| K6 | `DATABASE.md` §5.2, §5.2.1; `ARCHITECTURE.md` §3.2 | `4xx → failed` edge deleted in both files; `failed` narrowed to "no request was ever issued" |
| K7 | `DATABASE.md` §5.2 | Configuration-fault reason code + org pause for auth/permission errors |
| K9 | `ARCHITECTURE.md` §3.3; §10.1, §10.3 here | Coverage-completeness test; incomplete coverage is a read failure, never an absence |
| K10 | `ARCHITECTURE.md` §3.3; §10.1 here | Prefix match requires a corroborating `created_time` |
| K11 | `ARCHITECTURE.md` §3.3; `DATABASE.md` §5.4 | More than one match → `unresolved` |
| K13 | `DATABASE.md` §4, §5.2.3 | `attestation_count` column, capped at 1; the two-request ceiling |
| K14 | `DATABASE.md` §5.3; §6.2 here | Marker-write failure ⇒ do not send; ambiguity ⇒ the database arbitrates |
| K15 | `DATABASE.md` §5.2.3; `ARCHITECTURE.md` §3.3.1; §10.4 here | The guarded confirmation read behind `not_published` |
| K16 | `DATABASE.md` §5.3, §4; `ARCHITECTURE.md` §3.2; §1.1, §7.1, §8.1 here | Reclaim keyed on `request_sent_at IS NULL`, never on marker staleness |
| K18 | `CLAUDE.md` R4 | Crashed-worker rule and `failed` definition corrected |
| K19 | `SECURITY.md` T18, T5 | Both control descriptions corrected |
| K20 | `SECURITY.md` §12 | **R-A10** added: duplicate publication remains possible |
| K21 | `DATABASE.md` §4, §5.3, §8 | `request_sent_at` write-once, trigger-enforced; column asymmetry documented |
| K22 | `CLAUDE.md` R4; `SECURITY.md` T5; §1.1, §10.4 here | "At-most-once" restated as an application-level limit, not a guarantee |
| K3 | §9.2 here | Error 32 narrowed — probably unreachable on the Page-token path |
| K8 | §6.3 here | Zero transport-level retries mandated |
| K12 | `API_INTEGRATIONS.md` | Classification, 506 handling, and claim corrections |
| K17 | §1.1, §6.2, §7.1, §8.1, §9.2, §10.1, §10.3, §10.4, §13, §15.3, §16, §17 here | This document reconciled throughout |

**Amendment policy, unchanged `[D]`.** Candidates accumulate in §17.1 until a frozen file is next
opened for a substantive reason — a specification reopened for a footnote is not frozen. Frozen
text remains authoritative wherever this document and a frozen file disagree (§0 `[F]`).

`[?]` **Known gap from this pass:** §14 does not yet carry assertions for the confirmation read,
the one-shot attestation, the marker-write failure rule, or coverage-completeness. Those tests were
listed as *implied* in the proposal but were **not** in the approved 20-entry register, so they
were deliberately not added here rather than expanding scope unasked.
