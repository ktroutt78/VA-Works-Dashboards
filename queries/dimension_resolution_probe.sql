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
-- RESULTS LOG — populated 2026-06-10 against the live VA WID 3.0 install
-- =============================================================================
-- Probes were run via "Results to Text" mode in SSMS against the VA Azure SQL
-- WID 3.0 server. See git log for the audit / decisions these results drove.
--
-- ─── P1 SOCCodes — LOADED ────────────────────────────────────────────────────
--    rows:                 1,447 total, 1,447 distinct SOCCode (no duplicates)
--    code col:             SOCCode  CHAR(6)  — values like '110000', '111011'
--                          unhyphenated. CHAR-padded BY TYPE but observed
--                          values are exactly 6 chars (LEN=DATALENGTH=6), so
--                          no trailing-space noise in this load. RTRIM in any
--                          rewired JOIN remains safe-by-default.
--    title col:            SOCTitle  VARCHAR(100)  (samples: 'Chief Executives',
--                          'General and Operations Managers', 'Management
--                          Occupations'). SOCTitleLong matched SOCTitle in
--                          every sampled row — pick SOCTitle (shorter).
--                          SOCDesc carries the long paragraph text, populated
--                          only on SOC-6 detail rows.
--    vintage:              SOCCodeType  CHAR(2)  = '19' on every sampled row
--                          (BLS SOC-2018). Re-run P9.a for formal confirmation
--                          (see Open follow-ups below).
--    hierarchy bonus:      SOCParent column gives the SOC tree
--                          ('111011' → '111010' → '111000' → '110000'). The
--                          hardcoded 23-row major_groups VALUES CTE in
--                          employer_wage_tool_mssql_RUN.sql Q1 can retire —
--                          source major-group label from
--                          SOCCodes.SOCTitle WHERE SOCCode LIKE 'XX0000'.
--    Step 2 wire-in:
--        soc_vintage AS (
--            SELECT MAX(SOCCodeType) AS SOCCodeType FROM WID.dbo.SOCCodes
--        ),
--        soc_dim AS (
--            SELECT RTRIM(sc.SOCCode) AS soc_code, sc.SOCTitle AS soc_title
--            FROM WID.dbo.SOCCodes sc
--            JOIN soc_vintage sv ON sc.SOCCodeType = sv.SOCCodeType
--        )
--        -- Q1 wages.json `label` becomes:
--        --   COALESCE(sd.soc_title, sw.soc_code) AS label
--        -- Demote soc-titles.json to client-side fallback for NULL rows only.
--
-- ─── P2 ONETCodes — LOADED ───────────────────────────────────────────────────
--    rows:                 1,016 total
--    code col:             ONETCode  CHAR(8)  — values like '11101100',
--                          '11101103' (8 digits, NO hyphen, NO dot — BLS
--                          spec format '11-1011.00' is normalized here).
--                          SOC-6 prefix = LEFT(ONETCode, 6).
--    title col:            ONETTitle  VARCHAR(200)  (samples: 'Chief Executives',
--                          'Chief Sustainability Officers', 'Legislators',
--                          'Advertising and Promotions Managers'). NOT NULL.
--    vintage:              ONETCodeType  CHAR(2)  = '12' on every sampled row,
--                          ONETYear  CHAR(4)  = '2025'. Re-run P9.b for formal
--                          confirmation (see Open follow-ups).
--    Step 2 wire-in (paired with the EMPTY P3 below — see Aliases path):
--        Aliases are harvested DIRECTLY from ONETCodes via the SOC-6 prefix
--        grouping (LEFT(ONETCode, 6) = SOCCode). Each SOC-6 has 1..N ONET
--        detail codes; the alternate titles become aliases for the SOC-6
--        parent. Concrete example seen:
--            SOC '111011' Chief Executives
--              ↑
--            ONETCode '11101100' ONETTitle 'Chief Executives'        (dup)
--            ONETCode '11101103' ONETTitle 'Chief Sustainability Officers'
--            → aliases for SOC 111011 = ['Chief Sustainability Officers']
--              (dedup against the SOC's own SOCTitle to suppress the dup).
--
-- ─── P3 OccupationXOccupation — EMPTY (table exists, 0 rows) ────────────────
--    rows:                 0
--    cols:                 StFips CHAR(2), CodeType CHAR(2), Code CHAR(10),
--                          CodeType2 CHAR(2), Code2 CHAR(10)
--    StFips column:        Y (but no rows to filter)
--    Implication:          The BLS WID 3.0 crosswalk table exists structurally
--                          but isn't populated on this install. The originally
--                          planned aliases path (SOCCodes ↔ OccupationXOccupation
--                          ↔ ONETCodes via the crosswalk) is unavailable —
--                          pivot to the ONETCodes-direct path described under
--                          P2 above. The commented-out aliases CTE in
--                          employer_wage_tool_mssql_RUN.sql (lines 303–332)
--                          was written for OccupationXOccupation and needs
--                          to be rewritten for the ONETCodes-direct shape
--                          before live-flipping.
--    Load-gap ticket:      "WID 3.0 on this install: OccupationXOccupation
--                          table exists but has 0 rows. The BLS-spec table
--                          is intended to carry SOC↔ONET↔alt-title crosswalks.
--                          Tools currently fall back to grouping ONETCodes
--                          by SOC-6 prefix as an alternative." File under
--                          the WID owner's load backlog.
--
-- ─── P4 NAICSSectors — LOADED ────────────────────────────────────────────────
--    rows:                 23 total — covers '00' Total, '10' Supersector
--                          totals, the 20 single-2-digit NAICS sectors
--                          ('11', '21', '22', '23', '31', '42', '44', '48',
--                          '51', '52', '53', '54', '55', '56', '61', '62',
--                          '71', '72', '81', '92'), plus '99' Unclassified.
--    code col:             NAICSSector  CHAR(2)  — stored as the leading
--                          digit-pair even for the QCEW supersector RANGES
--                          ('31' represents 31-33, '44' represents 44-45,
--                          '48' represents 48-49).
--    title col:            SectorDesc  VARCHAR(45)  — and SectorDescLong
--                          VARCHAR(120) is slightly longer. Both carry the
--                          BLS range annotation directly in the title
--                          ('Manufacturing (31-33)', 'Retail Trade (44 & 45)',
--                          'Transportation and Warehousing (48 & 49)').
--    Data quality issues observed (will surface in the Employer tool UI):
--        '54' SectorDesc = 'Professiona.l Scientific & Technical Svc'    ← typo
--                          SectorDescLong = 'Professional., Scientific, and
--                          Technical Services'                            ← also typo
--        '56' SectorDesc = 'Admin., Support, Waste Mgmt, Remediation'    ← abbreviated
--        Other rows look clean. File the typos on the WID owner's data-QA
--        backlog when wiring the Employer Q2 label.
--    Range-mapping CTE:    The Employer Q2 `naics_sectors` VALUES CTE
--                          continues to provide the WID-IndCode → 2-digit
--                          mapping (the wid_code / naics_code columns) but
--                          can drop the sector_name column entirely — label
--                          comes from NAICSSectors.SectorDesc at refresh.
--    Step 2 wire-in:       (no vintage column in this dim — flat)
--        naics_dim AS (
--            SELECT RTRIM(ns.NAICSSector) AS naics_code,
--                   ns.SectorDesc          AS sector_label
--            FROM WID.dbo.NAICSSectors ns
--        )
--        -- Q2 industries.json `label` becomes the dim's SectorDesc.
--
-- ─── P5 NAICSSuperSectors — LOADED ──────────────────────────────────────────
--    rows:                 15 total — '10' Total all industries, '101' / '102'
--                          domain totals, '1011'..'1029' CES supersectors.
--    code col:             NAICSSuper  CHAR(4)  — '10', '101', '102',
--                          '1011', '1012', '1013', '1021', '1022', '1023',
--                          '1024', '1025', '1026', '1027', '1028', '1029'.
--    title col:            SuperTitle  VARCHAR(35)  — samples:
--                            '10'   = 'Total, all industries'
--                            '1011' = 'Natural Resources and Mining'
--                            '1013' = 'Manufacturing'
--                            '1021' = 'Trade, Transportation and Utilities'
--                            '1025' = 'Education and Health Services'
--                            '1028' = 'Public Administration'      ← see commit 76a6515
--                                                                    re: Government bar
--                                                                    label exception
--    has 1011..1028 (CES codes)?  Y — all 11 codes present.
--    has '31-33'/'44-45'/'48-49'? N — those range strings are NAICSSectors
--                                  territory (P4), not NAICSSuperSectors.
--                                  This dim uses the 4-digit CES code form.
--    Notable label deltas vs the Front Page Q3 hardcoded VALUES CTE:
--        '1021' dim 'Trade, Transportation and Utilities' vs current 'Trade & Transportation'
--        '1024' dim 'Professional and Business Services' vs current 'Professional & Business'
--        '1025' dim 'Education and Health Services'      vs current 'Education & Health'
--        '1026' dim 'Leisure and Hospitality'            vs current 'Leisure & Hospitality'
--        '1028' dim 'Public Administration'              — Q3 keeps the 'Government'
--                                                          literal as a documented
--                                                          dim-label exception per
--                                                          the rollup audit (the bar
--                                                          is sourced from IndCode='10'
--                                                          + Ownership IN (10,20,30),
--                                                          not the dim's '1028' row).
--    Step 2 wire-in (Front Page Q3 supersector labels):
--        super_dim AS (
--            SELECT RTRIM(ss.NAICSSuper) AS super_code,
--                   ss.SuperTitle        AS super_label
--            FROM WID.dbo.NAICSSuperSectors ss
--        )
--        -- industry_sectors VALUES CTE in Q3 drops the sector_name field
--        -- entirely; label is sourced by JOIN super_dim ON super_code = indcode.
--        -- Government row keeps its 'Government' literal (rollup-derived bar).
--
-- ─── P6 GEOGRAPHIES short-name — MISSING column ─────────────────────────────
--    column found?  N — no ShortName / Alias / DisplayName / Abbreviation
--                       column exists. Columns present: StFips, AreaType,
--                       AreaTypeVersion, Area, AreaName, AreaDesc, Latitude,
--                       Longitude, GeoPrecisionCode.
--    AreaName format (current vintage '0002', 14 LWDAs + 1 Combined):
--        000441 'Southwest Region (LWDA I)'
--        000442 'New River/Mt. Rogers Region (LWDA II)'
--        000443 'Greater Roanoke Region (LWDA III)'
--        000444 'Shenandoah Valley Region (LWDA IV)'
--        000446 'Piedmont Region (LWDA VI)'
--        000447 'Central Region (LWDA VII)'
--        000448 'South Central Region (LWDA VIII)'
--        000449 'Capital Region (LWDA IX)'
--        000451 'Northern Region (LWDA XI)'
--        000452 'Alexandria/Arlington Region (LWDA XII)'
--        000453 'Bay Consortium Region (LWDA XIII)'
--        000455 'Crater Region (LWDA V)'         (notice AreaDesc is "XV" — see notes)
--        000456 'Hampton Roads (LWDA XIV)'      (no "Region" suffix — irregular)
--        000457 'West Piedmont Region (LWDA X)'
--        000491 'Combined Projections Area (LWDA XI and LWDA XII)'  ← excluded by '%Combined%' filter
--    AreaDesc column:      Carries 'Local Workforce Development Area I' etc.
--                          — also not a short name. NOTE: 000455 has AreaDesc
--                          'Local Workforce Development Area XV' while
--                          AreaName says '(LWDA V)' — internal WID inconsistency,
--                          not load-bearing here.
--    Implication:
--        * Employer Wage Tool — already emits AreaName verbatim per commit
--          d6ecedb (dynamic LWDA). No follow-up needed beyond regenerating
--          the JSON.
--        * Front Page Dashboard Q3 — currently substring-parses AreaName for
--          lwda_short_name. The substring-parser must go per the dimension-
--          derived-labels standard. Decision pending on whether to emit
--          AreaName verbatim ("Greater Roanoke Region (LWDA III)") or accept
--          a temporary documented exception while waiting on a short-name
--          column.
--        * The irregular 'Hampton Roads (LWDA XIV)' (no "Region" suffix)
--          confirms the existing substring-parser would already produce
--          "Hampton Roads" cleanly for that row — but it's brittle.
--    Load-gap ticket:      "WID 3.0 on this install: GEOGRAPHIES has no
--                          short-name / display-name column for LWDA rows.
--                          Both dashboards currently work around this with
--                          either verbose AreaName emission (Employer) or
--                          substring parsing (Front Page Q3, scheduled for
--                          removal)."
--
-- ─── P7 Ownership lookup — TWO CANDIDATES (column inventory NOT yet run) ────
--    candidate tables:     `Ownerships` and `InstitutionOwnerships` (both
--                          surfaced via INFORMATION_SCHEMA.TABLES with name
--                          LIKE '%Owner%').
--    column inventory:     NOT run yet — see Open follow-ups.
--    Likely interpretation: BLS WID 3.0 convention puts ownership codes
--                          (00/10/20/30/50/80) in 'Ownerships'.
--                          'InstitutionOwnerships' is probably IPEDS / higher-ed
--                          related (separate WID domain). Confirm with the
--                          P7.b follow-up before wiring.
--    Step 2 wire-in:       Deferred. Neither tool currently exposes ownership
--                          labels in the UI surface — the Q2 query filters
--                          to Ownership='00' (Total Covered) silently, and
--                          the Front Page Q3 Government bar is rollup-derived
--                          with a hardcoded label. No urgency.
--
-- ─── P8 catch-all (BLS CES / other industry dims) ──────────────────────────
--    relevant matches in INFORMATION_SCHEMA.TABLES (%Industry%/%Sector%/%CES%):
--        CES, CESCodes, CPISources, IncomeSources, Industry, IndustryCodes,
--        IndustrySums, IndustryXIndustry, NAICSSectors, NAICSSuperSectors,
--        PopulationSources, VI_CES, VI_Industry, VI_IndustryBySize, WageSources
--    NAICSSuperSectors covers everything Q3 needs (P5 confirmed '1011'..'1028'
--    are all present in that dim). No CES-specific lookup required.
--    CESCodes inventory was NOT pursued — file as "explored if needed" follow-up.
--
-- ─── P9 vintage anchors — partial (re-run needed) ───────────────────────────
--    P9.a SOCCodeType:     NOT formally run. P1 sample showed '19' on every
--                          row (1,447 of 1,447) — strong signal that this
--                          install carries only the SOC-2018 vintage. Formal
--                          GROUP BY confirmation pending — see Open follow-ups.
--    P9.b ONETCodeType:    Errored on first attempt — the probe used the
--                          BLS-spec column name 'ONETSOCCodeType' which
--                          doesn't exist on this WID install. The actual
--                          column is 'ONETCodeType' (no SOC infix). P2 sample
--                          showed '12' on every row with ONETYear '2025' —
--                          strong signal of single vintage. Formal GROUP BY
--                          confirmation pending — see Open follow-ups.
--
-- =============================================================================
-- OPEN FOLLOW-UPS (small, non-blocking)
-- =============================================================================
-- Run when convenient; results don't gate Step 2 SQL rewires for SOC / NAICS
-- supersector / NAICS sector / aliases (which can proceed on the strong-signal
-- vintage assumption that '19' / '12' are the only loaded values).
--
-- 1. P9.a re-run — confirm SOC vintage count
--      SELECT SOCCodeType, COUNT(*) AS row_count
--      FROM WID.dbo.SOCCodes
--      GROUP BY SOCCodeType
--      ORDER BY SOCCodeType;
--    EXPECT: one row, SOCCodeType='19', row_count=1447. Anything else means
--    a second vintage coexists and the rewired JOIN needs to MAX-anchor.
--
-- 2. P9.b re-run with the correct column name — confirm ONET vintage count
--      SELECT ONETCodeType, COUNT(*) AS row_count
--      FROM WID.dbo.ONETCodes
--      GROUP BY ONETCodeType
--      ORDER BY ONETCodeType;
--    EXPECT: one row, ONETCodeType='12', row_count=1016.
--
-- 3. P7 column inventory — pick the right Ownership table
--      SELECT 'Ownerships' AS t, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
--      FROM WID.INFORMATION_SCHEMA.COLUMNS
--      WHERE TABLE_NAME = 'Ownerships' ORDER BY ORDINAL_POSITION;
--
--      SELECT TOP 10 * FROM WID.dbo.Ownerships;
--
--      SELECT 'InstitutionOwnerships' AS t, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
--      FROM WID.INFORMATION_SCHEMA.COLUMNS
--      WHERE TABLE_NAME = 'InstitutionOwnerships' ORDER BY ORDINAL_POSITION;
--
--      SELECT TOP 10 * FROM WID.dbo.InstitutionOwnerships;
--
-- =============================================================================
-- =============================================================================
