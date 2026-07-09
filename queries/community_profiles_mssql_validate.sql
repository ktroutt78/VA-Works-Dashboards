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


-- =============================================================================
-- ROUND 1 — RUN 2026-07-09, ALL RESULTS LOGGED BELOW. Wrapped in a block
-- comment so executing this whole file runs ROUND 2 only. To re-run Round 1
-- (e.g. after a WID reload), remove this /* and the matching */ just above
-- the ROUND 2 banner.
-- =============================================================================
/*

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
-- RESULTS LOG P1 (2026-07-09, first run): CONFIRMED — full inventory received
-- (122 base tables, mixed-case names; collation is case-insensitive so the
-- uppercase references in these probes resolve fine).
--   * NO housing tables: nothing tenure/rent/home-value/occupancy-shaped
--     (no Housing/ACS/Census table). Affordability & Housing candidates that
--     DO exist: Income (+IncomeSources/IncomeTypes), Demographics,
--     CPI/CPIPlus/CPIItems, Commute, BuildingPermits, TransferPayments —
--     P7 below rewritten to dump exactly these.
--   * Industry label dim is IndustryCodes (NOT the WID-standard INDCODES
--     name) — P5d corrected. NAICSCodes/NAICSSectors/NAICSSuperSectors also
--     exist as label dims.
--   * Population + PopulationSources exist — P6 is live.
--   * Geographies / SubGeographies / LaborForce / Industry / IOWage present
--     as expected.
--   * Future-tranche shelf (no SQL now): BED (business formations chart),
--     UIClaims (UI payments chart), Supply/ProgramCompleters/Schools
--     (education), Demographics (age/race pyramid).


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
-- RESULTS LOG P2 (2026-07-09, first run): CONFIRMED — 15 rows at vintage
-- '0002': the 14 real LWDAs (codes 000441-000444, 000446-000449, 000451-
-- 000453, 000455-000457 — note gaps at 445/450/454) plus 000491 "Combined
-- Projections Area (LWDA XI and LWDA XII)", excluded by the NOT LIKE
-- '%Combined%' filter as expected. Names are verbose AreaName with roman
-- numerals, e.g. 'Hampton Roads (LWDA XIV)', 'Capital Region (LWDA IX)'.
-- Roman numeral does NOT track code order (LWDA V = Crater = 000455).
-- These codes become the app's LWDA region ids.


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
-- RESULTS LOG P3a (2026-07-09, first run): CONFIRMED — exactly 133 rows,
-- every locality under exactly one of the 14 LWDAs, all SubAreaType '04'.
-- Full membership captured for the front-end map fix (e.g. Hampton Roads
-- 000456 = 16 localities incl. Accomack; Alexandria/Arlington 000452 = just
-- Arlington County + Alexandria city).

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
-- RESULTS LOG P3b (2026-07-09, first run): CONFIRMED — 0 rows. Clean 1:1
-- locality->LWDA at MAX vintage; the 000491 Combined area carries no
-- SUBGEOGRAPHIES membership of its own.

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
-- RESULTS LOG P3c (2026-07-09, first run): CONFIRMED — Accomack '000001',
-- Alexandria '000510'. County encoding is '000' + 3-digit FIPS; app locality
-- id = '51' + RIGHT(Area, 3) holds. RUN.sql emits county ids that way.


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
-- RESULTS LOG P4a (2026-07-09, first run): CONFIRMED — PeriodType '01' =
-- annual average, 2010-2025, all 133 localities, Adjusted '0' only (as
-- expected at county grain). PeriodType '03' monthly runs 2010-2026. Annual
-- 2015-2025 fully covers the 11-year trend axis; latest annual = 2025.

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
-- RESULTS LOG P4b (2026-07-09, first run): CONFIRMED — 2025 annual county
-- rows with LaborForce / Employed / Unemployed / UnemployedRate all
-- populated (e.g. 000001: LF 14565, Emp 13934, Unemp 631, rate 4.3).
-- Rollup numerators available; rates recompute as SUM(Unemployed)/
-- SUM(LaborForce). Statewide anchor stays AreaType '01'.


-- ─── P5: INDUSTRY (QCEW) county coverage (Overview top industries) ───────────
-- P5a — column dump FIRST (high-variance employment column: AnnualAvgEmp vs
-- QuarterAvgEmp vs Month1/2/3Emp — the front-page dashboard ate this cost).
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'INDUSTRY'
ORDER BY ORDINAL_POSITION;
-- RESULTS LOG P5a (2026-07-09, first run): CONFIRMED — there is NO annual
-- employment column on this install. Measures: QuarterAvgEmp (+ Month1/2/3
-- Emp), AvgWeeklyWage, TotalWages, Establishments, Firms, TopEmployerAvgEmp,
-- and a single Suppress flag (char 1) — not the SuppressEmp/SuppressWage
-- pair IOWAGE uses. Annual averages must be computed across quarters in
-- RUN.sql. TopEmployerAvgEmp noted for the future top-employers chart.

-- P5b — code-space inventory at county grain: which IndCodeType, Ownership,
-- PeriodType combinations exist, and how recent?
SELECT i.IndCodeType, i.Ownership, i.PeriodType,
       MIN(i.PeriodYear) AS min_year, MAX(i.PeriodYear) AS max_year,
       COUNT(DISTINCT i.Area) AS areas
FROM WID.dbo.INDUSTRY i
WHERE i.StFips = '51' AND i.AreaType = '04'
GROUP BY i.IndCodeType, i.Ownership, i.PeriodType
ORDER BY i.IndCodeType, i.Ownership, i.PeriodType;
-- RESULTS LOG P5b (2026-07-09, first run): CONFIRMED with two big caveats —
--   * IndCodeType '10' (NAICS) only; PeriodType '02' (QUARTERLY) only; and
--     county QCEW history is 2024-2025 ONLY. Fine for the Overview top-
--     industries card (latest year); any industry TREND chart is capped at
--     ~2 years until more history loads — design note for later tranches.
--   * Ownership '00' all-ownership total EXISTS (137 areas) — use it
--     directly, no IN-list summation. Others present: '10'/'20'/'30' gov
--     levels, '50' private, '80' (unidentified — R2e dumps the Ownerships
--     dim; do NOT use '80' until decoded).
--   * 137 areas > 133 localities — pseudo/extra areas exist at AreaType
--     '04'. RUN.sql must INNER JOIN facts to the P3a locality membership so
--     extras drop out of rollups.

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
-- RESULTS LOG P5c (2026-07-09, first run): CONFIRMED — 1,117 distinct
-- IndCodes at county grain, full NAICS hierarchy down to 5-digit, range
-- codes '31-33' (136 counties), '44-45' (136), '48-49' (136) present, plus
-- QCEW domain/supersector rollup codes ('10' total-all = 137 areas, '101',
-- '1011', '102x' family). Latest year 2025 across the board. Suppression via
-- the single Suppress flag (P5a) — R2f checks how it's encoded on NAICS-2
-- county rows before rollup logic is written.

-- P5d — industry label dims (dimension-derived-labels standard: sector names
-- JOIN a dim at refresh, never hard-coded, never read off fact rows).
-- P1 confirmed this install names the dim IndustryCodes (not the WID-standard
-- INDCODES); NAICSSectors/NAICSSuperSectors exist too and may carry the
-- cleaner supersector labels for the Overview top-industries card.
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo'
  AND TABLE_NAME IN ('IndustryCodes', 'NAICSCodes', 'NAICSSectors', 'NAICSSuperSectors')
ORDER BY TABLE_NAME, ORDINAL_POSITION;
-- RESULTS LOG P5d (2026-07-09): PARTIAL — the run executed the pre-P1
-- committed version (TABLE_NAME='INDCODES') and returned 0 rows as
-- predicted. The corrected IN-list above (IndustryCodes/NAICSCodes/
-- NAICSSectors/NAICSSuperSectors) has NOT run yet — reissued as R2a below.


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
-- RESULTS LOG P6a (2026-07-09, first run): CONFIRMED — Population is a
-- simple totals table: StFips, AreaType, AreaTypeVersion, Area, PeriodYear,
-- PeriodType, Period, PopSource, Population (numeric), ReleaseDate. No
-- age/sex/race here (that's Demographics — see P7a). Totals are summable
-- for region rollups.

-- P6b — grain probe: adjust column names to P6a reality before running.
-- Want: how is "total, all demographics" encoded (age/sex/race rollup codes),
-- which AreaTypes and years exist?
-- SELECT PeriodYear, COUNT(DISTINCT Area) AS areas, COUNT(*) AS rows_
-- FROM WID.dbo.POPULATION
-- WHERE StFips = '51' AND AreaType = '04'
-- GROUP BY PeriodYear ORDER BY PeriodYear;
-- RESULTS LOG P6b (2026-07-09): NOT RUN (was commented pending P6a column
-- names — now confirmed). No demographic-rollup encoding to worry about
-- (table is totals-only), but year coverage + PopSource values still needed
-- — reissued as R2b below with real column names.


-- ─── P7: Affordability & Housing candidate tables (rewritten after P1) ───────
-- Fields needed by the section (index.html afford{} contract): total units,
-- occupied units / occupancy rate, avg household size, owner/renter split,
-- median rent + trend, median home value + trend, cost-burdened % by tenure,
-- median household income. P1 found NO housing/tenure/rent table, so the
-- question becomes: how much of the contract can Income / Demographics /
-- CPI / BuildingPermits cover, and what stays representative?
-- P7a — column dump of every candidate P1 surfaced:
SELECT c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
FROM WID.INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_SCHEMA = 'dbo'
  AND c.TABLE_NAME IN (
      'Income', 'IncomeSources', 'IncomeTypes',
      'Demographics',
      'CPI', 'CPIPlus', 'CPIItems', 'CPISources', 'CPITypes',
      'Commute',
      'BuildingPermits',
      'TransferPayments', 'TransferPaymentTypes'
  )
ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;
-- RESULTS LOG P7a (2026-07-09): PARTIAL — the run executed the pre-P1
-- committed LIKE-sweep, which covered 6 of the 13 candidates (164 columns):
--   * Demographics: FULL Census age x sex x race profile per area/year —
--     ~18 age brackets with Total/Female/Male each, plus race (White, Black,
--     NAAN, Asian, PacificIslander, Other, Twomoraces) and Hispanic-origin
--     splits, MedianAge. >>> The age-pyramid and race charts — currently
--     scoped out as design placeholders — HAVE a real WID source when their
--     designs finalize. <<<
--   * Income: generic fact keyed (IncomeType, IncomeSource) with Income,
--     IncomeRank, Population, ReleaseDate — whether median HOUSEHOLD income
--     exists depends on the IncomeTypes/IncomeSources dim rows (R2c).
--   * Population/PopulationSources: see P6a.
-- Still unprobed: CPI/CPIPlus/CPIItems/CPISources/CPITypes, Commute,
-- BuildingPermits, TransferPayments/TransferPaymentTypes — reissued as R2d.

-- P7b — grain snapshot of the two most load-bearing candidates: does Income
-- carry county-level median household income (vs BEA per-capita personal
-- income), and what does Demographics actually hold? Column names may need
-- adjusting to P7a reality before running.
SELECT TOP 20 * FROM WID.dbo.Income
WHERE StFips = '51' AND AreaType = '04'
ORDER BY PeriodYear DESC;
SELECT TOP 20 * FROM WID.dbo.Demographics
WHERE StFips = '51' AND AreaType = '04'
ORDER BY PeriodYear DESC;
-- RESULTS LOG P7b (2026-07-09): NOT RUN — folded into R2c (Income dims must
-- be decoded before the sample rows mean anything). Standing expectation per
-- P1 holds: units/tenure/rent/home-value/cost-burden/household-size have NO
-- WID source and stay representative in tranche 1; median household income
-- is the one field Income may cover pending R2c.


-- ─── P8: SUBGEOGRAPHIES composition inventory (MSA rollups, GOVA absence) ────
-- Which parent geographies have membership rows on this install? Determines
-- whether MSA -> locality composition is dim-derived (preferred) or must
-- mirror the app's hard-coded VA-member lists.
SELECT sg.AreaType, COUNT(DISTINCT sg.Area) AS parents, COUNT(*) AS member_rows
FROM WID.dbo.SUBGEOGRAPHIES sg
WHERE sg.StFips = '51'
GROUP BY sg.AreaType
ORDER BY sg.AreaType;
-- RESULTS LOG P8 (2026-07-09, first run): CONFIRMED — SUBGEOGRAPHIES parent
-- AreaTypes at StFips 51: '01' state (1 parent/138 members), '04' (138/138),
-- '09' (21 parents — likely planning districts), '15' LWDA (15/400 — the 400
-- spans vintages; MAX-vintage non-Combined membership is the 133 of P3a),
-- '19' (11), '31' MSA (15 parents/129 members — membership IS dim-derived;
-- 15 = 11 whole + 4 'S%' state-part rows, resolve in RUN per the no-trimming
-- geography model), '32' Micro (5/8), '33' MetroDiv (2/35), '50' (4/53),
-- '57' (23/142). No GO Virginia anywhere, as expected — its 9-region VALUES
-- block stands as the sanctioned hand-mapping exception.

*/
-- ============================== END ROUND 1 ==================================


