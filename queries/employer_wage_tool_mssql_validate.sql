-- =============================================================================
-- EMPLOYER WAGE TOOL — WID 3.0 schema discovery (run before _RUN.sql)
-- =============================================================================
-- Read-only. Run all probes in SSMS / Azure Data Studio. Use the output to:
--   (a) confirm AreaType code for LWDAs is '15' on this WID install (Probe 2)
--   (b) stamp _RUN.sql's header with verified column names (high-variance columns
--       called out below — these are the ones where rename = silent wrong numbers)
--   (c) flip the O*NET aliases CTE in _RUN.sql from commented to live if
--       WID.dbo.ONET_TITLES (or equivalent) exists with the expected columns
--
-- NOTE: This tool no longer uses a hand-maintained dbo.LWDA_Slugs seed table —
-- LWDA codes AND labels come live from WID.dbo.GEOGRAPHIES at refresh time
-- (see _RUN.sql lwda_dim / state_area CTEs). There is no elevated setup step.
-- =============================================================================


-- ─── PROBE 1: column inventory for the 5 tables _RUN.sql touches ─────────────
-- High-variance columns to watch (rename = silent wrong numbers, NOT errors):
--   * IOWAGE percentiles: AnnWage10/25/50/75/90, HrWage10/25/50/75/90
--     (variants seen elsewhere: ANNUAL_PCT10_WAGE, A_PCT10)
--   * INDUSTRY employment: QuarterAvgEmp
--     (variants: Month1Emp + Month2Emp + Month3Emp / 3.0 — labor market dashboard hit this)
--   * INDUSTRY establishments: AnnualAvgEst
--     (variants: QtrlyEstabs, Establishments)
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('IOWAGE','INDUSTRY','LABORFORCE','OCCUPATIONS','GEOGRAPHIES','SUBGEOGRAPHIES','ONET_TITLES')
ORDER BY TABLE_NAME, ORDINAL_POSITION;
GO


-- ─── PROBE 2: confirm AreaType code for LWDAs + inventory the lwda_code values
-- The labor market dashboard uses AreaType='15' for LWDAs in this WID install,
-- but BLS variants use '06' or '07'. Confirm before relying on _RUN.sql's
-- AreaType='15' filter in lwda_dim. Expected: N real LWDAs (currently 14) +
-- the synthetic "Combined Projections Area" which _RUN.sql excludes via
-- `AreaName NOT LIKE '%Combined%'`. The output is informational only — no
-- seed table to populate.
SELECT DISTINCT AreaType, Area, AreaName, AreaTypeVersion
FROM WID.dbo.GEOGRAPHIES
WHERE StFips = '51'
  AND (AreaName LIKE '%Consortium%'
    OR AreaName LIKE '%Workforce%'
    OR AreaName LIKE '%LWDA%'
    OR AreaName LIKE '%Region%')
ORDER BY AreaType, Area;
GO


-- ─── PROBE 3: confirm OEWS data is published at LWDA level ───────────────────
-- IOWAGE may only carry statewide ('01') and MSA ('03') — if AreaType=<lwda> rows
-- are absent, every job × LWDA cell will fall back to statewide. That's still
-- valid (provenance='statewide_fallback'), but the client should know up front.
-- Returns row counts per AreaType so you can see at a glance what's loaded.
SELECT AreaType, COUNT(*) AS row_count, MAX(PeriodYear) AS latest_year
FROM WID.dbo.IOWAGE
WHERE StFips = '51'
GROUP BY AreaType
ORDER BY AreaType;
GO


-- ─── PROBE 4: IOWAGE RateType + INDUSTRY Ownership/PeriodType/Period values ─
-- Confirms the dimension values _RUN.sql filters on actually exist in this WID.
-- Expected results (verified against Virginia WID 3.0, 2026-06-04):
--   * IOWAGE.RateType         '1' = Hourly (~$32 median), '4' = Annual (~$67k median).
--                             RUN.sql uses '4' for annual percentiles, '1' for hourly.
--   * INDUSTRY.Ownership      '00' = Total Covered, '10' Federal, '20' State,
--                             '30' Local, '50' Private, '80' unknown (343k VA rows,
--                             non-standard). RUN.sql uses '00'.
--   * INDUSTRY.PeriodType     '01' = annual, '02' = quarterly. RUN.sql uses '01'.
--   * INDUSTRY.Period (for PeriodType='01' rows)  only '00' exists on annual rows
--                             (= full-year aggregate). RUN.sql uses '00'.
SELECT 'IOWAGE.RateType' AS dimension, RateType AS value, COUNT(*) AS row_count
FROM WID.dbo.IOWAGE WHERE StFips = '51' GROUP BY RateType
UNION ALL
SELECT 'INDUSTRY.Ownership', Ownership, COUNT(*)
FROM WID.dbo.INDUSTRY WHERE StFips = '51' GROUP BY Ownership
UNION ALL
SELECT 'INDUSTRY.PeriodType', PeriodType, COUNT(*)
FROM WID.dbo.INDUSTRY WHERE StFips = '51' GROUP BY PeriodType
UNION ALL
SELECT 'INDUSTRY.Period(when 01)', Period, COUNT(*)
FROM WID.dbo.INDUSTRY WHERE StFips = '51' AND PeriodType = '01' GROUP BY Period
ORDER BY dimension, value;
GO


-- ─── PROBE 5: confirm O*NET aliases table presence + shape ───────────────────
-- If this returns 0 rows, the aliases CTE in _RUN.sql stays commented out and
-- every job emits "aliases": []. Frontend handles empty arrays fine.
-- If it returns rows, verify the ONETSOC_CODE format (8 chars like '11-1011.00')
-- and confirm OccCodeVersion exists for the vintage anchor.
SELECT TOP 5 *
FROM WID.dbo.ONET_TITLES;
GO

-- And count distinct SOC-6 prefixes available (sanity check that aggregation
-- via LEFT(ONETSOC_CODE, 7) will produce expected SOC-6 coverage):
SELECT COUNT(DISTINCT LEFT(ONETSOC_CODE, 7)) AS distinct_soc6_codes
FROM WID.dbo.ONET_TITLES
WHERE ALTERNATE_TITLE IS NOT NULL AND ALTERNATE_TITLE <> '';
GO
