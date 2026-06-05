-- =============================================================================
-- EMPLOYER WAGE TOOL — SQL Server (T-SQL) — JSON-emitting "RUN" build
--
-- Translates queries/employer_wage_tool_snowflake.sql to T-SQL against the
-- production WID 3.0 SQL Server (read-only account). Two queries, each final
-- SELECT wrapped with FOR JSON PATH so SQL Server emits one NVARCHAR(MAX) cell
-- per file:
--
--   Q1 -> apps/wage-tool-employer/data/wages.json
--   Q2 -> apps/wage-tool-employer/data/industries.json
--
-- PREREQUISITES:
--   * Run _validate.sql once; record findings.
--   * Run _setup.sql once (write access) — fills dbo.LWDA_Slugs with real
--     lwda_code + AreaTypeVersion values from validate.sql probe 2.
--   * This RUN.sql is then scheduled (read-only) for periodic refresh.
--
-- WID 3.0 conventions in play (see [[sqlserver_data_pipeline]]):
--   * Schema: WID.dbo.*
--   * AreaType: '01'=state, '15'=LWDA (CONFIRM via _validate.sql probe 2 —
--     some BLS variants use '06'/'07')
--   * AreaTypeVersion: anchor to MAX() per (table, AreaType) — fact/dim
--     vintages diverge.
--   * Ownership codes (verified via _validate.sql Probe 4 on WID 3.0, 2-digit):
--       '00'=Total Covered (sums constituents below) · '10'=Federal · '20'=State ·
--       '30'=Local · '50'=Private · '80'=other/unknown (343k VA rows, not standard
--       BLS QCEW — possibly nonprofit or supplemental). This query uses '00'.
--     Never combine '00' with ('10','20','30','50') in the same filter — that
--     would double-count. Total Covered IS the sum.
--
-- =============================================================================
-- COLUMN ASSUMPTIONS — verify against WID 3.0 before first run
-- =============================================================================
-- Verified-against-real-data marker (fill after _validate.sql probe 1 confirms):
--   Verified: <YYYY-MM-DD>  WID variant: <VA-Azure-WID-3.x or similar>
--
-- HIGH-VARIANCE COLUMNS (rename = silent wrong numbers, NOT runtime errors):
--   * IOWAGE shape: one row per (OccCode, Area, RateType). RateType values
--     (verified via _validate.sql Probe 4 on WID 3.0):
--       '4' = Annual  (median ~$67k across VA statewide)
--       '1' = Hourly  (median ~$32 across VA statewide)
--     Percentile cols: Percentile10Wage, Percentile25Wage, MedianWage,
--     Percentile75Wage, Percentile90Wage. Plus MeanWage, EmpCount.
--     Annual vs hourly are pivoted via conditional aggregation on RateType —
--     NOT separate AnnWage10/HrWage10 cols.
--   * INDUSTRY annual rollup: PeriodType='01' AND Period='00' (numeric codes —
--     '01'=annual, '02'=quarterly; only Period value on annual rows is '00').
--   * INDUSTRY Ownership='00' is the BLS Total Covered row (sums '10' federal,
--     '20' state, '30' local, '50' private — all 2-digit). Use that OR the
--     constituents — never both, or you double-count. This query uses '00'.
--   * INDUSTRY columns (verified via _validate.sql Probe 1 on WID 3.0):
--       - employment    = QuarterAvgEmp (annual rows hold annual avg here)
--                         fallback: (Month1Emp + Month2Emp + Month3Emp) / 3.0
--       - establishments = Establishments
--       - mean_wage     = TotalWages / QuarterAvgEmp on PeriodType='01'
--                         Period='00' rows. Reproduces BLS's published
--                         AvgAnnualPay methodology exactly (annual total wages
--                         divided by annual avg employment, with NULLIF guard
--                         for suppressed/zero-employment cells).
--         NOTE: WID 3.0 spec defines AvgAnnualPay as a first-class published
--         column, but this WID install does not expose it. The derivation
--         above is the closest-to-spec workaround; raise the missing column
--         with the WID owner as a separate ticket — it's a load gap on their
--         end, not something to permanently work around in SQL.
--
-- Other columns referenced (lower-risk, expected to be standard):
--   WID.dbo.IOWAGE       : StFips, Area, AreaType, AreaTypeVersion, PeriodYear,
--                          OccCode, RateType, EmpCount, plus Percentile*Wage /
--                          MedianWage / MeanWage cols above.
--                          MISSING in this WID install: OccName (occupation
--                          label). Label defaults to SOC code. Major group
--                          labels are hardcoded from the BLS SOC structure.
--                          Production fix: load BLS SOC occupation-name
--                          reference (separate WID load-gap ticket — parallel
--                          to the AvgAnnualPay gap above).
--   WID.dbo.INDUSTRY     : StFips, Area, AreaType, AreaTypeVersion, PeriodYear,
--                          PeriodType, Period, Ownership, IndCode,
--                          TotalWages, QuarterAvgEmp, Establishments
--                          (plus Month1/2/3Emp fallback, AvgWeeklyWage, Suppress)
--   WID.dbo.GEOGRAPHIES  : StFips, Area, AreaType, AreaTypeVersion, AreaName
--   dbo.LWDA_Slugs       : lwda_code, lwda_id, lwda_label, AreaTypeVersion
--                          (built by _setup.sql)
--
-- REQUIRES: SQL Server 2017+ for STRING_AGG (Azure SQL — the prod host —
--   qualifies). FOR JSON PATH needs 2016+. Read-only; no temp tables.
--
-- JSON SHAPE NOTE: Both files have a data-keyed `areas` object inside each
--   job/sector (keys = lwda_id slugs). FOR JSON PATH can't dynamically key an
--   object, so that nested blob is hand-built with STRING_AGG and spliced via
--   JSON_QUERY. The outer envelope (meta/areas[]/jobs[] or sectors[]) uses
--   normal FOR JSON PATH.
-- =============================================================================


