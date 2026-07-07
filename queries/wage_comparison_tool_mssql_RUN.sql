-- =============================================================================
-- WAGE COMPARISON TOOL — SQL Server (T-SQL) — JSON-emitting "RUN" build
--
-- Replaces the Snowflake export (WID_DB.ANALYTICS.V_IOWAGE_ENRICHED via Cortex
-- Code, last pulled 2026-05-16) as the data source for apps/wage-tool/. Two
-- queries, each final SELECT wrapped with FOR JSON PATH so SQL Server emits
-- one NVARCHAR(MAX) cell per file:
--
--   Q1 -> apps/wage-tool/data/wages.json
--   Q2 -> apps/wage-tool/data/employment_trend.json
--
-- PREREQUISITES:
--   * queries/wage_comparison_tool_mssql_validate.sql run once; RESULTS LOG
--     filled. ALL probes CONFIRMED against prod 2026-07-07 (P1–P7). Re-run
--     after any WID reload/vintage roll.
--   * This RUN.sql is then scheduled (read-only) for periodic refresh. No
--     elevated setup step; codes and labels come live from dims every run.
--
-- GEOGRAPHY MODEL (client decisions, 2026-07-07):
--   * Areas are MSAs — GEOGRAPHIES/IOWAGE/LABORFORCE AreaType='31' — plus the
--     statewide row (AreaType='01', Area='000000'). Pin exactly '31'; do NOT
--     include '32' Micropolitan / '33' Metro Division / '34' CSA.
--   * Two OMB delineation vintages exist per MSA (AreaTypeVersion '2001' and
--     '2301') with differing names AND definitions. GEOGRAPHIES labels pin to
--     MAX(AreaTypeVersion) per Area so each MSA appears once under its
--     current name (kills the old export's duplicate Virginia Beach rows).
--   * Area LIKE 'S%' rows are state-part splits of multi-state MSAs (e.g.
--     S47900 = Washington MSA "VA Part") — different grain, EXCLUDED.
--   * Multi-state MSAs (Washington DC-VA-MD-WV, Virginia Beach VA-NC,
--     Winchester VA-WV, Kingsport-Bristol TN-VA) are INCLUDED as whole MSAs;
--     figures span state lines. Client decision 2026-07-07: include all.
--     VA-scoped whole-MSA count is 11 (validate P2/P3 — the early "15"
--     figure was unscoped: it counted the 4 'S%' state-part rows).
--   * JSON area.id = the 6-digit GEOGRAPHIES.Area code (no synthetic slugs —
--     project dimension-derived-labels standard). Front-end identifies the
--     statewide row via area.areatype === '01'.
--
-- TARGET YEAR — PINNED LITERAL, NOT MAX():
--   target_year below pins 2024: the richest IOWAGE MSA year on this install
--   (874 occs / 41,858 rows); 2025 rows exist but are partial/preliminary, so
--   MAX(PeriodYear) would silently degrade coverage. Client decision
--   2026-07-07. ROLL-FORWARD: when a new OEWS year finalizes, update the ONE
--   literal in target_year (both queries) and re-run validate P3.
--
-- IOWAGE VINTAGE ANCHOR — per (AreaType, Area, PeriodYear), NOT per Area:
--   CONFIRMED LOAD-BEARING (validate P3b, 2026-07-07): 2021/2023 rows sit
--   under OMB vintage '2001', 2024/2025 under '2301'. A per-Area MAX pin
--   would silently drop 2021 and 2023 from the wage trend; the per-year
--   anchor keeps every year alive while still deduping any dual-vintage rows
--   within a year. The trend therefore splices delineation vintages across
--   years — same tradeoff BLS time series make, and what the tool showed
--   under Snowflake. Do NOT "simplify" this to a per-Area pin.
--
-- TREND-YEAR GAP: IOWAGE has NO 2022 MSA rows (validate P3). trend_years_dim
--   is data-derived, so meta.trend_years emits [2021,2023,2024] and every
--   trend array aligns to those 3 positions. If a 2022 backfill ever lands,
--   the arrays grow to 4 automatically.
--
-- ALIASES — WID.dbo.ONETAlternativeTitles (validate P4, CONFIRMED):
--   The real O*NET alternate-titles table (57,543 rows) — NOT the lossy
--   ONETCodes formal-titles proxy the employer tool documents. ONETCode is
--   8-digit unpunctuated ('21102200'); SOC-6 = LEFT(ONETCode,6). Alias text
--   = ONETJobTitle. Vintage pinned to literal ONETCodeType='12' (single
--   vintage today; pin fails loud if a second vintage rolls the fact side —
--   same discipline as SOCCodeType='19').
--   >>> SEARCH-ONLY RULE: the alias index joins to jobs[] for the search box
--   ONLY. It must NEVER be joined into wage aggregation — alias-count fanout
--   would inflate every wage metric. It is a standalone CTE consumed solely
--   in the final jobs SELECT. <<<
--
-- WID 3.0 conventions in play (verified on the employer-tool port):
--   * IOWAGE: one row per (OccCode, Area, RateType, PeriodYear). RateType
--     '4'=Annual (this tool is annual-only; '1' hourly unused). Percentile
--     cols Percentile10/25/75/90Wage + MedianWage; EmpCount; suppression via
--     SuppressWage/SuppressEmp = '0' means publishable.
--   * All-industries cross-industry row: IndCodeType='10', IndCode='000000'.
--   * SOC codes stored unhyphenated 6-digit; hyphen-tolerant normalization
--     via REPLACE. SOC-6 detail rows only (aggregates end in '0').
--   * SOCCodes dim pinned SOCCodeType='19' (BLS SOC-2018) — labels + major
--     groups. Statewide GEOGRAPHIES/IOWAGE anchor: Area='000000' (the
--     '000051' row is a phantom dup — employer validate Probe 12).
--   * LABORFORCE: PeriodType='03' monthly (Period '01'..'12'), Adjusted='0'
--     (unadjusted — Q2 extracts seasonality deliberately), Employed /
--     LaborForce / UnemployedRate columns.
--
-- PERF NOTE: T-SQL inlines CTEs per reference. all_wages_raw is reachable
--   through at most 4 expansion paths in Q1 (bounded aggregate scans over
--   ~5 yrs × 16 areas of the all-industries SOC-6 slice). Acceptable for a
--   scheduled refresh; if a future WID load makes this slow, restructure as
--   the employer tool did (single-reference chains), don't add temp tables
--   (read-only account).
--
-- JSON SHAPE NOTE: FOR JSON PATH cannot emit dynamic object keys or scalar
--   arrays, so jobs[].areas (keyed by area code), each cell's trend array,
--   meta.trend_years, meta.months, and Q2's entire trends object are
--   hand-built with STRING_AGG (CAST to NVARCHAR(MAX) — 8000-char guard)
--   and spliced via JSON_QUERY. Envelopes use normal FOR JSON PATH.
--
-- REQUIRES: SQL Server 2017+ for STRING_AGG (Azure SQL prod host qualifies).
--   Read-only; no temp tables. Capture each query's single-cell result
--   verbatim to its target file (sqlcmd -y 0, or copy cell from SSMS).
-- =============================================================================


-- =============================================================================
-- QUERY 1: OEWS MSA WAGES + WAGE TRENDS  ->  wages.json
--
-- Shape (unchanged front-end contract, except area ids are now codes):
--   { meta:  { source, extracted_at, latest_year, trend_years[] },
--     areas: [ {id, label, areatype} ],            -- 11 MSAs + statewide
--     jobs:  [ {id, soc_code, label, major_group, aliases[], areas{}} ] }
--   jobs[].areas: keyed object -
--     { "<area_code>": {p10,p25,p50,p75,p90,employment,trend[]}, ... }
--   trend[] = annual MEDIAN (p50) aligned to meta.trend_years; null-padded.
--
-- Cell emission rule: a (soc, area) cell is emitted only when it has a
-- publishable p50 at the target year (no statewide-fallback synthesis — the
-- front-end handles missing cells and offers its own statewide fallback for
-- sparklines). Top-code repair mirrors the employer tool's annual caps:
-- p75/p90 NULL/0 alongside a >$100k lower percentile -> $239,200.
-- =============================================================================

WITH
-- ─── PINNED TARGET YEAR — see header before touching ─────────────────────────
target_year AS (
    SELECT 2024 AS yr    -- PINNED (client decision 2026-07-07); do NOT swap to MAX(PeriodYear)
),

-- ─── MSA DIMENSION — GEOGRAPHIES @ MAX OMB vintage per Area ──────────────────
geo_msa_vintage AS (
    SELECT Area, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '31' AND Area NOT LIKE 'S%'
    GROUP BY Area
),
msa_dim AS (
    SELECT g.Area AS msa_code, g.AreaName AS msa_label
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_msa_vintage gv
      ON gv.Area = g.Area AND gv.AreaTypeVersion = g.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '31' AND g.Area NOT LIKE 'S%'
),

-- ─── STATEWIDE AREA — dynamic from GEOGRAPHIES @ AreaType='01' ───────────────
geo_state_vintage AS (
    SELECT MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '01'
),
state_area AS (
    SELECT g.Area AS state_code, g.AreaName AS state_label
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_state_vintage gv ON g.AreaTypeVersion = gv.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '01'
      AND g.Area = '000000'          -- '000051' phantom dup excluded (employer Probe 12)
),

-- ─── IOWAGE VINTAGE ANCHOR — per (AreaType, Area, PeriodYear) ────────────────
-- Per-YEAR anchor (not per-Area) so trend years published under the older OMB
-- vintage survive; see header. Dedupes dual-vintage rows within a year.
iowage_year_vintage AS (
    SELECT AreaType, Area, PeriodYear, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.IOWAGE
    WHERE StFips = '51' AND AreaType IN ('01','31')
    GROUP BY AreaType, Area, PeriodYear
),

-- ─── TREND YEAR DIMENSION — up to 5 years ending at the pinned target ───────
-- Data-derived (statewide-only scan, bounded): 2022 is absent from IOWAGE
-- (validate P3), so with 2024 pinned this yields [2021,2023,2024]. seq drives
-- trend array positions; a 2022 backfill would flow through automatically.
trend_years_dim AS (
    SELECT y.yr, ROW_NUMBER() OVER (ORDER BY y.yr) AS seq
    FROM (
        SELECT DISTINCT w.PeriodYear AS yr
        FROM WID.dbo.IOWAGE w
        WHERE w.StFips = '51' AND w.AreaType = '01' AND w.Area = '000000'
          AND w.RateType = '4' AND w.IndCodeType = '10' AND w.IndCode = '000000'
          AND w.PeriodYear BETWEEN (SELECT yr FROM target_year) - 4
                                AND (SELECT yr FROM target_year)
    ) y
),

-- ─── SOC DIMENSION — pinned SOCCodeType='19' (BLS SOC-2018) ──────────────────
-- Same pin + rationale as the employer tool: MAX would silently re-key titles
-- if a second SOC vintage loads before IOWAGE rolls; the literal fails loud.
soc_dim AS (
    SELECT RTRIM(sc.SOCCode) AS soc_code, sc.SOCTitle AS soc_title
    FROM WID.dbo.SOCCodes sc
    WHERE sc.SOCCodeType = '19'   -- pinned; do NOT swap to MAX
),
major_group_dim AS (
    SELECT LEFT(soc_code, 2) AS mg_prefix, soc_title AS major_group_name
    FROM soc_dim
    WHERE RIGHT(soc_code, 4) = '0000' AND LEFT(soc_code, 2) <> '00'
),

-- ─── O*NET ALIAS INDEX — SEARCH-ONLY (see header rule) ───────────────────────
-- Standalone index keyed by SOC-6; consumed ONLY in the final jobs SELECT.
-- Inner GROUP BY collapses duplicate alias strings arising when multiple
-- O*NET-SOC detail codes share a SOC-6 prefix.
onet_aliases AS (
    SELECT
        d.soc6,
        '[' + STRING_AGG(
                  CAST('"' + STRING_ESCAPE(d.alias_title, 'json') + '"' AS NVARCHAR(MAX)),
                  ','
              ) WITHIN GROUP (ORDER BY d.alias_title) + ']' AS aliases_json
    FROM (
        SELECT LEFT(a.ONETCode, 6) AS soc6,
               a.ONETJobTitle      AS alias_title
        FROM WID.dbo.ONETAlternativeTitles a
        WHERE a.ONETCodeType = '12'          -- pinned per header; do NOT swap to MAX
          AND a.ONETJobTitle IS NOT NULL
          AND a.ONETJobTitle <> ''
        GROUP BY LEFT(a.ONETCode, 6), a.ONETJobTitle
    ) d
    GROUP BY d.soc6
),

-- ─── SINGLE IOWAGE WAGE SCAN — all trend years, both tiers ───────────────────
-- Annual rows only (RateType='4' — EmpCount rides the same row). One row out
-- per (soc, area, year); GROUP BY is a defensive dedupe on top of the
-- per-year vintage pin.
all_wages_raw AS (
    SELECT
        REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')  AS soc_code,
        RTRIM(w.Area)                              AS area_id,
        w.AreaType                                 AS areatype,
        w.PeriodYear                               AS yr,
        MAX(CASE WHEN w.SuppressWage = '0' THEN TRY_CAST(w.Percentile10Wage AS INT) END) AS p10,
        MAX(CASE WHEN w.SuppressWage = '0' THEN TRY_CAST(w.Percentile25Wage AS INT) END) AS p25,
        MAX(CASE WHEN w.SuppressWage = '0' THEN TRY_CAST(w.MedianWage       AS INT) END) AS p50,
        MAX(CASE WHEN w.SuppressWage = '0' THEN TRY_CAST(w.Percentile75Wage AS INT) END) AS p75,
        MAX(CASE WHEN w.SuppressWage = '0' THEN TRY_CAST(w.Percentile90Wage AS INT) END) AS p90,
        MAX(CASE WHEN w.SuppressEmp  = '0' THEN TRY_CAST(w.EmpCount         AS INT) END) AS employment
    FROM WID.dbo.IOWAGE w
    JOIN iowage_year_vintage iv
      ON iv.AreaType = w.AreaType AND iv.Area = w.Area
     AND iv.PeriodYear = w.PeriodYear AND iv.AreaTypeVersion = w.AreaTypeVersion
    WHERE w.StFips = '51'
      AND (   (w.AreaType = '01' AND w.Area = '000000')
           OR (w.AreaType = '31' AND w.Area NOT LIKE 'S%') )
      AND w.PeriodYear BETWEEN (SELECT yr FROM target_year) - 4
                            AND (SELECT yr FROM target_year)
      AND w.RateType = '4'
      AND w.IndCodeType = '10' AND w.IndCode = '000000'      -- all-industries row
      AND LEN(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')) = 6
      AND RIGHT(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), 1) <> '0'   -- SOC-6 detail only
    GROUP BY REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), RTRIM(w.Area), w.AreaType, w.PeriodYear
),

