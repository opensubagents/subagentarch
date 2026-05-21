# Kimball bus matrix — subagent warehouse

Target platform: **AlloyDB for Postgres 17.8** (or equivalent Postgres 17 with
columnar engine + pg_cron + pgvector). Assume HTAP — same cluster handles OLTP
ingest plus aggregate dashboards via the AlloyDB columnar engine.

This document is the planning artifact that comes *before* the DDL. It names
the business processes (which become fact tables), the conformed dimensions
they share, and the SCD type chosen for each dimension based on how the
real-world entity actually changes.

## Business processes → fact tables

```
Process                       Grain                                   Fact table
────────────────────────────  ─────────────────────────────────────   ──────────────────────────
Session execution             1 row per managed-agents session run    fact_session
Tool invocation               1 row per tool call inside a session    fact_tool_invocation
Skill activation              1 row per SKILL.md loaded into context  fact_skill_activation
Token spend                   1 row per turn (assistant message)      fact_token_spend
Catalog snapshot              1 row per (creator, snapshot date)      fact_creator_snapshot   ← periodic snapshot
Reward-hack alert             1 row per detector firing               fact_reward_hack
Vendor onboarding event       1 row per step status transition        fact_vendor_onboarding_step
Label-task lifecycle          1 row per status transition             fact_label_task_event
```

Of these, `fact_creator_snapshot` is a Kimball **periodic snapshot** fact —
we capture the state of every creator on every observation day, even if
nothing changed. The other seven are **transaction** facts — one row per
real-world event.

There is also one **accumulating snapshot** fact in the design:
`fact_vendor_onboarding_lifecycle` — one row per vendor, columns for each
milestone date (msa_signed_at, docker_provisioned_at, token_issued_at,
env_smoke_passed_at, activated_at). It coexists with the transaction fact
`fact_vendor_onboarding_step` and gives fast queries on "how long did
onboarding take per vendor".

## Conformed dimensions and their SCD types

```
Dimension              SCD type   Why
─────────────────────  ────────   ────────────────────────────────────────────────────────────
dim_date               0          immutable calendar; never changes
dim_user               1          display_name overwrites are fine; no audit need
dim_model              1          a model release is a new row; "claude-opus-4-7" never mutates
dim_tool               3          tool categories shift rarely; current + previous as columns
dim_creator            2          creator counts grow daily; need point-in-time queries
dim_skill              2          SKILL.md description is the activation signal — needs history
dim_repo               2          repos get renamed/archived/default-branch-changed
dim_agent              2          system_prompt + tool grants change; audit requirement
dim_plugin_source      2          marketplace.json SHA pins bump nightly; need point-in-time
dim_environment        4          changes constantly; main = current (hot), history table = all
```

### Why these SCD choices in detail

**SCD Type 0 — `dim_date`.** Pure calendar. Pre-seeded for 2020-01-01 to
2099-12-31. Day_of_week, week_of_year, fiscal quarter, all the usual.

**SCD Type 1 — `dim_user`, `dim_model`.** Overwrite in place. For
`dim_user.display_name` we genuinely do not need history. For `dim_model`,
new model releases are new dimension rows (claude-opus-4-7 is a different
row from claude-opus-4-6), so no in-place updates ever happen anyway — Type 1
is the right semantic even though no value ever changes.

**SCD Type 3 — `dim_tool`.** A tool's category changes rarely (e.g. if Edit
gets reclassified from CORE to AGENTIC). We keep `category` and
`category_previous` as sibling columns, plus `category_changed_at`. We do
NOT need the full history. Type 3 fits exactly.

**SCD Type 2 — `dim_creator`, `dim_skill`, `dim_repo`, `dim_agent`,
`dim_plugin_source`.** All five share the standard Type 2 columns:
`scd_valid_from`, `scd_valid_to`, `scd_is_current`, `scd_version`. New row
written on every observed change. Surrogate key `_sk` columns join to fact
tables; natural key (`slug`, `name`, `id`) stays stable across versions so
analysts can group by it.

