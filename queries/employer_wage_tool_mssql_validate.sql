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


-- ─── PROBE 6: county → LWDA membership — discovery for region search feature ─
-- Client request: extend Region filter so typing a county name (e.g. "Henrico")
-- surfaces the LWDA containing that county. Mirrors the Job Family filter's
-- alias-aware Tom Select pattern (see wage-tool-employer.html lines 962-1019).
-- Requires emitting a `counties: [...]` array per LWDA in wages.json.areas[].
--
-- Past sourcing precedent: the Employer Wage Tool has only ever pulled the LWDA
-- ROW itself from WID.dbo.GEOGRAPHIES (AreaType='15') — never asked for the
-- counties inside. P6 of dimension_resolution_probe.sql confirmed GEOGRAPHIES
-- has no parent_area / RegionCode column. So county → LWDA membership lives
-- somewhere we haven't probed yet. Three candidates:
--   (a) Counties live in GEOGRAPHIES under a different AreaType (BLS convention
--       is '04' = county) and the linkage is positional / by area-code prefix.
--   (b) WID.dbo.SUBGEOGRAPHIES carries an explicit xwalk (table name surfaced
--       in Probe 1 IN list but never inventoried).
--   (c) Neither — county → LWDA isn't in WID at all and we ship a one-time
--       static xwalk from BLS / VEC reference data.
--
-- Probe 6 enumerates 6a, 6b, 6c in order. Read the results and decide which
-- path the RUN.sql counties-array CTE follows.
-- =============================================================================


-- ─── PROBE 6a: all AreaType values in GEOGRAPHIES for VA ─────────────────────
-- Today's known AreaTypes (from prior probes): '01' statewide, '15' LWDA.
-- This probe enumerates EVERY AreaType present and shows a 3-row sample of
-- each. Look in the results for:
--   * An AreaType with ~95-133 rows and AreaNames like "Henrico County" /
--     "City of Richmond" — that's the VA county tier (95 counties + 38
--     independent cities = 133 county-equivalents). Likely '04' per BLS
--     convention, but confirm here.
--   * An AreaType with MSA-style names ("Richmond, VA Metro Area") — that's
--     '03' MSA, not what we need but informative.
--   * Any tier that looks like a parent-of-LWDA grouping — unlikely but
--     surface it if present.
SELECT
    g.AreaType,
    COUNT(*)            AS row_count,
    MIN(g.AreaName)     AS sample_first,
    MAX(g.AreaName)     AS sample_last
FROM WID.dbo.GEOGRAPHIES g
WHERE g.StFips = '51'
  AND g.AreaTypeVersion = (
      SELECT MAX(AreaTypeVersion) FROM WID.dbo.GEOGRAPHIES gv
      WHERE gv.StFips = g.StFips AND gv.AreaType = g.AreaType
  )
GROUP BY g.AreaType
ORDER BY g.AreaType;
GO