-- ─── LATEST-YEAR CELLS + TOP-CODE REPAIR ─────────────────────────────────────
-- Cell exists iff publishable p50 at target year. Annual caps mirror the
-- employer tool ($239,200 when p90/p75 top-coded away above a $100k band).
cells_latest AS (
    SELECT
        aw.soc_code, aw.area_id, aw.areatype, aw.employment,
        aw.p10, aw.p25, aw.p50,
        CASE WHEN (aw.p75 IS NULL OR aw.p75 = 0) AND aw.p50 > 100000 THEN 239200 ELSE aw.p75 END AS p75,
        CASE WHEN (aw.p90 IS NULL OR aw.p90 = 0)
                  AND (ISNULL(aw.p75, 0) > 100000 OR aw.p50 > 100000) THEN 239200
             ELSE aw.p90 END                                                                     AS p90,
        CASE WHEN aw.areatype = '01' THEN 'zzz-' + aw.area_id ELSE aw.area_id END               AS area_sort_key
    FROM all_wages_raw aw
    WHERE aw.yr = (SELECT yr FROM target_year)
      AND aw.p50 IS NOT NULL
),

-- ─── PER-CELL WAGE TREND — p50 aligned to trend_years_dim, null-padded ───────
cell_data AS (
    SELECT
        cl.soc_code, cl.area_id, cl.areatype, cl.area_sort_key,
        cl.p10, cl.p25, cl.p50, cl.p75, cl.p90, cl.employment,
        '[' + STRING_AGG(
                  CAST(ISNULL(CONVERT(VARCHAR(20), aw.p50), 'null') AS NVARCHAR(MAX)),
                  ','
              ) WITHIN GROUP (ORDER BY tyd.seq) + ']' AS trend_json
    FROM cells_latest cl
    CROSS JOIN trend_years_dim tyd
    LEFT JOIN all_wages_raw aw
      ON aw.soc_code = cl.soc_code AND aw.area_id = cl.area_id AND aw.yr = tyd.yr
    GROUP BY cl.soc_code, cl.area_id, cl.areatype, cl.area_sort_key,
             cl.p10, cl.p25, cl.p50, cl.p75, cl.p90, cl.employment
),

