-- ============================================================================
-- File: 02_facts.sql
-- Target: AlloyDB for Postgres 17.8
-- Schema: warehouse
-- Purpose: Eight transaction fact tables + one accumulating snapshot,
--          range-partitioned on event_ts for hot insert + cheap pruning.
--          BRIN indexes everywhere — facts are insert-in-time-order.
-- ============================================================================

SET search_path TO warehouse, public;


-- ============================================================================
-- fact_session — one row per managed-agents Session
-- Grain: one row per session.id
-- ============================================================================

CREATE TABLE fact_session (
    session_sk           bigint GENERATED ALWAYS AS IDENTITY,
    session_id           uuid NOT NULL,
    -- Conformed dimension FKs (surrogate keys = "point-in-time accurate")
    date_sk              integer NOT NULL REFERENCES dim_date (date_sk),
    user_sk              bigint NOT NULL REFERENCES dim_user (user_sk),
    agent_sk             bigint NOT NULL REFERENCES dim_agent (agent_sk),
    model_sk             smallint NOT NULL REFERENCES dim_model (model_sk),
    environment_sk       bigint NOT NULL REFERENCES dim_environment (environment_sk),
    session_context_sk   smallint NOT NULL REFERENCES dim_session_context (session_context_sk),
    -- Degenerate dimension
    session_external_ref text,
    -- Time anchors
    event_ts             timestamptz NOT NULL,           -- session.started_at
    ended_at             timestamptz,
    -- Measures
    final_state          text NOT NULL,                  -- 'completed' | 'failed' | 'cancelled'
    duration_ms          integer
        GENERATED ALWAYS AS (
            CASE WHEN ended_at IS NULL THEN NULL
                 ELSE (EXTRACT(EPOCH FROM (ended_at - event_ts)) * 1000)::integer
            END
        ) STORED,
    outcomes_total       smallint NOT NULL DEFAULT 0,
    outcomes_passed      smallint NOT NULL DEFAULT 0,
    tool_invocations     integer NOT NULL DEFAULT 0,
    skill_activations    smallint NOT NULL DEFAULT 0,
    input_tokens_total   integer NOT NULL DEFAULT 0,
    output_tokens_total  integer NOT NULL DEFAULT 0,
    cached_tokens_total  integer NOT NULL DEFAULT 0,
    cost_estimated_usd   numeric(12,6),
    PRIMARY KEY (session_sk, event_ts)
) PARTITION BY RANGE (event_ts);

CREATE INDEX fact_session_session_idx ON fact_session (session_id);
CREATE INDEX fact_session_user_idx ON fact_session (user_sk, event_ts);
CREATE INDEX fact_session_agent_idx ON fact_session (agent_sk, event_ts);
-- BRIN: fact rows insert in time order, so BRIN gives ~1000x smaller index than btree
CREATE INDEX fact_session_event_ts_brin ON fact_session USING brin (event_ts);

COMMENT ON TABLE fact_session IS
  'Transaction fact, grain = 1 session. Range-partitioned monthly on event_ts. AlloyDB columnar engine recommended on partitions older than 30 days.';

-- Seed a couple of partitions; pg_cron creates future ones (see 05_pg_cron.sql)
CREATE TABLE fact_session_2026_05 PARTITION OF fact_session
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE fact_session_2026_06 PARTITION OF fact_session
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');


-- ============================================================================
-- fact_tool_invocation — one row per tool call inside a session
-- Grain: one row per (session, turn, tool call sequence)
-- ============================================================================

