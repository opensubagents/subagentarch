-- ============================================================================
-- File: 05_pg_cron_and_columnar.sql
-- Target: AlloyDB for Postgres 17.8
-- Schema: warehouse
-- Purpose: Scheduled jobs (partition rolling, snapshot capture, MV refresh,
--          retention) + AlloyDB columnar engine hints for aggregate facts.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SET search_path TO warehouse, public;


-- ============================================================================
-- 1. Nightly partition creation — 30 days ahead for the daily-partitioned
--    high-volume table, 3 months ahead for monthly facts and events.
-- ============================================================================

CREATE OR REPLACE FUNCTION roll_partitions() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    d date;
    m date;
BEGIN
    -- Daily partitions for events_session_stream — 30 days ahead
    FOR d IN
        SELECT generate_series(
            CURRENT_DATE,
            CURRENT_DATE + INTERVAL '30 days',
            INTERVAL '1 day'
        )::date
    LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS events_session_stream_%s '
            'PARTITION OF events_session_stream '
            'FOR VALUES FROM (%L) TO (%L)',
            to_char(d, 'YYYYMMDD'), d, d + 1
        );
    END LOOP;

    -- Monthly partitions for the 8 transaction facts + 6 monthly events — 3 months ahead
    FOR m IN
        SELECT generate_series(
            date_trunc('month', CURRENT_DATE),
            date_trunc('month', CURRENT_DATE) + INTERVAL '3 months',
            INTERVAL '1 month'
        )::date
    LOOP
        FOR tbl IN ARRAY[
            'fact_session', 'fact_tool_invocation', 'fact_skill_activation',
            'fact_token_spend', 'fact_reward_hack',
            'fact_vendor_onboarding_step', 'fact_label_task_event',
            'events_session_lifecycle', 'events_creator_observed',
            'events_skill_activation', 'events_reward_hack_detected',
            'events_vendor_onboarding', 'events_label_task'
        ] LOOP
            EXECUTE format(
                'CREATE TABLE IF NOT EXISTS %I_%s '
                'PARTITION OF %I '
                'FOR VALUES FROM (%L) TO (%L)',
                tbl, to_char(m, 'YYYY_MM'), tbl, m, m + INTERVAL '1 month'
            );
        END LOOP;
    END LOOP;

    -- Quarterly partitions for fact_creator_snapshot — 2 quarters ahead
    FOR m IN
        SELECT generate_series(
            date_trunc('quarter', CURRENT_DATE),
            date_trunc('quarter', CURRENT_DATE) + INTERVAL '6 months',
            INTERVAL '3 months'
        )::date
    LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS fact_creator_snapshot_%sq%s '
            'PARTITION OF fact_creator_snapshot '
            'FOR VALUES FROM (%L) TO (%L)',
            to_char(m, 'YYYY'),
            EXTRACT(QUARTER FROM m)::integer,
            m, m + INTERVAL '3 months'
        );
    END LOOP;
END;
$$;


-- ============================================================================
-- 2. Retention — drop partitions older than the policy says
-- ============================================================================

CREATE OR REPLACE FUNCTION drop_old_partitions() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    p text;
BEGIN
    -- events_session_stream retention: 90 days
    FOR p IN
        SELECT inhrelid::regclass::text
        FROM pg_inherits
        JOIN pg_class parent ON parent.oid = inhparent
        WHERE parent.relname = 'events_session_stream'
          AND substring(inhrelid::regclass::text FROM '\d{8}$')::date
              < CURRENT_DATE - INTERVAL '90 days'
    LOOP
        EXECUTE format('DROP TABLE IF EXISTS %s', p);
    END LOOP;

    -- Monthly events retention: 18 months
    FOR p IN
        SELECT inhrelid::regclass::text AS partname
        FROM pg_inherits
        JOIN pg_class parent ON parent.oid = inhparent
        WHERE parent.relname IN (
            'events_session_lifecycle', 'events_creator_observed',
            'events_skill_activation', 'events_reward_hack_detected',
            'events_vendor_onboarding', 'events_label_task'
        )
        AND to_date(
                substring(inhrelid::regclass::text FROM '\d{4}_\d{2}$'),
                'YYYY_MM'
            ) < CURRENT_DATE - INTERVAL '18 months'
    LOOP
        EXECUTE format('DROP TABLE IF EXISTS %s', p);
    END LOOP;

    -- Facts: no automatic drop. Aged partitions get moved to columnar
    -- storage instead (see section 5). DROP only on explicit policy.
END;
$$;


-- ============================================================================
-- 3. Nightly creator snapshot capture (the periodic snapshot fact)
-- This is the job that materializes one fact_creator_snapshot row per
-- creator per day, even when nothing changed.
-- ============================================================================

CREATE OR REPLACE FUNCTION capture_creator_snapshot(p_source text DEFAULT 'skills.sh/official')
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_today_sk     integer;
    v_inserted     integer := 0;
    v_total_skills integer;