-- ─── HAND-BUILD jobs[].areas KEYED OBJECT ────────────────────────────────────
job_areas_blob AS (
    SELECT
        cd.soc_code,
        '{' + STRING_AGG(
            CAST(
                '"' + cd.area_id + '":{'
                    + '"p10":'        + ISNULL(CONVERT(VARCHAR(20), cd.p10),        'null') + ','
                    + '"p25":'        + ISNULL(CONVERT(VARCHAR(20), cd.p25),        'null') + ','
                    + '"p50":'        + ISNULL(CONVERT(VARCHAR(20), cd.p50),        'null') + ','
                    + '"p75":'        + ISNULL(CONVERT(VARCHAR(20), cd.p75),        'null') + ','
                    + '"p90":'        + ISNULL(CONVERT(VARCHAR(20), cd.p90),        'null') + ','
                    + '"employment":' + ISNULL(CONVERT(VARCHAR(20), cd.employment), 'null') + ','
                    + '"trend":'      + ISNULL(cd.trend_json, '[]')
                + '}'
                AS NVARCHAR(MAX)
            ),
            ','
        ) WITHIN GROUP (ORDER BY cd.area_sort_key) + '}' AS areas_json
    FROM cell_data cd
    GROUP BY cd.soc_code
)

-- ─── FINAL OUTPUT — wages.json ───────────────────────────────────────────────
SELECT
    JSON_QUERY((
        SELECT
            'WID.dbo.IOWAGE (T-SQL refresh)'                   AS source,
            CONVERT(VARCHAR(33), SYSUTCDATETIME(), 126) + 'Z'  AS extracted_at,
            (SELECT yr FROM target_year)                       AS latest_year,
            JSON_QUERY((
                SELECT '[' + STRING_AGG(CONVERT(VARCHAR(4), yr), ',')
                             WITHIN GROUP (ORDER BY seq) + ']'
                FROM trend_years_dim
            ))                                                 AS trend_years
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS meta,
    JSON_QUERY((
        -- MSA rows bounded to areas actually observed in the target-year
        -- cells; label LEFT-JOINs the dim and falls back to the raw code
        -- (visible-loud; validate P6 expects zero fallbacks).
        SELECT id, label, areatype
        FROM (
            SELECT obs.area_id                          AS id,
                   COALESCE(md.msa_label, obs.area_id)  AS label,
                   '31'                                 AS areatype,
                   obs.area_id                          AS sortk
            FROM (SELECT DISTINCT area_id FROM cell_data WHERE areatype = '31') obs
            LEFT JOIN msa_dim md ON md.msa_code = obs.area_id
            UNION ALL
            SELECT sa.state_code, sa.state_label, '01', 'zzz-' + sa.state_code
            FROM state_area sa
        ) src
        ORDER BY src.sortk
        FOR JSON PATH
    )) AS areas,
    JSON_QUERY((
        SELECT
            STUFF(jb.soc_code, 3, 0, '-')                          AS id,
            STUFF(jb.soc_code, 3, 0, '-')                          AS soc_code,
            COALESCE(sd.soc_title, STUFF(jb.soc_code, 3, 0, '-'))  AS label,
            ISNULL(mgd.major_group_name, 'Other')                  AS major_group,
            -- onet_aliases join = the SEARCH-ONLY consumption point. It joins
            -- job_areas_blob (post-aggregation, one row per SOC) so alias
            -- fanout cannot touch any wage number by construction.
            JSON_QUERY(ISNULL(oa.aliases_json, '[]'))              AS aliases,
            JSON_QUERY(jb.areas_json)                              AS areas
        FROM job_areas_blob jb
        LEFT JOIN soc_dim         sd  ON sd.soc_code  = jb.soc_code
        LEFT JOIN major_group_dim mgd ON mgd.mg_prefix = LEFT(jb.soc_code, 2)
        LEFT JOIN onet_aliases    oa  ON oa.soc6       = jb.soc_code
        ORDER BY jb.soc_code
        FOR JSON PATH
    )) AS jobs
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO


-- =============================================================================
-- QUERY 2: MONTHLY EMPLOYMENT SPARKLINES  ->  employment_trend.json
--
-- Shape (unchanged front-end contract, except key area ids are now codes):
--   { meta:   { source, extracted_at, months[], notes },
--     trends: { "<soc-hyphenated>__<area_code>": [24 x int|null], ... } }
--
-- Methodology (port of the Snowflake seasonal-weighting export, one upgrade):
--   annual IOWAGE EmpCount for each (soc, area, year) is distributed across
--   that year's 12 months using a LABORFORCE seasonal weight
--       w(area, yr, mo) = LaborForce(area, yr, mo) / AVG month LaborForce(area, yr)
--   UPGRADE vs Snowflake: weights are the AREA'S OWN monthly labor-force
--   seasonality where LABORFORCE carries it, not the statewide curve applied
--   to every area. Statewide series uses statewide weights. Window = 24
--   months: (target_year - 1)..target_year.
--
--   STATEWIDE-CURVE FALLBACK (found on first real export, 2026-07-07): LAUS
--   files an MSA's monthly series under its PRIMARY state's StFips, so
--   LABORFORCE at StFips='51' has NO monthly rows for the two MSAs homed in
--   another state — 028700 Kingsport-Bristol (TN-homed) and 047900
--   Washington (DC-homed). VA Beach (VA-NC) and Winchester (VA-WV) are
--   VA-homed and carry their own series. Without a fallback those two areas
--   emitted all-null series — which the front-end treats as "local data
--   present" (truthy array) and renders as an empty sparkline INSTEAD of
--   falling back to statewide. Fix: COALESCE the area's weight with the
--   statewide weight — the employment LEVEL stays the area's own IOWAGE
--   count; only the monthly SHAPE borrows the state curve (exactly the
--   original Snowflake methodology, which applied the state curve to all
--   areas).
--
--   Missing/suppressed inputs (no EmpCount for a year) still emit JSON null
--   at the right index — front-end plots with gaps. Keys exist only for
--   (soc, area) pairs with EmpCount in >= 1 window year; the front-end falls
--   back to the statewide series for absent local keys.
-- =============================================================================

WITH
target_year AS (
    SELECT 2024 AS yr    -- PINNED — keep in lockstep with Q1's pin
),

-- ─── LABORFORCE VINTAGE ANCHOR — same per-year discipline as IOWAGE ─────────
lf_year_vintage AS (
    SELECT AreaType, Area, PeriodYear, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.LABORFORCE
    WHERE StFips = '51' AND AreaType IN ('01','31')
    GROUP BY AreaType, Area, PeriodYear
),

-- ─── MONTH DIMENSION — 24 months from the statewide monthly series ──────────
month_dim AS (
    SELECT lf.PeriodYear                                   AS yr,
           lf.Period                                       AS mo,
           CONCAT(lf.PeriodYear, '-', lf.Period)           AS ym,
           ROW_NUMBER() OVER (ORDER BY lf.PeriodYear, lf.Period) AS seq
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_year_vintage lfv
      ON lfv.AreaType = lf.AreaType AND lfv.Area = lf.Area
     AND lfv.PeriodYear = lf.PeriodYear AND lfv.AreaTypeVersion = lf.AreaTypeVersion
    WHERE lf.StFips = '51' AND lf.AreaType = '01' AND lf.Area = '000000'
      AND lf.PeriodType = '03' AND lf.Adjusted = '0'
      AND lf.PeriodYear IN ((SELECT yr FROM target_year) - 1, (SELECT yr FROM target_year))
),

-- ─── SEASONAL WEIGHTS — each area's own monthly labor-force curve ────────────
-- Carries the StFips='51' '31' MSAs (12 per validate P5) + statewide; the
-- pairs join below bounds output to the 11 IOWAGE MSAs.
area_month_lf AS (
    SELECT
        RTRIM(lf.Area)                     AS area_id,
        lf.PeriodYear                      AS yr,
        lf.Period                          AS mo,
        TRY_CAST(lf.LaborForce AS FLOAT)   AS lf_val
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_year_vintage lfv
      ON lfv.AreaType = lf.AreaType AND lfv.Area = lf.Area
     AND lfv.PeriodYear = lf.PeriodYear AND lfv.AreaTypeVersion = lf.AreaTypeVersion
    WHERE lf.StFips = '51'
      AND (   (lf.AreaType = '01' AND lf.Area = '000000')
           OR (lf.AreaType = '31' AND lf.Area NOT LIKE 'S%') )
      AND lf.PeriodType = '03' AND lf.Adjusted = '0'
      AND lf.PeriodYear IN ((SELECT yr FROM target_year) - 1, (SELECT yr FROM target_year))
),
weights AS (
    SELECT area_id, yr, mo,
           lf_val / NULLIF(AVG(lf_val) OVER (PARTITION BY area_id, yr), 0) AS w
    FROM area_month_lf
),

-- ─── ANNUAL EMPLOYMENT — same IOWAGE constraints as Q1, window years only ────
iowage_year_vintage AS (
    SELECT AreaType, Area, PeriodYear, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.IOWAGE
    WHERE StFips = '51' AND AreaType IN ('01','31')
    GROUP BY AreaType, Area, PeriodYear
),
emp_by_year AS (
    SELECT
        REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')  AS soc_code,
        RTRIM(w.Area)                              AS area_id,
        w.PeriodYear                               AS yr,
        MAX(CASE WHEN w.SuppressEmp = '0' THEN TRY_CAST(w.EmpCount AS INT) END) AS emp
    FROM WID.dbo.IOWAGE w
    JOIN iowage_year_vintage iv
      ON iv.AreaType = w.AreaType AND iv.Area = w.Area
     AND iv.PeriodYear = w.PeriodYear AND iv.AreaTypeVersion = w.AreaTypeVersion
    WHERE w.StFips = '51'
      AND (   (w.AreaType = '01' AND w.Area = '000000')
           OR (w.AreaType = '31' AND w.Area NOT LIKE 'S%') )
      AND w.PeriodYear IN ((SELECT yr FROM target_year) - 1, (SELECT yr FROM target_year))
      AND w.RateType = '4'
      AND w.IndCodeType = '10' AND w.IndCode = '000000'
      AND LEN(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')) = 6
      AND RIGHT(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), 1) <> '0'
    GROUP BY REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), RTRIM(w.Area), w.PeriodYear
),

-- ─── SERIES — (pair × month), null where either input is missing ─────────────
pairs AS (
    SELECT DISTINCT soc_code, area_id
    FROM emp_by_year
    WHERE emp IS NOT NULL
),
series AS (
    -- COALESCE(wt.w, sw.w): statewide-curve fallback for MSAs with no
    -- StFips-51 LAUS monthly series (028700, 047900 — see header). The
    -- area's own weight always wins when present.
    SELECT
        p.soc_code, p.area_id, md.seq,
        CASE WHEN eb.emp IS NULL OR COALESCE(wt.w, sw.w) IS NULL THEN NULL
             ELSE CAST(ROUND(eb.emp * COALESCE(wt.w, sw.w), 0) AS INT) END AS val
    FROM pairs p
    CROSS JOIN month_dim md
    LEFT JOIN emp_by_year eb
      ON eb.soc_code = p.soc_code AND eb.area_id = p.area_id AND eb.yr = md.yr
    LEFT JOIN weights wt
      ON wt.area_id = p.area_id AND wt.yr = md.yr AND wt.mo = md.mo
    LEFT JOIN weights sw
      ON sw.area_id = '000000' AND sw.yr = md.yr AND sw.mo = md.mo
),
trend_arrays AS (
    SELECT soc_code, area_id,
           '[' + STRING_AGG(
                     CAST(ISNULL(CONVERT(VARCHAR(20), val), 'null') AS NVARCHAR(MAX)),
                     ','
                 ) WITHIN GROUP (ORDER BY seq) + ']' AS arr
    FROM series
    GROUP BY soc_code, area_id
),
trends_blob AS (
    -- Key contract: "<hyphenated soc>__<area_id>" — must match wages.json area
    -- ids exactly (front-end builds lookup keys as jobId + '__' + areaId).
    SELECT '{' + STRING_AGG(
                     CAST('"' + STUFF(ta.soc_code, 3, 0, '-') + '__' + ta.area_id + '":' + ta.arr
                          AS NVARCHAR(MAX)),
                     ','
                 ) WITHIN GROUP (ORDER BY ta.soc_code, ta.area_id) + '}' AS blob
    FROM trend_arrays ta
)

-- ─── FINAL OUTPUT — employment_trend.json ────────────────────────────────────
SELECT
    JSON_QUERY((
        SELECT
            'WID.dbo.IOWAGE x WID.dbo.LABORFORCE (T-SQL refresh; per-area monthly seasonal weighting)' AS source,
            CONVERT(VARCHAR(33), SYSUTCDATETIME(), 126) + 'Z'  AS extracted_at,
            JSON_QUERY((
                SELECT '[' + STRING_AGG(CAST('"' + ym + '"' AS NVARCHAR(MAX)), ',')
                             WITHIN GROUP (ORDER BY seq) + ']'
                FROM month_dim
            ))                                                 AS months,
            'Annual EmpCount distributed across months using each area''s own monthly labor-force seasonal weight; statewide weights for the statewide series and for MSAs without a StFips-51 LAUS monthly series (Kingsport-Bristol, Washington).' AS notes
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS meta,
    JSON_QUERY(tb.blob) AS trends
FROM trends_blob tb
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO
