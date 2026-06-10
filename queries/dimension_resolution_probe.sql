-- =============================================================================
-- DIMENSION RESOLUTION PROBE — WID 3.0 (Azure SQL, read-only)
-- =============================================================================
-- Purpose:
--   Discover which WID 3.0 dimension tables are populated on this install,
--   so the Front Page Dashboard (queries/labor_market_dashboard_mssql_RUN_v8.sql)
--   and Employer Wage Tool (queries/employer_wage_tool_mssql_RUN.sql) can be
--   rewired to JOIN dimension tables for every human-readable label at refresh
--   time, instead of hardcoding labels in CTEs, seed tables, or static JSON.
--
-- Project-wide standard being enforced:
--   * All display labels (LWDA names, NAICS sector/supersector titles, SOC
--     titles, O*NET aliases, Ownership labels) come from JOINing the code's
--     WID dimension table at refresh time.
--   * Codes remain the emitted join keys AND the JSON area.id values — no
--     synthetic URL slug. (Prior versions had a hand-maintained dbo.LWDA_Slugs
--     seed table; that's been removed. JSON area.id is now the lwda_code from
--     GEOGRAPHIES.Area directly.)
--   * No hardcoded labels in CTEs, seed tables, or static JSON.
--   * No substring-parsing of dimension fields (e.g. GEOGRAPHIES.AreaName)
--     for display labels.
--
-- How to run:
--   1. Open this file in SSMS / Azure Data Studio against the WID server.
--   2. Run all probes P1..P9 sequentially. Each is independent.
--      "Invalid object name" on an existence query means that dimension is
--      not loaded on this install — that's expected for some.
--   3. For each probe, paste outcomes into the RESULTS LOG at the bottom
--      using the LOADED / EMPTY / MISSING classification.
--   4. Share the populated RESULTS LOG back. That's the input for Step 2
--      (the SQL/doc rewire).
--
-- Outcome semantics:
--   LOADED   — table exists, has rows, code+label columns identifiable.
--              → Rewire SQL to JOIN this dimension at refresh time.
--   EMPTY    — table exists, 0 rows.
--              → Treat as MISSING for rewire purposes; file a load-gap
--                ticket against the actual table name.
--   MISSING  — table does not exist (Msg 208 on existence query).
--              → Keep the static-JSON fallback; reclassify the existing
--                load-gap entry to name THIS dimension as the missing one.
-- =============================================================================


-- ─── P1: SOCCodes — SOC-6 → occupation title ─────────────────────────────────
-- Target: Employer Q1 (wages.json `label`, currently emits soc_code as a
-- placeholder; soc-titles.json patches client-side).
-- Planned rewire if LOADED:
--   LEFT JOIN WID.dbo.SOCCodes sc
--     ON RTRIM(sc.SOCCode) = REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')
--    AND sc.SOCCodeType = <latest vintage from P9.a>
--   → emit sc.<title-column-from-P1.b> AS label
-- =============================================================================

-- 1a. Existence
SELECT 'P1.a' AS probe, TABLE_NAME, TABLE_TYPE
FROM WID.INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = 'SOCCodes';

-- 1b. Column inventory — note any column that looks like a title/name/desc.
SELECT 'P1.b' AS probe, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'SOCCodes'
ORDER BY ORDINAL_POSITION;

-- 1c. Sample rows (so we can see what real titles look like).
SELECT TOP 5 * FROM WID.dbo.SOCCodes;

-- 1d. Row count + distinct code count (gauges coverage).
SELECT 'P1.d' AS probe,
       COUNT(*) AS total_rows,
       COUNT(DISTINCT SOCCode) AS distinct_codes
FROM WID.dbo.SOCCodes;

-- 1e. CHAR padding behavior on SOCCode (RTRIM required if CHAR(N) padded).
SELECT TOP 3
       'P1.e' AS probe,
       '|' + SOCCode + '|' AS with_pipes,
       LEN(SOCCode) AS len_trimmed,
       DATALENGTH(SOCCode) AS datalength_raw
FROM WID.dbo.SOCCodes;
GO


-- ─── P2: ONETCodes — O*NET-SOC code + title ──────────────────────────────────
-- Target: Employer Q1 (wages.json `aliases`).
-- Planned rewire if LOADED (paired with P3): aliases via crosswalk JOINs.
-- =============================================================================

