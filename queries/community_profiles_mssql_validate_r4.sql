-- =============================================================================
-- COMMUNITY PROFILES — validation ROUND 4 (2026-07-09) — MSA membership defect
--
-- Companion to queries/community_profiles_mssql_validate.sql (rounds 1-3) and
-- docs/defects/MSA-DEFECT-suffix-collision.md. Run all three probes; fill the
-- RESULTS LOG inline. The RUN.sql fix is BLOCKED until P9-P11 are answered.
--
-- DEFECT BEING DIAGNOSED: msa_members in community_profiles_mssql_RUN.sql
-- joins county_dim ON cd.Area = sg.SubArea with NO constraint on the member's
-- state. SUBGEOGRAPHIES '31' rows include out-of-state member counties whose
-- SubArea carries their OWN state's 3-digit suffix ('000001' = DC 11001),
-- which collides onto VA localities sharing the suffix (51001 Accomack).
-- Result: 12 intruder localities across the 4 multi-state MSAs — wrong map
-- highlights for all 4, and wrong UNBADGED unemployment rates for every MSA
-- whose COALESCE fell through native to the polluted rollup.
--
-- THE TWO FACTS THE FIX NEEDS:
--   (1) the real name of the member-state column on SUBGEOGRAPHIES (P9), and
--   (2) exactly which MSAs lack native LAUS annual rows (P10), plus whether
--       native '31' rows are whole-MSA or VA-part quantities (P11) — i.e.
--       whether COALESCE(native, rollup) mixes two different grains in one
--       emitted field.
-- =============================================================================


-- ─── P9: SUBGEOGRAPHIES columns + Washington MSA member rows ─────────────────
-- Verify the member-state column's ACTUAL name (assumed SubStFips from the
-- WID 3.0 standard — verify, don't trust; rounds 1-3 never selected it).
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'SUBGEOGRAPHIES'
ORDER BY ORDINAL_POSITION;
-- RESULTS LOG P9a: OPEN — record the member-state column name verbatim.

-- P9b — assumption-free row dump (SELECT * so no column-name guess): the
-- Washington MSA membership. Expect out-of-state members (DC 001, Charles MD
-- 017, Frederick MD 021, Montgomery MD 031, Prince George's MD 033, Jefferson
-- WV 037 — and note whether Calvert MD 009 is present or genuinely missing)
-- carrying their own state code in the member-state column.
SELECT TOP 10 *
FROM WID.dbo.SUBGEOGRAPHIES
WHERE StFips = '51' AND AreaType = '31' AND Area = '047900'
ORDER BY SubArea;
-- RESULTS LOG P9b: OPEN — paste the rows; confirm which column separates
-- VA members from DC/MD/WV members, and whether Calvert MD (suffix 009) has
-- a row (profiles.json shows no 51009 collision, implying it may be absent).


-- ─── P10: native LAUS coverage at MSA grain — enumerate the fall-throughs ────
-- RUN.sql emits unempLatest = COALESCE(native '31' annual row, rollup). Every
-- MSA with NO native row below took the POLLUTED rollup and is displaying a
-- wrong, unbadged rate. Enumerate them — no more "likely Washington and
-- Kingsport".
WITH msa11 AS (
    SELECT * FROM (VALUES
        ('013980'),('016820'),('025500'),('028700'),('031340'),('040060'),
        ('040220'),('044420'),('047260'),('047900'),('049020')
    ) AS t(Area)                        -- the 11 whole MSAs in profiles.json
),
native_annual AS (
    SELECT lf.Area, lf.LaborForce, lf.Unemployed, lf.UnemployedRate
    FROM WID.dbo.LaborForce lf
    JOIN (
        SELECT StFips, AreaType, MAX(AreaTypeVersion) AS v
        FROM WID.dbo.LaborForce GROUP BY StFips, AreaType
    ) lv ON lv.StFips = lf.StFips AND lv.AreaType = lf.AreaType
        AND lv.v = lf.AreaTypeVersion
    WHERE lf.StFips = '51' AND lf.AreaType = '31'
      AND lf.PeriodType = '01' AND lf.PeriodYear = '2025'   -- same pins as RUN
      AND lf.Adjusted = '0'
)
SELECT m.Area,
       g.AreaName,
       CASE WHEN na.Area IS NULL THEN '*** NO NATIVE ROW -> POLLUTED ROLLUP ***'
            ELSE 'native' END AS unemp_source,
       na.LaborForce, na.Unemployed, na.UnemployedRate
FROM msa11 m
LEFT JOIN native_annual na ON na.Area = m.Area
LEFT JOIN WID.dbo.Geographies g
  ON g.StFips = '51' AND g.AreaType = '31' AND g.Area = m.Area
 AND g.AreaTypeVersion = (SELECT MAX(AreaTypeVersion) FROM WID.dbo.Geographies
                          WHERE StFips = '51' AND AreaType = '31' AND Area = m.Area)
