-- =============================================================================
-- COMMUNITY PROFILES — validation ROUND 4 (2026-07-09) — MSA membership defect
--
-- Companion to queries/community_profiles_mssql_validate.sql (rounds 1-3) and
-- docs/defects/MSA-DEFECT-suffix-collision.md. P9 is RESOLVED (results below);
-- P10/P11 were REWRITTEN 2026-07-09 after P9 — the originals enumerated only
-- the 11 whole MSA codes and could not see the S-prefixed state-part areas,
-- which may carry PUBLISHED VA-part fact rows. If they do, MSA profiles read
-- published VA-part aggregates natively and the mixed-grain COALESCE problem
-- DISSOLVES rather than needing a fallback rule. The RUN.sql fix is BLOCKED
-- until P10/P11 are answered; P12 is parked context, not blocking.
--
-- DEFECT RECAP: msa_members joined county_dim ON cd.Area = sg.SubArea with no
-- member-state constraint; out-of-state members collided onto same-suffix VA
-- localities (12 intruders across the 4 multi-state MSAs).
--
-- STORAGE MODEL (proven — P9 + the 129-row identity, see defect note):
--   * Whole-MSA parents (e.g. 047900) replicate the FULL member list under
--     EVERY asking state's StFips (Washington: 92 rows = 23 members x 4).
--   * S-part parents (S47900) list each member ONCE, filed under the
--     member's own StFips -> at StFips '51' an S-twin's membership is
--     exactly the VA part.
--   * Only the 4 multi-state MSAs have S-twins (S28700, S47260, S47900,
--     S49020 — wage tool P2, client-confirmed 2026-07-07, named e.g.
--     "Washington ... VA Part"). Single-state MSAs have none.
--   * ONE vintage on this install (AreaTypeVersion 2301 / SubAreaTypeVersion
--     0000) — no vintage anchor needed; NOT the front-page multi-vintage
--     mechanism.
-- =============================================================================


-- ─── P9: SUBGEOGRAPHIES columns + Washington MSA member rows ─────────────────
SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = 'SUBGEOGRAPHIES'
ORDER BY ORDINAL_POSITION;
-- RESULTS LOG P9a (2026-07-09, client run): CONFIRMED — member-state column
-- is SubStFips, char(2) NOT NULL, ordinal 5. Assumption verified.

SELECT TOP 10 *
FROM WID.dbo.SUBGEOGRAPHIES
WHERE StFips = '51' AND AreaType = '31' AND Area = '047900'
ORDER BY SubArea;
-- RESULTS LOG P9b (2026-07-09, client run): CONFIRMED —
--   * 047900 unfiltered: 92 rows = 23 distinct members x 4 asking states
--     (StFips 11/24/51/54 each carry a full whole-MSA copy).
--   * StFips='51' AND SubStFips='51': EXACTLY 17 rows, all genuine VA-part
--     members (51013,51043,51047,51059,51061,51107,51153,51157,51177,51179,
--     51187,51510,51600,51610,51630,51683,51685). Zero intruders. The
--     two-predicate pin is correct and sufficient for MEMBERSHIP.
--   * S47900: 23 rows / 23 members / 4 asking states — one row per member
--     under the member's own state (NOT replicated).
--   * Single vintage: 2301/0000, 1967 rows total.
--   * Calvert MD (24009) absent from the StFips-51 whole copy (23 members =
--     17 VA + DC + 4 MD + 1 WV) -> P12.
--   * The undocumented 92->23 collapse in RUN.sql = the sg.StFips='51'
--     predicate selecting Virginia's whole-MSA copy; county_dim dropped
--     nothing (23 in -> 23 out) and no DISTINCT exists downstream (the
--     Virginia Beach duplicate Gloucester proves it).


-- ─── P10 (REWRITTEN): S-aware fact-row sweep — NO known-area filter ──────────
-- R3a counted 12 distinct LABORFORCE areas and 15 INDUSTRY areas at '31'
-- without naming them. Stop inferring from counts: enumerate every Area,
-- S-prefixed or not, at the EXACT pins RUN.sql uses, with names.

-- P10a — LABORFORCE '31' areas at RUN pins (annual '01', 2025, Adjusted '0').
SELECT lf.Area,
       CASE WHEN lf.Area LIKE 'S%' THEN 'S-PART' ELSE 'whole' END AS kind,
       g.AreaName,
       COUNT(*) AS rows_
FROM WID.dbo.LaborForce lf
LEFT JOIN WID.dbo.Geographies g
  ON g.StFips = '51' AND g.AreaType = '31' AND g.Area = lf.Area
 AND g.AreaTypeVersion = (SELECT MAX(AreaTypeVersion) FROM WID.dbo.Geographies
                          WHERE StFips = '51' AND AreaType = '31' AND Area = lf.Area)
WHERE lf.StFips = '51' AND lf.AreaType = '31'
  AND lf.PeriodType = '01' AND lf.PeriodYear = '2025' AND lf.Adjusted = '0'
GROUP BY lf.Area, g.AreaName
ORDER BY lf.Area;
-- RESULTS LOG P10a: OPEN

-- P10b — LABORFORCE '31' areas across ALL years/periods (context: whether an
-- area exists at all vs merely lacking the pinned annual row).
SELECT lf.Area,
       CASE WHEN lf.Area LIKE 'S%' THEN 'S-PART' ELSE 'whole' END AS kind,
       MIN(lf.PeriodYear) AS min_yr, MAX(lf.PeriodYear) AS max_yr,
       COUNT(*) AS rows_
FROM WID.dbo.LaborForce lf
WHERE lf.StFips = '51' AND lf.AreaType = '31'
GROUP BY lf.Area
ORDER BY lf.Area;
-- RESULTS LOG P10b: OPEN — expect 12 areas (R3a); resolve the composition
-- by name/kind, not by count.

-- P10c — INDUSTRY '31' areas at RUN pins (IndCodeType '10', Ownership '00',
-- PeriodType '02', PeriodYear '2025').
SELECT i.Area,
       CASE WHEN i.Area LIKE 'S%' THEN 'S-PART' ELSE 'whole' END AS kind,
       g.AreaName,
       COUNT(*) AS rows_, COUNT(DISTINCT i.IndCode) AS ind_codes
FROM WID.dbo.Industry i
LEFT JOIN WID.dbo.Geographies g
  ON g.StFips = '51' AND g.AreaType = '31' AND g.Area = i.Area
 AND g.AreaTypeVersion = (SELECT MAX(AreaTypeVersion) FROM WID.dbo.Geographies
                          WHERE StFips = '51' AND AreaType = '31' AND Area = i.Area)
WHERE i.StFips = '51' AND i.AreaType = '31'
  AND i.IndCodeType = '10' AND i.Ownership = '00'
  AND i.PeriodType = '02' AND i.PeriodYear = '2025'
GROUP BY i.Area, g.AreaName
ORDER BY i.Area;
-- RESULTS LOG P10c: OPEN — expect ~15 areas (R3a, all years); confirm the
-- 11-whole + 4-S composition by name at the 2025 pins.

-- P10d — VERDICT TABLE: per multi-state MSA, per fact table.
WITH multi AS (
    SELECT * FROM (VALUES
        ('028700','S28700','Kingsport-Bristol'),
        ('047260','S47260','Virginia Beach'),
        ('047900','S47900','Washington'),
        ('049020','S49020','Winchester')
    ) AS t(whole_code, s_code, short_name)
),
laus_areas AS (
    SELECT DISTINCT Area FROM WID.dbo.LaborForce
    WHERE StFips = '51' AND AreaType = '31'
      AND PeriodType = '01' AND PeriodYear = '2025' AND Adjusted = '0'
),
ind_areas AS (
    SELECT DISTINCT Area FROM WID.dbo.Industry
    WHERE StFips = '51' AND AreaType = '31'
      AND IndCodeType = '10' AND Ownership = '00'
      AND PeriodType = '02' AND PeriodYear = '2025'
)
SELECT m.short_name, m.whole_code, m.s_code,
       CASE WHEN lw.Area IS NULL THEN 'no' ELSE 'yes' END AS laus_whole,
       CASE WHEN ls.Area IS NULL THEN 'no' ELSE 'yes' END AS laus_s,
       CASE WHEN ls.Area IS NOT NULL AND lw.Area IS NOT NULL THEN 'BOTH AVAILABLE (grain choice -> P11)'
            WHEN ls.Area IS NOT NULL THEN 'USE PUBLISHED S-PART'
            WHEN lw.Area IS NOT NULL THEN 'USE WHOLE'
            ELSE 'NEITHER -> ROLLUP REQUIRED' END AS laus_verdict,
       CASE WHEN iw.Area IS NULL THEN 'no' ELSE 'yes' END AS ind_whole,
       CASE WHEN isp.Area IS NULL THEN 'no' ELSE 'yes' END AS ind_s,
       CASE WHEN isp.Area IS NOT NULL AND iw.Area IS NOT NULL THEN 'BOTH AVAILABLE (grain choice -> P11)'
            WHEN isp.Area IS NOT NULL THEN 'USE PUBLISHED S-PART'
            WHEN iw.Area IS NOT NULL THEN 'USE WHOLE'
            ELSE 'NEITHER -> ROLLUP REQUIRED' END AS ind_verdict
FROM multi m
LEFT JOIN laus_areas lw  ON lw.Area  = m.whole_code
LEFT JOIN laus_areas ls  ON ls.Area  = m.s_code
LEFT JOIN ind_areas  iw  ON iw.Area  = m.whole_code
LEFT JOIN ind_areas  isp ON isp.Area = m.s_code
ORDER BY m.whole_code;
-- RESULTS LOG P10d: OPEN — this table decides the fix shape. Note: the
-- verdict is presence-based; where BOTH exist, the whole-vs-VA-part grain
-- choice is a design decision informed by P11 and the no-trimming geography
-- model (report as-sourced at the chosen grain).


