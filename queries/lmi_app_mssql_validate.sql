-- =============================================================================
-- LMI APP — WID 3.0 Step 0 probe pack (run before any _RUN.sql work)
-- =============================================================================
-- Read-only. Run all probes in SSMS / Azure Data Studio against the WID server.
-- Every probe is an independent batch (GO-separated) — a failure in one does
-- not stop the rest. Paste outcomes into the RESULTS LOG at the bottom and
-- share the populated file back; that is the input for LMI app query work.
--
-- Companion doc: LMI_APP_BRIEF.md §2 ("Step 0 — Reuse first, then verify the
-- gaps"). This file is the runnable form of that section plus the follow-on
-- probes the brief calls for but does not spell out.
--
-- Three-part names (WID.dbo.X / WID.sys.X / WID.INFORMATION_SCHEMA.X) are used
-- throughout so the file is database-context independent. No USE statement.
--
-- ─── OUTCOME SEMANTICS ───────────────────────────────────────────────────────
--   ABSENT   — object does not exist on this install.
--              → For CES/CPI this is a scope cut for §5.3/§5.4, not a load
--                ticket. For UIClams/ProjectionsMatrix, §5.5/§5.7 are cut.
--   PRESENT, 0 rows
--            — table exists, no data. File a load-gap ticket naming the table.
--              Expected for Population and Income (see "already known" below).
--   PRESENT, N rows
--            — proceed to P3/P4 to learn the grain and measure codes.
--
-- ─── ALREADY KNOWN — do not re-derive (sourced from prior probe RESULTS LOGS)
--   * CES        EXISTS as a table name on this install. So do CESCodes and
--                VI_CES. Source: dimension_resolution_probe.sql P8 RESULTS LOG
--                (2026-06-10). Row count, grain, and whether it carries an
--                average-hourly-earnings measure are ALL still unknown —
--                CESCodes inventory was explicitly deferred there.
--   * CPI        EXISTS with CONFIRMED columns, alongside CPIPlus / CPIItems /
--                CPITypes / CPISources. Source: community_profiles_mssql_
--                validate.sql R2d RESULTS LOG (2026-07-09), which characterizes
--                it as "inflation index series (CPI, PctChangeY2Y/M2M by
--                CPIType/CPIItem) — an INFLATION measure, NOT a US=100 cost-of-
--                living index." What is STILL unknown is the AREA GRAIN, which
--                is exactly brief open question 2 (national-only vs metro).
--                P3 answers it.
--   * Population EXIST with correct WID 3.0 schema and ZERO rows. Confirmed
--   * Income     2026-07-09, probe R3c. See docs/client-tickets/
--                WID-LOAD-GAP-PopulationIncome.md. They are listed in P1 so the
--                zero is visible and attributable, NOT because it is in doubt.
--   * UIClams    NO prior probe, no shipped query, no mention anywhere in this
--   * Projections   repo. Genuinely unknown. P1 is the first look.
--     Matrix
--
--   Consequence: P1's real job is row counts and the two unknown tables. Do not
--   report "CES exists" as a finding — that was established in June.
-- =============================================================================


-- ─── P1: existence + row counts ──────────────────────────────────────────────
-- Driven from an expected-list VALUES clause with LEFT JOINs, NOT from a
-- WHERE ... IN over sys.objects. That distinction is load-bearing: an IN-list
-- query cannot separate "table is absent" from "I forgot to list it" — both
-- return nothing. Same absent-versus-empty trap WID-LOAD-GAP-AvgAnnualPay.md
-- documents for a column, one level up.
--
-- sys.objects (not sys.tables) with type IN ('U','V') so VI_CES is caught if it
-- is a view. Views report NULL rows — that is correct, not a gap.
--
-- EXPECT: 12 rows, always. Population and Income at PRESENT/0.
WITH expected(table_name) AS (
    SELECT * FROM (VALUES
        ('CES'),('CPI'),('UIClams'),('ProjectionsMatrix'),
        ('Population'),('Income'),
        ('CESCodes'),('VI_CES'),
        ('CPIPlus'),('CPIItems'),('CPITypes'),('CPISources')
    ) v(table_name)
)
SELECT  e.table_name                        AS [expected_object],
        s.name                              AS [schema],
        CASE WHEN o.object_id IS NULL THEN 'ABSENT' ELSE 'PRESENT' END AS [status],
        o.type_desc                         AS [object_type],
        SUM(p.rows)                         AS [rows]