-- =============================================================================
-- ROUND 2 — RUN 2026-07-09, ALL RESULTS LOGGED BELOW. Wrapped in a block
-- comment so executing this whole file runs ROUND 3 only.
-- (R2a/R2d re-issued probes whose corrected versions post-dated the committed
-- copy; R2b/R2c/R2e/R2f were new questions from the first run.)
-- =============================================================================
/*

-- ─── R2a: industry label dims (P5d corrected — INDCODES doesn't exist) ───────
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo'
  AND TABLE_NAME IN ('IndustryCodes', 'NAICSCodes', 'NAICSSectors', 'NAICSSuperSectors')
ORDER BY TABLE_NAME, ORDINAL_POSITION;
-- Label sanity: what do sector-level labels look like? (Adjust column names
-- to the dump above if these guesses miss.)
SELECT TOP 40 * FROM WID.dbo.NAICSSectors;
SELECT TOP 40 * FROM WID.dbo.NAICSSuperSectors;
-- RESULTS LOG R2a (2026-07-09, run 2): CONFIRMED — sector labels come from
-- NAICSSectors (NAICSSector char(2) -> SectorDesc / SectorDescLong), no
-- vintage column, 23 rows. Keys are PLAIN 2-digit ('31','44','48') while
-- fact IndCode stores ranges ('31-33','44-45','48-49') — join via
-- LEFT(LTRIM(RTRIM(IndCode)), 2) after filtering facts to the 20 sector
-- codes; labels already carry the range in text ("Manufacturing (31-33)").
-- NAICSSuperSectors gives the 1011..1029 supersector labels if ever needed.
-- IndustryCodes is a generic (CodeType, Code, CodeTitle) dim — not required.
-- DATA QUALITY: SectorDesc for 54 = "Professiona.l Scientific & Technical
-- Svc" (stray period, also in SectorDescLong) — matches the existing NAICS-
-- typos item on the WID punchlist (docs/client-tickets/); emit verbatim per
-- the dimension-derived-labels standard.

-- ─── R2b: Population coverage + source (P6b with confirmed columns) ──────────
SELECT p.PeriodYear, p.PeriodType, p.PopSource, ps.PopSourceDesc,
       COUNT(DISTINCT p.Area) AS areas
FROM WID.dbo.Population p
LEFT JOIN WID.dbo.PopulationSources ps
  ON ps.StFips = p.StFips AND ps.PopSource = p.PopSource
WHERE p.StFips = '51' AND p.AreaType = '04'
GROUP BY p.PeriodYear, p.PeriodType, p.PopSource, ps.PopSourceDesc
ORDER BY p.PeriodYear, p.PopSource;
-- RESULTS LOG R2b (2026-07-09, run 2): *** 0 ROWS *** — Population has NO
-- rows at StFips '51' + AreaType '04'. Either the table is unloaded (load
-- gap) or population lives under a different StFips/AreaType encoding.
-- R3a below inventories the table unfiltered. Until resolved, the Overview
-- population card is AT RISK of staying representative in tranche 1.

-- ─── R2c: Income decode — does median HOUSEHOLD income exist? ────────────────
SELECT * FROM WID.dbo.IncomeTypes ORDER BY IncomeType;
SELECT * FROM WID.dbo.IncomeSources ORDER BY IncomeSource;
-- County-grain sample with dim labels spliced in:
SELECT TOP 40 i.PeriodYear, i.IncomeType, it.IncomeDesc,
       i.IncomeSource, isrc.IncomeSourceDesc, i.Income, i.Area
FROM WID.dbo.Income i
LEFT JOIN WID.dbo.IncomeTypes it
  ON it.StFips = i.StFips AND it.IncomeType = i.IncomeType
LEFT JOIN WID.dbo.IncomeSources isrc
  ON isrc.StFips = i.StFips AND isrc.IncomeSource = i.IncomeSource
WHERE i.StFips = '51' AND i.AreaType = '04'
ORDER BY i.PeriodYear DESC, i.IncomeType, i.Area;
-- RESULTS LOG R2c (2026-07-09, run 2): SPLIT DECISION —
--   * IncomeTypes: IncomeType '03' = "Median Household Income - United
--     States Census" EXISTS on StFips '51' (also '04' Median Family Income,
--     plus the BEA personal-income family). IncomeSources: '1' Census,
--     '3' BEA on StFips 51 ('2' HUD national-only).
--   * BUT the county-grain fact sample returned *** 0 ROWS *** — same
--     symptom as Population (R2b). Dim says the concept exists; fact rows at
--     StFips '51' + AreaType '04' are absent. R3a inventories Income
--     unfiltered. medianIncome stays representative until resolved.
--   * Non-summability note stands: even when found, median income emits at
--     source grain only; multi-county rollups stay representative for it.

-- ─── R2d: remaining Affordability candidates (P7a tables the sweep missed) ───
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo'
  AND TABLE_NAME IN ('CPI', 'CPIPlus', 'CPIItems', 'CPISources', 'CPITypes',
                     'Commute', 'BuildingPermits',
                     'TransferPayments', 'TransferPaymentTypes')
ORDER BY TABLE_NAME, ORDINAL_POSITION;
-- RESULTS LOG R2d (2026-07-09, run 2): CONFIRMED columns; shelf notes —
--   * CPI/CPIPlus: inflation index series (CPI, PctChangeY2Y/M2M by CPIType/
--     CPIItem) — an INFLATION measure, NOT a US=100 cost-of-living index.
--     Cannot feed the costOfLiving chart as designed; could power an
--     inflation-trend chart instead. Design question for later.
--   * Commute: origin->work-area FLOWS (Area -> WorkArea, Workers) — not
--     mode split. The current commute chart (drove alone/transit/WFH %) has
--     NO WID source as designed; flows could power a "where residents work"
--     viz instead. Design question for later.
--   * BuildingPermits: Units + UnitCost by UnitType per area/period — real
--     housing-adjacent series; candidate context chart for the Affordability
--     section (not in the current afford{} contract).
--   * TransferPayments: BEA payments by PaymentType — shelf.

-- ─── R2e: Ownerships dim — decode '80', confirm '00' ─────────────────────────
SELECT * FROM WID.dbo.Ownerships ORDER BY Ownership;
-- RESULTS LOG R2e (2026-07-09, run 2): CONFIRMED — '00' = "Aggregate of all
-- types" (pin it in RUN.sql). '80' = "Total Government", '90' = "Total UI
-- Covered (excludes Federal Gov.)", '40' = "International Government".
-- Handy shortcut vs the CES three-code sum: QCEW gov splits can use '80'
-- directly if a government rollup is ever charted here.

-- ─── R2f: Industry quarter completeness + suppression shape ──────────────────
-- 2025 may be partial (e.g. Q1-Q2 only) — the top-industries card must know
-- whether to average 4 quarters of 2024 or the available 2025 quarters.
SELECT i.PeriodYear, i.Period, COUNT(DISTINCT i.Area) AS areas
FROM WID.dbo.Industry i
WHERE i.StFips = '51' AND i.AreaType = '04'
  AND i.IndCodeType = '10' AND i.Ownership = '00' AND i.PeriodType = '02'
  AND LTRIM(RTRIM(i.IndCode)) = '10'
GROUP BY i.PeriodYear, i.Period
ORDER BY i.PeriodYear, i.Period;
-- Suppression encoding on NAICS-2 county rows (values + how often):
SELECT i.Suppress, COUNT(*) AS rows_,
       SUM(CASE WHEN i.QuarterAvgEmp IS NULL THEN 1 ELSE 0 END) AS null_emp
FROM WID.dbo.Industry i
WHERE i.StFips = '51' AND i.AreaType = '04'
  AND i.IndCodeType = '10' AND i.Ownership = '00' AND i.PeriodType = '02'
  AND (LEN(LTRIM(RTRIM(i.IndCode))) = 2 OR LTRIM(RTRIM(i.IndCode)) IN ('31-33','44-45','48-49'))
GROUP BY i.Suppress;
-- RESULTS LOG R2f (2026-07-09, run 2): CONFIRMED + one open hazard —
--   * Quarters: 2024 Q1-Q4 AND 2025 Q1-Q4 all present at 137 areas — 2025 is
--     a COMPLETE year. Annual avg emp 2025 = AVG(QuarterAvgEmp) over the 4
--     quarters. Top-industries card uses 2025 annual averages.
--   * Suppression: Suppress '0' = 17,967 rows, '1' = 5,259 rows (~23% of
--     NAICS-2 county cells) and QuarterAvgEmp is NEVER NULL (null_emp = 0)
--     — so suppressed rows carry a VALUE, most likely 0, which would
--     silently deflate region rollups. R3b checks the value distribution.
--     If zeros: county-sum rollups undercount; prefer native-grain fact rows
--     (AreaType '15'/'31'/'01') for rollup regions — which R3a inventories —
--     and treat county sums as last resort.

*/
-- ============================== END ROUND 2 ==================================