-- =============================================================================
-- QUERY 1: OEWS OCCUPATION WAGES  ->  wages.json
--
-- Shape: { meta, areas[], jobs[] }
--   meta:    { source, extracted_at, latest_year }
--   areas:   [ {id, label, areatype} ]  — 14 LWDAs + 'virginia' statewide
--   jobs:    [ {id, soc_code, label, major_group, aliases, areas} ]
--     areas: keyed object — { "<lwda_id>": {p10..p90, p10_h..p90_h,
--                                           employment, provenance}, ... }
--
-- Provenance is 3-state:
--   'lwda'                — native LWDA cell exists
--   'statewide_fallback'  — LWDA cell suppressed; copied from statewide
--   'statewide'           — the statewide-area row's own native cell
--
-- Top-code repair caps (mirrors UI v1):
--   annual  $239,200 when p90 NULL/0 with p75 or p50 > $100,000
--   hourly  $115.00  when p90_h NULL/0 with p75_h or p50_h > $50.00
-- =============================================================================

WITH
-- ─── VINTAGE ANCHORS ─────────────────────────────────────────────────────────
iowage_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.IOWAGE
    WHERE StFips = '51'
    GROUP BY StFips, AreaType
),
geo_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY StFips, AreaType
),

-- ─── LWDA DIMENSION (6-column composite identity at the LWDA boundary) ──────
-- Joins GEOGRAPHIES (with vintage anchor) to dbo.LWDA_Slugs. Establishes a
-- 4-column composite key (StFips + AreaType + AreaTypeVersion + Area) for
-- IOWAGE / INDUSTRY to join against. Defensive against future GEOGRAPHIES
-- vintage rollovers — e.g., LWDA III was "Western Virginia" at vintage 0000
-- but "Greater Roanoke Region" at 0002. Binding the slug to a specific
-- AreaTypeVersion prevents silent label drift when the WID load advances.
lwda_dim AS (
    SELECT
        g.StFips, g.AreaType, g.AreaTypeVersion, g.Area AS lwda_code,
        g.AreaName AS wid_name,
        s.lwda_id, s.lwda_label
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    JOIN dbo.LWDA_Slugs s
      ON g.Area = s.lwda_code AND g.AreaTypeVersion = s.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
),

-- ─── LATEST YEAR IN STATEWIDE OEWS ───────────────────────────────────────────
latest_oews_year AS (
    SELECT MAX(w.PeriodYear) AS yr
    FROM WID.dbo.IOWAGE w
    JOIN iowage_vintage iv
      ON w.StFips = iv.StFips AND w.AreaType = iv.AreaType
     AND w.AreaTypeVersion = iv.AreaTypeVersion
    WHERE w.StFips = '51' AND w.AreaType = '01'
),

-- ─── STATEWIDE OEWS (fallback source + 'virginia' area row) ──────────────────
-- IOWAGE shape: one row per (OccCode, Area, RateType). Pivot annual/hourly via
-- conditional aggregation on RateType ('4' = annual, '1' = hourly).
-- EmpCount is the same on both rate-type rows; MAX() pulls it deterministically.
state_wages AS (
    SELECT
        REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')                                                          AS soc_code,
        -- OccName column does not exist in this WID install's IOWAGE table; label
        -- defaults to soc_code in the final SELECT. Production fix: load BLS SOC
        -- occupation-name reference (separate WID load-gap ticket — parallel to
        -- the AvgAnnualPay gap flagged above).
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile10Wage AS INT) END)     AS p10,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile25Wage AS INT) END)     AS p25,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.MedianWage       AS INT) END)     AS p50,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile75Wage AS INT) END)     AS p75,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile90Wage AS INT) END)     AS p90,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile10Wage AS DECIMAL(6,2)) END) AS p10_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile25Wage AS DECIMAL(6,2)) END) AS p25_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.MedianWage       AS DECIMAL(6,2)) END) AS p50_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile75Wage AS DECIMAL(6,2)) END) AS p75_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile90Wage AS DECIMAL(6,2)) END) AS p90_h,
        MAX(CASE WHEN w.SuppressEmp = '0' THEN TRY_CAST(w.EmpCount AS INT) END)                                       AS employment
    FROM WID.dbo.IOWAGE w
    JOIN iowage_vintage iv
      ON w.StFips = iv.StFips AND w.AreaType = iv.AreaType
     AND w.AreaTypeVersion = iv.AreaTypeVersion
    CROSS JOIN latest_oews_year ly
    WHERE w.StFips = '51'
      AND w.AreaType = '01'
      AND w.PeriodYear = ly.yr
      AND w.RateType IN ('1','4')
      AND w.IndCodeType = '10' AND w.IndCode = '000000'   -- all-industries cross-industry row
      AND LEN(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')) = 6   -- SOC-6 (WID stores 6 digits; hyphen-tolerant via REPLACE)         -- SOC-6 only (XX-XXXX)
      AND RIGHT(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), 1) <> '0'   -- SOC-6 detail only (BLS aggregates end in 0)              -- exclude major group totals
    GROUP BY REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')
),

-- ─── LWDA-LEVEL OEWS ─────────────────────────────────────────────────────────
-- Joins on lwda_dim (GEOGRAPHIES + dbo.LWDA_Slugs, 4-col composite). If IOWAGE
-- has no LWDA-level rows in this WID install, this CTE returns 0 rows and EVERY
-- cell falls back to statewide — provenance flips to 'statewide_fallback'.
lwda_wages AS (
    SELECT
        REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')                                                          AS soc_code,
        ld.lwda_id                                                                       AS area_id,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile10Wage AS INT) END)     AS p10,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile25Wage AS INT) END)     AS p25,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.MedianWage       AS INT) END)     AS p50,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile75Wage AS INT) END)     AS p75,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile90Wage AS INT) END)     AS p90,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile10Wage AS DECIMAL(6,2)) END) AS p10_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile25Wage AS DECIMAL(6,2)) END) AS p25_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.MedianWage       AS DECIMAL(6,2)) END) AS p50_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile75Wage AS DECIMAL(6,2)) END) AS p75_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile90Wage AS DECIMAL(6,2)) END) AS p90_h,
        MAX(CASE WHEN w.SuppressEmp = '0' THEN TRY_CAST(w.EmpCount AS INT) END)                                       AS employment
    FROM WID.dbo.IOWAGE w
    JOIN iowage_vintage iv
      ON w.StFips = iv.StFips AND w.AreaType = iv.AreaType
     AND w.AreaTypeVersion = iv.AreaTypeVersion
    JOIN lwda_dim ld                                          -- 3-col composite (StFips+AreaType+Area).
      ON w.StFips = ld.StFips AND w.AreaType = ld.AreaType    -- AreaTypeVersion is intentionally NOT in the
     AND w.Area = ld.lwda_code                                -- join condition: fact vs dim vintages are
                                                              -- independent. iowage_vintage pins IOWAGE to its
                                                              -- MAX, geo_vintage pins GEOGRAPHIES to its MAX;
                                                              -- they may differ.
    CROSS JOIN latest_oews_year ly
    WHERE w.StFips = '51'
      AND w.AreaType = '15'                        -- LWDA (confirm via validate.sql)
      AND w.PeriodYear = ly.yr
      AND w.RateType IN ('1','4')
      AND w.IndCodeType = '10' AND w.IndCode = '000000'   -- all-industries cross-industry row
      AND LEN(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')) = 6   -- SOC-6 (WID stores 6 digits; hyphen-tolerant via REPLACE)
      AND RIGHT(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), 1) <> '0'   -- SOC-6 detail only (BLS aggregates end in 0)
    GROUP BY REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), ld.lwda_id
),