CREATE TABLE fact_tool_invocation (
    invocation_sk        bigint GENERATED ALWAYS AS IDENTITY,
    invocation_id        uuid NOT NULL,
    session_id           uuid NOT NULL,
    turn_id              uuid NOT NULL,
    -- Conformed FKs
    date_sk              integer NOT NULL REFERENCES dim_date (date_sk),
    tool_sk              integer NOT NULL REFERENCES dim_tool (tool_sk),
    agent_sk             bigint NOT NULL REFERENCES dim_agent (agent_sk),
    model_sk             smallint NOT NULL REFERENCES dim_model (model_sk),
    environment_sk       bigint NOT NULL REFERENCES dim_environment (environment_sk),
    -- Time anchors
    event_ts             timestamptz NOT NULL,
    ended_at             timestamptz,
    -- Measures
    status               text NOT NULL,                  -- 'succeeded' | 'failed' | 'timed_out' | 'cancelled'
    duration_ms          integer
        GENERATED ALWAYS AS (
            CASE WHEN ended_at IS NULL THEN NULL
                 ELSE (EXTRACT(EPOCH FROM (ended_at - event_ts)) * 1000)::integer
            END
        ) STORED,
    input_size_bytes     integer,
    output_size_bytes    integer,
    permission_decision  text,                           -- 'allow' | 'deny' | 'prompt'
    error_class          text,                           -- bucketed error category
    PRIMARY KEY (invocation_sk, event_ts)
) PARTITION BY RANGE (event_ts);

CREATE INDEX fact_tool_invocation_session_idx ON fact_tool_invocation (session_id, event_ts);
CREATE INDEX fact_tool_invocation_tool_idx ON fact_tool_invocation (tool_sk, event_ts);
CREATE INDEX fact_tool_invocation_event_ts_brin ON fact_tool_invocation USING brin (event_ts);

CREATE TABLE fact_tool_invocation_2026_05 PARTITION OF fact_tool_invocation
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE fact_tool_invocation_2026_06 PARTITION OF fact_tool_invocation
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');

COMMENT ON TABLE fact_tool_invocation IS
  'Transaction fact, grain = 1 tool call. Range-partitioned monthly. The highest-volume non-event fact.';


-- ============================================================================
-- fact_skill_activation — one row per SKILL.md load into context
-- Grain: one row per (session, agent, skill activation event)
-- ============================================================================

CREATE TABLE fact_skill_activation (
    activation_sk        bigint GENERATED ALWAYS AS IDENTITY,
    activation_id        uuid NOT NULL,
    session_id           uuid NOT NULL,
    -- Conformed FKs
    date_sk              integer NOT NULL REFERENCES dim_date (date_sk),
    skill_sk             bigint NOT NULL REFERENCES dim_skill (skill_sk),
    creator_sk           bigint NOT NULL REFERENCES dim_creator (creator_sk),
    repo_sk              bigint NOT NULL REFERENCES dim_repo (repo_sk),
    plugin_source_sk     bigint REFERENCES dim_plugin_source (plugin_source_sk),
    agent_sk             bigint NOT NULL REFERENCES dim_agent (agent_sk),
    model_sk             smallint NOT NULL REFERENCES dim_model (model_sk),
    environment_sk       bigint REFERENCES dim_environment (environment_sk),
    -- Time anchors
    event_ts             timestamptz NOT NULL,
    -- Measures
    trigger_kind         text NOT NULL,                  -- 'auto' | 'explicit_slash' | 'tool_search'
    triggered_by_phrase  text,                           -- the text that matched
    skill_body_tokens    integer NOT NULL,
    references_loaded    smallint NOT NULL DEFAULT 0,    -- count of files loaded from references/
    scripts_invoked      smallint NOT NULL DEFAULT 0,
    completed            boolean NOT NULL DEFAULT true,
    PRIMARY KEY (activation_sk, event_ts)
) PARTITION BY RANGE (event_ts);

CREATE INDEX fact_skill_activation_session_idx ON fact_skill_activation (session_id, event_ts);
CREATE INDEX fact_skill_activation_skill_idx ON fact_skill_activation (skill_sk, event_ts);
CREATE INDEX fact_skill_activation_creator_idx ON fact_skill_activation (creator_sk, event_ts);
CREATE INDEX fact_skill_activation_event_ts_brin ON fact_skill_activation USING brin (event_ts);

CREATE TABLE fact_skill_activation_2026_05 PARTITION OF fact_skill_activation
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE fact_skill_activation_2026_06 PARTITION OF fact_skill_activation
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');

COMMENT ON TABLE fact_skill_activation IS
  'Transaction fact, grain = 1 SKILL.md load. This is the table that answers "which skills are actually loading, who wrote them, and how often". Joins to dim_skill at point-in-time so historical activation queries see the description that was active then.';


-- ============================================================================
-- fact_token_spend — one row per turn (assistant message)
-- Grain: one row per (session, turn)
-- ============================================================================

CREATE TABLE fact_token_spend (
    spend_sk             bigint GENERATED ALWAYS AS IDENTITY,
    session_id           uuid NOT NULL,
    turn_id              uuid NOT NULL,
    turn_seq             integer NOT NULL,
    -- Conformed FKs
    date_sk              integer NOT NULL REFERENCES dim_date (date_sk),
    user_sk              bigint NOT NULL REFERENCES dim_user (user_sk),
    agent_sk             bigint NOT NULL REFERENCES dim_agent (agent_sk),
    model_sk             smallint NOT NULL REFERENCES dim_model (model_sk),
    -- Time anchors
    event_ts             timestamptz NOT NULL,
    -- Measures (additive)
    input_tokens         integer NOT NULL,
    output_tokens        integer NOT NULL,
    cached_tokens        integer NOT NULL DEFAULT 0,
    cache_read_tokens    integer NOT NULL DEFAULT 0,
    cache_write_tokens   integer NOT NULL DEFAULT 0,
    -- Derived cost (generated column joining to dim_model would need a trigger;
    -- we materialize once on insert via the ETL — simpler and avoids row triggers).
    cost_usd             numeric(12,6) NOT NULL DEFAULT 0,
    latency_ms           integer,
    PRIMARY KEY (spend_sk, event_ts)
) PARTITION BY RANGE (event_ts);

CREATE INDEX fact_token_spend_session_turn_idx ON fact_token_spend (session_id, turn_seq);
CREATE INDEX fact_token_spend_user_idx ON fact_token_spend (user_sk, event_ts);
CREATE INDEX fact_token_spend_event_ts_brin ON fact_token_spend USING brin (event_ts);

CREATE TABLE fact_token_spend_2026_05 PARTITION OF fact_token_spend
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE fact_token_spend_2026_06 PARTITION OF fact_token_spend
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');

COMMENT ON TABLE fact_token_spend IS
  'Transaction fact, grain = 1 turn. All measures additive (sum across any dim combination). This is the table cost dashboards aggregate from.';


-- ============================================================================
-- fact_creator_snapshot — PERIODIC SNAPSHOT FACT
-- Grain: one row per (creator, snapshot date), captured nightly
-- ============================================================================

CREATE TABLE fact_creator_snapshot (
    snapshot_sk          bigint GENERATED ALWAYS AS IDENTITY,
    -- Conformed FKs
    date_sk              integer NOT NULL REFERENCES dim_date (date_sk),
    creator_sk           bigint NOT NULL REFERENCES dim_creator (creator_sk),
    -- Snapshot anchor
    snapshot_ts          timestamptz NOT NULL,
    catalog_source       text NOT NULL,                  -- 'skills.sh/official'
    -- Snapshot measures (semi-additive: sum across creator OK, sum across date NOT OK)
    repo_count           integer NOT NULL,
    skill_count          integer NOT NULL,
    -- Daily delta measures (additive across both creator and date)
    repos_added          integer NOT NULL DEFAULT 0,
    skills_added         integer NOT NULL DEFAULT 0,
    skills_removed       integer NOT NULL DEFAULT 0,
    -- Ranking measures (calculated nightly, not additive)
    rank_by_skill_count  integer,
    pct_of_total_skills  numeric(7,4),
    PRIMARY KEY (snapshot_sk, snapshot_ts),
    UNIQUE (creator_sk, date_sk, catalog_source)
) PARTITION BY RANGE (snapshot_ts);

