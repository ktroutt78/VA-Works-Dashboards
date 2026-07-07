-- =============================================================================
-- WAGE COMPARISON TOOL — SQL Server (T-SQL) — schema validation probes
--
-- Companion to queries/wage_comparison_tool_mssql_RUN.sql (the JSON-emitting
-- refresh script for apps/wage-tool/data/wages.json + employment_trend.json).
-- Run these probes once against the production WID 3.0 server before first
-- RUN execution; record findings in the RESULTS LOG under each probe. Re-run
-- after any WID reload/vintage roll.
--
-- Discovery-first workflow: nothing in RUN.sql may rest on an unverified
-- column/code assumption. Probes below marked CONFIRMED were validated by the
-- client directly against the prod server on 2026-07-07 (relayed; treated as
-- authoritative). Probes marked OPEN still need a first run.
-- =============================================================================


-- ─── P1: MSA AreaType code ───────────────────────────────────────────────────
-- Expect '31' = Metropolitan Statistical Area. Neighbors that must NOT be
-- included in the tool: '32' Micropolitan, '33' Metro Division, '34' CSA.
--
-- P1a — discover the dim's actual column names first (this install does NOT
-- have an 'AreaTypeDesc' column; Msg 207 on 2026-07-07). Record the real
-- label column below, then run P1b.
SELECT COLUMN_NAME, DATA_TYPE
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'AREATYPES'
ORDER BY ORDINAL_POSITION;
-- RESULTS LOG P1a (2026-07-07, first run): CONFIRMED — columns are StFips
-- (char), AreaType (char), AreaTypeName (varchar). National dim keyed by
-- StFips (57 states/territories x 4 codes = 225 rows in P1b). RUN.sql never
-- reads AREATYPES; this probe documents codes only.

-- P1b — assumption-free row dump (SELECT * so no column-name guess).
SELECT *
FROM WID.dbo.AREATYPES
WHERE AreaType IN ('31','32','33','34')
ORDER BY AreaType;
-- RESULTS LOG P1 (2026-07-07, client probe): CONFIRMED — '31' = Metropolitan
-- Statistical Area. Pin exactly '31' in RUN.sql; do not include neighbors.
-- (The '31' code fact is confirmed; only this probe's label-column NAME was
-- wrong. RUN.sql never touches AREATYPES, so the error affected nothing else.)


