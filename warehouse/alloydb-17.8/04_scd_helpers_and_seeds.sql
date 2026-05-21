-- ============================================================================
-- File: 04_scd_helpers_and_seeds.sql
-- Target: AlloyDB for Postgres 17.8
-- Schema: warehouse
-- Purpose:
--   1. Seed dim_date for 2020-01-01..2099-12-31 (idempotent)
--   2. SCD2 upsert function using Postgres 17 MERGE ... RETURNING
--   3. SCD4 upsert function for dim_environment + dim_environment_history
--   4. SCD3 update function for dim_tool
-- ============================================================================

SET search_path TO warehouse, public;


-- ============================================================================
-- 1. Seed dim_date
-- ============================================================================

INSERT INTO dim_date (
    date_sk, date_actual, day_of_week, day_name, day_of_month, day_of_year,
    week_of_year, iso_week_year, month_number, month_name,
    quarter_number, year_number, is_weekend, fiscal_year, fiscal_quarter
)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::integer                              AS date_sk,
    d::date                                                       AS date_actual,
    EXTRACT(ISODOW FROM d)::smallint                              AS day_of_week,
    TO_CHAR(d, 'Day')                                             AS day_name,
    EXTRACT(DAY FROM d)::smallint                                 AS day_of_month,
    EXTRACT(DOY FROM d)::smallint                                 AS day_of_year,
    EXTRACT(WEEK FROM d)::smallint                                AS week_of_year,
    EXTRACT(ISOYEAR FROM d)::smallint                             AS iso_week_year,
    EXTRACT(MONTH FROM d)::smallint                               AS month_number,
    TRIM(TO_CHAR(d, 'Month'))                                     AS month_name,
    EXTRACT(QUARTER FROM d)::smallint                             AS quarter_number,
    EXTRACT(YEAR FROM d)::smallint                                AS year_number,
    EXTRACT(ISODOW FROM d) IN (6, 7)                              AS is_weekend,
    (CASE WHEN EXTRACT(MONTH FROM d) >= 2
          THEN EXTRACT(YEAR FROM d)
          ELSE EXTRACT(YEAR FROM d) - 1 END)::smallint            AS fiscal_year,
    ((EXTRACT(MONTH FROM d)::integer - 2 + 12) % 12 / 3 + 1)::smallint AS fiscal_quarter
FROM generate_series(DATE '2020-01-01', DATE '2099-12-31', INTERVAL '1 day') d
ON CONFLICT (date_sk) DO NOTHING;


-- ============================================================================
-- 2. SCD Type 2 upsert — generic helper using Postgres 17 MERGE ... RETURNING
--
-- Pattern: call once per natural key per ETL batch. If hash matches the
-- current row, no-op. If different, close the current row (set valid_to,
-- is_current=false) and insert a new current row in a single MERGE.
-- Returns the surrogate key of the row that now represents "current".
-- ============================================================================