-- =============================================================================
-- ROUND 3 (2026-07-09) — final follow-ups before RUN.sql. Three questions:
--   (1) R3a: which AreaTypes does each fact table actually carry? Decides
--       native-grain vs county-rollup per region level (per the no-trimming
--       geography model, native grain is preferred where it exists), and
--       diagnoses the empty Population/Income results from R2b/R2c.
--   (2) R3b: what value do suppressed QCEW rows carry? Decides rollup math.
--   (3) R3c: if Population/Income are empty at StFips 51 entirely, what DO
--       they contain? (Load-gap ticket if truly empty.)
-- =============================================================================

-- ─── R3a: fact-table AreaType inventory (StFips 51, all vintages) ────────────
SELECT 'LaborForce' AS tbl, AreaType, COUNT(DISTINCT Area) AS areas,
       MIN(PeriodYear) AS min_yr, MAX(PeriodYear) AS max_yr, COUNT(*) AS rows_
FROM WID.dbo.LaborForce WHERE StFips = '51' GROUP BY AreaType
UNION ALL
SELECT 'Industry', AreaType, COUNT(DISTINCT Area),
       MIN(PeriodYear), MAX(PeriodYear), COUNT(*)
FROM WID.dbo.Industry WHERE StFips = '51' GROUP BY AreaType
UNION ALL
SELECT 'Population', AreaType, COUNT(DISTINCT Area),
       MIN(PeriodYear), MAX(PeriodYear), COUNT(*)
