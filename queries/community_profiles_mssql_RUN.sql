-- =============================================================================
-- COMMUNITY PROFILES — SQL Server (T-SQL) — JSON-emitting "RUN" build
--
-- Emits ONE JSON blob -> apps/community-profiles/data/profiles.json
-- (single NVARCHAR(MAX) cell; save the cell contents verbatim to the file).
--
-- Verified: 2026-07-09   WID variant: VA WID 3.0 (client SQL Server)
-- Validation: queries/community_profiles_mssql_validate.sql — 3 rounds, ALL
-- probes resolved 2026-07-09. Re-run validation after any WID reload.
--
-- TRANCHE 1 SCOPE (client decisions 2026-07-08):
--   * Overview cards: unemployment (LAUS) + top industries (QCEW). Real.
--   * GDP: representative by decision (BEA, not in WID).
--   * Population + median household income: WID tables are EMPTY — load gap
--     filed (docs/client-tickets/WID-LOAD-GAP-PopulationIncome.md). Those
--     fields are OMITTED from profiles; the front-end merge seam keeps
--     representative data and the per-chart "Illustrative" badge for them.
--   * All other charts: design placeholders, no SQL by decision.
--
-- GEOGRAPHY MODEL (client decision 2026-07-09 — NO STATE-BOUNDARY TRIMMING):
--   Profiles report whatever the WID tables carry at the chosen grain; grain
--   selection is the only filter. Native-grain fact rows are used wherever
--   they exist (R3a): Industry has native state/LWDA/MSA/county rows;
--   LaborForce has native state/MSA/county (NO LWDA rows). Rollups from
--   member counties happen ONLY where no native grain exists:
--     - LWDA unemployment (LAUS counties, unsuppressed numerators — safe)
--     - GO Virginia everything (not a WID geography; official 9-region
--       composition is the sanctioned hand-mapped VALUES block)
--     - COALESCE fallback for state/MSA unemployment if native annual rows
--       are absent for the pinned year.
--   MSAs: GEOGRAPHIES '31' minus Area LIKE 'S%' state-part splits as REGION
--   IDS (11 whole MSAs, labels at MAX(AreaTypeVersion) per Area — same id
--   scheme as the wage tool). Cross-border MSA labeling is a deferred
--   cosmetic question.
--
-- MSA GRAIN POLICY (client decision 2026-07-11 — "as-sourced, whole-first"):
--   * MEMBERSHIP (map fips + rollup inputs): VA-part members via the
--     two-predicate pin StFips='51' AND SubStFips='51' (defect fix, R4 P9).
--     SUBGEOGRAPHIES replicates whole-MSA member lists under EVERY asking
--     state's StFips with out-of-state members carrying their own state's
--     suffix — StFips alone selects a full multi-state copy whose codes
--     collide onto same-suffix VA localities. See
--     docs/defects/MSA-DEFECT-suffix-collision.md. VA-part member counts:
--     Washington 17, Virginia Beach 15, Kingsport 3, Winchester 2.
--   * industryEmployment: whole-MSA native '31' rows (as-sourced; correct
--     since tranche 1). Do NOT switch to S-part Industry rows — R4 P10c red
--     flag: S-part row/code counts are IDENTICAL to their whole twins and
--     may be duplicated whole values; P13 unresolved.
--   * unempLatest: priority chain per MSA, documented per region —
--       1) whole-MSA published LAUS ('31' whole code)  [9 MSAs incl VB, Winchester]
--       2) S-part published LAUS ('S'+code = the published VA part; R4 P11
--          proved S = VA rollup to 1 unit)              [Kingsport only]
--       3) correct-membership VA rollup                 [Washington only —
--          NO published LAUS at ANY grain under StFips 51; R4 P10a/b]
--     Grain therefore varies by MSA (whole for most, VA-part for Kingsport/
--     Washington) — accepted under as-sourced policy; the front end's
--     "Illustrative" badges are unaffected (all three sources are real).
--
-- REGION IDS in profiles[] (front-end lookup keys):
--   'state' | 'c-51xxx' counties (fips) | 6-digit LWDA codes ('000441'…) |
--   6-digit MSA Area codes | 'gov-1'..'gov-9'.
--   >>> FRONT-END NOTE: index.html currently uses hand-curated MSA slugs
--   ('msa-richmond', …). The regions.msa block below carries the dim-derived
--   codes + names + member fips; switch the app's MSA list to consume it
--   (wiring task) so profile lookups key correctly. LWDA ids already match
--   (map fix 2026-07-09). Bedford City 51515 exists only as app display
--   geometry; no data ever keys to it. <<<
--
-- PINNED LITERALS — ROLL-FORWARD:
--   * LAUS year '2025' (annual avg, PeriodType '01', Adjusted '0'; 2010-2025
--     confirmed at county grain, P4a). Roll to '2026' when its annual rows
--     land.
--   * QCEW year '2025' (PeriodType '02', quarters 01-04 all present, R2f).
--     Annual avg emp = SUM(QuarterAvgEmp)/4.0. Roll the ONE literal + /4.0
--     assumption together (partial years would need COUNT of quarters).
--   * Ownership '00' = "Aggregate of all types" (R2e). IndCodeType '10'.
--
-- SECTOR LABELS (dimension-derived-labels standard):
--   NAICSSectors dim, joined via the two-column wid_code lookup because fact
--   IndCode stores BLS range strings ('31-33','44-45','48-49') while the dim
--   keys plain 2-digit codes (R2a). Labels verbatim — incl. the known
--   punchlist typo in sector 54 ("Professiona.l …").
--
-- SUPPRESSION (R3b): Suppress='1' county cells carry real values on this
--   install; sums are numerically sound and native-grain rows sidestep the
--   question for state/LWDA/MSA. Whether suppressed COUNTY cells may be
--   displayed publicly is an open client policy question (handover doc).
--
-- REQUIRES: SQL Server 2017+ (STRING_AGG). Read-only; no temp tables/DDL.
-- =============================================================================