CREATE INDEX fact_creator_snapshot_creator_idx ON fact_creator_snapshot (creator_sk, snapshot_ts);
CREATE INDEX fact_creator_snapshot_brin ON fact_creator_snapshot USING brin (snapshot_ts);

CREATE TABLE fact_creator_snapshot_2026_q2 PARTITION OF fact_creator_snapshot
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');
CREATE TABLE fact_creator_snapshot_2026_q3 PARTITION OF fact_creator_snapshot
    FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');

COMMENT ON TABLE fact_creator_snapshot IS
  'Periodic snapshot fact — captures every creator every day even if nothing changed. Semi-additive measures: SUM works across creators, but NOT across dates (use AVG or LAST_VALUE over time).';


-- ============================================================================
-- fact_reward_hack — one row per HDCP detector firing
-- Grain: one row per detected reward-hack event
-- ============================================================================

CREATE TABLE fact_reward_hack (
    reward_hack_sk       bigint GENERATED ALWAYS AS IDENTITY,
    reward_hack_id       uuid NOT NULL,
    training_run_id      uuid NOT NULL,
    -- Conformed FKs
    date_sk              integer NOT NULL REFERENCES dim_date (date_sk),
    environment_sk       bigint REFERENCES dim_environment (environment_sk),
    model_sk             smallint REFERENCES dim_model (model_sk),
    agent_sk             bigint REFERENCES dim_agent (agent_sk),
    -- Time anchors
    event_ts             timestamptz NOT NULL,
    acknowledged_at      timestamptz,
    -- Measures
    kind                 text NOT NULL,                  -- enum from HDCP RewardHackKind
    severity             smallint NOT NULL,              -- 1..5
    trajectory_ref       text,                           -- gs://... or s3://...
    time_to_ack_seconds  integer
        GENERATED ALWAYS AS (
            CASE WHEN acknowledged_at IS NULL THEN NULL
                 ELSE (EXTRACT(EPOCH FROM (acknowledged_at - event_ts)))::integer
            END
        ) STORED,
    PRIMARY KEY (reward_hack_sk, event_ts)
) PARTITION BY RANGE (event_ts);

CREATE INDEX fact_reward_hack_run_idx ON fact_reward_hack (training_run_id, event_ts);
CREATE INDEX fact_reward_hack_kind_idx ON fact_reward_hack (kind, event_ts);
CREATE INDEX fact_reward_hack_brin ON fact_reward_hack USING brin (event_ts);

CREATE TABLE fact_reward_hack_2026_05 PARTITION OF fact_reward_hack
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE fact_reward_hack_2026_06 PARTITION OF fact_reward_hack
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');


-- ============================================================================
-- fact_vendor_onboarding_step — TRANSACTION fact: one row per step transition
-- Grain: one row per (vendor, step, status change)
-- ============================================================================

CREATE TABLE fact_vendor_onboarding_step (
    onboarding_step_sk   bigint GENERATED ALWAYS AS IDENTITY,
    vendor_id            uuid NOT NULL,
    step_key             text NOT NULL,                  -- 'msa_signed' | 'docker_registry' | ...
    -- Conformed FK
    date_sk              integer NOT NULL REFERENCES dim_date (date_sk),
    -- Time anchor
    event_ts             timestamptz NOT NULL,
    -- Measures
    from_status          text,                           -- null on first observation
    to_status            text NOT NULL,                  -- 'pending'..'passed'..'failed'..'skipped'
    duration_in_prev_status_seconds integer,
    PRIMARY KEY (onboarding_step_sk, event_ts)
) PARTITION BY RANGE (event_ts);

CREATE INDEX fact_vendor_onboarding_step_vendor_idx
    ON fact_vendor_onboarding_step (vendor_id, event_ts);
CREATE INDEX fact_vendor_onboarding_step_brin
    ON fact_vendor_onboarding_step USING brin (event_ts);

CREATE TABLE fact_vendor_onboarding_step_2026_05 PARTITION OF fact_vendor_onboarding_step
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE fact_vendor_onboarding_step_2026_06 PARTITION OF fact_vendor_onboarding_step
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');


-- ============================================================================
-- fact_vendor_onboarding_lifecycle — ACCUMULATING SNAPSHOT
-- Grain: one row PER VENDOR. Updated in place as milestones complete.
-- Coexists with fact_vendor_onboarding_step (transaction) — same source data,
-- two consumption shapes.
-- ============================================================================

CREATE TABLE fact_vendor_onboarding_lifecycle (
    vendor_id            uuid PRIMARY KEY,
    -- Conformed FK (date the vendor was invited)
    invited_date_sk      integer NOT NULL REFERENCES dim_date (date_sk),
    -- Milestone dates — each updated as the corresponding step transitions to 'passed'
    invited_at           timestamptz NOT NULL,
    msa_signed_at        timestamptz,
    docker_provisioned_at timestamptz,
    token_issued_at      timestamptz,
    env_smoke_passed_at  timestamptz,
    dataset_access_verified_at timestamptz,
    security_attested_at timestamptz,
    activated_at         timestamptz,
    -- Derived lag measures, recomputed by trigger or ETL on every update
    lag_to_msa_signed_days       integer
        GENERATED ALWAYS AS (
            EXTRACT(DAY FROM (msa_signed_at - invited_at))::integer
        ) STORED,
    lag_to_activated_days        integer
        GENERATED ALWAYS AS (
            EXTRACT(DAY FROM (activated_at - invited_at))::integer
        ) STORED,
    onboarding_status    text NOT NULL DEFAULT 'in_progress',  -- 'in_progress' | 'completed' | 'stalled' | 'abandoned'
    last_updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX fact_vendor_onboarding_lifecycle_status_idx
    ON fact_vendor_onboarding_lifecycle (onboarding_status);
CREATE INDEX fact_vendor_onboarding_lifecycle_activated_idx
    ON fact_vendor_onboarding_lifecycle (activated_at)
    WHERE activated_at IS NOT NULL;

COMMENT ON TABLE fact_vendor_onboarding_lifecycle IS
  'Accumulating snapshot — one row per vendor, columns updated as milestones complete. Standard Kimball pattern for ordered pipelines. Lag columns are generated for fast "time-to-activate" dashboards.';


-- ============================================================================
-- fact_label_task_event — HDCP label task state transitions
-- Grain: one row per (task, status change)
-- ============================================================================

CREATE TABLE fact_label_task_event (
    label_task_event_sk  bigint GENERATED ALWAYS AS IDENTITY,
    task_id              uuid NOT NULL,
    project_id           uuid NOT NULL,
    -- Conformed FKs
    date_sk              integer NOT NULL REFERENCES dim_date (date_sk),
    environment_sk       bigint REFERENCES dim_environment (environment_sk),
    labeler_user_sk      bigint REFERENCES dim_user (user_sk),         -- nullable; some events are auto
    reviewer_user_sk     bigint REFERENCES dim_user (user_sk),
    -- Time anchor
    event_ts             timestamptz NOT NULL,
    -- Measures
    from_status          text,
    to_status            text NOT NULL,                  -- 'queued'..'accepted' etc
    qa_outcome           text,                           -- 'accept' | 'reject' | 'needs_revision' | 'escalate'
    rubric_score         numeric(5,4),
    time_in_prev_status_seconds integer,
    PRIMARY KEY (label_task_event_sk, event_ts)
) PARTITION BY RANGE (event_ts);

CREATE INDEX fact_label_task_event_task_idx ON fact_label_task_event (task_id, event_ts);
CREATE INDEX fact_label_task_event_project_idx ON fact_label_task_event (project_id, event_ts);
CREATE INDEX fact_label_task_event_brin ON fact_label_task_event USING brin (event_ts);

CREATE TABLE fact_label_task_event_2026_05 PARTITION OF fact_label_task_event
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE fact_label_task_event_2026_06 PARTITION OF fact_label_task_event
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