FROM WID.dbo.Population WHERE StFips = '51' GROUP BY AreaType
UNION ALL
SELECT 'Income', AreaType, COUNT(DISTINCT Area),
       MIN(PeriodYear), MAX(PeriodYear), COUNT(*)
FROM WID.dbo.Income WHERE StFips = '51' GROUP BY AreaType
UNION ALL
SELECT 'Demographics', AreaType, COUNT(DISTINCT Area),
       MIN(PeriodYear), MAX(PeriodYear), COUNT(*)
FROM WID.dbo.Demographics WHERE StFips = '51' GROUP BY AreaType
ORDER BY tbl, AreaType;
-- RESULTS LOG R3a (2026-07-09, run 3): CONFIRMED — grain map:
--   * LaborForce: '01' state (1976-2026!), '04' 133 counties (2010-2026),
--     '31' 12 MSAs (2010-2026), plus '10','11','32','33','34'. NO '15' LWDA
--     rows -> LWDA unemployment is a county rollup (safe: LAUS numerators
--     unsuppressed). MSA/state: prefer native annual rows, COALESCE to
--     member-county rollup (annual PeriodType presence at '31' not
--     separately probed; the fallback makes it moot).
--   * Industry: native rows at '01' state, '15' ALL 14 LWDAs, '31' 15 MSAs,
--     '04' 137 (+ '09','19','33','57'), 2024-2025. -> industryEmployment
--     uses NATIVE grain for state/LWDA/MSA/county; only GO Virginia rolls up
--     from counties.
--   * Demographics: '01'/'04'(133)/'31'(11)/'32'(4) — single year 2022.
--     Shelf note: age-pyramid/race charts get one vintage year, no trend.
--   * Population, Income: nothing at StFips 51 — see R3c.