-- ─── PROBE 6b: does WID.dbo.SUBGEOGRAPHIES exist? what columns? ──────────────
-- INFORMATION_SCHEMA lookup is defensive — if the table doesn't exist this
-- just returns 0 rows instead of erroring. The name surfaced in Probe 1's
-- IN list but was never inventoried.
--
-- Look in the results for column names like ParentArea / ChildArea / Area /
-- AreaType + ParentAreaType (the "child geography belongs to parent geography
-- of this type" shape). Also surface any *Slug / *Name / *Code variants so
-- we know what's queryable.
--
-- Also catches near-name variants — some WID installs use 'GeographyXGeography'
-- or 'AreaXArea' instead.
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('SUBGEOGRAPHIES', 'GeographyXGeography', 'AreaXArea',
                     'GeographyHierarchy', 'AreaHierarchy', 'GeoXref',
                     'GEOGRAPHIESXGEOGRAPHIES')
ORDER BY TABLE_NAME, ORDINAL_POSITION;
GO


-- ─── PROBE 6c: catch-all — find ANY table/column hinting at geo hierarchy ───
-- If 6b returns 0 rows, the xwalk might live under a name we haven't guessed.
-- This searches INFORMATION_SCHEMA broadly for tables with hierarchy-sounding
-- columns. Tables that mention 'County' in their name OR have a 'Parent*' /
-- 'LWDA*' column are the prime suspects.
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo'
  AND (
        COLUMN_NAME LIKE 'Parent%'
     OR COLUMN_NAME LIKE 'ParentArea%'
     OR COLUMN_NAME LIKE '%LWDA%'
     OR COLUMN_NAME LIKE 'County%'
     OR COLUMN_NAME LIKE '%CountyFips%'
     OR TABLE_NAME  LIKE '%County%'
     OR TABLE_NAME  LIKE '%LWDA%'
     OR TABLE_NAME  LIKE '%WDA%'
     OR TABLE_NAME  LIKE '%Region%'
  )
ORDER BY TABLE_NAME, COLUMN_NAME;
GO


-- ─── PROBE 6d: sample the xwalk for two known LWDAs (REAL COLUMN NAMES) ────
-- 6b confirmed SubGeographies on 2026-06-12 with columns: StFips, AreaType,
-- AreaTypeVersion, Area (parent), SubStFips, SubAreaType, SubAreaTypeVersion,
-- SubArea (child). This probe samples LWDA→county membership for two known
-- LWDAs to confirm the xwalk produces the expected county+city lists.
--
-- Two example LWDAs to anchor:
--   '000449' = Capital Region (LWDA IX)   — Richmond area
--   '000455' = Crater Region (LWDA V)     — Petersburg area
-- Expected after vintage-pinning (sgeo_vintage equivalent inline below):
--   Capital: 7 counties + 1 indep city (Richmond city) = 8 rows
--   Crater:  5 counties + 4 indep cities (Colonial Heights, Emporia,
--            Hopewell, Petersburg) = 9 rows
SELECT TOP 40
    sg.Area               AS lwda_code,
    sg.SubAreaType        AS sub_areatype,
    sg.SubArea            AS sub_area_code,
    g.AreaName            AS sub_name
FROM WID.dbo.SubGeographies sg
LEFT JOIN WID.dbo.GEOGRAPHIES g
  ON g.StFips          = sg.SubStFips
 AND g.AreaType        = sg.SubAreaType
 AND g.AreaTypeVersion = sg.SubAreaTypeVersion
 AND g.Area            = sg.SubArea
WHERE sg.StFips = '51'
  AND sg.AreaType = '15'
  AND sg.SubAreaType = '04'
  AND sg.AreaTypeVersion = (
      SELECT MAX(AreaTypeVersion) FROM WID.dbo.SubGeographies
      WHERE StFips = '51' AND AreaType = '15'
  )
  AND sg.Area IN ('000449', '000455')
ORDER BY sg.Area, sg.SubAreaType, sg.SubArea;
GO


-- ─── PROBE 6e: vintage diagnostic for SubGeographies ────────────────────────
-- Ran 2026-06-12 to diagnose the 3x duplication seen in 6d's first run.
-- Result: 3 vintages of SubGeographies coexist on this install (0000=134,
-- 0001=133, 0002=133 rows for StFips='51' AreaType='15'). MAX-pin to '0002'
-- is the standard vintage-anchor fix (sgeo_vintage CTE in RUN.sql).
SELECT AreaTypeVersion, COUNT(*) AS row_count
FROM WID.dbo.SubGeographies
WHERE StFips = '51' AND AreaType = '15'
GROUP BY AreaTypeVersion
ORDER BY AreaTypeVersion;
GO


-- ─── PROBE 6 RESULTS LOG — ran 2026-06-12, conclusion PATH A ────────────────
-- The probes resolved that county→LWDA membership lives in WID.dbo.SubGeographies
-- (PATH A). RUN.sql now sources counties+independent-cities live via the
-- sgeo_vintage + lwda_counties CTEs.
--
-- 6a — AreaTypes present in GEOGRAPHIES (VA, latest vintage):
--    AreaType  row_count  sample_first                 sample_last
--    --------  ---------  ---------------------------  -----------------------------
--    01           2       Virginia                     Virginia            ← 2 ROWS — see footnote
--    04         138       Accomack County              York County         ← county tier
--    09          21       Accomack-Northampton PDC     West Piedmont PDC
--    10           6       Alleghany-Covington LMA      Wise-Norton LMA
--    11          42       Alexandria city              Winchester city     ← VA indep cities
--    12         227       Abingdon town                Wytheville town
--    15          15       Alexandria/Arlington (XII)   West Piedmont (X)   ← LWDA tier (14 + 1 Combined)
--    19          11       Congressional District 1     Congressional District 9
--    30           4       Northeast Virginia           Southwest Virginia
--    31          15       Blacksburg-Christiansburg    Winchester MSA
--    32           5       Bluefield Micropolitan       Martinsville Micropolitan
--    33           2       Arlington-Alexandria-Reston  Arlington-Alexandria-Reston VA Part
--    34           4       Harrisonburg-Staunton        Washington-Baltimore-Arlington
--    50           4       Northeast Virginia           Southwest Virginia
--    57          23       Blue Ridge Community College Wytheville Community College
--    County tier identified?  Y — AreaType '04' (BLS convention).
--    Note: VA indep cities at AreaType='11' are NOT used for LWDA membership;
--    SubGeographies references them under SubAreaType='04' (BLS lumps them).
--    FOOTNOTE: AreaType='01' returns 2 rows on this install — state_area CTE
--    in RUN.sql needs a deterministic filter to pick exactly one. Probe 11
--    (added 2026-06-12) inspects the two rows; fix is pending its result.
--
-- 6b — SubGeographies column inventory:
--    Table found?  Y — name: WID.dbo.SubGeographies (camelCase, not all-caps)
--    Columns:
--       StFips             char(2)
--       AreaType           char(2)
--       AreaTypeVersion    char(4)
--       Area               char(6)        ← parent (the LWDA when AreaType='15')
--       SubStFips          char(2)
--       SubAreaType        char(2)
--       SubAreaTypeVersion char(4)
--       SubArea            char(6)        ← child (the county/city)
--    Parent/child shape detected?  Y — classic (Area, SubArea) xwalk.
--
-- 6c — Catch-all hierarchy hits:
--    Only EmpDB.ParentID surfaced (unrelated to geo hierarchy). Confirms
--    SubGeographies is the sole xwalk table on this install.
--
-- 6d — Sample xwalk rows for LWDA 000449 (Capital) + 000455 (Crater):
--    Row counts as expected (~10-20 per LWDA)?  Y after vintage pin.
--    Capital (000449):  7 counties + 1 indep city (Richmond city)        = 8 rows
--    Crater  (000455):  5 counties + 4 indep cities (Colonial Heights,
--                                                   Emporia, Hopewell,
--                                                   Petersburg)          = 9 rows
--    County names readable?  Y — sourced directly from GEOGRAPHIES.AreaName.
--    Note: first run of 6d returned 3x duplicates (24 + 27 rows). Probe 6e
--    diagnosed the cause — 3 SubGeographies vintages coexist. RUN.sql's
--    sgeo_vintage CTE pins to MAX (currently '0002').
--
-- 6e — SubGeographies vintage inventory (VA, AreaType='15'):
--    AreaTypeVersion  row_count
--    0000             134
--    0001             133
--    0002             133              ← MAX-pinned by sgeo_vintage CTE
--
-- Conclusion:  PATH A (SubGeographies xwalk, vintage-pinned)
-- Path taken in RUN.sql counties CTE:
--   sgeo_vintage    — MAX(AreaTypeVersion) per (StFips, AreaType='15')
--   lwda_counties   — JOIN SubGeographies → GEOGRAPHIES on Sub* tuple,
--                     STRING_AGG to JSON array per LWDA. Statewide row
--                     emits counties:[] (search shouldn't match Virginia).
GO