-- ─── TOP-CODE REPAIR ─────────────────────────────────────────────────────────
state_wages_repaired AS (
    SELECT
        soc_code, employment,
        p10, p25, p50,
        CASE WHEN (p75 IS NULL OR p75 = 0) AND p50 > 100000 THEN 239200 ELSE p75 END AS p75,
        CASE WHEN (p90 IS NULL OR p90 = 0)
                  AND (ISNULL(p75, 0) > 100000 OR p50 > 100000) THEN 239200
             ELSE p90 END                                                            AS p90,
        p10_h, p25_h, p50_h,
        CASE WHEN (p75_h IS NULL OR p75_h = 0) AND p50_h > 50.00 THEN 115.00 ELSE p75_h END AS p75_h,
        CASE WHEN (p90_h IS NULL OR p90_h = 0)
                  AND (ISNULL(p75_h, 0) > 50.00 OR p50_h > 50.00) THEN 115.00
             ELSE p90_h END                                                          AS p90_h
    FROM state_wages
),
lwda_wages_repaired AS (
    SELECT
        soc_code, area_id, employment,
        p10, p25, p50,
        CASE WHEN (p75 IS NULL OR p75 = 0) AND p50 > 100000 THEN 239200 ELSE p75 END AS p75,
        CASE WHEN (p90 IS NULL OR p90 = 0)
                  AND (ISNULL(p75, 0) > 100000 OR p50 > 100000) THEN 239200
             ELSE p90 END                                                            AS p90,
        p10_h, p25_h, p50_h,
        CASE WHEN (p75_h IS NULL OR p75_h = 0) AND p50_h > 50.00 THEN 115.00 ELSE p75_h END AS p75_h,
        CASE WHEN (p90_h IS NULL OR p90_h = 0)
                  AND (ISNULL(p75_h, 0) > 50.00 OR p50_h > 50.00) THEN 115.00
             ELSE p90_h END                                                          AS p90_h
    FROM lwda_wages
),

-- ─── MAJOR GROUP LABELS (hardcoded BLS SOC majors) ───────────────────────────
-- Original plan was to source from IOWAGE XX-0000 rows + OccName; IOWAGE has
-- the rows but no OccName column in this WID install. SOC major groups are
-- stable (23 entries), safe to inline.
major_groups AS (
    SELECT * FROM (VALUES
        ('11-0000', 'Management Occupations'),
        ('13-0000', 'Business and Financial Operations'),
        ('15-0000', 'Computer and Mathematical'),
        ('17-0000', 'Architecture and Engineering'),
        ('19-0000', 'Life, Physical, and Social Science'),
        ('21-0000', 'Community and Social Service'),
        ('23-0000', 'Legal'),
        ('25-0000', 'Educational Instruction and Library'),
        ('27-0000', 'Arts, Design, Entertainment, Sports, and Media'),
        ('29-0000', 'Healthcare Practitioners and Technical'),
        ('31-0000', 'Healthcare Support'),
        ('33-0000', 'Protective Service'),
        ('35-0000', 'Food Preparation and Serving Related'),
        ('37-0000', 'Building and Grounds Cleaning and Maintenance'),
        ('39-0000', 'Personal Care and Service'),
        ('41-0000', 'Sales and Related'),
        ('43-0000', 'Office and Administrative Support'),
        ('45-0000', 'Farming, Fishing, and Forestry'),
        ('47-0000', 'Construction and Extraction'),
        ('49-0000', 'Installation, Maintenance, and Repair'),
        ('51-0000', 'Production Occupations'),
        ('53-0000', 'Transportation and Material Moving'),
        ('55-0000', 'Military Specific Occupations')
    ) AS t(mg_code, major_group_name)
),

-- ─── O*NET ALIASES — COMMENTED OUT FOR v1 ────────────────────────────────────
-- Frontend always reads the `aliases` field on each job. v1 emits "aliases": [].
-- To wire real aliases: load O*NET Alternate Titles into WID.dbo.ONET_TITLES
-- (cols: ONETSOC_CODE, ALTERNATE_TITLE, OccCodeVersion) and uncomment the two
-- CTEs below + the LEFT JOIN + the JSON_QUERY swap in the final SELECT.
--
-- onet_vintage AS (
--     SELECT MAX(OccCodeVersion) AS OccCodeVersion
--     FROM WID.dbo.ONET_TITLES
-- ),
-- onet_aliases AS (
--     -- O*NET ONETSOC_CODE is 8 chars (e.g. '11-1011.00'); WID SOC is 6 chars
--     -- (e.g. '11-1011'). LEFT(..., 7) trims to the SOC-6 prefix including the
--     -- hyphen. Inner DISTINCT dedupes the many-to-one fanout (one SOC-6 maps
--     -- to multiple O*NET-SOC detail codes with overlapping alt titles).
--     SELECT
--         soc_code,
--         '[' + STRING_AGG('"' + STRING_ESCAPE(alt, 'json') + '"', ',')
--               WITHIN GROUP (ORDER BY alt) + ']' AS aliases_json
--     FROM (
--         SELECT DISTINCT
--             LEFT(o.ONETSOC_CODE, 7) AS soc_code,
--             o.ALTERNATE_TITLE       AS alt
--         FROM WID.dbo.ONET_TITLES o
--         JOIN onet_vintage ov ON o.OccCodeVersion = ov.OccCodeVersion
--         WHERE o.ALTERNATE_TITLE IS NOT NULL
--           AND o.ALTERNATE_TITLE <> ''
--     ) deduped
--     GROUP BY soc_code
-- ),

