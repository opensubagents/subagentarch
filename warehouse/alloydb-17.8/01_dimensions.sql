-- ============================================================================
-- File: 01_dimensions.sql
-- Target: AlloyDB for Postgres 17.8 (or vanilla Postgres 17.8)
-- Schema: warehouse
-- Purpose: All conformed dimensions, each demonstrating a specific SCD type.
--          See 00_bus_matrix.md for SCD rationale per dimension.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS warehouse;
SET search_path TO warehouse, public;

CREATE EXTENSION IF NOT EXISTS pgcrypto;        -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pg_trgm;          -- fuzzy match on slugs/names
CREATE EXTENSION IF NOT EXISTS btree_gin;
-- AlloyDB-only: pgvector ships pre-installed; on vanilla pg run:
--   CREATE EXTENSION IF NOT EXISTS vector;
-- AlloyDB-only directive (no-op elsewhere):
--   ALTER DATABASE warehouse SET google_columnar_engine.enabled = on;


-- ============================================================================
-- SCD TYPE 0 — dim_date
-- Pure calendar. Never changes. Pre-seeded once for 2020-01-01..2099-12-31.
-- ============================================================================

CREATE TABLE dim_date (
    date_sk          integer PRIMARY KEY,         -- YYYYMMDD natural surrogate
    date_actual      date NOT NULL UNIQUE,
    day_of_week      smallint NOT NULL,           -- 0..6, ISO Monday=1
    day_name         text NOT NULL,               -- 'Monday'
    day_of_month     smallint NOT NULL,
    day_of_year      smallint NOT NULL,
    week_of_year     smallint NOT NULL,           -- ISO week
    iso_week_year    smallint NOT NULL,
    month_number     smallint NOT NULL,
    month_name       text NOT NULL,
    quarter_number   smallint NOT NULL,
    year_number      smallint NOT NULL,
    is_weekend       boolean NOT NULL,
    is_us_holiday    boolean NOT NULL DEFAULT false,
    fiscal_year      smallint NOT NULL,           -- assume Feb 1 fiscal start
    fiscal_quarter   smallint NOT NULL
);

COMMENT ON TABLE dim_date IS
  'SCD type 0 — immutable calendar. Seeded once by 04_seed_dim_date.sql.';


-- ============================================================================
-- SCD TYPE 1 — dim_user, dim_model
-- Overwrite in place. No history kept.
-- ============================================================================