ORDER BY m.Area;
-- RESULTS LOG P10: OPEN — name every MSA on the polluted-rollup path. Those
-- are the profiles.json unempLatest values that are WRONG today (unbadged).
-- Also record whether any Area appears under a different Adjusted/PeriodType
-- only (re-run without those filters if the native list looks short).


-- ─── P11: native vs rollup semantics — whole-MSA or VA-part? ─────────────────
-- COALESCE(native, rollup) is only coherent if both sides measure the same
-- thing. Test on three MSAs:
--   * Richmond 040060  — single-state CONTROL: native and VA rollup should be
--     near-identical (LAUS county sum vs published MSA figure).
--   * Virginia Beach 047260 (VA-NC) and Winchester 049020 (VA-WV) — TESTS:
--     if native >> VA-only rollup, the native row covers the WHOLE multi-state
--     MSA and RUN.sql's COALESCE mixes whole-MSA (native) with VA-part
--     (rollup) quantities in the same emitted field across regions.
-- >>> BEFORE RUNNING: replace SubStFips below with the member-state column
--     name confirmed in P9a. <<<
WITH members AS (
    SELECT sg.Area AS msa, sg.SubArea AS county
    FROM WID.dbo.SUBGEOGRAPHIES sg
    JOIN (
        SELECT StFips, AreaType, MAX(AreaTypeVersion) AS v
        FROM WID.dbo.SUBGEOGRAPHIES GROUP BY StFips, AreaType
    ) sv ON sv.StFips = sg.StFips AND sv.AreaType = sg.AreaType
        AND sv.v = sg.AreaTypeVersion
    WHERE sg.StFips = '51' AND sg.AreaType = '31'
      AND sg.Area IN ('040060','047260','049020')
      AND sg.SubStFips = '51'          -- <<< CORRECT PER P9a BEFORE RUNNING
),
county_laus AS (
    SELECT lf.Area, lf.LaborForce, lf.Unemployed
    FROM WID.dbo.LaborForce lf
    JOIN (
        SELECT StFips, AreaType, MAX(AreaTypeVersion) AS v
        FROM WID.dbo.LaborForce GROUP BY StFips, AreaType
    ) lv ON lv.StFips = lf.StFips AND lv.AreaType = lf.AreaType
        AND lv.v = lf.AreaTypeVersion
    WHERE lf.StFips = '51' AND lf.AreaType = '04'
      AND lf.PeriodType = '01' AND lf.PeriodYear = '2025' AND lf.Adjusted = '0'
),
va_rollup AS (
    SELECT m.msa,
           SUM(cl.LaborForce) AS rollup_lf,
           SUM(cl.Unemployed) AS rollup_unemp,
           ROUND(CAST(SUM(cl.Unemployed) AS FLOAT)
                 / NULLIF(SUM(cl.LaborForce), 0) * 100, 1) AS rollup_rate,
           COUNT(*) AS va_members
    FROM members m
    JOIN county_laus cl ON cl.Area = m.county
    GROUP BY m.msa
),
native_annual AS (
    SELECT lf.Area, lf.LaborForce, lf.Unemployed, lf.UnemployedRate
    FROM WID.dbo.LaborForce lf
    JOIN (
        SELECT StFips, AreaType, MAX(AreaTypeVersion) AS v
        FROM WID.dbo.LaborForce GROUP BY StFips, AreaType
    ) lv ON lv.StFips = lf.StFips AND lv.AreaType = lf.AreaType
        AND lv.v = lf.AreaTypeVersion
    WHERE lf.StFips = '51' AND lf.AreaType = '31'
      AND lf.PeriodType = '01' AND lf.PeriodYear = '2025' AND lf.Adjusted = '0'
)
SELECT r.msa,
       r.va_members,
       r.rollup_lf,  na.LaborForce  AS native_lf,
       r.rollup_unemp, na.Unemployed AS native_unemp,
       r.rollup_rate,  na.UnemployedRate AS native_rate,
       CASE WHEN na.LaborForce IS NULL THEN 'no native row'
            WHEN ABS(na.LaborForce - r.rollup_lf)
                 < 0.05 * r.rollup_lf THEN 'SAME magnitude -> native ~ VA part'
            ELSE 'DIFFERENT -> native covers whole multi-state MSA' END AS verdict
FROM va_rollup r
LEFT JOIN native_annual na ON na.Area = r.msa
ORDER BY r.msa;
-- RESULTS LOG P11: OPEN — Richmond should read SAME (control). Record the
-- Virginia Beach / Winchester verdicts. If DIFFERENT, the fix must decide ONE
-- semantic for unempLatest at MSA grain (native whole-MSA everywhere it
-- exists, VA-part rollup only as a LABELED fallback, or drop the fallback) —
-- per the no-trimming geography model, as-sourced native is the default
-- candidate, but the mixed-grain COALESCE as shipped is not acceptable.