-- ─── RESOLVE EVERY (soc_code, area_id) CELL ──────────────────────────────────
all_cells AS (
    -- Native LWDA cells
    SELECT
        lw.soc_code, lw.area_id,
        lw.p10, lw.p25, lw.p50, lw.p75, lw.p90,
        lw.p10_h, lw.p25_h, lw.p50_h, lw.p75_h, lw.p90_h,
        lw.employment,
        'lwda'      AS provenance,
        lw.area_id  AS area_sort_key
    FROM lwda_wages_repaired lw
    WHERE lw.p50 IS NOT NULL

    UNION ALL

    -- Statewide fallback for missing LWDA cells
    SELECT
        sw.soc_code, ld.lwda_id AS area_id,
        sw.p10, sw.p25, sw.p50, sw.p75, sw.p90,
        sw.p10_h, sw.p25_h, sw.p50_h, sw.p75_h, sw.p90_h,
        sw.employment,
        'statewide_fallback'    AS provenance,
        ld.lwda_id              AS area_sort_key
    FROM state_wages_repaired sw
    CROSS JOIN lwda_dim ld
    WHERE NOT EXISTS (
        SELECT 1 FROM lwda_wages_repaired lw2
        WHERE lw2.soc_code = sw.soc_code
          AND lw2.area_id  = ld.lwda_id
          AND lw2.p50 IS NOT NULL
    )

    UNION ALL

    -- The 'virginia' statewide row itself (always native)
    SELECT
        sw.soc_code, 'virginia'  AS area_id,
        sw.p10, sw.p25, sw.p50, sw.p75, sw.p90,
        sw.p10_h, sw.p25_h, sw.p50_h, sw.p75_h, sw.p90_h,
        sw.employment,
        'statewide'              AS provenance,
        'zzz-virginia'           AS area_sort_key
    FROM state_wages_repaired sw
),

-- ─── HAND-BUILD job.areas KEYED OBJECT ───────────────────────────────────────
-- FOR JSON PATH cannot dynamically key an object, so we build the {area_id: {...}}
-- blob as a JSON string per soc_code and splice it in via JSON_QUERY.
job_areas_blob AS (
    SELECT
        ac.soc_code,
        '{' + STRING_AGG(
            CAST(
                '"' + ac.area_id + '":{'
                    + '"p10":'         + ISNULL(CONVERT(VARCHAR(20), ac.p10),         'null') + ','
                    + '"p25":'         + ISNULL(CONVERT(VARCHAR(20), ac.p25),         'null') + ','
                    + '"p50":'         + ISNULL(CONVERT(VARCHAR(20), ac.p50),         'null') + ','
                    + '"p75":'         + ISNULL(CONVERT(VARCHAR(20), ac.p75),         'null') + ','
                    + '"p90":'         + ISNULL(CONVERT(VARCHAR(20), ac.p90),         'null') + ','
                    + '"p10_h":'       + ISNULL(CONVERT(VARCHAR(20), ac.p10_h),       'null') + ','
                    + '"p25_h":'       + ISNULL(CONVERT(VARCHAR(20), ac.p25_h),       'null') + ','
                    + '"p50_h":'       + ISNULL(CONVERT(VARCHAR(20), ac.p50_h),       'null') + ','
                    + '"p75_h":'       + ISNULL(CONVERT(VARCHAR(20), ac.p75_h),       'null') + ','
                    + '"p90_h":'       + ISNULL(CONVERT(VARCHAR(20), ac.p90_h),       'null') + ','
                    + '"employment":'  + ISNULL(CONVERT(VARCHAR(20), ac.employment),  'null') + ','
                    + '"provenance":"' + ac.provenance + '"'
                + '}'
                AS NVARCHAR(MAX)                  -- prevents 8000-char STRING_AGG truncation
            ),
            ','
        ) WITHIN GROUP (ORDER BY ac.area_sort_key) + '}' AS areas_json
    FROM all_cells ac
    GROUP BY ac.soc_code
)