CREATE OR REPLACE FUNCTION scd2_upsert_creator(
    p_creator_id   text,
    p_primary_repo text,
    p_repo_count   integer,
    p_skill_count  integer,
    p_catalog_url  text,
    p_tier         text,
    p_catalog_source text,
    p_observed_at  timestamptz
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_new_hash       text;
    v_current_sk     bigint;
    v_current_hash   text;
    v_current_ver    integer;
    v_returned_sk    bigint;
BEGIN
    v_new_hash := encode(digest(
        concat_ws('|', p_primary_repo, p_repo_count::text, p_skill_count::text,
                  p_catalog_url, p_tier),
        'sha256'
    ), 'hex');

    SELECT creator_sk, scd_hash_diff, scd_version
        INTO v_current_sk, v_current_hash, v_current_ver
    FROM dim_creator
    WHERE creator_id = p_creator_id AND scd_is_current
    FOR UPDATE;

    -- Case A: first observation — insert version 1
    IF v_current_sk IS NULL THEN
        INSERT INTO dim_creator (
            creator_id, primary_repo, repo_count, skill_count, catalog_url,
            tier, catalog_source, scd_valid_from, scd_is_current, scd_version,
            scd_hash_diff
        ) VALUES (
            p_creator_id, p_primary_repo, p_repo_count, p_skill_count, p_catalog_url,
            p_tier, p_catalog_source, p_observed_at, true, 1, v_new_hash
        ) RETURNING creator_sk INTO v_returned_sk;
        RETURN v_returned_sk;
    END IF;

    -- Case B: no change — no-op, return existing sk
    IF v_current_hash = v_new_hash THEN
        RETURN v_current_sk;
    END IF;

    -- Case C: changed — close current row and open new one.
    -- Postgres 17 MERGE ... RETURNING makes this a single statement on the
    -- close-side; we then INSERT the new row.
    MERGE INTO dim_creator AS d
    USING (SELECT v_current_sk AS sk) AS s
    ON d.creator_sk = s.sk
    WHEN MATCHED THEN UPDATE SET
        scd_valid_to   = p_observed_at,
        scd_is_current = false;

    INSERT INTO dim_creator (
        creator_id, primary_repo, repo_count, skill_count, catalog_url,
        tier, catalog_source, scd_valid_from, scd_is_current, scd_version,
        scd_hash_diff
    ) VALUES (
        p_creator_id, p_primary_repo, p_repo_count, p_skill_count, p_catalog_url,
        p_tier, p_catalog_source, p_observed_at, true, v_current_ver + 1, v_new_hash
    ) RETURNING creator_sk INTO v_returned_sk;

    RETURN v_returned_sk;
END;
$$;

COMMENT ON FUNCTION scd2_upsert_creator IS
  'SCD2 upsert for dim_creator. Idempotent — calling with the same inputs as the current row is a no-op. Returns the surrogate key of the current row after the operation.';


-- ============================================================================
-- 3. SCD Type 4 upsert — dim_environment (hot) + dim_environment_history
-- ============================================================================

CREATE OR REPLACE FUNCTION scd4_upsert_environment(
    p_environment_id    uuid,
    p_environment_slug  text,
    p_title             text,
    p_image_digest      text,
    p_status            text,
    p_difficulty_band   text,
    p_estimated_solve_rate numeric,
    p_owner_vendor_id   uuid,
    p_tags              text[],
    p_observed_at       timestamptz
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_new_hash       text;
    v_current_history_sk bigint;
    v_current_hash   text;
    v_current_ver    integer;
    v_returned_sk    bigint;
    v_history_sk     bigint;
BEGIN
    v_new_hash := encode(digest(
        concat_ws('|', p_image_digest, p_status, COALESCE(p_difficulty_band, ''),
                  COALESCE(p_estimated_solve_rate::text, ''),
                  COALESCE(p_owner_vendor_id::text, ''),
                  array_to_string(COALESCE(p_tags, '{}'::text[]), ',')),
        'sha256'
    ), 'hex');

    -- Look at the current history row for this environment
    SELECT environment_history_sk, scd_hash_diff, scd_version
        INTO v_current_history_sk, v_current_hash, v_current_ver
    FROM dim_environment_history
    WHERE environment_id = p_environment_id AND scd_is_current
    FOR UPDATE;

    -- Case A: first observation
    IF v_current_history_sk IS NULL THEN
        INSERT INTO dim_environment_history (
            environment_id, image_digest, status, difficulty_band,
            estimated_solve_rate, owner_vendor_id, tags,
            scd_valid_from, scd_is_current, scd_version, scd_hash_diff
        ) VALUES (
            p_environment_id, p_image_digest, p_status, p_difficulty_band,
            p_estimated_solve_rate, p_owner_vendor_id, COALESCE(p_tags, '{}'::text[]),
            p_observed_at, true, 1, v_new_hash
        ) RETURNING environment_history_sk INTO v_history_sk;

        INSERT INTO dim_environment (
            environment_id, environment_slug, title, image_digest, status,
            difficulty_band, estimated_solve_rate, owner_vendor_id, tags,
            last_changed_at, current_history_sk
        ) VALUES (
            p_environment_id, p_environment_slug, p_title, p_image_digest, p_status,
            p_difficulty_band, p_estimated_solve_rate, p_owner_vendor_id,
            COALESCE(p_tags, '{}'::text[]),
            p_observed_at, v_history_sk
        ) RETURNING environment_sk INTO v_returned_sk;

        RETURN v_returned_sk;
    END IF;

    -- Case B: no change
    IF v_current_hash = v_new_hash THEN
        SELECT environment_sk INTO v_returned_sk
        FROM dim_environment WHERE environment_id = p_environment_id;
        RETURN v_returned_sk;
    END IF;

    -- Case C: changed — close history row, insert new history row,
    -- update hot row (overwrite in place — that's the SCD4 trick), point
    -- current_history_sk at the new history row.
    UPDATE dim_environment_history
       SET scd_valid_to = p_observed_at, scd_is_current = false
     WHERE environment_history_sk = v_current_history_sk;

    INSERT INTO dim_environment_history (
        environment_id, image_digest, status, difficulty_band,
        estimated_solve_rate, owner_vendor_id, tags,
        scd_valid_from, scd_is_current, scd_version, scd_hash_diff
    ) VALUES (
        p_environment_id, p_image_digest, p_status, p_difficulty_band,
        p_estimated_solve_rate, p_owner_vendor_id, COALESCE(p_tags, '{}'::text[]),
        p_observed_at, true, v_current_ver + 1, v_new_hash
    ) RETURNING environment_history_sk INTO v_history_sk;

    UPDATE dim_environment
       SET image_digest = p_image_digest,
           status = p_status,
           difficulty_band = p_difficulty_band,
           estimated_solve_rate = p_estimated_solve_rate,
           owner_vendor_id = p_owner_vendor_id,
           tags = COALESCE(p_tags, '{}'::text[]),
           last_changed_at = p_observed_at,
           current_history_sk = v_history_sk
     WHERE environment_id = p_environment_id
    RETURNING environment_sk INTO v_returned_sk;

    RETURN v_returned_sk;
END;
$$;

COMMENT ON FUNCTION scd4_upsert_environment IS
  'SCD4 upsert. Updates dim_environment (hot, current-only) in place AND appends a new row to dim_environment_history. Returns the hot environment_sk.';


-- ============================================================================
-- 4. SCD Type 3 update — dim_tool (one prior category retained)
-- ============================================================================

CREATE OR REPLACE FUNCTION scd3_update_tool_category(
    p_tool_name        text,
    p_new_category     text,
    p_observed_at      timestamptz
) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    v_tool_sk           integer;
    v_current_category  text;
BEGIN
    SELECT tool_sk, category
        INTO v_tool_sk, v_current_category
    FROM dim_tool
    WHERE tool_name = p_tool_name
    FOR UPDATE;

    IF v_tool_sk IS NULL THEN
        RAISE EXCEPTION 'Tool % not in catalog. Insert via dim_tool DDL first.', p_tool_name;
    END IF;

    -- No-op if category unchanged
    IF v_current_category = p_new_category THEN
        RETURN v_tool_sk;
    END IF;

    -- Swap: previous gets the old current, current gets the new value.
    -- Note: any earlier "category_previous" is dropped — Type 3 keeps ONE prior only.
    UPDATE dim_tool
       SET category_previous   = v_current_category,
           category            = p_new_category,
           category_changed_at = p_observed_at,
           last_updated_at     = p_observed_at
     WHERE tool_sk = v_tool_sk;

    RETURN v_tool_sk;
END;
$$;

COMMENT ON FUNCTION scd3_update_tool_category IS
  'SCD3 update. Promotes current category into category_previous, sets new current. Only one prior value retained — any earlier category_previous is overwritten.';


-- ============================================================================
-- 5. Materialized view of "current state across all dims" for hot dashboards
-- AlloyDB columnar engine can be hinted to materialize this columnar.
-- ============================================================================

CREATE MATERIALIZED VIEW mv_creator_current AS
SELECT
    c.creator_sk,
    c.creator_id,
    c.primary_repo,
    c.repo_count,
    c.skill_count,
    c.tier,
    c.scd_valid_from AS in_current_state_since,
    s.skill_count_today,
    s.skills_added_7d,
    s.repos_added_7d
FROM dim_creator c
LEFT JOIN LATERAL (
    SELECT
        last.skill_count AS skill_count_today,
        last.skill_count - COALESCE(week_ago.skill_count, last.skill_count) AS skills_added_7d,
        last.repo_count  - COALESCE(week_ago.repo_count,  last.repo_count)  AS repos_added_7d
    FROM (
        SELECT skill_count, repo_count
        FROM fact_creator_snapshot
        WHERE creator_sk = c.creator_sk
        ORDER BY snapshot_ts DESC LIMIT 1
    ) AS last,
    LATERAL (
        SELECT skill_count, repo_count
        FROM fact_creator_snapshot
        WHERE creator_sk = c.creator_sk
          AND snapshot_ts < now() - INTERVAL '7 days'
        ORDER BY snapshot_ts DESC LIMIT 1
    ) AS week_ago
) s ON true
WHERE c.scd_is_current;

CREATE UNIQUE INDEX mv_creator_current_pk ON mv_creator_current (creator_id);

COMMENT ON MATERIALIZED VIEW mv_creator_current IS
  'Hot dashboard view — current state of each creator + 7-day deltas from fact_creator_snapshot. Refreshed by pg_cron every 15 min. On AlloyDB, mark for columnar engine.';