WITH
-- ── vintage anchors (intra-table MAX per StFips+AreaType — house standard) ──
g_vin AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS v
    FROM WID.dbo.Geographies GROUP BY StFips, AreaType
),
sg_vin AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS v
    FROM WID.dbo.SubGeographies GROUP BY StFips, AreaType
),
lf_vin AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS v
    FROM WID.dbo.LaborForce GROUP BY StFips, AreaType
),
i_vin AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS v
    FROM WID.dbo.Industry GROUP BY StFips, AreaType
),

-- ── geography dims ───────────────────────────────────────────────────────────
lwda_dim AS (              -- 14 real LWDAs (P2; excludes 000491 'Combined')
    SELECT g.Area, g.AreaName
    FROM WID.dbo.Geographies g
    JOIN g_vin gv ON gv.StFips = g.StFips AND gv.AreaType = g.AreaType
                 AND gv.v = g.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
),
lwda_members AS (          -- 133 locality memberships (P3a)
    SELECT sg.Area AS lwda, sg.SubArea AS county
    FROM WID.dbo.SubGeographies sg
    JOIN sg_vin sv ON sv.StFips = sg.StFips AND sv.AreaType = sg.AreaType
                  AND sv.v = sg.AreaTypeVersion
    JOIN lwda_dim ld ON ld.Area = sg.Area
    WHERE sg.StFips = '51' AND sg.AreaType = '15' AND sg.SubAreaType = '04'
      AND sg.SubStFips = '51'   -- explicit member-state pin (all LWDA members
                                -- are VA today, P3a — but never rely on it)
),
county_dim AS (            -- exactly the 133 LWDA-member localities; the
                           -- Industry fact has 137 '04' areas (P5b) — joining
                           -- through membership drops pseudo-areas.
    SELECT g.Area, g.AreaName,
           '51' + RIGHT(g.Area, 3)        AS fips,
           'c-51' + RIGHT(g.Area, 3)      AS region_id
    FROM WID.dbo.Geographies g
    JOIN g_vin gv ON gv.StFips = g.StFips AND gv.AreaType = g.AreaType
                 AND gv.v = g.AreaTypeVersion
    JOIN (SELECT DISTINCT county FROM lwda_members) lm ON lm.county = g.Area
    WHERE g.StFips = '51' AND g.AreaType = '04'
),
msa_dim AS (               -- 11 whole MSAs; label pinned MAX vintage PER AREA
                           -- (dual OMB vintages — wage-tool pattern)
    SELECT g.Area, g.AreaName
    FROM WID.dbo.Geographies g
    JOIN (
        SELECT Area, MAX(AreaTypeVersion) AS v
        FROM WID.dbo.Geographies
        WHERE StFips = '51' AND AreaType = '31'
        GROUP BY Area
    ) mv ON mv.Area = g.Area AND mv.v = g.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '31'
      AND g.Area NOT LIKE 'S%'
),
msa_members AS (           -- VA-PART membership — BOTH predicates required
                           -- (defect fix, R4 P9: StFips alone selects the
                           -- full multi-state copy; SubStFips='51' keeps the
                           -- 17/15/3/2 genuine VA members, zero collisions,
                           -- and kills the Gates-NC duplicate Gloucester)
    SELECT sg.Area AS msa, sg.SubArea AS county
    FROM WID.dbo.SubGeographies sg
    JOIN sg_vin sv ON sv.StFips = sg.StFips AND sv.AreaType = sg.AreaType
                  AND sv.v = sg.AreaTypeVersion
    JOIN msa_dim md ON md.Area = sg.Area
    JOIN county_dim cd ON cd.Area = sg.SubArea
    WHERE sg.StFips = '51' AND sg.AreaType = '31'
      AND sg.SubStFips = '51'
),
gova_members AS (          -- GO Virginia: official 9-region composition —
                           -- sanctioned hand-mapping (no WID dim exists, P8).
                           -- Mirrors apps/community-profiles/index.html.
    SELECT t.gov_id, '000' + t.c AS county
    FROM (VALUES
        ('gov-1','105'),('gov-1','169'),('gov-1','195'),('gov-1','720'),('gov-1','051'),('gov-1','027'),('gov-1','167'),('gov-1','185'),('gov-1','191'),('gov-1','520'),('gov-1','173'),('gov-1','021'),('gov-1','197'),('gov-1','077'),('gov-1','640'),('gov-1','035'),
        ('gov-2','005'),('gov-2','580'),('gov-2','023'),('gov-2','045'),('gov-2','161'),('gov-2','770'),('gov-2','775'),('gov-2','067'),('gov-2','063'),('gov-2','071'),('gov-2','121'),('gov-2','750'),('gov-2','155'),
        ('gov-3','089'),('gov-3','690'),('gov-3','141'),('gov-3','143'),('gov-3','590'),('gov-3','083'),('gov-3','117'),('gov-3','025'),('gov-3','037'),('gov-3','111'),('gov-3','135'),('gov-3','147'),('gov-3','029'),('gov-3','049'),
        ('gov-4','760'),('gov-4','087'),('gov-4','041'),('gov-4','085'),('gov-4','075'),('gov-4','145'),('gov-4','127'),('gov-4','036'),('gov-4','007'),('gov-4','053'),('gov-4','149'),('gov-4','730'),('gov-4','670'),('gov-4','570'),('gov-4','181'),('gov-4','183'),('gov-4','081'),('gov-4','595'),
        ('gov-5','810'),('gov-5','710'),('gov-5','550'),('gov-5','740'),('gov-5','800'),('gov-5','700'),('gov-5','650'),('gov-5','830'),('gov-5','095'),('gov-5','199'),('gov-5','735'),('gov-5','073'),('gov-5','093'),('gov-5','175'),('gov-5','620'),('gov-5','115'),('gov-5','001'),('gov-5','131'),
        ('gov-6','033'),('gov-6','057'),('gov-6','099'),('gov-6','101'),('gov-6','097'),('gov-6','103'),('gov-6','119'),('gov-6','133'),('gov-6','159'),('gov-6','193'),('gov-6','177'),('gov-6','179'),('gov-6','630'),
        ('gov-7','013'),('gov-7','059'),('gov-7','107'),('gov-7','153'),('gov-7','510'),('gov-7','600'),('gov-7','610'),('gov-7','683'),('gov-7','685'),
        ('gov-8','015'),('gov-8','017'),('gov-8','091'),('gov-8','163'),('gov-8','165'),('gov-8','171'),('gov-8','069'),('gov-8','043'),('gov-8','139'),('gov-8','187'),('gov-8','530'),('gov-8','678'),('gov-8','790'),('gov-8','820'),('gov-8','660'),('gov-8','840'),
        ('gov-9','003'),('gov-9','065'),('gov-9','079'),('gov-9','109'),('gov-9','125'),('gov-9','113'),('gov-9','137'),('gov-9','047'),('gov-9','061'),('gov-9','157'),('gov-9','009'),('gov-9','011'),('gov-9','031'),('gov-9','019'),('gov-9','540'),('gov-9','680')
    ) AS t(gov_id, c)
),