**SCD Type 4 — `dim_environment`.** The classic "rapidly-changing dimension"
case from Kimball. Environments get new image_digests on nearly every
training-run iteration. We split into:

- `dim_environment` — narrow, current-only, optimized for hot OLTP joins
- `dim_environment_history` — wide, full change log, one row per version

Facts that need the current state join `dim_environment` (cheap). Facts that
need point-in-time historical state join `dim_environment_history` (slower
but complete). Best of both worlds.

## Bus matrix

Rows = fact tables. Columns = conformed dimensions. ✓ = the fact joins to
that dimension.

```
                                  dim_date  user  model  tool  creator  skill  repo  agent  source  env  env_hist
fact_session                         ✓       ✓     ✓                            ✓             ✓
fact_tool_invocation                 ✓             ✓     ✓                      ✓             ✓
fact_skill_activation                ✓       ✓     ✓            ✓       ✓    ✓   ✓     ✓     ✓
fact_token_spend                     ✓       ✓     ✓                            ✓
fact_creator_snapshot                ✓                          ✓
fact_reward_hack                     ✓             ✓                            ✓             ✓
fact_vendor_onboarding_step          ✓
fact_vendor_onboarding_lifecycle     ✓
fact_label_task_event                ✓                                                              ✓
```

The dims with the most ✓ are the most conformed — they're the ones every
analyst will touch. `dim_date`, `dim_agent`, `dim_environment` are doing
the heavy lifting; they get the strongest SCD treatment and the best
indexes.

## Event tables (Kimball "event_*")

In Kimball, transaction fact tables already capture events. The `events_*`
tables in this design serve a different role: they are the **append-only
source-of-truth log** that the transaction facts are derived from. They
exist for replay, audit, and CDC, not for analyst queries.

```
events_session_lifecycle     state transitions on sessions      → derives fact_session
events_session_stream        every tool_call/result/message     → derives fact_tool_invocation
events_creator_observed      every skills.sh poll observation   → derives fact_creator_snapshot + SCD2 dim_creator
events_skill_activation      every SKILL.md load into context   → derives fact_skill_activation
events_reward_hack_detected  every classifier firing            → derives fact_reward_hack
events_vendor_onboarding     every step status change           → derives fact_vendor_onboarding_step + accumulating fact
events_label_task            every label task state change      → derives fact_label_task_event
```

All `events_*` tables share the same shape:
`(event_id uuid pk, ts timestamptz, source text, kind text, payload jsonb,
ingested_at timestamptz)`. The payload jsonb is where domain-specific data
lives. The pattern is "thin spine, fat payload" — the spine is queryable by
time and kind without unpacking the jsonb, and the payload is unpacked by
the ETL that derives facts and SCD2 rows downstream.

Partitioning: `events_session_stream` is the high-volume one — partitioned
by RANGE on `ts` with daily partitions, pg_cron managing creation and
retention. The others use monthly partitioning.

## What we exploit from AlloyDB 17.8 specifically

- **Columnar engine** marked on `fact_session`, `fact_tool_invocation`,
  `fact_skill_activation`, `fact_token_spend`, and
  `fact_creator_snapshot` — the five aggregate-heavy facts. Row store for
  everything else.
- **`MERGE ... RETURNING`** (Postgres 17 feature) for SCD2 upserts —
  cleaner than the classic two-step UPDATE-then-INSERT.
- **BRIN indexes** on every fact's `event_ts` column — fact tables are
  inserted in time order, so BRIN gives huge index size savings.
- **Generated columns** for derived measures (duration_ms,
  cost_estimated_usd, etc).
- **Declarative range partitioning** by month on transaction facts,
  by day on `events_session_stream`.
- **`pg_cron`** for nightly SCD2 close-out, partition creation,
  partition pruning, and `fact_creator_snapshot` capture.
- **`pgvector`** on `dim_skill.description_embedding` for similarity
  search across skills — supports "find me skills like this one" queries
  from analysts.
- **JSONB + GIN** on every payload column.