-- ─── P11 (REWRITTEN): three-way grain comparison ─────────────────────────────
-- For Washington and Virginia Beach put side by side:
--   (a) whole-code native LAUS  (b) S-code native LAUS
--   (c) VA-members-only rollup from the CORRECT membership (both predicates)
-- Richmond (no S-twin) is the single-state control where (a) should equal (c).
-- Questions: does (b) ~= (c) (S = published VA part)? Does (a) exceed both
-- (whole = multi-state)?
WITH targets AS (
    SELECT * FROM (VALUES
        ('Richmond (control)', '040060', CAST(NULL AS varchar(6))),
        ('Washington',         '047900', 'S47900'),
        ('Virginia Beach',     '047260', 'S47260')
    ) AS t(label, whole_code, s_code)
),
members AS (                       -- CORRECT membership: both predicates
    SELECT sg.Area AS msa, sg.SubArea AS county
    FROM WID.dbo.SUBGEOGRAPHIES sg
    WHERE sg.StFips = '51' AND sg.AreaType = '31'
      AND sg.SubStFips = '51'                     -- P9a-confirmed column
      AND sg.Area IN (SELECT whole_code FROM targets)
),
county_laus AS (
    SELECT lf.Area, lf.LaborForce, lf.Unemployed
    FROM WID.dbo.LaborForce lf
    WHERE lf.StFips = '51' AND lf.AreaType = '04'
      AND lf.PeriodType = '01' AND lf.PeriodYear = '2025' AND lf.Adjusted = '0'
),
va_rollup AS (
    SELECT m.msa,
           COUNT(*) AS va_members,
           SUM(cl.LaborForce) AS c_lf,
           SUM(cl.Unemployed) AS c_unemp,
           ROUND(CAST(SUM(cl.Unemployed) AS FLOAT)
                 / NULLIF(SUM(cl.LaborForce), 0) * 100, 1) AS c_rate
    FROM members m
    JOIN county_laus cl ON cl.Area = m.county
    GROUP BY m.msa
),
msa_laus AS (
    SELECT lf.Area, lf.LaborForce, lf.Unemployed, lf.UnemployedRate
    FROM WID.dbo.LaborForce lf
    WHERE lf.StFips = '51' AND lf.AreaType = '31'
      AND lf.PeriodType = '01' AND lf.PeriodYear = '2025' AND lf.Adjusted = '0'
)
SELECT t.label,
       r.va_members,
       a.LaborForce AS a_whole_lf,  a.UnemployedRate AS a_whole_rate,
       b.LaborForce AS b_spart_lf,  b.UnemployedRate AS b_spart_rate,
       r.c_lf       AS c_rollup_lf, r.c_rate         AS c_rollup_rate,
       CASE WHEN b.Area IS NULL THEN 'no S row'
            WHEN ABS(b.LaborForce - r.c_lf) < 0.05 * r.c_lf
                 THEN 'S ~= rollup -> S IS the published VA part'
            ELSE 'S <> rollup -> INVESTIGATE' END AS s_vs_rollup,
       CASE WHEN a.Area IS NULL THEN 'no whole row'
            WHEN a.LaborForce > 1.2 * r.c_lf
                 THEN 'whole >> VA part -> whole is multi-state'
            WHEN ABS(a.LaborForce - r.c_lf) < 0.05 * r.c_lf
                 THEN 'whole ~= VA rollup (single-state control OK)'
            ELSE 'AMBIGUOUS -> INVESTIGATE' END AS whole_vs_rollup
FROM targets t
LEFT JOIN va_rollup r ON r.msa  = t.whole_code
LEFT JOIN msa_laus  a ON a.Area = t.whole_code
LEFT JOIN msa_laus  b ON b.Area = t.s_code
ORDER BY t.label;
-- RESULTS LOG P11: OPEN — expected: Richmond control 'whole ~= VA rollup';
-- Washington likely 'no whole row' (home-state gotcha) + S verdict decides;
-- Virginia Beach (VA-primary) may have BOTH -> the a-vs-b gap measures the
-- NC share. If S rows confirm as published VA parts, the RUN.sql fix reads
-- them natively and no rollup or mixed-grain COALESCE is needed for MSAs.


-- ─── P12: CALVERT CHECK (parked — do not block on this) ──────────────────────
-- Washington's StFips-51 whole copy has 4 MD members, no Calvert (24009).
-- Absent from the 2301 delineation entirely, or just from Virginia's copy?
SELECT sg.StFips AS asking_state, sg.SubStFips, sg.SubArea
FROM WID.dbo.SUBGEOGRAPHIES sg
WHERE sg.Area = '047900' AND sg.AreaType = '31' AND sg.SubStFips = '24'
ORDER BY sg.StFips, sg.SubArea;
-- RESULTS LOG P12: OPEN — if '000009' appears under NO asking state, Calvert
-- is out of the loaded 2301 delineation (national-copy question / possible
-- punchlist item, since OMB 2023 lists Calvert in the Washington MSA). Park
-- the answer either way.