FROM expected e
LEFT JOIN WID.sys.objects    o ON o.name = e.table_name AND o.type IN ('U','V')
LEFT JOIN WID.sys.schemas    s ON s.schema_id = o.schema_id
LEFT JOIN WID.sys.partitions p ON p.object_id = o.object_id AND p.index_id IN (0,1)
GROUP BY e.table_name, s.name, o.object_id, o.type_desc
ORDER BY [status], [rows] DESC, [expected_object];
GO


-- ─── P2: column inventory for every object P1 finds ──────────────────────────
-- This is the probe that actually unblocks query writing. Nothing in this repo
-- knows the column names of CES, UIClams, or ProjectionsMatrix, so no content
-- query against them can be written until this returns.
--
-- Watch for (rename = silent wrong numbers, not errors — the failure mode
-- employer_wage_tool_mssql_validate.sql Probe 1 warns about):
--   * CES period columns — PeriodYear/Period vs a single date column
--   * CES measure discriminator — SeriesCode / DataType / Measure / CESCode.
--     §5.3 needs employment LEVELS and §5.4 needs AVERAGE HOURLY EARNINGS. If
--     only one measure is loaded, §5.4 is cut regardless of what CPI holds.
--   * CES seasonal-adjustment column — the brief assumes `Adjusted` per the
--     LABORFORCE convention. CES may name it differently or not carry it.
--   * UIClams initial-vs-continued discriminator, and its week column
--   * ProjectionsMatrix vintage columns (BaseYear / ProjYear or similar) —
--     §5.7 must resolve the loaded vintage at runtime, not assume 2022–2032
SELECT  c.TABLE_NAME, c.ORDINAL_POSITION, c.COLUMN_NAME,
        c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH, c.IS_NULLABLE
FROM WID.INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_SCHEMA = 'dbo'
  AND c.TABLE_NAME IN ('CES','CPI','UIClams','ProjectionsMatrix',
                       'CESCodes','VI_CES',
                       'CPIPlus','CPIItems','CPITypes','CPISources')
ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;
GO


-- ─── P3: per-column profile of the four unknown tables ───────────────────────
-- Answers the brief's "MIN and MAX period, distinct area types, distinct
-- measure or series codes" WITHOUT knowing which column is which. Profiles
-- every column generically: distinct count, min, max. Read the output and the
-- period / area / measure columns identify themselves.
--
-- Self-skipping: built from INFORMATION_SCHEMA, so an ABSENT table contributes
-- no columns and simply does not appear. Safe to run top-to-bottom regardless
-- of what P1 returned — no Msg 208.
--
-- READ IT LIKE THIS:
--   distinct_vals = 1        a pinned constant (StFips, a single vintage)
--   distinct_vals = 2..60    a code/dimension column — these are the ones that
--                            answer "distinct area types" and "measure codes"
--   min/max on a period col  the loaded date range, i.e. is the series current
--
--   For CPI specifically: if an area column shows distinct_vals = 1, CPI is
--   national-only on this install and §5.4 must state national CPI-U as the
--   deflator. That resolves brief open question 2.
--
-- COST: COUNT(DISTINCT) scans each column. Fine for a one-off on LMI-sized
-- tables. If a table turns out to be very large and this runs long, add a
-- WHERE clause to the generated SQL or profile that table alone.
DECLARE @sql NVARCHAR(MAX);

SELECT @sql = STRING_AGG(CAST(x.stmt AS NVARCHAR(MAX)), NCHAR(13) + N'UNION ALL' + NCHAR(13))
              WITHIN GROUP (ORDER BY x.TABLE_NAME, x.ORDINAL_POSITION)