BEGIN
    v_today_sk := TO_CHAR(CURRENT_DATE, 'YYYYMMDD')::integer;

    SELECT SUM(skill_count) INTO v_total_skills
    FROM dim_creator
    WHERE scd_is_current AND catalog_source = p_source;

    WITH inserts AS (
        INSERT INTO fact_creator_snapshot (
            date_sk, creator_sk, snapshot_ts, catalog_source,
            repo_count, skill_count,
            repos_added, skills_added, skills_removed,
            rank_by_skill_count, pct_of_total_skills
        )
        SELECT
            v_today_sk,
            c.creator_sk,
            now(),
            p_source,
            c.repo_count,
            c.skill_count,
            GREATEST(0, c.repo_count - COALESCE(prev.repo_count, c.repo_count)),
            GREATEST(0, c.skill_count - COALESCE(prev.skill_count, c.skill_count)),
            GREATEST(0, COALESCE(prev.skill_count, c.skill_count) - c.skill_count),
            RANK() OVER (ORDER BY c.skill_count DESC),
            (c.skill_count::numeric / NULLIF(v_total_skills, 0))
        FROM dim_creator c
        LEFT JOIN LATERAL (
            SELECT repo_count, skill_count
            FROM fact_creator_snapshot
            WHERE creator_sk = c.creator_sk
            ORDER BY snapshot_ts DESC LIMIT 1
        ) prev ON true
        WHERE c.scd_is_current
          AND c.catalog_source = p_source
        ON CONFLICT (creator_sk, date_sk, catalog_source) DO NOTHING
        RETURNING 1
    )
    SELECT count(*) INTO v_inserted FROM inserts;

    RETURN v_inserted;
END;
$$;


-- ============================================================================
-- 4. pg_cron job registrations (one-time setup)
-- ============================================================================

-- Run hourly: roll partitions forward
SELECT cron.schedule(
    'warehouse-roll-partitions',
    '0 * * * *',
    $$SELECT warehouse.roll_partitions()$$
);

-- Run daily at 02:00 UTC: drop old partitions per retention
SELECT cron.schedule(
    'warehouse-drop-old-partitions',
    '0 2 * * *',
    $$SELECT warehouse.drop_old_partitions()$$
);

-- Run daily at 03:00 UTC: capture creator snapshot
SELECT cron.schedule(
    'warehouse-creator-snapshot',
    '0 3 * * *',
    $$SELECT warehouse.capture_creator_snapshot('skills.sh/official')$$
);

-- Run every 15 minutes: refresh hot dashboard MV
SELECT cron.schedule(
    'warehouse-refresh-creator-mv',
    '*/15 * * * *',
    $$REFRESH MATERIALIZED VIEW CONCURRENTLY warehouse.mv_creator_current$$
);

-- Run daily at 04:00 UTC: VACUUM ANALYZE the wide fact partitions modified yesterday
SELECT cron.schedule(
    'warehouse-vacuum-yesterday',
    '0 4 * * *',
    $$
    DO $do$
    DECLARE
      p text;
      yyyymm text := to_char(CURRENT_DATE - INTERVAL '1 day', 'YYYY_MM');
    BEGIN
      FOR p IN
        SELECT inhrelid::regclass::text
        FROM pg_inherits
        JOIN pg_class parent ON parent.oid = inhparent
        WHERE parent.relname LIKE 'fact_%'
          AND inhrelid::regclass::text LIKE '%' || yyyymm
      LOOP
        EXECUTE format('VACUUM (ANALYZE, FREEZE) %s', p);
      END LOOP;
    END;
    $do$;
    $$
);


-- ============================================================================
-- 5. AlloyDB columnar engine hints
--
-- On AlloyDB, the columnar engine stores a column-oriented copy of selected
-- tables/partitions in memory + Tiered Cache, giving 10-100x speedups on
-- aggregate scans. These are no-ops on vanilla Postgres.
--
-- Marked here: the five aggregate-heavy facts. Row-store for the rest.
-- ============================================================================

-- ALLOYDB-ONLY (uncomment when running on AlloyDB):
--
-- SELECT google_columnar_engine_add(
--   relation => 'warehouse.fact_session',
--   columns  => 'event_ts,user_sk,agent_sk,model_sk,environment_sk,duration_ms,'
--               || 'input_tokens_total,output_tokens_total,cost_estimated_usd'
-- );
--
-- SELECT google_columnar_engine_add(
--   relation => 'warehouse.fact_tool_invocation',
--   columns  => 'event_ts,tool_sk,agent_sk,model_sk,environment_sk,duration_ms,status'
-- );
--
-- SELECT google_columnar_engine_add(
--   relation => 'warehouse.fact_skill_activation',
--   columns  => 'event_ts,skill_sk,creator_sk,repo_sk,agent_sk,model_sk,trigger_kind'
-- );
--
-- SELECT google_columnar_engine_add(
--   relation => 'warehouse.fact_token_spend',
--   columns  => 'event_ts,user_sk,agent_sk,model_sk,input_tokens,output_tokens,'
--               || 'cached_tokens,cost_usd'
-- );
--
-- SELECT google_columnar_engine_add(
--   relation => 'warehouse.fact_creator_snapshot',
--   columns  => 'date_sk,creator_sk,snapshot_ts,repo_count,skill_count,'
--               || 'rank_by_skill_count,pct_of_total_skills'
-- );
--
-- Recommended: also mark partitions older than 30 days for full-table columnar
-- via google_columnar_engine_add_policy() so cold data lives entirely in
-- the column store.


-- ============================================================================
-- 6. Pre-warmed first run
-- ============================================================================

SELECT roll_partitions();