-- ─── R3b: what do suppressed QCEW rows carry? ────────────────────────────────
SELECT i.Suppress,
       COUNT(*) AS rows_,
       SUM(CASE WHEN i.QuarterAvgEmp = 0 THEN 1 ELSE 0 END) AS zero_emp,
       MIN(i.QuarterAvgEmp) AS min_emp, MAX(i.QuarterAvgEmp) AS max_emp,
       AVG(i.QuarterAvgEmp) AS avg_emp
FROM WID.dbo.Industry i
WHERE i.StFips = '51' AND i.AreaType = '04'
  AND i.IndCodeType = '10' AND i.Ownership = '00' AND i.PeriodType = '02'
  AND (LEN(LTRIM(RTRIM(i.IndCode))) = 2 OR LTRIM(RTRIM(i.IndCode)) IN ('31-33','44-45','48-49'))
GROUP BY i.Suppress;
-- RESULTS LOG R3b (2026-07-09, run 3): CONFIRMED — suppressed rows carry
-- REAL values on this install (Suppress='1': 5,259 rows, only 136 zero,
-- max 29,625, avg 281). Suppress is a display flag, not a data mask, so
-- county-sum rollups are numerically sound. POLICY NOTE for the handover
-- doc: whether suppressed county-level cells may be DISPLAYED publicly is a
-- client call (BLS publication rules say no); RUN.sql emits values as
-- loaded and the flag question rides with the client.