-- ─── P2: GEOGRAPHIES MSA rows — vintages + state-part splits ────────────────
-- Expect two OMB delineation vintages per MSA in AreaTypeVersion: '2001'
-- (pre-2023) and '2301' (2023). Definitions AND names differ across vintages
-- (e.g. 047260 = "Virginia Beach-Norfolk-Newport News" @2001 vs
-- "Virginia Beach-Chesapeake-Norfolk" @2301). Also expect Area LIKE 'S%' rows
-- = state-part splits of multi-state MSAs (e.g. S47900 "Washington ... VA
-- Part") — a different grain that must be EXCLUDED.
SELECT Area, AreaTypeVersion, AreaName
FROM WID.dbo.GEOGRAPHIES
WHERE StFips = '51' AND AreaType = '31'
ORDER BY Area, AreaTypeVersion;
-- RESULTS LOG P2 (2026-07-07, first run): CONFIRMED — 11 whole MSAs + 4 'S%'
-- state-part rows (S28700, S47260, S47900, S49020), each under both vintages
-- ('2001','2301'). The earlier "15 MSAs" figure was unscoped — it counted the
-- 4 S-part rows; the VA-scoped whole-MSA count is 11. Names differing across
-- vintages: 013980 Blacksburg-Christiansburg(+Radford @2301), 044420
-- Staunton(-Stuarts Draft @2301), 047260 Virginia Beach-Norfolk-Newport News
-- ('2001') vs Virginia Beach-Chesapeake-Norfolk ('2301'). RUN.sql pins
-- MAX(AreaTypeVersion) per Area for labels and excludes Area LIKE 'S%'.


-- ─── P3: IOWAGE MSA-grain coverage ───────────────────────────────────────────
-- Expect real MSA rows at AreaType='31': 11 whole MSAs, ~830–880 occupations,
-- 2024 richest, 2025 partial. NOTE: 2022 has NO MSA rows at all.
SELECT w.PeriodYear,
       COUNT(DISTINCT w.Area)    AS msas,
       COUNT(DISTINCT w.OccCode) AS occs,
       COUNT(*)                  AS rows_
FROM WID.dbo.IOWAGE w
WHERE w.StFips = '51' AND w.AreaType = '31' AND w.Area NOT LIKE 'S%'
GROUP BY w.PeriodYear
ORDER BY w.PeriodYear;
-- RESULTS LOG P3 (2026-07-07, first run): CONFIRMED — 11 MSAs every year;
-- years {2021, 2023, 2024, 2025} — 2022 is ABSENT (trend_years_dim in RUN.sql
-- is data-derived, so trend_years emits [2021,2023,2024] and trend arrays
-- align; no code change needed). 2024 richest: 874 occs / 41,858 rows; 2025
-- partial (764 occs / 9,112 rows). Tool pins target year 2024 (client
-- decision 2026-07-07; intentional even though 2025 rows exist).


-- ─── P3b: IOWAGE MSA vintage distribution by year — OPEN ────────────────────
-- Determines whether the per-(Area, PeriodYear) vintage anchor in RUN.sql is
-- load-bearing. If early trend years (2021–22) sit under AreaTypeVersion
-- '2001' while 2023+ sits under '2301', a per-Area MAX pin would silently
-- DROP the early years from the 4-year wage trend. RUN.sql therefore anchors
-- MAX(AreaTypeVersion) per (AreaType, Area, PeriodYear) — correct under
-- either outcome; this probe documents which world we're in.
SELECT w.PeriodYear, w.AreaTypeVersion, COUNT(*) AS rows_
FROM WID.dbo.IOWAGE w
WHERE w.StFips = '51' AND w.AreaType = '31' AND w.Area NOT LIKE 'S%'
GROUP BY w.PeriodYear, w.AreaTypeVersion
ORDER BY w.PeriodYear, w.AreaTypeVersion;
-- RESULTS LOG P3b (2026-07-07, first run): CONFIRMED — the anchor is
-- LOAD-BEARING. Matrix: 2021→'2001' (11,312 rows), 2023→'2001' (10,694),
-- 2024→'2301' (41,858), 2025→'2301' (9,112). A per-Area MAX pin would have
-- silently dropped 2021 and 2023 from the wage trend. Keep the
-- per-(AreaType, Area, PeriodYear) anchor in RUN.sql exactly as written.


-- ─── P4: ONETAlternativeTitles — alias dimension ────────────────────────────
-- Expect 57,543 rows, single vintage ONETCodeType='12'. ONETCode is 8-digit
-- O*NET-SOC WITHOUT punctuation (e.g. '21102200'); SOC-6 = LEFT(ONETCode,6).
-- Alias text = ONETJobTitle (informal alternates). ONETTitle is the formal
-- name; ONETShortTitle often NULL — neither is used.
SELECT ONETCodeType, COUNT(*) AS rows_,
       MIN(LEN(ONETCode)) AS min_len, MAX(LEN(ONETCode)) AS max_len,
       SUM(CASE WHEN ONETJobTitle IS NULL OR ONETJobTitle = '' THEN 1 ELSE 0 END) AS null_titles
FROM WID.dbo.ONETAlternativeTitles
GROUP BY ONETCodeType;
-- RESULTS LOG P4 (2026-07-07, client probe): CONFIRMED — 57,543 rows, single
-- vintage '12', 8-digit unpunctuated ONETCode, ONETJobTitle populated.
-- RUN.sql pins ONETCodeType='12' (no-op today; guards a future 2nd vintage —
-- same discipline as the SOCCodeType='19' pin). Alias index is search-only:
-- NEVER joined into wage aggregation (fanout would inflate every wage metric).


-- ─── P5: LABORFORCE MSA monthly series ──────────────────────────────────────
-- Expect monthly rows at AreaType='31' under PeriodType='03' (12 periods,
-- month grain), 2010–2025 complete. PeriodType='01' is annual — not used.
-- The sparkline join is bounded by the 11 IOWAGE MSAs — LABORFORCE MSAs
-- beyond those correctly never appear in the output.
SELECT lf.PeriodType, COUNT(DISTINCT lf.Area) AS msas,
       MIN(lf.PeriodYear) AS min_yr, MAX(lf.PeriodYear) AS max_yr,
       COUNT(DISTINCT lf.Period) AS periods
FROM WID.dbo.LABORFORCE lf
WHERE lf.StFips = '51' AND lf.AreaType = '31'
GROUP BY lf.PeriodType;
-- RESULTS LOG P5 (2026-07-07, first run): CONFIRMED — PeriodType='03'
-- monthly, 12 periods, 2010–2026, 12 MSAs at StFips='51' (covers all 11
-- IOWAGE MSAs). PeriodType='01' annual also present — unused.


-- ─── P6: label coverage — IOWAGE MSAs missing from GEOGRAPHIES — OPEN ───────
-- Every IOWAGE '31' area at the target year should resolve to a GEOGRAPHIES
-- label at MAX vintage. RUN.sql LEFT JOINs and falls back to the raw code as
-- the label (visible-loud, not a silent drop); expect 0 rows here.
SELECT DISTINCT w.Area
FROM WID.dbo.IOWAGE w
WHERE w.StFips = '51' AND w.AreaType = '31' AND w.Area NOT LIKE 'S%'
  AND w.PeriodYear = 2024
  AND NOT EXISTS (
      SELECT 1 FROM WID.dbo.GEOGRAPHIES g
      WHERE g.StFips = '51' AND g.AreaType = '31' AND g.Area = w.Area
  );
-- RESULTS LOG P6 (2026-07-07, first run): CONFIRMED — 0 rows. Every IOWAGE
-- '31' area resolves to a GEOGRAPHIES label; the code-as-label fallback in
-- RUN.sql should never fire.


-- ─── P7: statewide anchor sanity ─────────────────────────────────────────────
-- Employer-tool Probe 12 (2026-06-12) proved IOWAGE references statewide
-- Area='000000' exclusively ('000051' is a phantom GEOGRAPHIES dup). Re-check
-- cheaply for this tool's scan window.
SELECT w.Area, COUNT(*) AS rows_
FROM WID.dbo.IOWAGE w
WHERE w.StFips = '51' AND w.AreaType = '01' AND w.PeriodYear >= 2020
GROUP BY w.Area;
-- RESULTS LOG P7 (2026-07-07, first run): CONFIRMED — only '000000'
-- (231,736 rows in the 2020+ window). '000051' phantom never appears.


-- ─── P8: post-run smoke tests (run AFTER RUN.sql, against the emitted JSON) ──
-- 1. areas[]: expect 12 entries — 11 MSAs (areatype '31') + 1 statewide
--    ('01'); exactly ONE Virginia Beach row (the '2301'-vintage name
--    "Virginia Beach-Chesapeake-Norfolk"); no id beginning with 'S'; no
--    label that equals its own id (P6 fallback firing).
-- 2. meta: latest_year = 2024; trend_years = [2021,2023,2024] (2022 absent
--    from IOWAGE per P3 — a 2022 entry appearing means a backfill landed).
-- 3. jobs[]: count near 874 (P3, 2024); every job has non-empty label
--    (soc_dim join) and aliases array populated for common SOCs
--    (spot-check 29-1141 Registered Nurses — expect "RN"-style alternates).
-- 4. employment_trend.json: meta.months = 24 entries '2023-01'..'2024-12';
--    every trends key matches ^\d{2}-\d{4}__(\d{6})$; statewide series
--    present for high-employment SOCs.
-- 5. Cross-file: every area id referenced in a trends key exists in
--    wages.json areas[] (id migration keeps both files in lockstep).