FROM (
    SELECT c.TABLE_NAME, c.ORDINAL_POSITION,
           N'SELECT ' + QUOTENAME(c.TABLE_NAME, '''')  + N' AS [table], '
                      + QUOTENAME(c.COLUMN_NAME, '''') + N' AS [column], '
                      + QUOTENAME(c.DATA_TYPE, '''')   + N' AS [type], '
             + N'COUNT(DISTINCT ' + QUOTENAME(c.COLUMN_NAME) + N') AS [distinct_vals], '
             + N'CONVERT(NVARCHAR(60), MIN(' + QUOTENAME(c.COLUMN_NAME) + N')) AS [min_val], '
             + N'CONVERT(NVARCHAR(60), MAX(' + QUOTENAME(c.COLUMN_NAME) + N')) AS [max_val] '
             + N'FROM WID.dbo.' + QUOTENAME(c.TABLE_NAME) AS stmt
    FROM WID.INFORMATION_SCHEMA.COLUMNS c
    WHERE c.TABLE_SCHEMA = 'dbo'
      AND c.TABLE_NAME IN ('CES','CPI','UIClams','ProjectionsMatrix')
      -- types where MIN/MAX/COUNT DISTINCT are illegal or meaningless
      AND c.DATA_TYPE NOT IN ('text','ntext','image','xml','varbinary','binary',
                              'geography','geometry','hierarchyid','sql_variant')
) x;

IF @sql IS NULL
    SELECT 'No columns found — all four tables ABSENT on this install. See P1.' AS [note];
ELSE
    EXEC sp_executesql @sql;
GO


-- ─── P4: sample rows ─────────────────────────────────────────────────────────
-- One look at real rows, per the brief's "and one sample row". Guarded by
-- OBJECT_ID so an absent table is skipped rather than raising Msg 208.
-- SELECT * is deliberate here — the whole point is that the columns are unknown.
IF OBJECT_ID('WID.dbo.CES')               IS NOT NULL SELECT TOP 5 * FROM WID.dbo.CES;
IF OBJECT_ID('WID.dbo.CPI')               IS NOT NULL SELECT TOP 5 * FROM WID.dbo.CPI;
IF OBJECT_ID('WID.dbo.UIClams')           IS NOT NULL SELECT TOP 5 * FROM WID.dbo.UIClams;
IF OBJECT_ID('WID.dbo.ProjectionsMatrix') IS NOT NULL SELECT TOP 5 * FROM WID.dbo.ProjectionsMatrix;
IF OBJECT_ID('WID.dbo.CESCodes')          IS NOT NULL SELECT TOP 20 * FROM WID.dbo.CESCodes;
IF OBJECT_ID('WID.dbo.CPITypes')          IS NOT NULL SELECT TOP 20 * FROM WID.dbo.CPITypes;
IF OBJECT_ID('WID.dbo.CPIItems')          IS NOT NULL SELECT TOP 20 * FROM WID.dbo.CPIItems;
GO


-- ─── P5: LWDA Government rows — per LWDA x Ownership ─────────────────────────
-- Tests the assumption at labor_market_dashboard_mssql_RUN_v8.sql:490-496:
--
--   ASSUMPTION (verify on first refresh): IndCode='10' rows exist at
--   AreaType='15' with Ownership IN ('10','20','30'). If they don't, the
--   per-LWDA Government row will be NULL.
--
-- Still unverified as of this file. It sits directly under the LMI app's §6
-- drill grain, and it also gates the SHIPPED front-page app's per-LWDA
-- Government bars.
--
-- >>> THIS SUPERSEDES SMOKE TEST 5 in docs/handover/front-page-dashboard.md,
-- which is documented as resolving Validation Status row #11 but CANNOT
-- detect the failure it is named for, for two independent reasons:
--   1. It does `GROUP BY i.AreaType`, pooling all 14 LWDAs. One LWDA carrying
--      IndCode='10' yields distinct_codes = 11 and coverage_pct = 100.0 while
--      the other 13 render NULL Government bars.
--   2. It applies NO Ownership filter. IndCode='10' with Ownership='50'
--      (total private) certainly exists, and alone satisfies the distinct-code
--      count — so coverage reads 100% even if ZERO LWDAs carry the
--      '10'/'20'/'30' government rows the bar actually needs.
-- Recommend updating that smoke test to this shape and re-anchoring row #11.
--
-- Driven from GEOGRAPHIES and vintage-anchored, so it ALWAYS returns 42 rows
-- (14 LWDAs x 3 ownerships) and a missing locality appears as 0 rather than
-- vanishing from the result.
--
-- Vintage note: i_vintage and g_vintage are pinned INDEPENDENTLY and the fact
-- table is never joined to the dimension on AreaTypeVersion — per Validation
-- Status row #13 in the front-page handover, fact and dim carry different
-- vintages on this install, and joining them on version silently drops rows.
--
-- EXPECT: 42 rows, every [rows] > 0, max_yr at the current QCEW year.
--         Any 0 is a load-gap ticket. Fewer than 42 rows means GEOGRAPHIES
--         does not yield 14 LWDAs at the anchored vintage — also a finding,
--         since the brief and four shipped apps all assume 14.
WITH i_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.INDUSTRY
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY StFips, AreaType
),
g_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY StFips, AreaType
),
lwda_dim AS (
    -- '%Combined%' excludes the synthetic "Combined Projections Area
    -- (LWDA XI and LWDA XII)" — the same filter every shipped RUN query uses.
    SELECT g.Area, g.AreaName
    FROM WID.dbo.GEOGRAPHIES g
    JOIN g_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
),
own(Ownership) AS (SELECT * FROM (VALUES ('10'),('20'),('30')) v(Ownership))
SELECT  d.Area, d.AreaName, o.Ownership,
        COUNT(i.Area)     AS [rows],
        MAX(i.PeriodYear) AS [max_yr]
FROM lwda_dim d
CROSS JOIN own o
LEFT JOIN WID.dbo.INDUSTRY i
       ON i.StFips = '51' AND i.AreaType = '15' AND i.Area = d.Area
      AND i.PeriodType = '02' AND i.IndCode = '10' AND i.Ownership = o.Ownership
      AND i.AreaTypeVersion = (SELECT AreaTypeVersion FROM i_vintage)
GROUP BY d.Area, d.AreaName, o.Ownership
ORDER BY [rows], d.Area, o.Ownership;
GO


-- ─── P6: reconcile the two candidate Government definitions ──────────────────
-- Brief §5.6-quarterly needs a Government row, and this repo documents TWO
-- ways to get one that were established by different probes:
--
--   A. IndCode='10' + Ownership IN ('10','20','30')
--      Used by the shipped front-page Q3. Audited at 748,907 statewide
--      (2026-06-10). Validation Status rows #12 and #15.
--   B. Ownership='80' ("Total Government")
--      community_profiles_mssql_validate.sql R2e RESULTS LOG calls this a
--      "handy shortcut vs the CES three-code sum ... if a government rollup
--      is ever charted here."
--
-- Both readings are in the repo, neither has been compared to the other, and
-- an LMI implementer could reasonably pick either. If they disagree, two apps
-- publish different numbers for "Government" off the same table — precisely
-- the drift brief open question 6 is about. Settle it here, before §5.6 is
-- written, and record the winner in the RUN query header.
--
-- Note Ownership='80' sits OUTSIDE '00' Total Covered (Validation Status
-- row #17: '10','20','30','50' sums to '00' at ratio 1.0000). So B is a valid
-- standalone total but must never be ADDED to the others.
--
-- EXPECT: definition A at ~748,907 for the audited quarter. If B matches,
-- prefer B for simplicity and say so. If it does not, use A and record why.
WITH i_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.INDUSTRY
    WHERE StFips = '51' AND AreaType = '01'
    GROUP BY StFips, AreaType
),
anchored AS (
    SELECT i.*
    FROM WID.dbo.INDUSTRY i
    JOIN i_vintage iv
      ON i.StFips = iv.StFips AND i.AreaType = iv.AreaType
     AND i.AreaTypeVersion = iv.AreaTypeVersion
    WHERE i.StFips = '51' AND i.AreaType = '01' AND i.PeriodType = '02'
),
latest_q AS (
    SELECT TOP 1 PeriodYear, Period FROM anchored
    ORDER BY PeriodYear DESC, Period DESC
)
-- Conditional aggregation rather than UNION ALL of two filtered SELECTs, so a
-- definition that matches NO rows returns NULL in its column instead of
-- silently dropping its row from the output. Same absent-versus-zero rule P1
-- follows: a missing thing has to be visible.
SELECT  lq.PeriodYear, lq.Period,
        SUM(CASE WHEN a.Ownership IN ('10','20','30') THEN a.QuarterAvgEmp END) AS [A_own_10_20_30],
        SUM(CASE WHEN a.Ownership =  '80'             THEN a.QuarterAvgEmp END) AS [B_own_80]
FROM anchored a
CROSS JOIN latest_q lq
WHERE a.PeriodYear = lq.PeriodYear AND a.Period = lq.Period
  AND a.IndCode = '10'
GROUP BY lq.PeriodYear, lq.Period;
GO


-- ─── P7: load-audit / freshness source ───────────────────────────────────────
-- Brief §2 closes with: "confirm whether the WID has a load-audit or
-- last-refreshed table. If it does, use it for freshness rather than inferring
-- from MAX(period) — it distinguishes 'BLS has not published yet' from 'our
-- load failed', which present identically and mean very different things."
--
-- That distinction drives the tile "Stale state" behavior in brief §4.
--
-- P7a — dedicated audit/log tables by name.
SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE
FROM WID.INFORMATION_SCHEMA.TABLES
WHERE TABLE_NAME LIKE '%Load%'    OR TABLE_NAME LIKE '%Refresh%'
   OR TABLE_NAME LIKE '%Audit%'   OR TABLE_NAME LIKE '%Log'
   OR TABLE_NAME LIKE '%Release%' OR TABLE_NAME LIKE '%Status%'
   OR TABLE_NAME LIKE '%Meta%'    OR TABLE_NAME LIKE '%Version%'
ORDER BY TABLE_NAME;

-- P7b — per-row release stamps on the fact tables themselves.
-- Strong lead: community_profiles_mssql_validate.sql P7a RESULTS LOG records
-- that WID.dbo.Income carries a ReleaseDate column. If that is a WID 3.0
-- standard column present on LABORFORCE / INDUSTRY / IOWAGE / CES too, per-tile
-- freshness is free and needs no audit table at all.
SELECT c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE
FROM WID.INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_SCHEMA = 'dbo'
  AND c.COLUMN_NAME IN ('ReleaseDate','LoadDate','UpdateDate','LastUpdated',
                        'RefreshDate','AsOfDate','DateLoaded','ModifiedDate')
ORDER BY c.COLUMN_NAME, c.TABLE_NAME;
GO


-- =============================================================================
-- RESULTS LOG — fill in and share back
-- =============================================================================
-- Run date: ____________   Run by: ____________   Server/DB: ____________
--
-- ─── P1 existence + row counts ───────────────────────────────────────────────
--   CES ................. status ________  rows ________
--   CPI ................. status ________  rows ________
--   UIClams ............. status ________  rows ________
--   ProjectionsMatrix ... status ________  rows ________
--   Population .......... status ________  rows ________   (expect PRESENT/0)
--   Income .............. status ________  rows ________   (expect PRESENT/0)
--   CESCodes / VI_CES / CPIPlus / CPIItems / CPITypes / CPISources:
--   ____________________________________________________________________
--
--   DECIDES: §5.3 nonfarm jobs, §5.4 real earnings, §5.5 claims, §5.7
--   projections. Any ABSENT here is a scope cut to record in the brief.
--
-- ─── P2 column inventory ─────────────────────────────────────────────────────
--   CES period column(s): ______________________________________________
--   CES measure/series discriminator: ___________________________________
--   CES has an average-hourly-earnings measure?  YES / NO  ← gates §5.4
--   CES seasonal-adjustment column: _____________________________________
--   UIClams initial-vs-continued discriminator: _________________________
--   UIClams week column: ________________________________________________
--   ProjectionsMatrix vintage columns: __________________________________
--
-- ─── P3 per-column profile ───────────────────────────────────────────────────
--   CPI area grain — distinct area values: ______________________________
--     If 1, CPI is national-only → §5.4 states national CPI-U as deflator.
--     RESOLVES brief open question 2.
--   CES period range: ______________ to ______________
--   CES distinct area types: ____________________________________________
--   UIClams week range: ______________ to ______________
--   ProjectionsMatrix loaded vintage: ______________  (brief assumed 2022-2032)
--
-- ─── P4 sample rows ──────────────────────────────────────────────────────────
--   Anything surprising: ________________________________________________
--
-- ─── P5 LWDA Government coverage ─────────────────────────────────────────────
--   Rows returned (expect 42): ________
--   LWDA x Ownership combos with 0 rows: ________________________________
--   VERDICT:  all loaded  /  partial load (ticket)  /  absent (ticket)
--   Also resolves front-page Validation Status row #11, open since 2026-06-10.
--
-- ─── P6 Government definition reconciliation ─────────────────────────────────
--   A: IndCode=10 + Own IN (10,20,30) = ____________
--   B: IndCode=10 + Own = 80 ............ = ____________
--   Match?  YES / NO      Definition chosen for LMI: ________
--
-- ─── P7 freshness source ─────────────────────────────────────────────────────
--   Audit/log tables found: _____________________________________________
--   ReleaseDate (or similar) present on which fact tables: ______________
--   VERDICT: per-tile freshness from ______________ , or fall back to
--            MAX(period) with the stale-state caveat in brief §4.
--
-- ─── BLOCKING DECISION STILL OUTSIDE THIS FILE ───────────────────────────────
--   Brief open question 5 — is the QCEW rail annual or quarterly? No probe
--   answers it. It determines the ancestor query, the ownership filter, the
--   taxonomy, and what YoY means. Needed before §5.6 can be written.
-- =============================================================================