-- ── region master + membership (drives rollups + emission order) ────────────
region_master AS (
    SELECT 'state' AS region_id, 'State' AS lvl, 'Commonwealth of Virginia' AS name, 10 AS sort1, '' AS sort2
    UNION ALL SELECT Area, 'Metro Area (MSA)', AreaName, 20, AreaName FROM msa_dim
    UNION ALL SELECT DISTINCT gov_id, 'GO Virginia Region', 'GO Virginia Region ' + RIGHT(gov_id, 1), 30, gov_id FROM gova_members
    UNION ALL SELECT Area, 'Local Workforce Area (LWDA)', AreaName, 40, Area FROM lwda_dim
    UNION ALL SELECT region_id, 'County / City', AreaName, 50, AreaName FROM county_dim
),
region_members AS (
    SELECT 'state' AS region_id, Area AS county FROM county_dim
    UNION ALL SELECT msa,    county FROM msa_members
    UNION ALL SELECT gov_id, county FROM gova_members
    UNION ALL SELECT lwda,   county FROM lwda_members
    UNION ALL SELECT region_id, Area FROM county_dim
),

-- ── LAUS: latest annual unemployment ─────────────────────────────────────────
laus_county AS (
    SELECT lf.Area, lf.LaborForce, lf.Unemployed, lf.UnemployedRate
    FROM WID.dbo.LaborForce lf
    JOIN lf_vin lv ON lv.StFips = lf.StFips AND lv.AreaType = lf.AreaType
                  AND lv.v = lf.AreaTypeVersion
    JOIN county_dim cd ON cd.Area = lf.Area
    WHERE lf.StFips = '51' AND lf.AreaType = '04'
      AND lf.PeriodType = '01' AND lf.PeriodYear = '2025'   -- ROLL-FORWARD
      AND lf.Adjusted = '0'
),
laus_native AS (           -- published rates with per-MSA grain priority
                           -- (client policy 2026-07-11, as-sourced whole-
                           -- first): pri 1 = whole grain, pri 2 = S-part
                           -- published VA part (R4 P11: S = VA rollup to 1
                           -- unit). ROW_NUMBER picks the best available;
                           -- regions with neither fall through to rollup.
    SELECT region_id, rate FROM (
        SELECT n.region_id, n.rate,
               ROW_NUMBER() OVER (PARTITION BY n.region_id ORDER BY n.pri) AS rn
        FROM (
            SELECT 'state' AS region_id, lf.UnemployedRate AS rate, 1 AS pri
            FROM WID.dbo.LaborForce lf
            JOIN lf_vin lv ON lv.StFips = lf.StFips AND lv.AreaType = lf.AreaType
                          AND lv.v = lf.AreaTypeVersion
            WHERE lf.StFips = '51' AND lf.AreaType = '01'
              AND lf.PeriodType = '01' AND lf.PeriodYear = '2025' AND lf.Adjusted = '0'
            UNION ALL
            -- whole-MSA published row (9 of 11 MSAs; absent for Washington +
            -- Kingsport — LAUS home-state gotcha, R4 P10a)
            SELECT md.Area, lf.UnemployedRate, 1
            FROM WID.dbo.LaborForce lf
            JOIN lf_vin lv ON lv.StFips = lf.StFips AND lv.AreaType = lf.AreaType
                          AND lv.v = lf.AreaTypeVersion
            JOIN msa_dim md ON md.Area = lf.Area
            WHERE lf.StFips = '51' AND lf.AreaType = '31'
              AND lf.PeriodType = '01' AND lf.PeriodYear = '2025' AND lf.Adjusted = '0'
            UNION ALL
            -- S-part published row = the VA part ('S' + last 5 of the whole
            -- code; covers Kingsport; S47900 does not exist so Washington
            -- still falls through to the rollup — R4 P10a/b)
            SELECT md.Area, lf.UnemployedRate, 2
            FROM WID.dbo.LaborForce lf
            JOIN lf_vin lv ON lv.StFips = lf.StFips AND lv.AreaType = lf.AreaType
                          AND lv.v = lf.AreaTypeVersion
            JOIN msa_dim md ON 'S' + RIGHT(md.Area, 5) = lf.Area
            WHERE lf.StFips = '51' AND lf.AreaType = '31'
              AND lf.PeriodType = '01' AND lf.PeriodYear = '2025' AND lf.Adjusted = '0'
            UNION ALL
            SELECT cd.region_id, lc.UnemployedRate, 1
            FROM laus_county lc JOIN county_dim cd ON cd.Area = lc.Area
        ) n
    ) x WHERE x.rn = 1
),
laus_rollup AS (           -- numerator-correct fallback / LWDA + GOVA path
    SELECT rm.region_id,
           SUM(lc.Unemployed) AS unemp, SUM(lc.LaborForce) AS lf
    FROM region_members rm
    JOIN laus_county lc ON lc.Area = rm.county
    GROUP BY rm.region_id
),
unemp_final AS (
    SELECT r.region_id,
           COALESCE(
               ln.rate,
               ROUND(CAST(lr.unemp AS FLOAT) / NULLIF(lr.lf, 0) * 100, 1)
           ) AS unempLatest
    FROM region_master r
    LEFT JOIN laus_native ln ON ln.region_id = r.region_id
    LEFT JOIN laus_rollup lr ON lr.region_id = r.region_id
),