-- 2a. Existence
SELECT 'P2.a' AS probe, TABLE_NAME
FROM WID.INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = 'ONETCodes';

-- 2b. Column inventory
SELECT 'P2.b' AS probe, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'ONETCodes'
ORDER BY ORDINAL_POSITION;

-- 2c. Sample
SELECT TOP 5 * FROM WID.dbo.ONETCodes;

-- 2d. Row count
SELECT 'P2.d' AS probe, COUNT(*) AS total_rows FROM WID.dbo.ONETCodes;
GO


-- ─── P3: OccupationXOccupation — SOC ↔ O*NET-SOC ↔ alt-title crosswalk ─────
-- Target: Employer Q1 (wages.json `aliases`).
-- Planned rewire if LOADED (paired with P2): aliases via
--   WID.dbo.SOCCodes ⟕ OccupationXOccupation ⟕ ONETCodes
-- The crosswalk's row "Type" column (Probe 3b) determines which alt-title
-- relationship type we harvest.
-- =============================================================================

-- 3a. Existence
SELECT 'P3.a' AS probe, TABLE_NAME
FROM WID.INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = 'OccupationXOccupation';

-- 3b. Column inventory — watch for: code1/code2 join columns, a "type"
-- column for relationship class (alias / parent / etc.), and a StFips
-- column (if state-scoped).
SELECT 'P3.b' AS probe, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'OccupationXOccupation'
ORDER BY ORDINAL_POSITION;

-- 3c. Unscoped sample (to see all columns regardless of StFips)
SELECT TOP 5 * FROM WID.dbo.OccupationXOccupation;

-- 3d. Row count
SELECT 'P3.d' AS probe, COUNT(*) AS total_rows FROM WID.dbo.OccupationXOccupation;

-- 3e. VA-scoped sample — RUN ONLY IF 3.b shows a StFips column. Comment
-- out if no StFips column exists.
SELECT TOP 5 * FROM WID.dbo.OccupationXOccupation WHERE StFips = '51';
GO


-- ─── P4: NAICSSectors — NAICS 2-digit code → sector title ───────────────────
-- Target: Employer Q2 (industries.json `label` for the 17 single-2-digit NAICS
-- sectors; currently hardcoded in the naics_sectors VALUES CTE).
-- Planned rewire if LOADED:
--   LEFT JOIN WID.dbo.NAICSSectors ns ON ns.<code-col> = naics_2digit_code
--   → emit ns.<title-col> AS label
-- =============================================================================

-- 4a. Existence
SELECT 'P4.a' AS probe, TABLE_NAME
FROM WID.INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = 'NAICSSectors';

-- 4b. Column inventory
SELECT 'P4.b' AS probe, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'NAICSSectors'
ORDER BY ORDINAL_POSITION;

-- 4c. Sample
SELECT TOP 25 * FROM WID.dbo.NAICSSectors;

-- 4d. Row count
SELECT 'P4.d' AS probe, COUNT(*) AS total_rows FROM WID.dbo.NAICSSectors;
GO


-- ─── P5: NAICSSuperSectors — supersector code → title ───────────────────────
-- Target:
--   * Employer Q2: range-string supersectors '31-33' Manufacturing, '44-45'
--     Retail Trade, '48-49' Transportation (currently hardcoded in
--     naics_sectors VALUES).
--   * Front Page Q3: BLS CES supersector codes '1011'..'1028' (currently
--     hardcoded in industry_sectors VALUES).
-- IMPORTANT: NAICSSuperSectors may hold EITHER the QCEW range strings, OR
-- the CES 4-digit codes, OR both. The samples below disambiguate.
-- =============================================================================

-- 5a. Existence
SELECT 'P5.a' AS probe, TABLE_NAME
FROM WID.INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME = 'NAICSSuperSectors';

-- 5b. Column inventory — identify the code column and the title column.
SELECT 'P5.b' AS probe, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'NAICSSuperSectors'
ORDER BY ORDINAL_POSITION;

-- 5c. Full sample (likely <50 rows total — show everything)
SELECT TOP 50 * FROM WID.dbo.NAICSSuperSectors;

-- 5d. Row count
SELECT 'P5.d' AS probe, COUNT(*) AS total_rows FROM WID.dbo.NAICSSuperSectors;

-- 5e. AFTER inspecting 5.b/5.c, replace <code_col> below with the actual
-- code column name, then run these two filtered samples:
--   * If 5.e returns 0 rows: the BLS CES supersectors (1011..1028) used
--     by the Front Page Q3 don't live here — see P8 for catch-all.
--   * If 5.f returns 0 rows: the QCEW range-string supersectors used by
--     Employer Q2 don't live here either — labels would need to come
--     from NAICSSectors with composite codes, or remain hardcoded.
--
-- SELECT 'P5.e' AS probe, * FROM WID.dbo.NAICSSuperSectors
--  WHERE LTRIM(RTRIM(<code_col>)) IN ('1011','1012','1013','1021','1022',
--                                     '1023','1024','1025','1026','1027','1028');
--
-- SELECT 'P5.f' AS probe, * FROM WID.dbo.NAICSSuperSectors
--  WHERE LTRIM(RTRIM(<code_col>)) IN ('31-33', '44-45', '48-49');
GO


-- ─── P6: GEOGRAPHIES — does it carry an LWDA short-name column? ─────────────
-- Target: both tools — the Front Page dashboard's Q3 currently substring-parses
-- GEOGRAPHIES.AreaName ("Greater Roanoke Region (LWDA III)" → "Greater Roanoke")
-- to derive an LWDA short label; the Employer Wage Tool now emits the full
-- AreaName verbatim (no parsing). If a short-name column exists in this WID
-- install, BOTH tools should switch to sourcing it directly.
-- Planned rewire if LOADED: emit the short label from the column.
-- If no short-name column exists: flag as a load gap, leave Employer Wage Tool
-- on verbose AreaName, decide separately whether the Front Page accepts
-- verbose labels or keeps the substring-parsing as a documented exception.
-- =============================================================================

-- 6a. Full GEOGRAPHIES column inventory — looking for ShortName / Abbreviation /
-- Alias / DisplayName / SortName or similar.
SELECT 'P6.a' AS probe, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'GEOGRAPHIES'
ORDER BY ORDINAL_POSITION;

-- 6b. All 14 LWDA rows at the latest vintage — so we see the full AreaName
-- format and any short-name column value side-by-side. SELECT * picks up
-- whatever short-name col we discover in 6.a without needing to re-edit.
SELECT *
FROM WID.dbo.GEOGRAPHIES g
WHERE g.StFips = '51' AND g.AreaType = '15'
  AND g.AreaTypeVersion = (
      SELECT MAX(AreaTypeVersion)
      FROM WID.dbo.GEOGRAPHIES
      WHERE StFips = '51' AND AreaType = '15'
  )
ORDER BY g.Area;
GO


-- ─── P7: Ownership lookup — Ownership code → label ──────────────────────────
-- Target: both tools (latent — currently no Ownership label is emitted, but
-- the Front-page Q3 Government rollup hardcodes the literal 'Government').
-- The exact table name is install-specific; discover via INFORMATION_SCHEMA.
-- =============================================================================

-- 7a. Discovery — list any WID table whose name contains 'Owner'
SELECT 'P7.a' AS probe, TABLE_NAME
FROM WID.INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME LIKE '%Owner%'
ORDER BY TABLE_NAME;

-- 7b. AFTER 7.a returns candidate(s), run these for EACH match:
--   SELECT 'P7.b' AS probe, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
--   FROM WID.INFORMATION_SCHEMA.COLUMNS
--   WHERE TABLE_NAME = '<candidate>'
--   ORDER BY ORDINAL_POSITION;
--
--   SELECT TOP 10 * FROM WID.dbo.<candidate>;
GO


-- ─── P8: Catch-all — BLS CES supersector dim (if NAICSSuperSectors lacks
-- 1011..1028) ────────────────────────────────────────────────────────────────
-- The Front-page Q3 supersector codes ('1011' Natural Resources, '1013'
-- Manufacturing, '1028' Government, etc.) are BLS Current Employment
-- Statistics (CES) codes, not NAICS. They may live in a separate dimension.
-- Only run if P5.e returned 0 rows.
-- =============================================================================

-- 8a. Broader table search
SELECT 'P8.a' AS probe, TABLE_NAME
FROM WID.INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME LIKE '%Industry%'
   OR TABLE_NAME LIKE '%Sector%'
   OR TABLE_NAME LIKE '%CES%'
   OR TABLE_NAME LIKE '%Super%'
ORDER BY TABLE_NAME;

-- 8b. AFTER 8.a returns candidate(s), for EACH plausible match:
--   SELECT 'P8.b' AS probe, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
--   FROM WID.INFORMATION_SCHEMA.COLUMNS
--   WHERE TABLE_NAME = '<candidate>'
--   ORDER BY ORDINAL_POSITION;
--
--   SELECT TOP 20 * FROM WID.dbo.<candidate>;
--
--   -- And if a code column is identifiable, check for the CES codes:
--   SELECT * FROM WID.dbo.<candidate>
--   WHERE LTRIM(RTRIM(<code_col>)) IN ('1011','1012','1013','1021','1022',
--                                      '1023','1024','1025','1026','1027','1028');
GO


-- ─── P9: Vintage anchors for SOCCodes + ONETCodes (mirrors AreaTypeVersion) ─
-- Target: rewired JOINs need to MAX() to the latest vintage of each
-- dimension, same as we already do for GEOGRAPHIES (AreaTypeVersion),
-- LABORFORCE, INDUSTRY, IOWAGE. Discover the version-column name here.
-- =============================================================================

-- 9a. SOC vintage (likely column: SOCCodeType — BLS-2018 vs BLS-2010)
-- Adapt the column name from P1.b if it's named differently.
SELECT 'P9.a' AS probe, SOCCodeType, COUNT(*) AS row_count
FROM WID.dbo.SOCCodes
GROUP BY SOCCodeType
ORDER BY SOCCodeType;

-- 9b. O*NET vintage (likely column: ONETSOCCodeType or OccCodeVersion)
-- Adapt the column name from P2.b if it's named differently.
SELECT 'P9.b' AS probe, ONETSOCCodeType, COUNT(*) AS row_count
FROM WID.dbo.ONETCodes
GROUP BY ONETSOCCodeType
ORDER BY ONETSOCCodeType;
GO


-- =============================================================================
-- RESULTS LOG — paste outcomes here after running the probes
-- =============================================================================
-- For each probe: LOADED / EMPTY / MISSING + key columns + notes.
--
-- P1 SOCCodes
--    status:    [LOADED | EMPTY | MISSING]
--    rows:      ___
--    code col:  SOCCode  (CHAR-padded? Y/N)
--    title col: ___      (e.g. SOCTitle / OccName / SocName)
--    vintage:   ___      (P9.a SOCCodeType values, latest = ___)
--    notes:
--
-- P2 ONETCodes
--    status:    [LOADED | EMPTY | MISSING]
--    rows:      ___
--    code col:  ___      (e.g. ONETSOCCode)
--    title col: ___      (e.g. Title / OccName)
--    vintage:   ___      (P9.b values, latest = ___)
--    notes:
--
-- P3 OccupationXOccupation
--    status:    [LOADED | EMPTY | MISSING]
--    rows:      ___
--    key cols:  ___      (e.g. OccCode1, OccCode2)
--    type col:  ___      (which value = alias / alt-title)
--    StFips:    Y/N      (scope by StFips='51' if Y)
--    notes:
--
-- P4 NAICSSectors
--    status:    [LOADED | EMPTY | MISSING]
--    rows:      ___
--    code col:  ___      (e.g. NAICSCode)
--    title col: ___      (e.g. NAICSTitle)
--    notes:
--
-- P5 NAICSSuperSectors
--    status:    [LOADED | EMPTY | MISSING]
--    rows:      ___
--    code col:  ___      (e.g. NAICSCode / SuperSectorCode)
--    title col: ___
--    has 1011..1028 (CES codes)?  Y/N    ← drives Front-page Q3 rewire
--    has '31-33'/'44-45'/'48-49'? Y/N    ← drives Employer Q2 range rewire
--    notes:
--
-- P6 GEOGRAPHIES short-name
--    column found?  Y/N   if Y → column name: ___
--    if N → load-gap ticket: short-name column for LWDA AreaType='15'
--    notes:
--
-- P7 Ownership lookup
--    table name found:    ___          (e.g. OwnershipTypes)
--    status:              [LOADED | EMPTY | MISSING]
--    code col / title col: ___ / ___
--    notes:
--
-- P8 CES supersector dim (only if P5 didn't have 1011..1028)
--    table name found:    ___
--    status:              [LOADED | EMPTY | MISSING]
--    code col / title col: ___ / ___
--    has 1011..1028?      Y/N
--    notes:
--
-- P9 vintage anchors
--    SOC latest vintage:  ___
--    ONET latest vintage: ___
--    notes:
-- =============================================================================