-- ─── FINAL OUTPUT — wages.json ───────────────────────────────────────────────
SELECT
    JSON_QUERY((
        SELECT
            'WID.dbo.IOWAGE (T-SQL refresh)'                  AS source,
            CONVERT(VARCHAR(33), SYSUTCDATETIME(), 126) + 'Z' AS extracted_at,
            TRY_CAST((SELECT yr FROM latest_oews_year) AS INT) AS latest_year
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS meta,
    JSON_QUERY((
        SELECT id, label, areatype
        FROM (
            SELECT ld.lwda_id AS id, ld.lwda_label AS label, '15' AS areatype, ld.lwda_id AS sortk
            FROM lwda_dim ld
            UNION ALL
            SELECT 'virginia', 'Virginia', '01', 'zzz-virginia'
        ) src
        ORDER BY src.sortk
        FOR JSON PATH
    )) AS areas,
    JSON_QUERY((
        SELECT
            STUFF(sw.soc_code, 3, 0, '-')            AS id,
            STUFF(sw.soc_code, 3, 0, '-')            AS soc_code,
            STUFF(sw.soc_code, 3, 0, '-')            AS label,        -- placeholder; OccName not in WID load

            ISNULL(mg.major_group_name, 'Other')     AS major_group,
            JSON_QUERY('[]')                         AS aliases,
            -- When aliases CTE is uncommented above, swap the line above for:
            --   JSON_QUERY(ISNULL(oa.aliases_json, '[]')) AS aliases,
            JSON_QUERY(jb.areas_json)                AS areas
        FROM state_wages_repaired sw
        JOIN job_areas_blob jb ON jb.soc_code = sw.soc_code
        LEFT JOIN major_groups mg ON LEFT(sw.soc_code, 2) + '-0000' = mg.mg_code
        -- LEFT JOIN onet_aliases oa ON oa.soc_code = sw.soc_code
        ORDER BY sw.soc_code
        FOR JSON PATH
    )) AS jobs
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO


-- =============================================================================
-- QUERY 2: QCEW INDUSTRY SUMMARIES  ->  industries.json
--
-- Shape: { meta, areas[], sectors[] }
--   meta:    { source, extracted_at, latest_year }
--   areas:   [ {id, label} ]  — same 14 LWDAs + 'virginia' (no areatype field)
--   sectors: [ {naics, label, areas} ]
--     areas: keyed object — { "<lwda_id>": {mean_wage, employment,
--                                           establishments}, ... }
--
-- Aggregation choice: filter to Ownership='00' (BLS QCEW Total Covered row —
-- federal+state+local+private already summed). One row per (NAICS, area, year),
-- so TotalWages / QuarterAvgEmp / Establishments are taken directly — no
-- weighting. This keeps every NAICS sector populated, including '92' Public
-- Administration. mean_wage = TotalWages / QuarterAvgEmp (BLS AvgAnnualPay
-- methodology); see file header for the WID load-gap note.
--
-- Alternative: filter to Ownership IN ('10','20','30','50') (the constituents)
-- and compute mean_wage as employment-weighted:
--     SUM(TotalWages) / NULLIF(SUM(QuarterAvgEmp), 0)
-- Use if you need per-ownership splits later or don't trust the Total row.
-- DO NOT include '00' AND the constituents simultaneously — double-counts.
-- =============================================================================

WITH
-- ─── VINTAGE ANCHORS ─────────────────────────────────────────────────────────
ind_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.INDUSTRY
    WHERE StFips = '51' AND AreaType IN ('01', '15')
    GROUP BY StFips, AreaType
),
geo_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY StFips, AreaType
),

-- ─── LWDA DIMENSION (6-column composite identity at the LWDA boundary) ──────
-- See Q1 header note. Same pattern, redefined here because Q1 and Q2 are
-- separate batches (GO separator) and CTEs don't carry across.
lwda_dim AS (
    SELECT
        g.StFips, g.AreaType, g.AreaTypeVersion, g.Area AS lwda_code,
        g.AreaName AS wid_name,
        s.lwda_id, s.lwda_label
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    JOIN dbo.LWDA_Slugs s
      ON g.Area = s.lwda_code AND g.AreaTypeVersion = s.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
),

-- ─── LATEST ANNUAL YEAR IN INDUSTRY (statewide) ──────────────────────────────
latest_ind_year AS (
    SELECT MAX(i.PeriodYear) AS yr
    FROM WID.dbo.INDUSTRY i
    JOIN ind_vintage iv
      ON i.StFips = iv.StFips AND i.AreaType = iv.AreaType
     AND i.AreaTypeVersion = iv.AreaTypeVersion
    WHERE i.StFips = '51' AND i.AreaType = '01'
      AND i.PeriodType = '01' AND i.Period = '00'    -- annual full-year aggregate
),