CREATE TABLE dim_user (
    user_sk          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id          uuid NOT NULL UNIQUE,              -- natural key from source OLTP
    email            text NOT NULL,
    display_name     text NOT NULL,
    role             text NOT NULL,                     -- 'member' | 'admin' | 'it_admin'
    customer_slug    text NOT NULL,
    is_active        boolean NOT NULL DEFAULT true,
    -- SCD1 metadata
    last_updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX dim_user_customer_idx ON dim_user (customer_slug) INCLUDE (user_sk);

COMMENT ON TABLE dim_user IS
  'SCD type 1 — overwrite. display_name and role overwrite freely; no prior values retained.';


CREATE TABLE dim_model (
    model_sk         smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    model_name       text NOT NULL UNIQUE,              -- 'claude-opus-4-7'
    model_family     text NOT NULL,                     -- 'claude-opus' | 'claude-sonnet' | 'claude-haiku'
    model_version    text NOT NULL,                     -- '4-7'
    released_on      date,
    context_window   integer,
    input_cost_per_mtok_usd  numeric(10,4),
    output_cost_per_mtok_usd numeric(10,4),
    cache_read_cost_per_mtok_usd numeric(10,4),
    is_deprecated    boolean NOT NULL DEFAULT false,
    last_updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE dim_model IS
  'SCD type 1 — overwrite. New models are new rows; existing rows update in place if pricing changes.';


-- ============================================================================
-- SCD TYPE 3 — dim_tool
-- Limited history. Keep one prior value for `category` only.
-- ============================================================================

CREATE TABLE dim_tool (
    tool_sk                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tool_name               text NOT NULL UNIQUE,       -- 'Bash', 'Edit', 'Agent', ...
    category                text NOT NULL,              -- current category
    category_previous       text,                       -- one prior value, NULL if never changed
    category_changed_at     timestamptz,                -- when the swap happened, NULL if never
    permission_required     boolean NOT NULL,
    is_deprecated           boolean NOT NULL DEFAULT false,
    description             text,
    min_version             text,
    last_updated_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE dim_tool IS
  'SCD type 3 — limited history. category_previous + category_changed_at retain ONE prior reclassification.';

COMMENT ON COLUMN dim_tool.category_previous IS
  'NULL if the tool has never been reclassified. After a second reclassification, the second-most-recent value is dropped.';


-- ============================================================================
-- SCD TYPE 2 — dim_creator, dim_skill, dim_repo, dim_agent, dim_plugin_source
-- New row on every observed change. Surrogate key joins to facts.
--
-- Standard Type 2 columns shared by all five:
--   *_sk           surrogate key (the join target for facts)
--   *_id           natural/business key (stable across versions)
--   scd_valid_from timestamptz when this version became active
--   scd_valid_to   timestamptz when superseded; '9999-12-31' for current
--   scd_is_current boolean derived; indexed for fast hot-row lookups
--   scd_version    monotonic version counter per natural key
-- ============================================================================

-- dim_creator: skills.sh creator over time (94 today, will grow)
CREATE TABLE dim_creator (
    creator_sk          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    creator_id          text NOT NULL,                  -- github org slug, e.g. 'anthropics'
    -- Tracked attributes
    primary_repo        text NOT NULL,
    repo_count          integer NOT NULL,
    skill_count         integer NOT NULL,
    catalog_url         text NOT NULL,
    tier                text NOT NULL,                  -- 'official' | 'community' | 'partner' | 'experimental'
    catalog_source      text NOT NULL,                  -- 'skills.sh/official'
    -- SCD2 metadata
    scd_valid_from      timestamptz NOT NULL,
    scd_valid_to        timestamptz NOT NULL DEFAULT '9999-12-31 00:00:00+00',
    scd_is_current      boolean NOT NULL,
    scd_version         integer NOT NULL,
    scd_hash_diff       text NOT NULL,                  -- sha256 of tracked attrs, for change detection
    UNIQUE (creator_id, scd_version)
);

CREATE INDEX dim_creator_current_idx ON dim_creator (creator_id)
    WHERE scd_is_current;
CREATE INDEX dim_creator_natural_idx ON dim_creator (creator_id, scd_valid_from);

COMMENT ON TABLE dim_creator IS
  'SCD type 2 — full history. One row per (creator_id, version). Surrogate key creator_sk joins to facts. Use scd_is_current=true for current-state queries.';

COMMENT ON COLUMN dim_creator.scd_hash_diff IS
  'sha256 of (primary_repo, repo_count, skill_count, catalog_url, tier). ETL compares this hash to detect "is this version different from the current one". Avoids spurious new rows when nothing changed.';


-- dim_skill: SKILL.md description is the activation signal — needs full history
CREATE TABLE dim_skill (
    skill_sk            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    skill_id            text NOT NULL,                  -- 'reveal-and-restore-worker-token'
    creator_id          text NOT NULL,                  -- 'opensubagents' — denormalized for partition pruning
    skill_name          text NOT NULL,                  -- redundant w/ skill_id but kept for readability
    description         text NOT NULL,                  -- the activation signal — primary tracked attr
    skill_body_sha      text NOT NULL,                  -- sha256 of SKILL.md body
    allowed_tools       text[],                         -- if 'allowed-tools' frontmatter set
    license             text,
    description_embedding vector(1536),                  -- pgvector — for similarity search across skills
    -- SCD2 metadata
    scd_valid_from      timestamptz NOT NULL,
    scd_valid_to        timestamptz NOT NULL DEFAULT '9999-12-31 00:00:00+00',
    scd_is_current      boolean NOT NULL,
    scd_version         integer NOT NULL,
    scd_hash_diff       text NOT NULL,
    UNIQUE (skill_id, creator_id, scd_version)
);

CREATE INDEX dim_skill_current_idx ON dim_skill (skill_id, creator_id)
    WHERE scd_is_current;
CREATE INDEX dim_skill_creator_idx ON dim_skill (creator_id) INCLUDE (skill_sk);
CREATE INDEX dim_skill_description_trgm_idx ON dim_skill USING gin (description gin_trgm_ops);
-- vector index for embedding similarity (HNSW)
CREATE INDEX dim_skill_embedding_idx ON dim_skill
    USING hnsw (description_embedding vector_cosine_ops);

COMMENT ON TABLE dim_skill IS
  'SCD type 2 — full history of every SKILL.md, keyed by (skill_id, creator_id). Description changes create new rows. Embedding indexed via HNSW for "find me skills like this".';


-- dim_repo: track repo renames, archival, default-branch changes
CREATE TABLE dim_repo (
    repo_sk             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    repo_id             text NOT NULL,                  -- '<creator>/<repo>' canonical
    creator_id          text NOT NULL,
    repo_name           text NOT NULL,
    default_branch      text NOT NULL,
    is_archived         boolean NOT NULL DEFAULT false,
    is_private          boolean NOT NULL DEFAULT false,
    license_spdx        text,
    homepage_url        text,
    description         text,
    -- SCD2 metadata
    scd_valid_from      timestamptz NOT NULL,
    scd_valid_to        timestamptz NOT NULL DEFAULT '9999-12-31 00:00:00+00',
    scd_is_current      boolean NOT NULL,
    scd_version         integer NOT NULL,
    scd_hash_diff       text NOT NULL,
    UNIQUE (repo_id, scd_version)
);

CREATE INDEX dim_repo_current_idx ON dim_repo (repo_id) WHERE scd_is_current;
CREATE INDEX dim_repo_creator_idx ON dim_repo (creator_id) WHERE scd_is_current;

COMMENT ON TABLE dim_repo IS 'SCD type 2 — full history. Renames are tracked by repo_id changes; archival by is_archived flips.';


-- dim_agent: system_prompt + tool grants change; auditing requires history
CREATE TABLE dim_agent (
    agent_sk            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_id            uuid NOT NULL,
    agent_name          text NOT NULL,
    system_prompt_sha   text NOT NULL,                  -- sha256 of the prompt body
    system_prompt_excerpt text,                         -- first 200 chars for readability
    allowed_tool_names  text[] NOT NULL,
    allowed_skill_ids   text[] NOT NULL,
    permission_policy_id uuid,
    environment_kind    text NOT NULL,                  -- 'cloud_container' | 'self_hosted_sandbox'
    -- SCD2 metadata
    scd_valid_from      timestamptz NOT NULL,
    scd_valid_to        timestamptz NOT NULL DEFAULT '9999-12-31 00:00:00+00',
    scd_is_current      boolean NOT NULL,
    scd_version         integer NOT NULL,
    scd_hash_diff       text NOT NULL,
    UNIQUE (agent_id, scd_version)
);

CREATE INDEX dim_agent_current_idx ON dim_agent (agent_id) WHERE scd_is_current;
CREATE INDEX dim_agent_tools_idx ON dim_agent USING gin (allowed_tool_names);
CREATE INDEX dim_agent_skills_idx ON dim_agent USING gin (allowed_skill_ids);

COMMENT ON TABLE dim_agent IS 'SCD type 2 — full history. system_prompt and allowed_* arrays are the tracked attributes.';


-- dim_plugin_source: marketplace.json `source` entries, SHA-pinned, bumped nightly
CREATE TABLE dim_plugin_source (
    plugin_source_sk    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plugin_name         text NOT NULL,                  -- 'cloudflare' or '42crunch-api-security-testing'
    source_kind         text NOT NULL,                  -- 'git-subdir' | 'local'
    source_url          text,                           -- 'https://github.com/.../skills.git'
    source_path         text,                           -- 'plugins/api-security-testing'
    source_ref          text,                           -- 'v1.5.5' or 'main' — what we asked for
    source_sha          text,                           -- the actual SHA we pinned to
    category            text,                           -- 'security' | 'development' | ...
    author_name         text,
    homepage            text,
    -- SCD2 metadata
    scd_valid_from      timestamptz NOT NULL,
    scd_valid_to        timestamptz NOT NULL DEFAULT '9999-12-31 00:00:00+00',
    scd_is_current      boolean NOT NULL,
    scd_version         integer NOT NULL,
    scd_hash_diff       text NOT NULL,                  -- sha256 of (source_ref, source_sha, category, author_name)
    UNIQUE (plugin_name, scd_version)
);

CREATE INDEX dim_plugin_source_current_idx ON dim_plugin_source (plugin_name)
    WHERE scd_is_current;
CREATE INDEX dim_plugin_source_sha_idx ON dim_plugin_source (source_sha);

COMMENT ON TABLE dim_plugin_source IS
  'SCD type 2 — every nightly SHA bump of marketplace.json creates a new row. Lets analysts answer "which SHA was pinned when activation X happened".';


-- ============================================================================
-- SCD TYPE 4 — dim_environment
-- Rapidly-changing dimension. Split into hot (current-only) + history.
-- ============================================================================

-- The HOT current-only table — narrow, what facts join to by default
CREATE TABLE dim_environment (
    environment_sk      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    environment_id      uuid NOT NULL UNIQUE,
    environment_slug    text NOT NULL UNIQUE,
    title               text NOT NULL,
    -- Current state only — never mutated; updated on overwrite
    image_digest        text NOT NULL,
    status              text NOT NULL,                  -- 'draft'..'production'..'quarantined'
    difficulty_band     text,
    estimated_solve_rate numeric(5,4),
    owner_vendor_id     uuid,
    tags                text[] NOT NULL DEFAULT '{}',
    -- SCD4 metadata — bookkeeping only
    last_changed_at     timestamptz NOT NULL DEFAULT now(),
    current_history_sk  bigint                          -- FK to dim_environment_history of the *current* row
);

CREATE INDEX dim_environment_status_idx ON dim_environment (status);
CREATE INDEX dim_environment_tags_idx ON dim_environment USING gin (tags);

-- The HISTORY table — wide, one row per version
CREATE TABLE dim_environment_history (
    environment_history_sk bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    environment_id      uuid NOT NULL,                  -- joins back to the hot row
    image_digest        text NOT NULL,
    status              text NOT NULL,
    difficulty_band     text,
    estimated_solve_rate numeric(5,4),
    owner_vendor_id     uuid,
    tags                text[] NOT NULL,
    -- SCD2-style validity inside the history table
    scd_valid_from      timestamptz NOT NULL,
    scd_valid_to        timestamptz NOT NULL DEFAULT '9999-12-31 00:00:00+00',
    scd_is_current      boolean NOT NULL,
    scd_version         integer NOT NULL,
    scd_hash_diff       text NOT NULL,
    UNIQUE (environment_id, scd_version)
);

CREATE INDEX dim_environment_history_current_idx
    ON dim_environment_history (environment_id) WHERE scd_is_current;
CREATE INDEX dim_environment_history_temporal_idx
    ON dim_environment_history (environment_id, scd_valid_from);

ALTER TABLE dim_environment
    ADD CONSTRAINT dim_environment_current_history_fk
    FOREIGN KEY (current_history_sk)
    REFERENCES dim_environment_history (environment_history_sk);

COMMENT ON TABLE dim_environment IS
  'SCD type 4 — hot table. One row per environment, current state only. Facts join here for "current" queries (the common case). For point-in-time queries, fact rows that captured environment_history_sk can be re-joined to dim_environment_history.';

COMMENT ON TABLE dim_environment_history IS
  'SCD type 4 — history. Full SCD2 history of every environment version. Justified by HDCP environments changing image_digest on most training-run iterations.';


-- ============================================================================
-- Type 6 hybrid (mini-dimension pattern) — dim_session_context
-- Not strictly required, but useful: a *junk dimension* that combines
-- low-cardinality flags from a session (platform, model_family, was_remote,
-- was_in_plan_mode, was_resumed) so fact_session doesn't carry 5 boolean
-- columns and dim_agent doesn't get versioned for these.
-- ============================================================================

CREATE TABLE dim_session_context (
    session_context_sk  smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    platform            text NOT NULL,                  -- 'cli' | 'web' | 'mobile' | 'desktop' | 'api'
    model_family        text NOT NULL,                  -- 'claude-opus' | 'claude-sonnet' | 'claude-haiku'
    was_remote          boolean NOT NULL,
    was_in_plan_mode    boolean NOT NULL,
    was_resumed         boolean NOT NULL,
    UNIQUE (platform, model_family, was_remote, was_in_plan_mode, was_resumed)
);

COMMENT ON TABLE dim_session_context IS
  'Junk dimension — pre-enumerated cartesian product of low-cardinality flags. fact_session FK-references this with a single smallint instead of carrying 5 columns.';