-- ── QCEW: industry employment by NAICS-2 sector, annual average ─────────────
sector_lookup AS (         -- wid_code = form stored in fact IndCode (ranges!);
                           -- sector_key joins the NAICSSectors label dim (R2a)
    SELECT * FROM (VALUES
        ('11','11'),('21','21'),('22','22'),('23','23'),('31','31-33'),
        ('42','42'),('44','44-45'),('48','48-49'),('51','51'),('52','52'),
        ('53','53'),('54','54'),('55','55'),('56','56'),('61','61'),
        ('62','62'),('71','71'),('72','72'),('81','81'),('92','92'),('99','99')
    ) AS t(sector_key, wid_code)
),
qcew_cell AS (             -- one row per (grain area, sector): 2025 annual avg
    SELECT i.AreaType, i.Area, sl.sector_key, ns.SectorDesc,
           SUM(i.QuarterAvgEmp) / 4.0 AS annual_avg   -- 4 quarters confirmed R2f
    FROM WID.dbo.Industry i
    JOIN i_vin iv ON iv.StFips = i.StFips AND iv.AreaType = i.AreaType
                 AND iv.v = i.AreaTypeVersion
    JOIN sector_lookup sl ON sl.wid_code = LTRIM(RTRIM(i.IndCode))
    JOIN WID.dbo.NAICSSectors ns ON ns.NAICSSector = sl.sector_key
    WHERE i.StFips = '51'
      AND i.AreaType IN ('01','04','15','31')
      AND i.IndCodeType = '10' AND i.Ownership = '00'
      AND i.PeriodType = '02' AND i.PeriodYear = '2025'   -- ROLL-FORWARD
    GROUP BY i.AreaType, i.Area, sl.sector_key, ns.SectorDesc
),
ind_by_region AS (
    -- native grain: state / LWDA / MSA / county
    SELECT 'state' AS region_id, sector_key, SectorDesc, annual_avg
    FROM qcew_cell WHERE AreaType = '01'
    UNION ALL
    SELECT ld.Area, qc.sector_key, qc.SectorDesc, qc.annual_avg
    FROM qcew_cell qc JOIN lwda_dim ld ON ld.Area = qc.Area
    WHERE qc.AreaType = '15'
    UNION ALL
    SELECT md.Area, qc.sector_key, qc.SectorDesc, qc.annual_avg
    FROM qcew_cell qc JOIN msa_dim md ON md.Area = qc.Area
    WHERE qc.AreaType = '31'
    UNION ALL
    SELECT cd.region_id, qc.sector_key, qc.SectorDesc, qc.annual_avg
    FROM qcew_cell qc JOIN county_dim cd ON cd.Area = qc.Area
    WHERE qc.AreaType = '04'
    UNION ALL
    -- GO Virginia: county rollup (values present even when Suppress='1', R3b)
    SELECT gm.gov_id, qc.sector_key, MAX(qc.SectorDesc), SUM(qc.annual_avg)
    FROM gova_members gm
    JOIN qcew_cell qc ON qc.AreaType = '04' AND qc.Area = gm.county
    GROUP BY gm.gov_id, qc.sector_key
)

-- ── final emission: ONE cell -> data/profiles.json ───────────────────────────
SELECT
    JSON_QUERY((
        SELECT
            CONVERT(varchar(10), GETDATE(), 120) AS generated,
            '2025' AS laus_year,
            '2025' AS qcew_year,
            'unempLatest+industryEmployment real; population/income await WID load (see WID-LOAD-GAP-PopulationIncome); GDP representative by decision' AS coverage
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS meta,
    JSON_QUERY((
        SELECT
            JSON_QUERY((
                SELECT ld.Area AS id, ld.AreaName AS name,
                       JSON_QUERY('[' + (
                           SELECT STRING_AGG(CAST('"' + cd.fips + '"' AS NVARCHAR(MAX)), ',')
                           FROM lwda_members lm JOIN county_dim cd ON cd.Area = lm.county
                           WHERE lm.lwda = ld.Area
                       ) + ']') AS fips
                FROM lwda_dim ld ORDER BY ld.Area
                FOR JSON PATH
            )) AS lwda,
            JSON_QUERY((
                SELECT md.Area AS id, md.AreaName AS name,
                       JSON_QUERY('[' + (
                           SELECT STRING_AGG(CAST('"' + cd.fips + '"' AS NVARCHAR(MAX)), ',')
                           FROM msa_members mm JOIN county_dim cd ON cd.Area = mm.county
                           WHERE mm.msa = md.Area
                       ) + ']') AS fips
                FROM msa_dim md ORDER BY md.AreaName
                FOR JSON PATH
            )) AS msa
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS regions,
    JSON_QUERY((
        SELECT
            rm.region_id AS id,
            CAST(uf.unempLatest AS DECIMAL(4,1)) AS unempLatest,
            '2025' AS unempLatestYear,
            JSON_QUERY((
                SELECT ir.SectorDesc AS name,
                       CAST(ROUND(ir.annual_avg, 0) AS INT) AS value
                FROM ind_by_region ir
                WHERE ir.region_id = rm.region_id
                ORDER BY ir.annual_avg DESC
                FOR JSON PATH
            )) AS industryEmployment
        FROM region_master rm
        LEFT JOIN unemp_final uf ON uf.region_id = rm.region_id
        ORDER BY rm.sort1, rm.sort2
        FOR JSON PATH
    )) AS profiles
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;


-- =============================================================================
-- SMOKE TESTS (run separately after the emission; do not schedule)
-- =============================================================================
-- S1: profile count — expect 168 (1 state + 11 MSA + 9 GOVA + 14 LWDA + 133).
-- S2: state unempLatest equals the published VA 2025 annual-average rate
--     (native '01' row, not the county rollup — check laus_native hit).
-- S3: an LWDA unemployment spot-check: Hampton Roads (000456) rate must equal
--     ROUND(SUM(Unemployed)/SUM(LaborForce)*100,1) over its 16 localities.
-- S4: industryEmployment for LWDA regions comes from NATIVE '15' rows —
--     compare 000456 total vs summing its member counties; a small gap is
--     expected (suppression/rounding), a large one means a join broke.
-- S5: every profiles[].industryEmployment has <= 21 sectors and its top
--     sector label matches NAICSSectors verbatim (incl. the sector-54 typo).
-- S6: no MSA id in profiles[] starts with 'S' — S-codes are read INTERNALLY
--     (Kingsport's published VA-part LAUS) but always emitted under the
--     whole-MSA id.
-- S7 (defect regression, R4): regions.msa member counts = Washington 17,
--     Virginia Beach 15, Kingsport 3, Winchester 2; NO duplicate fips within
--     any member list (the Gates-NC Gloucester dup must be gone); every
--     Washington member is genuinely NoVA/exurban — NAME-LEVEL check against
--     the P9b list, not a count check.
-- S8 (expected values from R4 P11): Washington unempLatest = 3.1 (correct-
--     membership rollup, LF 1,759,084); Kingsport = the S28700 published
--     rate (cross-check against P13's second result set); Virginia Beach
--     stays 3.5 and Winchester 3.2 (whole-grain, unchanged from tranche 1).
-- S9: industryEmployment for the 4 multi-state MSAs still comes from WHOLE
--     '31' rows (S-part industry unused pending P13).
-- =============================================================================
