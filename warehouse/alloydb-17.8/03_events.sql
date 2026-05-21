-- ============================================================================
-- File: 03_events.sql
-- Target: AlloyDB for Postgres 17.8
-- Schema: warehouse
-- Purpose: Append-only event log tables. These are the source-of-truth that
--          ETL derives facts and SCD2 dimension rows from. Replay-friendly,
--          partitioned for retention, thin-spine fat-payload shape.
-- ============================================================================

SET search_path TO warehouse, public;


-- ============================================================================
-- Shared shape for all events_* tables.
-- We do NOT use table inheritance — declarative partitioning + identical
-- DDL per table is cleaner in Postgres 17. Each events_* table is its own
-- partitioned root.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- events_session_lifecycle — state transitions on sessions
-- Source: managed-agents session.state changes (queued → running → completed/...)
-- Derives: fact_session (one fact row per session.id when state reaches terminal)
-- ---------------------------------------------------------------------------

CREATE TABLE events_session_lifecycle (
    event_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ts              timestamptz NOT NULL,
    source          text NOT NULL,                       -- 'managed-agents/control-plane'
    kind            text NOT NULL,                       -- 'session.queued' | 'session.running' | 'session.completed' | ...
    session_id      uuid NOT NULL,                       -- pulled out of payload for indexing
    from_state      text,
    to_state        text NOT NULL,
    payload         jsonb NOT NULL DEFAULT '{}'::jsonb,  -- agent_id, outcomes, env_id, etc
    ingested_at     timestamptz NOT NULL DEFAULT now()
) PARTITION BY RANGE (ts);

CREATE INDEX events_session_lifecycle_session_idx
    ON events_session_lifecycle (session_id, ts);
CREATE INDEX events_session_lifecycle_kind_idx
    ON events_session_lifecycle (kind, ts);
CREATE INDEX events_session_lifecycle_payload_gin
    ON events_session_lifecycle USING gin (payload jsonb_path_ops);
CREATE INDEX events_session_lifecycle_ts_brin
    ON events_session_lifecycle USING brin (ts);

CREATE TABLE events_session_lifecycle_2026_05 PARTITION OF events_session_lifecycle
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE events_session_lifecycle_2026_06 PARTITION OF events_session_lifecycle
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');


-- ---------------------------------------------------------------------------
-- events_session_stream — every tool_call/tool_result/message/hook event
-- This is the HIGH-VOLUME stream. Partition daily, not monthly.
-- Source: managed-agents session events_and_streaming webhook
-- Derives: fact_tool_invocation (every tool_call+tool_result pair → 1 fact row)
-- ---------------------------------------------------------------------------

CREATE TABLE events_session_stream (
    event_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ts              timestamptz NOT NULL,
    source          text NOT NULL,                       -- 'managed-agents/session/<uuid>'
    kind            text NOT NULL,                       -- 'tool_call' | 'tool_result' | 'message' | 'hook' | 'permission_request' | 'permission_decision'
    session_id      uuid NOT NULL,
    turn_id         uuid,
    tool_name       text,                                -- denormalized from payload for hot filtering
    payload         jsonb NOT NULL,
    ingested_at     timestamptz NOT NULL DEFAULT now()
) PARTITION BY RANGE (ts);

CREATE INDEX events_session_stream_session_idx
    ON events_session_stream (session_id, ts);
CREATE INDEX events_session_stream_kind_idx
    ON events_session_stream (kind, ts);
CREATE INDEX events_session_stream_tool_idx
    ON events_session_stream (tool_name, ts) WHERE tool_name IS NOT NULL;
CREATE INDEX events_session_stream_payload_gin
    ON events_session_stream USING gin (payload jsonb_path_ops);
CREATE INDEX events_session_stream_ts_brin
    ON events_session_stream USING brin (ts);

-- Daily partitions for the high-volume stream
CREATE TABLE events_session_stream_20260521 PARTITION OF events_session_stream
    FOR VALUES FROM ('2026-05-21') TO ('2026-05-22');
CREATE TABLE events_session_stream_20260522 PARTITION OF events_session_stream
    FOR VALUES FROM ('2026-05-22') TO ('2026-05-23');
-- pg_cron creates the next 30 days nightly (see 05_pg_cron.sql)