-- ─── NAICS-2 SECTOR LOOKUP (QCEW supersector range encoding) ────────────────
-- BLS QCEW publishes three NAICS supersectors as combined 2-digit RANGES,
-- not as single 2-digit codes:
--   '31-33' Manufacturing  (covers NAICS 31, 32, 33)
--   '44-45' Retail Trade  (covers NAICS 44, 45)
--   '48-49' Transportation & Warehousing  (covers NAICS 48, 49)
-- WID stores the IndCode literally as the hyphenated range string. The other
-- 17 NAICS-2 sectors store as single 2-digit codes (e.g. '11', '22'). Joining
-- on a single 2-digit code would silently drop Manufacturing, Retail Trade,
-- and Transportation — three of Virginia's largest sectors.
-- Solution: two-column lookup. wid_code = the form actually stored in
-- IndCode (used in the JOIN); naics_code = the clean 2-digit form (emitted
-- into the JSON so the UI's sector keys stay consistent with the skeleton).
naics_sectors AS (
    SELECT * FROM (VALUES
        ('11', '11',    'Agriculture, Forestry, Fishing & Hunting'),
        ('21', '21',    'Mining, Quarrying & Oil/Gas Extraction'),
        ('22', '22',    'Utilities'),
        ('23', '23',    'Construction'),
        ('31', '31-33', 'Manufacturing'),
        ('42', '42',    'Wholesale Trade'),
        ('44', '44-45', 'Retail Trade'),
        ('48', '48-49', 'Transportation & Warehousing'),
        ('51', '51',    'Information'),
        ('52', '52',    'Finance & Insurance'),
        ('53', '53',    'Real Estate & Rental/Leasing'),
        ('54', '54',    'Professional, Scientific & Technical'),
        ('55', '55',    'Management of Companies'),
        ('56', '56',    'Administrative & Support/Waste Mgmt'),
        ('61', '61',    'Educational Services'),
        ('62', '62',    'Health Care & Social Assistance'),
        ('71', '71',    'Arts, Entertainment & Recreation'),
        ('72', '72',    'Accommodation & Food Services'),
        ('81', '81',    'Other Services (except Public Admin)'),
        ('92', '92',    'Public Administration')
    ) AS t(naics_code, wid_code, sector_name)
),

-- ─── STATEWIDE QCEW (BLS Total Covered row direct, no rollup) ───────────────
-- Ownership='00' = one row per (NAICS, area). mean_wage uses the BLS AvgAnnualPay
-- formula: TotalWages / QuarterAvgEmp on the PeriodType='01' Period='00' row.
-- To split by ownership instead, flip filter to IN ('10','20','30','50') and
-- use SUM(TotalWages) / NULLIF(SUM(QuarterAvgEmp), 0) per (NAICS, area).
state_qcew AS (
    SELECT
        ns.naics_code                                                          AS naics_code,
        TRY_CAST(i.TotalWages
                 / NULLIF(COALESCE(i.QuarterAvgEmp,
                                   (i.Month1Emp + i.Month2Emp + i.Month3Emp) / 3.0), 0) AS INT) AS mean_wage,
        TRY_CAST(COALESCE(i.QuarterAvgEmp,
                          (i.Month1Emp + i.Month2Emp + i.Month3Emp) / 3.0) AS INT) AS employment,
        TRY_CAST(i.Establishments AS INT)                                      AS establishments
    FROM WID.dbo.INDUSTRY i
    JOIN ind_vintage iv
      ON i.StFips = iv.StFips AND i.AreaType = iv.AreaType
     AND i.AreaTypeVersion = iv.AreaTypeVersion
    JOIN naics_sectors ns ON ns.wid_code = LTRIM(RTRIM(i.IndCode))   -- matches WID's hyphenated supersector ranges
    CROSS JOIN latest_ind_year ly
    WHERE i.StFips = '51'
      AND i.AreaType = '01'
      AND i.PeriodYear = ly.yr
      AND i.PeriodType = '01' AND i.Period = '00'
      AND i.Ownership = '00'
      -- Suppress filter intentionally OMITTED. INDUSTRY.Suppress='1' covers ~66%
      -- of VA annual rows (per validate.sql diagnostic) — too broad to be BLS
      -- confidentiality. Values on flagged rows are populated and reconcile to
      -- statewide totals at 99.96% — likely flags imputation/quality, not
      -- non-publishability. Revisit if WID load semantics are documented.
),

-- ─── PER-LWDA QCEW (Ownership='00' = BLS Total Covered row) ────────────────
lwda_qcew AS (
    SELECT
        ld.lwda_id                                                             AS area_id,
        ns.naics_code                                                          AS naics_code,
        TRY_CAST(i.TotalWages
                 / NULLIF(COALESCE(i.QuarterAvgEmp,
                                   (i.Month1Emp + i.Month2Emp + i.Month3Emp) / 3.0), 0) AS INT) AS mean_wage,
        TRY_CAST(COALESCE(i.QuarterAvgEmp,
                          (i.Month1Emp + i.Month2Emp + i.Month3Emp) / 3.0) AS INT) AS employment,
        TRY_CAST(i.Establishments AS INT)                                      AS establishments
    FROM WID.dbo.INDUSTRY i
    JOIN ind_vintage iv
      ON i.StFips = iv.StFips AND i.AreaType = iv.AreaType
     AND i.AreaTypeVersion = iv.AreaTypeVersion
    JOIN lwda_dim ld                                          -- 3-col composite (StFips+AreaType+Area).
      ON i.StFips = ld.StFips AND i.AreaType = ld.AreaType    -- AreaTypeVersion is intentionally NOT in the
     AND i.Area = ld.lwda_code                                -- join condition: fact vs dim vintages are
                                                              -- independent. ind_vintage pins INDUSTRY to its
                                                              -- MAX, geo_vintage pins GEOGRAPHIES to its MAX;
                                                              -- they may differ.
    JOIN naics_sectors ns ON ns.wid_code = LTRIM(RTRIM(i.IndCode))   -- matches WID's hyphenated supersector ranges
    CROSS JOIN latest_ind_year ly
    WHERE i.StFips = '51'
      AND i.AreaType = '15'
      AND i.PeriodYear = ly.yr
      AND i.PeriodType = '01' AND i.Period = '00'
      AND i.Ownership = '00'
      -- Suppress filter intentionally OMITTED. INDUSTRY.Suppress='1' covers ~66%
      -- of VA annual rows (per validate.sql diagnostic) — too broad to be BLS
      -- confidentiality. Values on flagged rows are populated and reconcile to
      -- statewide totals at 99.96% — likely flags imputation/quality, not
      -- non-publishability. Revisit if WID load semantics are documented.
),

-- ─── COMBINE ALL CELLS ───────────────────────────────────────────────────────
all_industry_cells AS (
    SELECT area_id, naics_code, mean_wage, employment, establishments,
           area_id AS area_sort_key
    FROM lwda_qcew

    UNION ALL

    SELECT 'virginia' AS area_id, naics_code, mean_wage, employment, establishments,
           'zzz-virginia' AS area_sort_key
    FROM state_qcew
),

-- ─── HAND-BUILD sector.areas KEYED OBJECT ────────────────────────────────────
sector_areas_blob AS (
    SELECT
        aic.naics_code,
        '{' + STRING_AGG(
            CAST(
                '"' + aic.area_id + '":{'
                    + '"mean_wage":'      + ISNULL(CONVERT(VARCHAR(20), aic.mean_wage),      'null') + ','
                    + '"employment":'     + ISNULL(CONVERT(VARCHAR(20), aic.employment),     'null') + ','
                    + '"establishments":' + ISNULL(CONVERT(VARCHAR(20), aic.establishments), 'null')
                + '}'
                AS NVARCHAR(MAX)                  -- prevents 8000-char STRING_AGG truncation
            ),
            ','
        ) WITHIN GROUP (ORDER BY aic.area_sort_key) + '}' AS areas_json
    FROM all_industry_cells aic
    GROUP BY aic.naics_code
)

-- ─── FINAL OUTPUT — industries.json ──────────────────────────────────────────
SELECT
    JSON_QUERY((
        SELECT
            'WID.dbo.INDUSTRY (QCEW, T-SQL refresh)'          AS source,
            CONVERT(VARCHAR(33), SYSUTCDATETIME(), 126) + 'Z' AS extracted_at,
            TRY_CAST((SELECT yr FROM latest_ind_year) AS INT)  AS latest_year
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS meta,
    JSON_QUERY((
        SELECT id, label
        FROM (
            SELECT ld.lwda_id AS id, ld.lwda_label AS label, ld.lwda_id AS sortk
            FROM lwda_dim ld
            UNION ALL
            SELECT 'virginia', 'Virginia', 'zzz-virginia'
        ) src
        ORDER BY src.sortk
        FOR JSON PATH
    )) AS areas,
    JSON_QUERY((
        SELECT
            ns.naics_code                AS naics,
            ns.sector_name               AS label,
            JSON_QUERY(sab.areas_json)   AS areas
        FROM naics_sectors ns
        JOIN sector_areas_blob sab ON sab.naics_code = ns.naics_code
        ORDER BY ns.naics_code
        FOR JSON PATH
    )) AS sectors
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO
