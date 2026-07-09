-- =============================================================================
-- COMMUNITY PROFILES — SQL Server (T-SQL) — schema validation probes
--
-- Companion to the future queries/community_profiles_mssql_RUN.sql (the
-- JSON-emitting refresh script for apps/community-profiles/data/profiles.json).
-- Run these probes once against the production WID 3.0 server before the RUN
-- script is written; record findings in the RESULTS LOG under each probe.
-- Re-run after any WID reload/vintage roll.
--
-- Discovery-first workflow: nothing in RUN.sql may rest on an unverified
-- column/code assumption. All probes below are OPEN (no first run yet).
--
-- SCOPE (client decisions, 2026-07-08):
--   * First tranche wires ONLY: (a) the map selector's LWDA regions, (b) the
--     Overview cards (unemployment, population, top industries — GDP stays
--     representative; BEA data, not in WID), (c) the Affordability & Housing
--     section (client believes the DB carries Census/ACS data — P7 verifies).
--   * All other charts (age pyramid, race, commute, education, business
--     formations, apprenticeships, ...) are still design concepts and keep
--     representative data — no SQL is built for placeholders.
--   * Rollups are SQL-side: profiles.json carries one record per app region
--     at every level (County/City, MSA, GO Virginia, LWDA, State), with rates
--     recomputed from numerators/denominators — never averaged from rates.
--   * Per-chart provenance: the front end badges a chart "Illustrative" only
--     when its field came from the mock generator, so real and representative
--     data ship side by side while designs are finalized.
--
-- GEOGRAPHY MODEL:
--   * NO STATE-BOUNDARY TRIMMING (client decision, 2026-07-08): profiles
--     report whatever the WID tables carry at the chosen geographic grain.
--     Grain selection is the ONLY filter — neither RUN.sql nor the front end
--     filters out localities for being outside Virginia. A cross-border MSA
--     rolls up and reports as-sourced (whole MSA if the tables carry it
--     whole; VA members if that's all they carry). This keeps profiles
--     self-consistent with any other tool built on the same tables at the
--     same grain (e.g. the wage tool). The one open MSA question is cosmetic
--     — how a cross-border MSA is labeled — deferred until MSA profiles ship.
--     (The map only draws Virginia geometry; that display nuance is part of
--     the deferred labeling question, not a data filter.)
--   * App locality ids are 5-digit FIPS strings ('51001'); the RUN script
--     must emit county ids as '51' + RIGHT(Area, 3) once P3c confirms the
--     Area encoding.
--   * GO Virginia regions are a state program, not a WID/BLS geography — no
--     dim exists to derive them from (P8 double-checks). Their composition
--     stays a VALUES block in RUN.sql mirroring the official 9-region list
--     already in the app. This is the sanctioned exception to the
--     dimension-derived-labels standard: hand mappings are allowed only where
--     no dimension exists at all.
--
-- HIGH-VARIANCE WID COLUMNS in play (rename = silent wrong numbers):
--   * INDUSTRY employment: AnnualAvgEmp vs QuarterAvgEmp vs Month1/2/3Emp —
--     the front-page dashboard hit this exact variance (P5a settles it).
--   * LABORFORCE: LaborForce / Employed / Unemployed / UnemployedRate names
--     assumed from RUN_v8 (same install, so low risk — P4b confirms anyway).
-- =============================================================================


-- ─── P1: Full table inventory — find the Census/ACS tables ──────────────────
-- The Affordability & Housing section needs ACS-style fields (tenure,
-- occupancy, median rent / home value, cost burden, household size, median
-- household income). These are NOT part of the BLS WID core; the client
-- believes they were loaded into this install. Eyeball the full list for
-- census/ACS/housing/income table names — P7 then dumps columns for anything
-- promising.
SELECT TABLE_NAME
FROM WID.INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;
-- RESULTS LOG P1: OPEN


-- ─── P2: LWDA rows in GEOGRAPHIES — expect 14 real LWDAs ─────────────────────
-- The app currently fabricates 15 LWDAs from map-grid position (index.html:237
-- `f._lwda = lrow*5+lcol+1`) — pure placeholder. Virginia has 14 LWDAs.
-- RUN_v8 (front-page dashboard) reads them at AreaType '15' and excludes
-- AreaName LIKE '%Combined%' rows; expect the same shape here. Labels come
-- verbatim from AreaName (no ShortName column on this install — known load
-- gap, front-page probe P6).
SELECT g.Area, g.AreaName, g.AreaTypeVersion
FROM WID.dbo.GEOGRAPHIES g
JOIN (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    GROUP BY StFips, AreaType
) gv
  ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
 AND g.AreaTypeVersion = gv.AreaTypeVersion
WHERE g.StFips = '51' AND g.AreaType = '15'
ORDER BY g.Area;
-- RESULTS LOG P2: OPEN — record the 14 (Area, AreaName) pairs and any
-- 'Combined' rows to exclude. These 6-digit Area codes become the app's LWDA
-- region ids (replacing synthetic 'lwda-1'..'lwda-15').


-- ─── P3: LWDA -> locality composition via SUBGEOGRAPHIES ─────────────────────
-- P3a — full membership dump. Expect every VA locality to appear exactly once
-- (the app draws 133 localities).
SELECT
    sg.Area          AS lwda_code,
    gl.AreaName      AS lwda_name,
    sg.SubArea       AS locality_area,
    sg.SubAreaType   AS locality_areatype,
    gc.AreaName      AS locality_name
FROM WID.dbo.SUBGEOGRAPHIES sg
JOIN (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.SUBGEOGRAPHIES
    GROUP BY StFips, AreaType
) sgv
  ON sg.StFips = sgv.StFips AND sg.AreaType = sgv.AreaType
 AND sg.AreaTypeVersion = sgv.AreaTypeVersion
JOIN WID.dbo.GEOGRAPHIES gl
  ON gl.StFips = sg.StFips AND gl.AreaType = sg.AreaType AND gl.Area = sg.Area
JOIN (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    GROUP BY StFips, AreaType
) glv
  ON gl.StFips = glv.StFips AND gl.AreaType = glv.AreaType
 AND gl.AreaTypeVersion = glv.AreaTypeVersion
LEFT JOIN WID.dbo.GEOGRAPHIES gc
  ON gc.StFips = sg.StFips AND gc.AreaType = sg.SubAreaType AND gc.Area = sg.SubArea
 AND gc.AreaTypeVersion = (
     SELECT MAX(AreaTypeVersion) FROM WID.dbo.GEOGRAPHIES
     WHERE StFips = sg.StFips AND AreaType = sg.SubAreaType
 )
WHERE sg.StFips = '51' AND sg.AreaType = '15'
  AND gl.AreaName NOT LIKE '%Combined%'
ORDER BY sg.Area, sg.SubArea;
-- RESULTS LOG P3a: OPEN — expect ~133 rows, each locality under exactly one
-- LWDA.

-- P3b — coverage check: any locality in NO LWDA, or in MORE than one?
SELECT sg.SubArea, COUNT(DISTINCT sg.Area) AS lwda_count
FROM WID.dbo.SUBGEOGRAPHIES sg
JOIN (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.SUBGEOGRAPHIES
    GROUP BY StFips, AreaType
) sgv
  ON sg.StFips = sgv.StFips AND sg.AreaType = sgv.AreaType
 AND sg.AreaTypeVersion = sgv.AreaTypeVersion
WHERE sg.StFips = '51' AND sg.AreaType = '15'
GROUP BY sg.SubArea
HAVING COUNT(DISTINCT sg.Area) <> 1
ORDER BY sg.SubArea;
-- RESULTS LOG P3b: OPEN — expect 0 rows (or only rows explained by 'Combined'
-- parents; if so, re-run with the NOT LIKE '%Combined%' join from P3a).

-- P3c — county Area encoding vs app FIPS ('51001' form). Verify the
-- '51' + RIGHT(Area, 3) mapping on two known localities.
SELECT g.Area, g.AreaName
FROM WID.dbo.GEOGRAPHIES g
JOIN (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    GROUP BY StFips, AreaType
) gv
  ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
 AND g.AreaTypeVersion = gv.AreaTypeVersion
WHERE g.StFips = '51' AND g.AreaType = '04'
  AND (g.AreaName LIKE 'Accomack%' OR g.AreaName LIKE 'Alexandria%');
-- RESULTS LOG P3c: OPEN — expect Accomack RIGHT(Area,3)='001', Alexandria
-- '510'. If the encoding differs, record the real rule here; RUN.sql's
-- county id emission depends on it.


-- ─── P4: LABORFORCE annual county coverage (Overview unemployment) ───────────
-- The Overview card shows a latest ANNUAL average rate per region plus a
-- trend. RUN_v8 uses PeriodType '03' (monthly); annual averages are expected
-- at a different PeriodType code — dump what exists rather than assume.
-- P4a — period grain inventory at county level.
SELECT lf.PeriodType, lf.Adjusted,
       MIN(lf.PeriodYear) AS min_year, MAX(lf.PeriodYear) AS max_year,
       COUNT(DISTINCT lf.Area) AS areas, COUNT(*) AS rows_
FROM WID.dbo.LABORFORCE lf
JOIN (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.LABORFORCE
    GROUP BY StFips, AreaType
) lfv
  ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
 AND lf.AreaTypeVersion = lfv.AreaTypeVersion
WHERE lf.StFips = '51' AND lf.AreaType = '04'
GROUP BY lf.PeriodType, lf.Adjusted
ORDER BY lf.PeriodType, lf.Adjusted;
-- RESULTS LOG P4a: OPEN — record which PeriodType is the annual average
-- (WID standard says '01') and the year span (want 2015..latest for the
-- 11-year trend axis).

-- P4b — column sanity + rollup ingredients on one annual county row.
-- Rates for multi-county regions are recomputed as SUM(Unemployed)/
-- SUM(LaborForce); confirm the numerator columns are populated.
SELECT TOP 5 lf.Area, lf.PeriodYear, lf.PeriodType,
       lf.LaborForce, lf.Employed, lf.Unemployed, lf.UnemployedRate
FROM WID.dbo.LABORFORCE lf
JOIN (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.LABORFORCE
    GROUP BY StFips, AreaType
) lfv
  ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
 AND lf.AreaTypeVersion = lfv.AreaTypeVersion
WHERE lf.StFips = '51' AND lf.AreaType = '04'
  AND lf.PeriodType = '01' AND lf.Adjusted = '0'
ORDER BY lf.PeriodYear DESC, lf.Area;
-- RESULTS LOG P4b: OPEN — if PeriodType '01' returns nothing, substitute the
-- annual code found in P4a. Statewide anchor for the State profile is
-- AreaType '01' (RUN_v8-confirmed on this install).


-- ─── P5: INDUSTRY (QCEW) county coverage (Overview top industries) ───────────
-- P5a — column dump FIRST (high-variance employment column: AnnualAvgEmp vs
-- QuarterAvgEmp vs Month1/2/3Emp — the front-page dashboard ate this cost).
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'INDUSTRY'
ORDER BY ORDINAL_POSITION;
-- RESULTS LOG P5a: OPEN — record the annual-average employment column name.

-- P5b — code-space inventory at county grain: which IndCodeType, Ownership,
-- PeriodType combinations exist, and how recent?
SELECT i.IndCodeType, i.Ownership, i.PeriodType,
       MIN(i.PeriodYear) AS min_year, MAX(i.PeriodYear) AS max_year,
       COUNT(DISTINCT i.Area) AS areas
FROM WID.dbo.INDUSTRY i
WHERE i.StFips = '51' AND i.AreaType = '04'
GROUP BY i.IndCodeType, i.Ownership, i.PeriodType
ORDER BY i.IndCodeType, i.Ownership, i.PeriodType;
-- RESULTS LOG P5b: OPEN — for "jobs by sector" want NAICS-2 supersectors,
-- private + government ownership rolled to a total. Record whether an
-- all-ownership rollup row exists (Ownership '0'?) or RUN.sql must SUM
-- Ownership IN ('10','20','30','50'?) — mirror the CES gotcha: IndCode '10'
-- vs '1028' semantics do NOT apply to QCEW, but verify what total rows exist.

-- P5c — NAICS-2 sector rows for the latest annual year, one sample county.
-- Must include the BLS range codes '31-33', '44-45', '48-49' (stored
-- literally as hyphenated strings — a naive 2-char filter drops
-- Manufacturing, Retail, Transportation).
SELECT i.IndCode, COUNT(DISTINCT i.Area) AS counties, MAX(i.PeriodYear) AS latest_year
FROM WID.dbo.INDUSTRY i
WHERE i.StFips = '51' AND i.AreaType = '04'
  AND LEN(LTRIM(RTRIM(i.IndCode))) BETWEEN 2 AND 5   -- catches '31-33' ranges
GROUP BY i.IndCode
ORDER BY i.IndCode;
-- RESULTS LOG P5c: OPEN — confirm range codes present and county coverage
-- (~133). Suppression: QCEW county cells are often suppressed — record which
-- column flags it (SuppressEmp?) so rollups can decide whether suppressed
-- member counties poison a region sum.

-- P5d — industry label dim (dimension-derived-labels standard: sector names
-- JOIN a dim at refresh, never hard-coded, never read off fact rows).
SELECT COLUMN_NAME, DATA_TYPE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'INDCODES'
ORDER BY ORDINAL_POSITION;
-- RESULTS LOG P5d: OPEN — record the dim's name/label column and its vintage
-- column (pin to a literal per the vintage-pinning standard once known).


-- ─── P6: Population — county totals + trend (Overview population card) ───────
-- WID 3.0 standard carries a POPULATION table (Census-sourced). Needed:
-- total population per locality per year, 2016..latest, for the Overview
-- count + sparkline. If the table is absent from P1, population stays
-- representative in tranche 1.
-- P6a — columns (only if POPULATION appears in P1).
SELECT COLUMN_NAME, DATA_TYPE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'POPULATION'
ORDER BY ORDINAL_POSITION;
-- RESULTS LOG P6a: OPEN

-- P6b — grain probe: adjust column names to P6a reality before running.
-- Want: how is "total, all demographics" encoded (age/sex/race rollup codes),
-- which AreaTypes and years exist?
-- SELECT PeriodYear, COUNT(DISTINCT Area) AS areas, COUNT(*) AS rows_
-- FROM WID.dbo.POPULATION
-- WHERE StFips = '51' AND AreaType = '04'
-- GROUP BY PeriodYear ORDER BY PeriodYear;
-- RESULTS LOG P6b: OPEN — also record the total-row encoding (e.g. AgeGroup
-- '00', Gender '0', Race '0') so RUN.sql filters to it exactly.


-- ─── P7: Census/ACS housing tables (Affordability & Housing section) ─────────
-- Fields needed by the section (index.html afford{} contract): total units,
-- occupied units / occupancy rate, avg household size, owner/renter split,
-- median rent + trend, median home value + trend, cost-burdened % by tenure,
-- median household income. Column sweep over anything census-ish from P1:
SELECT c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
FROM WID.INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_NAME LIKE '%ACS%'
   OR c.TABLE_NAME LIKE '%CENSUS%'
   OR c.TABLE_NAME LIKE '%HOUS%'
   OR c.TABLE_NAME LIKE '%INCOME%'
   OR c.TABLE_NAME LIKE '%DEMOG%'
   OR c.TABLE_NAME LIKE '%POPUL%'
ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;
-- RESULTS LOG P7: OPEN — if nothing housing-shaped exists, the Affordability
-- section stays representative in tranche 1 and the source decision (ACS API
-- pull vs static extract) goes back to the client. Also add any candidate
-- table names spotted in P1 that this LIKE sweep missed.


-- ─── P8: SUBGEOGRAPHIES composition inventory (MSA rollups, GOVA absence) ────
-- Which parent geographies have membership rows on this install? Determines
-- whether MSA -> locality composition is dim-derived (preferred) or must
-- mirror the app's hard-coded VA-member lists.
SELECT sg.AreaType, COUNT(DISTINCT sg.Area) AS parents, COUNT(*) AS member_rows
FROM WID.dbo.SUBGEOGRAPHIES sg
WHERE sg.StFips = '51'
GROUP BY sg.AreaType
ORDER BY sg.AreaType;
-- RESULTS LOG P8: OPEN — expect '15' (LWDA) present. If '31' (MSA) is
-- present, RUN.sql derives MSA membership from it as-sourced (no state
-- trimming — see GEOGRAPHY MODEL note); if absent, MSA composition is a
-- VALUES block mirroring index.html. GO Virginia ('%GO%'?) is NOT expected
-- in any WID dim — its 9-region VALUES block is the sanctioned hand-mapping
-- exception.