COMMENT ON TABLE events_session_stream IS
  'High-volume event log — every tool_call/tool_result/message/hook fired inside any session. Daily partitions. Retention typically 30-90 days; older partitions archived to R2/GCS.';


-- ---------------------------------------------------------------------------
-- events_creator_observed — every skills.sh observation we make
-- Source: nightly poll of skills.sh/{official,community,partner}
-- Derives: fact_creator_snapshot (1 row per (creator, observation date))
--          dim_creator SCD2 (new row if scd_hash_diff differs)
-- ---------------------------------------------------------------------------

CREATE TABLE events_creator_observed (
    event_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ts              timestamptz NOT NULL,
    source          text NOT NULL,                       -- 'skills.sh/official'
    kind            text NOT NULL DEFAULT 'creator.observed',
    creator_id      text NOT NULL,                       -- github org slug
    primary_repo    text NOT NULL,
    repo_count      integer NOT NULL,
    skill_count     integer NOT NULL,
    catalog_url     text NOT NULL,
    tier            text NOT NULL,                       -- 'official' | ...
    raw_html_sha    text,                                -- sha256 of the scraped page; for audit
    payload         jsonb NOT NULL DEFAULT '{}'::jsonb,
    ingested_at     timestamptz NOT NULL DEFAULT now()
) PARTITION BY RANGE (ts);

CREATE INDEX events_creator_observed_creator_idx
    ON events_creator_observed (creator_id, ts);
CREATE INDEX events_creator_observed_tier_idx
    ON events_creator_observed (tier, ts);
CREATE INDEX events_creator_observed_ts_brin
    ON events_creator_observed USING brin (ts);

CREATE TABLE events_creator_observed_2026_05 PARTITION OF events_creator_observed
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE events_creator_observed_2026_06 PARTITION OF events_creator_observed
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');


-- ---------------------------------------------------------------------------
-- events_skill_activation — every SKILL.md load
-- Source: managed-agents skill-activation hook
-- Derives: fact_skill_activation
-- ---------------------------------------------------------------------------

CREATE TABLE events_skill_activation (
    event_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ts              timestamptz NOT NULL,
    source          text NOT NULL,                       -- 'managed-agents/session/<uuid>'
    kind            text NOT NULL DEFAULT 'skill.activated',
    session_id      uuid NOT NULL,
    skill_id        text NOT NULL,                       -- 'reveal-and-restore-worker-token'
    creator_id      text NOT NULL,                       -- 'opensubagents'
    repo_id         text NOT NULL,                       -- 'opensubagents/subagentskills'
    trigger_kind    text NOT NULL,                       -- 'auto' | 'explicit_slash' | 'tool_search'
    triggered_by_phrase text,
    payload         jsonb NOT NULL DEFAULT '{}'::jsonb,  -- references loaded, scripts invoked, etc
    ingested_at     timestamptz NOT NULL DEFAULT now()
) PARTITION BY RANGE (ts);

CREATE INDEX events_skill_activation_session_idx
    ON events_skill_activation (session_id, ts);
CREATE INDEX events_skill_activation_skill_idx
    ON events_skill_activation (skill_id, creator_id, ts);
CREATE INDEX events_skill_activation_ts_brin
    ON events_skill_activation USING brin (ts);

CREATE TABLE events_skill_activation_2026_05 PARTITION OF events_skill_activation
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE events_skill_activation_2026_06 PARTITION OF events_skill_activation
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');


-- ---------------------------------------------------------------------------
-- events_reward_hack_detected — HDCP detector firings
-- Source: HDCP runs/<id>/trajectories ingestion endpoint
-- Derives: fact_reward_hack
-- ---------------------------------------------------------------------------

CREATE TABLE events_reward_hack_detected (
    event_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ts              timestamptz NOT NULL,
    source          text NOT NULL,                       -- 'hdcp/runs/<uuid>'
    kind            text NOT NULL DEFAULT 'reward_hack.detected',
    training_run_id uuid NOT NULL,
    environment_id  uuid,
    hack_kind       text NOT NULL,                       -- enum from HDCP RewardHackKind
    severity        smallint NOT NULL,
    trajectory_ref  text,
    payload         jsonb NOT NULL,                      -- the trajectory summary
    ingested_at     timestamptz NOT NULL DEFAULT now()
) PARTITION BY RANGE (ts);

CREATE INDEX events_reward_hack_detected_run_idx
    ON events_reward_hack_detected (training_run_id, ts);
CREATE INDEX events_reward_hack_detected_kind_idx
    ON events_reward_hack_detected (hack_kind, ts);
CREATE INDEX events_reward_hack_detected_ts_brin
    ON events_reward_hack_detected USING brin (ts);

CREATE TABLE events_reward_hack_detected_2026_05 PARTITION OF events_reward_hack_detected
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE events_reward_hack_detected_2026_06 PARTITION OF events_reward_hack_detected
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');


-- ---------------------------------------------------------------------------
-- events_vendor_onboarding — every step status change
-- Source: HDCP vendor service onboarding state machine
-- Derives: fact_vendor_onboarding_step (transaction)
--          fact_vendor_onboarding_lifecycle (accumulating snapshot — update in place)
-- ---------------------------------------------------------------------------

CREATE TABLE events_vendor_onboarding (
    event_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ts              timestamptz NOT NULL,
    source          text NOT NULL,                       -- 'hdcp/vendors'
    kind            text NOT NULL,                       -- 'step.pending' | 'step.in_progress' | 'step.passed' | 'step.failed' | 'step.skipped'
    vendor_id       uuid NOT NULL,
    step_key        text NOT NULL,                       -- 'msa_signed' | 'docker_registry' | ...
    from_status     text,
    to_status       text NOT NULL,
    payload         jsonb NOT NULL DEFAULT '{}'::jsonb,  -- evidence, etc
    ingested_at     timestamptz NOT NULL DEFAULT now()
) PARTITION BY RANGE (ts);

CREATE INDEX events_vendor_onboarding_vendor_idx
    ON events_vendor_onboarding (vendor_id, ts);
CREATE INDEX events_vendor_onboarding_step_idx
    ON events_vendor_onboarding (step_key, ts);
CREATE INDEX events_vendor_onboarding_ts_brin
    ON events_vendor_onboarding USING brin (ts);

CREATE TABLE events_vendor_onboarding_2026_05 PARTITION OF events_vendor_onboarding
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE events_vendor_onboarding_2026_06 PARTITION OF events_vendor_onboarding
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');


-- ---------------------------------------------------------------------------
-- events_label_task — HDCP label_task lifecycle events
-- Source: HDCP labeling service
-- Derives: fact_label_task_event
-- ---------------------------------------------------------------------------

CREATE TABLE events_label_task (
    event_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ts              timestamptz NOT NULL,
    source          text NOT NULL,                       -- 'hdcp/labeling'
    kind            text NOT NULL,                       -- 'label_task.assigned' | '.submitted' | '.qa_completed' | '.accepted' | '.rejected'
    task_id         uuid NOT NULL,
    project_id      uuid NOT NULL,
    labeler_id      uuid,
    reviewer_id     uuid,
    from_status     text,
    to_status       text NOT NULL,
    payload         jsonb NOT NULL DEFAULT '{}'::jsonb,  -- rubric_scores, qa_outcome, etc
    ingested_at     timestamptz NOT NULL DEFAULT now()
) PARTITION BY RANGE (ts);

CREATE INDEX events_label_task_task_idx ON events_label_task (task_id, ts);
CREATE INDEX events_label_task_project_idx ON events_label_task (project_id, ts);
CREATE INDEX events_label_task_ts_brin ON events_label_task USING brin (ts);

CREATE TABLE events_label_task_2026_05 PARTITION OF events_label_task
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE events_label_task_2026_06 PARTITION OF events_label_task
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');


-- ---------------------------------------------------------------------------
-- DLQ — anything the ETL fails to derive a fact from lands here for replay
-- ---------------------------------------------------------------------------

CREATE TABLE events_dlq (
    event_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ts              timestamptz NOT NULL DEFAULT now(),
    original_table  text NOT NULL,
    original_event_id uuid NOT NULL,
    error_class     text NOT NULL,
    error_message   text,
    payload         jsonb NOT NULL,
    retry_count     smallint NOT NULL DEFAULT 0,
    resolved        boolean NOT NULL DEFAULT false,
    resolved_at     timestamptz
);

CREATE INDEX events_dlq_original_idx ON events_dlq (original_table, original_event_id);
CREATE INDEX events_dlq_unresolved_idx ON events_dlq (ts) WHERE NOT resolved;