-- ─── R3c: Population / Income — what's actually in them? ────────────────────
-- Only meaningful if R3a shows nothing for StFips 51: check total size and
-- which StFips values exist at all (empty table = load-gap ticket).
SELECT 'Population' AS tbl, COUNT(*) AS total_rows FROM WID.dbo.Population
UNION ALL
SELECT 'Income', COUNT(*) FROM WID.dbo.Income;
SELECT TOP 10 'Population' AS tbl, StFips, COUNT(*) AS rows_
FROM WID.dbo.Population GROUP BY StFips ORDER BY COUNT(*) DESC;
SELECT TOP 10 'Income' AS tbl, StFips, COUNT(*) AS rows_
FROM WID.dbo.Income GROUP BY StFips ORDER BY COUNT(*) DESC;
-- RESULTS LOG R3c (2026-07-09, run 3): CONFIRMED EMPTY — Population and
-- Income are 0 rows TOTAL (any StFips). Load gap filed:
-- docs/client-tickets/WID-LOAD-GAP-PopulationIncome.md. Overview population
-- card and afford medianIncome stay representative until the load lands
-- (IncomeType '03' Median Household Income is already in the dim, so the
-- wiring in RUN.sql can follow the ticket without re-validation).
--
-- ======================= VALIDATION COMPLETE 2026-07-09 ======================
-- All probes resolved across 3 rounds. Consuming query:
-- queries/community_profiles_mssql_RUN.sql. Re-run rounds after any WID
-- reload/vintage roll (remove the /* */ wrappers).
-- =============================================================================


