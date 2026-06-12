-- =============================================================================
-- EMPLOYER WAGE TOOL — SQL Server (T-SQL) — JSON-emitting "RUN" build
--
-- Translates queries/employer_wage_tool_snowflake.sql to T-SQL against the
-- production WID 3.0 SQL Server (read-only account). Two queries, each final
-- SELECT wrapped with FOR JSON PATH so SQL Server emits one NVARCHAR(MAX) cell
-- per file:
--
--   Q1 -> apps/wage-tool-employer/data/wages.json
--   Q2 -> apps/wage-tool-employer/data/industries.json
--
-- PREREQUISITES:
--   * Run _validate.sql once to confirm schema assumptions; record findings.
--   * This RUN.sql is then scheduled (read-only) for periodic refresh. NO
--     elevated setup step — labels and codes come live from GEOGRAPHIES on
--     every run.
--
-- LABEL RESOLUTION:
--   * LWDA code + label come from WID.dbo.GEOGRAPHIES live (AreaType='15',
--     vintage-anchored via geo_vintage CTE). area_id in the JSON is the
--     6-digit GEOGRAPHIES.Area; label is GEOGRAPHIES.AreaName verbatim
--     (NOT substring-parsed — the "(LWDA III)" suffix flows through).
--   * Statewide row likewise: area_id from GEOGRAPHIES.Area at AreaType='01';
--     label from AreaName. Front-end identifies statewide by
--     area.areatype === '01'.
--   * Prior versions used a hand-maintained dbo.LWDA_Slugs seed table for
--     slug + label; that's been removed. LWDA additions, retirements, and
--     renames flow through automatically with zero manual edits.
--
-- WID 3.0 conventions in play (see [[sqlserver_data_pipeline]]):
--   * Schema: WID.dbo.*
--   * AreaType: '01'=state, '15'=LWDA (CONFIRM via _validate.sql probe 2 —
--     some BLS variants use '06'/'07')
--   * AreaTypeVersion: anchor to MAX() per (table, AreaType) — fact/dim
--     vintages diverge.
--   * Ownership codes (verified via _validate.sql Probe 4 on WID 3.0, 2-digit):
--       '00'=Total Covered (= '10'+'20'+'30'+'50') · '10'=Federal · '20'=State ·
--       '30'=Local · '50'=Private · '80'=industry-of-function government (NOT
--       "other/unknown" — that was an earlier guess; resolved by the 2026-06-10
--       audit, see docs/client-tickets/wid-data-quality-punchlist.md Note B).
--       '80' is government employment classified by industry of function rather
--       than employer ownership (public teachers under Education NAICS 61,
--       public-hospital nurses under Health NAICS 62, etc.). It sits OUTSIDE
--       '00' Total Covered, ~343k VA rows, concentrated in NAICS 92/61/62.
--     This query uses '00' (Q2 industries.json). '80' is intentionally excluded
--     — Total Covered is the right denominator for an employer benchmark tool,
--     and including '80' would double-count government workers already counted
--     under '10'/'20'/'30'. Never combine '00' with any of ('10','20','30','50')
--     in the same filter either — same double-count risk; Total Covered IS the
--     sum.
--
-- =============================================================================
-- COLUMN ASSUMPTIONS — verify against WID 3.0 before first run
-- =============================================================================
-- Verified-against-real-data marker (fill after _validate.sql probe 1 confirms):
--   Verified: <YYYY-MM-DD>  WID variant: <VA-Azure-WID-3.x or similar>
--
-- HIGH-VARIANCE COLUMNS (rename = silent wrong numbers, NOT runtime errors):
--   * IOWAGE shape: one row per (OccCode, Area, RateType). RateType values
--     (verified via _validate.sql Probe 4 on WID 3.0):
--       '4' = Annual  (median ~$67k across VA statewide)
--       '1' = Hourly  (median ~$32 across VA statewide)
--     Percentile cols: Percentile10Wage, Percentile25Wage, MedianWage,
--     Percentile75Wage, Percentile90Wage. Plus MeanWage, EmpCount.
--     Annual vs hourly are pivoted via conditional aggregation on RateType —
--     NOT separate AnnWage10/HrWage10 cols.
--   * INDUSTRY annual rollup: PeriodType='01' AND Period='00' (numeric codes —
--     '01'=annual, '02'=quarterly; only Period value on annual rows is '00').
--   * INDUSTRY Ownership='00' is the BLS Total Covered row (sums '10' federal,
--     '20' state, '30' local, '50' private — all 2-digit). Use that OR the
--     constituents — never both, or you double-count. This query uses '00'.
--   * INDUSTRY columns (verified via _validate.sql Probe 1 on WID 3.0):
--       - employment    = QuarterAvgEmp (annual rows hold annual avg here)
--                         fallback: (Month1Emp + Month2Emp + Month3Emp) / 3.0
--       - establishments = Establishments
--       - mean_wage     = TotalWages / QuarterAvgEmp on PeriodType='01'
--                         Period='00' rows. Reproduces BLS's published
--                         AvgAnnualPay methodology exactly (annual total wages
--                         divided by annual avg employment, with NULLIF guard
--                         for suppressed/zero-employment cells).
--         NOTE: WID 3.0 spec defines AvgAnnualPay as a first-class published
--         column, but this WID install does not expose it. The derivation
--         above is the closest-to-spec workaround; raise the missing column
--         with the WID owner as a separate ticket — it's a load gap on their
--         end, not something to permanently work around in SQL.
--
-- Other columns referenced (lower-risk, expected to be standard):
--   WID.dbo.IOWAGE       : StFips, Area, AreaType, AreaTypeVersion, PeriodYear,
--                          OccCode, RateType, EmpCount, plus Percentile*Wage /
--                          MedianWage / MeanWage cols above.
--                          MISSING in this WID install: OccName (occupation
--                          label). NOT a blocker anymore: SOC-6 titles + the
--                          23 SOC major-group labels are now sourced live
--                          from WID.dbo.SOCCodes (see soc_dim / major_group_dim
--                          CTEs in Q1). data/soc-titles.json is retained as
--                          a NULL-only client-side fallback. The IOWAGE.OccName
--                          load-gap ticket against the WID owner remains
--                          open for completeness but no longer affects this
--                          tool's labels.
--   WID.dbo.INDUSTRY     : StFips, Area, AreaType, AreaTypeVersion, PeriodYear,
--                          PeriodType, Period, Ownership, IndCode,
--                          TotalWages, QuarterAvgEmp, Establishments
--                          (plus Month1/2/3Emp fallback, AvgWeeklyWage, Suppress)
--   WID.dbo.GEOGRAPHIES  : StFips, Area, AreaType, AreaTypeVersion, AreaName
--                          (sole source of LWDA + statewide codes AND labels;
--                          no local seed table)
--   WID.dbo.SOCCodes     : SOCCode CHAR(6) (unhyphenated 6-digit), SOCTitle,
--                          SOCParent, SOCCodeType (vintage). 1,447 rows on
--                          this install, SOCCodeType='19' (BLS SOC-2018).
--                          Live source for SOC-6 occupation labels and the
--                          23 SOC major-group labels (major rows: SOCCode
--                          LIKE '__0000' with non-'00' prefix).
--   WID.dbo.NAICSSectors : NAICSSector CHAR(2), SectorDesc, SectorDescLong.
--                          23 rows on this install — 20 BLS NAICS-2 sectors
--                          plus '00' Total, '10' Supersector totals, '99'
--                          Unclassified. Live source for NAICS-2 sector
--                          labels in Q2. NO vintage column. KNOWN DATA-QA
--                          ISSUES on this install: SectorDesc rows for '54'
--                          ('Professiona.l Scientific & Technical Svc') and
--                          '56' ('Admin., Support, Waste Mgmt, Remediation')
--                          have typos / abbreviations. Filed to the WID
--                          owner's data-QA backlog; NOT patched in SQL.
--                          (Aliases dim — WID.dbo.ONETCodes — carries
--                          O*NET FORMAL titles not alternate/lay titles.
--                          The true alias dim — O*NET Alternate Titles file
--                          / WID.dbo.OccupationXOccupation crosswalk — is
--                          structurally present but EMPTY on this install.
--                          Aliases stay sourced from the curated static
--                          file data/soc-aliases.json — NOT a fallback,
--                          the live source — until the true dim loads.
--                          See the commented-out aliases CTE below for the
--                          lossy-proxy ONETCodes-direct form to use only
--                          if soc-aliases.json ever becomes unavailable.)
--
-- REQUIRES: SQL Server 2017+ for STRING_AGG (Azure SQL — the prod host —
--   qualifies). FOR JSON PATH needs 2016+. Read-only; no temp tables.
--
-- JSON SHAPE NOTE: Both files have a data-keyed `areas` object inside each
--   job/sector (keys = 6-digit lwda_code for LWDAs + the statewide area code
--   for the Virginia row, both from GEOGRAPHIES.Area). FOR JSON PATH can't
--   dynamically key an object, so that nested blob is hand-built with
--   STRING_AGG and spliced via JSON_QUERY. The outer envelope (meta /
--   areas[] / jobs[] or sectors[]) uses normal FOR JSON PATH.
-- =============================================================================


-- =============================================================================
-- QUERY 1: OEWS OCCUPATION WAGES  ->  wages.json
--
-- Shape: { meta, areas[], jobs[] }
--   meta:    { source, extracted_at, latest_year }
--   areas:   [ {id, label, areatype} ]  — N LWDAs (AreaType='15') + the
--                                          statewide row (AreaType='01').
--                                          id = GEOGRAPHIES.Area code.
--   jobs:    [ {id, soc_code, label, major_group, aliases, areas} ]
--     areas: keyed object — { "<lwda_code>": {p10..p90, p10_h..p90_h,
--                                             employment, provenance}, ... }
--                            keys = the 6-digit lwda_code for LWDA rows
--                            and the statewide area code for the VA row.
--
-- Provenance is 3-state:
--   'lwda'                — native LWDA cell exists
--   'statewide_fallback'  — LWDA cell suppressed; copied from statewide
--   'statewide'           — the statewide-area row's own native cell
--
-- Top-code repair caps (mirrors UI v1):
--   annual  $239,200 when p90 NULL/0 with p75 or p50 > $100,000
--   hourly  $115.00  when p90_h NULL/0 with p75_h or p50_h > $50.00
-- =============================================================================

WITH
-- ─── VINTAGE ANCHORS ─────────────────────────────────────────────────────────
iowage_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.IOWAGE
    WHERE StFips = '51'
    GROUP BY StFips, AreaType
),
geo_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType IN ('01','15')
    GROUP BY StFips, AreaType
),
sgeo_vintage AS (
    -- SubGeographies carries 3 vintages on this install (0000/0001/0002) per
    -- validate.sql Probe 6 follow-up on 2026-06-12. MAX-pin to dodge the 3x
    -- vintage cartesian. AreaType='15' only — we're using SubGeographies for
    -- LWDA→child membership; other tiers (PDC, MSA, etc.) aren't part of the
    -- Employer Wage Tool's region model.
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.SubGeographies
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY StFips, AreaType
),

-- ─── LWDA DIMENSION — fully dynamic from GEOGRAPHIES ─────────────────────────
-- Both the LWDA code (= GEOGRAPHIES.Area) and the display label
-- (= GEOGRAPHIES.AreaName) come from the live dimension on every refresh.
-- LWDA additions, retirements, and renames flow through automatically with
-- zero hand-curated state. Prior versions of this tool used a hand-maintained
-- dbo.LWDA_Slugs seed table to control slugs + labels; that was deleted under
-- the project's dimension-derived-labels standard. The JSON area.id is the
-- 6-digit lwda_code; verbose AreaName flows through as the label. The
-- "(LWDA III)"-style suffix in AreaName is intentionally NOT parsed away.
lwda_dim AS (
    SELECT
        g.StFips, g.AreaType, g.AreaTypeVersion,
        g.Area      AS lwda_code,
        g.AreaName  AS lwda_label
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
),

-- ─── STATEWIDE AREA — same dynamic pattern, AreaType='01' ───────────────────
-- The "Virginia statewide" row in the JSON areas[] is sourced live from
-- GEOGRAPHIES at AreaType='01'. JSON area.id becomes the statewide Area code
-- (whatever WID stores there — typically a 6-digit '000000' or state-level
-- code), NOT the legacy hardcoded literal 'virginia'. Front-end identifies
-- statewide by area.areatype === '01'.
state_area AS (
    -- GEOGRAPHIES has 2 statewide rows on this install at AreaType='01' MAX
    -- vintage: Area='000000' and Area='000051' (validate.sql Probe 6a, 11
    -- 2026-06-12). Both labeled "Virginia", same lat/long, NULL AreaDesc.
    -- Probe 12 (2026-06-12) proved IOWAGE and INDUSTRY exclusively reference
    -- '000000' (231,736 OEWS rows + 50,653 QCEW rows; '000051' has zero of
    -- both). '000051' is therefore a phantom GEOGRAPHIES dup — flagged for
    -- the WID owner's data-QA backlog, NOT patched at load. Filter to
    -- '000000' explicitly so CROSS JOIN state_area downstream doesn't double
    -- every statewide row.
    SELECT
        g.Area      AS state_code,
        g.AreaName  AS state_label
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '01'
      AND g.Area = '000000'                            -- dedupe: see header comment
),

-- ─── LWDA → COUNTY/CITY MEMBERSHIP — JSON array per LWDA ────────────────────
-- Sources county + independent-city names per LWDA from WID.dbo.SubGeographies
-- (vintage-pinned via sgeo_vintage above). Used to power the Region filter's
-- county-first search UX in the front-end — a user typing "Henrico" surfaces
-- counties starting with those letters; selecting a county resolves to its
-- parent LWDA for the report scope. Mirrors the alias-aware Job Family filter
-- pattern.
--
-- VA-SPECIFIC NUANCE: BLS lumps Virginia counties AND independent cities
-- together under SubAreaType='04' in this xwalk (validate.sql Probe 6d
-- 2026-06-12 confirmed: e.g. LWDA 000455 Crater Region returns 5 counties +
-- 4 independent cities — Colonial Heights, Emporia, Hopewell, Petersburg —
-- all with sub_areatype='04'). The GEOGRAPHIES AreaType='11' tier holds
-- independent cities as a separate cut for other purposes but SubGeographies
-- doesn't reference it for LWDA membership. SubAreaType='04' alone is
-- correct and complete.
--
-- VINTAGE JOIN: GEOGRAPHIES is pinned via the SubAreaTypeVersion that the
-- SubGeographies row itself stipulates — that's the authoritative vintage
-- tuple ("this LWDA points at THIS sub-area at THIS sub-vintage"). NOT
-- re-anchored via geo_vintage at the dim level, because the dim's MAX vintage
-- for AreaType='04' may not match what SubGeographies references.
--
-- STRING_AGG cast to NVARCHAR(MAX) to dodge the 8000-char truncation;
-- alphabetical WITHIN GROUP for deterministic output.
lwda_counties AS (
    SELECT
        sg.Area AS lwda_code,
        '[' + STRING_AGG(
            CAST('"' + STRING_ESCAPE(g.AreaName, 'json') + '"' AS NVARCHAR(MAX)),
            ','
        ) WITHIN GROUP (ORDER BY g.AreaName) + ']' AS counties_json
    FROM WID.dbo.SubGeographies sg
    JOIN sgeo_vintage sgv
      ON sg.StFips = sgv.StFips AND sg.AreaType = sgv.AreaType
     AND sg.AreaTypeVersion = sgv.AreaTypeVersion
    JOIN WID.dbo.GEOGRAPHIES g
      ON g.StFips          = sg.SubStFips
     AND g.AreaType        = sg.SubAreaType
     AND g.AreaTypeVersion = sg.SubAreaTypeVersion
     AND g.Area            = sg.SubArea
    WHERE sg.StFips = '51'
      AND sg.AreaType = '15'
      AND sg.SubAreaType = '04'      -- counties + VA independent cities (BLS lumps both here)
    GROUP BY sg.Area
),

-- ─── SOC DIMENSION — live SOC-6 + major-group labels from WID.dbo.SOCCodes ──
-- Replaces the previously hardcoded 23-row major_groups VALUES CTE and the
-- soc_code-as-label placeholder.
--
-- VINTAGE PIN — DELIBERATE, NOT FLOATING. SOCCodeType is pinned to the
-- literal '19' (BLS SOC-2018), which is the SOC vintage the IOWAGE rows on
-- this install are coded under (per probe RESULTS LOG P1 + the parallel WID
-- OEWS release cadence). An earlier draft used MAX(SOCCodeType) defensively,
-- but MAX would silently re-key every title if the WID owner ever loads a
-- second vintage (e.g. SOC-2028 as '20') — fact rows are still SOC-2018-coded
-- until the OEWS load also rolls forward, so the dim/fact would slip out of
-- sync and titles would NULL out across the board. Pinning to '19' fails
-- LOUD instead: when SOC-2028 lands and IOWAGE rolls with it, this query
-- emits all-NULL labels and the smoke tests catch it. Re-pin the literal
-- AND re-verify the IOWAGE↔SOCCodes intersection at that point — do NOT
-- swap back to MAX.
--
-- SOCCode is CHAR(6) so RTRIM is safe-by-default even though the observed
-- values aren't padded today. WID stores SOC codes UNHYPHENATED (e.g.
-- '111011'); IOWAGE stores them in either form, normalized via
-- REPLACE(..., '-', '') downstream.
soc_dim AS (
    SELECT
        RTRIM(sc.SOCCode)  AS soc_code,
        sc.SOCTitle        AS soc_title
    FROM WID.dbo.SOCCodes sc
    WHERE sc.SOCCodeType = '19'   -- BLS SOC-2018; pinned per header comment, do NOT swap to MAX
),

-- ─── SOC MAJOR GROUP DIMENSION — derived from soc_dim ───────────────────────
-- BLS SOC majors are the 23 rows whose code ends in '0000' with a non-'00'
-- leading pair (e.g. '110000' Management Occupations, '550000' Military
-- Specific Occupations). Replaces the 23-row hardcoded VALUES CTE in prior
-- versions. The mg_prefix is the 2-digit SOC family used to join to any
-- SOC-6's leading 2 chars in the final SELECT.
major_group_dim AS (
    SELECT
        LEFT(soc_code, 2)  AS mg_prefix,
        soc_title          AS major_group_name
    FROM soc_dim
    WHERE RIGHT(soc_code, 4) = '0000'
      AND LEFT(soc_code, 2) <> '00'
),

-- ─── SOC MINOR GROUP DIMENSION — SOCParent-based, NOT pattern-based ─────────
-- A SOC-2018 MINOR group is defined hierarchically as any row whose SOCParent
-- is a major (parent ends in '0000'). This is the BLS-canonical definition,
-- NOT a code-pattern assumption.
--
-- WHY NOT JUST FILTER `RIGHT(SOCCode, 3) = '000'`:
--   SOC-2018 has minor groups whose codes DON'T fit the XX-X000 mold —
--   e.g. '151200' Computer Occupations, '515100' Printing Workers, '111000'
--   Top Executives (the last fits the pattern, the first two don't). A
--   structural pattern filter misses the non-classical ones, causing the
--   front-end to fall back to MAJOR group labels for those jobs (the
--   "duplicate descriptions at SOC3" bug the client reported 2026-06-12).
--   validate.sql Probe 9b/9c on 2026-06-12 confirmed: SOCParent-based
--   approach returns 97 minor groups; pattern-based returns only 95.
--   (BLS spec is 98; the 1 missing is Military 55-X000, which this WID
--   install intentionally excludes and which OEWS doesn't carry either.)
--
-- DATA ANOMALY HANDLED:
--   311100 (Home Health and Personal Care Aides...) has a self-referencing
--   SOCParent on this install — load anomaly, probably should be a broad
--   pointing at minor '311000'. The SOCCode <> SOCParent filter excludes it;
--   if/when the WID owner fixes the load it'll start matching this CTE
--   without code changes here.
minor_group_dim AS (
    SELECT
        sc.SOCCode  AS minor_code,
        sc.SOCTitle AS minor_title
    FROM WID.dbo.SOCCodes sc
    WHERE sc.SOCCodeType = '19'        -- pinned per soc_dim header; do NOT swap to MAX
      AND RIGHT(sc.SOCParent, 4) = '0000'
      AND sc.SOCCode <> sc.SOCParent
),

-- ─── SOC-6 → MINOR GROUP RESOLUTION — SOCParent walk ────────────────────────
-- For each SOC-6 row in SOCCodes, walks SOCParent up 1 or 2 hops to find the
-- minor. Two paths to cover, picked by COALESCE:
--   depth-1 (m_direct):    detail.SOCParent IS itself a minor — happens
--                          when BLS skips the broad level for some details.
--   depth-2 (m_via_broad): detail.SOCParent is a broad — walk one more hop
--                          via that broad's SOCParent (which is the minor).
-- Common case is depth-2: detail → broad → minor (e.g. 11-3121 HR Managers
-- → 11-3120 HR Managers broad → 11-3000 Operations Specialties Managers
-- minor → 11-0000 Management major). COALESCE prefers m_direct when both
-- match — both can populate when detail.SOCParent is itself a minor (the
-- broad LEFT JOIN happens to match the same row), but m_via_broad's hop
-- to broad.SOCParent then walks to the major which isn't in minor_group_dim,
-- so m_via_broad ends up null anyway. Either way COALESCE resolves.
--
-- If a SOC-6 detail can't be resolved by either path (SOCCodes missing a
-- parent row, etc.), minor_code/minor_title come through as NULL and the
-- final SELECT's emit treats them as null — front-end falls back to
-- j.major_group, same behavior as before this fix for the unmatched cases.
soc6_to_minor AS (
    SELECT
        d.SOCCode AS detail_code,
        COALESCE(m_direct.minor_code,  m_via_broad.minor_code)  AS minor_code,
        COALESCE(m_direct.minor_title, m_via_broad.minor_title) AS minor_title
    FROM WID.dbo.SOCCodes d
    LEFT JOIN minor_group_dim m_direct
        ON m_direct.minor_code = d.SOCParent
    LEFT JOIN WID.dbo.SOCCodes broad
        ON broad.SOCCode = d.SOCParent
       AND broad.SOCCodeType = '19'
    LEFT JOIN minor_group_dim m_via_broad
        ON m_via_broad.minor_code = broad.SOCParent
    WHERE d.SOCCodeType = '19'
),

-- ─── LATEST YEAR IN STATEWIDE OEWS ───────────────────────────────────────────
latest_oews_year AS (
    SELECT MAX(w.PeriodYear) AS yr
    FROM WID.dbo.IOWAGE w
    JOIN iowage_vintage iv
      ON w.StFips = iv.StFips AND w.AreaType = iv.AreaType
     AND w.AreaTypeVersion = iv.AreaTypeVersion
    WHERE w.StFips = '51' AND w.AreaType = '01'
),

-- ─── STATEWIDE OEWS (fallback source + 'virginia' area row) ──────────────────
-- IOWAGE shape: one row per (OccCode, Area, RateType). Pivot annual/hourly via
-- conditional aggregation on RateType ('4' = annual, '1' = hourly).
-- EmpCount is the same on both rate-type rows; MAX() pulls it deterministically.
state_wages AS (
    SELECT
        REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')                                                          AS soc_code,
        -- OccName column does not exist in this WID install's IOWAGE table; label
        -- defaults to soc_code in the final SELECT. Production fix: load BLS SOC
        -- occupation-name reference (separate WID load-gap ticket — parallel to
        -- the AvgAnnualPay gap flagged above).
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile10Wage AS INT) END)     AS p10,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile25Wage AS INT) END)     AS p25,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.MedianWage       AS INT) END)     AS p50,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile75Wage AS INT) END)     AS p75,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile90Wage AS INT) END)     AS p90,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile10Wage AS DECIMAL(6,2)) END) AS p10_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile25Wage AS DECIMAL(6,2)) END) AS p25_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.MedianWage       AS DECIMAL(6,2)) END) AS p50_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile75Wage AS DECIMAL(6,2)) END) AS p75_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile90Wage AS DECIMAL(6,2)) END) AS p90_h,
        MAX(CASE WHEN w.SuppressEmp = '0' THEN TRY_CAST(w.EmpCount AS INT) END)                                       AS employment
    FROM WID.dbo.IOWAGE w
    JOIN iowage_vintage iv
      ON w.StFips = iv.StFips AND w.AreaType = iv.AreaType
     AND w.AreaTypeVersion = iv.AreaTypeVersion
    CROSS JOIN latest_oews_year ly
    WHERE w.StFips = '51'
      AND w.AreaType = '01'
      AND w.PeriodYear = ly.yr
      AND w.RateType IN ('1','4')
      AND w.IndCodeType = '10' AND w.IndCode = '000000'   -- all-industries cross-industry row
      AND LEN(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')) = 6   -- SOC-6 (WID stores 6 digits; hyphen-tolerant via REPLACE)         -- SOC-6 only (XX-XXXX)
      AND RIGHT(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), 1) <> '0'   -- SOC-6 detail only (BLS aggregates end in 0)              -- exclude major group totals
    GROUP BY REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')
),

-- ─── LWDA-LEVEL OEWS ─────────────────────────────────────────────────────────
-- Joins on lwda_dim (GEOGRAPHIES only — no seed table). area_id is the
-- 6-digit lwda_code sourced live from GEOGRAPHIES.Area. If IOWAGE has no
-- LWDA-level rows in this WID install, this CTE returns 0 rows and EVERY
-- cell falls back to statewide — provenance flips to 'statewide_fallback'.
lwda_wages AS (
    SELECT
        REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')                                                          AS soc_code,
        ld.lwda_code                                                                     AS area_id,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile10Wage AS INT) END)     AS p10,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile25Wage AS INT) END)     AS p25,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.MedianWage       AS INT) END)     AS p50,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile75Wage AS INT) END)     AS p75,
        MAX(CASE WHEN w.RateType = '4' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile90Wage AS INT) END)     AS p90,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile10Wage AS DECIMAL(6,2)) END) AS p10_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile25Wage AS DECIMAL(6,2)) END) AS p25_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.MedianWage       AS DECIMAL(6,2)) END) AS p50_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile75Wage AS DECIMAL(6,2)) END) AS p75_h,
        MAX(CASE WHEN w.RateType = '1' AND w.SuppressWage = '0' THEN TRY_CAST(w.Percentile90Wage AS DECIMAL(6,2)) END) AS p90_h,
        MAX(CASE WHEN w.SuppressEmp = '0' THEN TRY_CAST(w.EmpCount AS INT) END)                                       AS employment
    FROM WID.dbo.IOWAGE w
    JOIN iowage_vintage iv
      ON w.StFips = iv.StFips AND w.AreaType = iv.AreaType
     AND w.AreaTypeVersion = iv.AreaTypeVersion
    JOIN lwda_dim ld                                          -- 3-col composite (StFips+AreaType+Area).
      ON w.StFips = ld.StFips AND w.AreaType = ld.AreaType    -- AreaTypeVersion is intentionally NOT in the
     AND w.Area = ld.lwda_code                                -- join condition: fact vs dim vintages are
                                                              -- independent. iowage_vintage pins IOWAGE to its
                                                              -- MAX, geo_vintage pins GEOGRAPHIES to its MAX;
                                                              -- they may differ.
    CROSS JOIN latest_oews_year ly
    WHERE w.StFips = '51'
      AND w.AreaType = '15'                        -- LWDA (confirm via validate.sql)
      AND w.PeriodYear = ly.yr
      AND w.RateType IN ('1','4')
      AND w.IndCodeType = '10' AND w.IndCode = '000000'   -- all-industries cross-industry row
      AND LEN(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')) = 6   -- SOC-6 (WID stores 6 digits; hyphen-tolerant via REPLACE)
      AND RIGHT(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), 1) <> '0'   -- SOC-6 detail only (BLS aggregates end in 0)
    GROUP BY REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), ld.lwda_code
),

-- ─── TOP-CODE REPAIR ─────────────────────────────────────────────────────────
state_wages_repaired AS (
    SELECT
        soc_code, employment,
        p10, p25, p50,
        CASE WHEN (p75 IS NULL OR p75 = 0) AND p50 > 100000 THEN 239200 ELSE p75 END AS p75,
        CASE WHEN (p90 IS NULL OR p90 = 0)
                  AND (ISNULL(p75, 0) > 100000 OR p50 > 100000) THEN 239200
             ELSE p90 END                                                            AS p90,
        p10_h, p25_h, p50_h,
        CASE WHEN (p75_h IS NULL OR p75_h = 0) AND p50_h > 50.00 THEN 115.00 ELSE p75_h END AS p75_h,
        CASE WHEN (p90_h IS NULL OR p90_h = 0)
                  AND (ISNULL(p75_h, 0) > 50.00 OR p50_h > 50.00) THEN 115.00
             ELSE p90_h END                                                          AS p90_h
    FROM state_wages
),
lwda_wages_repaired AS (
    SELECT
        soc_code, area_id, employment,
        p10, p25, p50,
        CASE WHEN (p75 IS NULL OR p75 = 0) AND p50 > 100000 THEN 239200 ELSE p75 END AS p75,
        CASE WHEN (p90 IS NULL OR p90 = 0)
                  AND (ISNULL(p75, 0) > 100000 OR p50 > 100000) THEN 239200
             ELSE p90 END                                                            AS p90,
        p10_h, p25_h, p50_h,
        CASE WHEN (p75_h IS NULL OR p75_h = 0) AND p50_h > 50.00 THEN 115.00 ELSE p75_h END AS p75_h,
        CASE WHEN (p90_h IS NULL OR p90_h = 0)
                  AND (ISNULL(p75_h, 0) > 50.00 OR p50_h > 50.00) THEN 115.00
             ELSE p90_h END                                                          AS p90_h
    FROM lwda_wages
),

-- ─── O*NET ALIASES — LOSSY PROXY, COMMENTED FOR v1 ──────────────────────────
-- Frontend always reads the `aliases` field on each job. v1 emits "aliases": []
-- from SQL. The LIVE alias source on this install is the static client-side
-- file data/soc-aliases.json (see Part 4 of docs/handover/employer-wage-tool.md).
-- That file is NOT a fallback — it carries curated O*NET ALTERNATE titles
-- (e.g. SOC 29-1141 → ["RN", "Nurse Practitioner", "Cardiac Nurse"]), which
-- is the right data shape for the family-dropdown alias-aware search.
--
-- WHY NOT WIRE FROM WID.dbo.ONETCodes:
--   WID.dbo.ONETCodes (P2 in queries/dimension_resolution_probe.sql) carries
--   O*NET FORMAL occupation titles, not alternate/lay titles. The true
--   alias dimension is the O*NET Alternate Titles file, which the BLS WID
--   3.0 spec exposes via WID.dbo.OccupationXOccupation as a SOC↔ONET↔alt
--   crosswalk. On this install OccupationXOccupation exists structurally but
--   has 0 rows (P3 RESULTS LOG). Until the WID owner loads it, the curated
--   static file is the best-available alias data and stays live.
--
-- THE BLOCK BELOW is the LOSSY PROXY available if data/soc-aliases.json ever
-- becomes unavailable AND OccupationXOccupation is still empty. It groups
-- ONETCodes by SOC-6 prefix and treats the formal ONETTitles as approximate
-- aliases. It will: (a) duplicate the SOCTitle on many SOC-6 detail rows,
-- (b) miss the 2-5 curated colloquial labels per occupation that the static
-- file carries. DO NOT live-wire without re-checking those tradeoffs. Load-gap
-- ticket against the WID owner: "O*NET Alternate Titles dim / OccupationXOccupation
-- crosswalk not loaded on this install" (see RESULTS LOG P3 for the spec).
--
-- onet_aliases AS (
--     -- Vintage is pinned to the literal ONETCodeType='12' (single vintage
--     -- on this install per probe RESULTS LOG P2). MAX is deliberately NOT
--     -- used here — same reasoning as soc_dim's literal pin: if a second
--     -- vintage ever loads, MAX would silently re-key against it while the
--     -- ONETCode↔SOC linkage may not have rolled forward in parallel. Pin
--     -- to '12'; fail loud if that vintage retires.
--     --
--     -- ONETCode is CHAR(8) unhyphenated, no dot (e.g. '11101100',
--     -- '11101103'); SOC-6 prefix = LEFT(ONETCode, 6). Inner DISTINCT
--     -- dedupes the many-to-one fanout (one SOC-6 has 1..N ONET detail
--     -- codes with overlapping formal titles).
--     SELECT
--         soc_code,
--         '[' + STRING_AGG('"' + STRING_ESCAPE(alt, 'json') + '"', ',')
--               WITHIN GROUP (ORDER BY alt) + ']' AS aliases_json
--     FROM (
--         SELECT DISTINCT
--             LEFT(o.ONETCode, 6) AS soc_code,
--             o.ONETTitle          AS alt
--         FROM WID.dbo.ONETCodes o
--         WHERE o.ONETCodeType = '12'      -- pinned per header; do NOT swap to MAX
--           AND o.ONETTitle IS NOT NULL
--           AND o.ONETTitle <> ''
--     ) deduped
--     GROUP BY soc_code
-- ),

-- ─── RESOLVE EVERY (soc_code, area_id) CELL ──────────────────────────────────
all_cells AS (
    -- Native LWDA cells
    SELECT
        lw.soc_code, lw.area_id,
        lw.p10, lw.p25, lw.p50, lw.p75, lw.p90,
        lw.p10_h, lw.p25_h, lw.p50_h, lw.p75_h, lw.p90_h,
        lw.employment,
        'lwda'      AS provenance,
        lw.area_id  AS area_sort_key
    FROM lwda_wages_repaired lw
    WHERE lw.p50 IS NOT NULL

    UNION ALL

    -- Statewide fallback for missing LWDA cells
    SELECT
        sw.soc_code, ld.lwda_code AS area_id,
        sw.p10, sw.p25, sw.p50, sw.p75, sw.p90,
        sw.p10_h, sw.p25_h, sw.p50_h, sw.p75_h, sw.p90_h,
        sw.employment,
        'statewide_fallback'    AS provenance,
        ld.lwda_code            AS area_sort_key
    FROM state_wages_repaired sw
    CROSS JOIN lwda_dim ld
    WHERE NOT EXISTS (
        SELECT 1 FROM lwda_wages_repaired lw2
        WHERE lw2.soc_code = sw.soc_code
          AND lw2.area_id  = ld.lwda_code
          AND lw2.p50 IS NOT NULL
    )

    UNION ALL

    -- The statewide row itself (always native). area_id = the statewide
    -- area code sourced live from GEOGRAPHIES at AreaType='01' — NOT the
    -- legacy hardcoded 'virginia' literal. Front-end identifies this row
    -- by areatype === '01' in the areas[] dropdown.
    SELECT
        sw.soc_code, sa.state_code     AS area_id,
        sw.p10, sw.p25, sw.p50, sw.p75, sw.p90,
        sw.p10_h, sw.p25_h, sw.p50_h, sw.p75_h, sw.p90_h,
        sw.employment,
        'statewide'                    AS provenance,
        'zzz-' + sa.state_code         AS area_sort_key
    FROM state_wages_repaired sw
    CROSS JOIN state_area sa
),

-- ─── HAND-BUILD job.areas KEYED OBJECT ───────────────────────────────────────
-- FOR JSON PATH cannot dynamically key an object, so we build the {area_id: {...}}
-- blob as a JSON string per soc_code and splice it in via JSON_QUERY.
job_areas_blob AS (
    SELECT
        ac.soc_code,
        '{' + STRING_AGG(
            CAST(
                '"' + ac.area_id + '":{'
                    + '"p10":'         + ISNULL(CONVERT(VARCHAR(20), ac.p10),         'null') + ','
                    + '"p25":'         + ISNULL(CONVERT(VARCHAR(20), ac.p25),         'null') + ','
                    + '"p50":'         + ISNULL(CONVERT(VARCHAR(20), ac.p50),         'null') + ','
                    + '"p75":'         + ISNULL(CONVERT(VARCHAR(20), ac.p75),         'null') + ','
                    + '"p90":'         + ISNULL(CONVERT(VARCHAR(20), ac.p90),         'null') + ','
                    + '"p10_h":'       + ISNULL(CONVERT(VARCHAR(20), ac.p10_h),       'null') + ','
                    + '"p25_h":'       + ISNULL(CONVERT(VARCHAR(20), ac.p25_h),       'null') + ','
                    + '"p50_h":'       + ISNULL(CONVERT(VARCHAR(20), ac.p50_h),       'null') + ','
                    + '"p75_h":'       + ISNULL(CONVERT(VARCHAR(20), ac.p75_h),       'null') + ','
                    + '"p90_h":'       + ISNULL(CONVERT(VARCHAR(20), ac.p90_h),       'null') + ','
                    + '"employment":'  + ISNULL(CONVERT(VARCHAR(20), ac.employment),  'null') + ','
                    + '"provenance":"' + ac.provenance + '"'
                + '}'
                AS NVARCHAR(MAX)                  -- prevents 8000-char STRING_AGG truncation
            ),
            ','
        ) WITHIN GROUP (ORDER BY ac.area_sort_key) + '}' AS areas_json
    FROM all_cells ac
    GROUP BY ac.soc_code
)

-- ─── FINAL OUTPUT — wages.json ───────────────────────────────────────────────
SELECT
    JSON_QUERY((
        SELECT
            'WID.dbo.IOWAGE (T-SQL refresh)'                  AS source,
            CONVERT(VARCHAR(33), SYSUTCDATETIME(), 126) + 'Z' AS extracted_at,
            TRY_CAST((SELECT yr FROM latest_oews_year) AS INT) AS latest_year
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS meta,
    JSON_QUERY((
        SELECT id, label, areatype, JSON_QUERY(counties) AS counties
        FROM (
            SELECT ld.lwda_code AS id,
                   ld.lwda_label AS label,
                   '15' AS areatype,
                   ld.lwda_code AS sortk,
                   ISNULL(lc.counties_json, '[]') AS counties
            FROM lwda_dim ld
            LEFT JOIN lwda_counties lc ON lc.lwda_code = ld.lwda_code
            UNION ALL
            -- Statewide row gets counties:[] — the Region filter's county-first
            -- search shouldn't surface "Virginia" when a user types a county
            -- name (statewide is its own deliberate scope, not a county hit).
            SELECT sa.state_code, sa.state_label, '01' AS areatype,
                   'zzz-' + sa.state_code AS sortk, '[]' AS counties
            FROM state_area sa
        ) src
        ORDER BY src.sortk
        FOR JSON PATH
    )) AS areas,
    JSON_QUERY((
        SELECT
            STUFF(sw.soc_code, 3, 0, '-')                                       AS id,
            STUFF(sw.soc_code, 3, 0, '-')                                       AS soc_code,
            COALESCE(sd.soc_title, STUFF(sw.soc_code, 3, 0, '-'))               AS label,
            ISNULL(mgd.major_group_name, 'Other')                               AS major_group,
            -- minor_code/minor_group resolved via SOCParent walk (see
            -- soc6_to_minor CTE). minor_code is hyphenated to match the
            -- front-end's existing SOC code display convention; NULL when
            -- the walk fails (front-end falls back to major_group on null).
            CASE WHEN s2m.minor_code IS NOT NULL
                 THEN STUFF(s2m.minor_code, 3, 0, '-') END                      AS minor_code,
            s2m.minor_title                                                     AS minor_group,
            JSON_QUERY('[]')                                                    AS aliases,
            -- aliases stays [] from SQL by design — data/soc-aliases.json is
            -- the LIVE alias source (see header note + commented onet_aliases
            -- block above). If/when the OccupationXOccupation crosswalk is
            -- loaded AND the onet_aliases block is rewritten against it (not
            -- the current ONETCodes-direct lossy proxy), swap the line above
            -- for:  JSON_QUERY(ISNULL(oa.aliases_json, '[]')) AS aliases,
            JSON_QUERY(jb.areas_json)                                           AS areas
        FROM state_wages_repaired sw
        JOIN job_areas_blob jb ON jb.soc_code = sw.soc_code
        LEFT JOIN soc_dim sd ON sd.soc_code = sw.soc_code
        LEFT JOIN major_group_dim mgd ON mgd.mg_prefix = LEFT(sw.soc_code, 2)
        LEFT JOIN soc6_to_minor s2m ON s2m.detail_code = sw.soc_code
        -- LEFT JOIN onet_aliases oa ON oa.soc_code = sw.soc_code
        ORDER BY sw.soc_code
        FOR JSON PATH
    )) AS jobs
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO


-- =============================================================================
-- QUERY 2: QCEW INDUSTRY SUMMARIES  ->  industries.json
--
-- Shape: { meta, areas[], sectors[] }
--   meta:    { source, extracted_at, latest_year }
--   areas:   [ {id, label, areatype} ]  — same N LWDAs + statewide.
--                                          id = GEOGRAPHIES.Area code.
--   sectors: [ {naics, label, areas} ]
--     areas: keyed object — { "<lwda_code>": {mean_wage, employment,
--                                             establishments}, ... }
--                            keys = the 6-digit lwda_code for LWDA rows
--                            and the statewide area code for the VA row.
--
-- Aggregation choice: filter to Ownership='00' (BLS QCEW Total Covered row —
-- federal+state+local+private already summed). One row per (NAICS, area, year),
-- so TotalWages / QuarterAvgEmp / Establishments are taken directly — no
-- weighting. This keeps every NAICS sector populated, including '92' Public
-- Administration. mean_wage = TotalWages / QuarterAvgEmp (BLS AvgAnnualPay
-- methodology); see file header for the WID load-gap note.
--
-- Alternative: filter to Ownership IN ('10','20','30','50') (the constituents)
-- and compute mean_wage as employment-weighted:
--     SUM(TotalWages) / NULLIF(SUM(QuarterAvgEmp), 0)
-- Use if you need per-ownership splits later or don't trust the Total row.
-- DO NOT include '00' AND the constituents simultaneously — double-counts.
-- =============================================================================

WITH
-- ─── VINTAGE ANCHORS ─────────────────────────────────────────────────────────
ind_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.INDUSTRY
    WHERE StFips = '51' AND AreaType IN ('01', '15')
    GROUP BY StFips, AreaType
),
geo_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType IN ('01','15')
    GROUP BY StFips, AreaType
),

-- ─── LWDA DIMENSION — fully dynamic from GEOGRAPHIES ─────────────────────────
-- See Q1 lwda_dim header. Same pattern, redefined here because Q1 and Q2 are
-- separate batches (GO separator) and CTEs don't carry across. No seed table.
lwda_dim AS (
    SELECT
        g.StFips, g.AreaType, g.AreaTypeVersion,
        g.Area      AS lwda_code,
        g.AreaName  AS lwda_label
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
),

-- ─── STATEWIDE AREA — same dynamic pattern, AreaType='01' ───────────────────
-- See Q1 state_area header. Same pattern, redefined here for the Q2 batch.
state_area AS (
    -- GEOGRAPHIES has 2 statewide rows on this install at AreaType='01' MAX
    -- vintage: Area='000000' and Area='000051' (validate.sql Probe 6a, 11
    -- 2026-06-12). Both labeled "Virginia", same lat/long, NULL AreaDesc.
    -- Probe 12 (2026-06-12) proved IOWAGE and INDUSTRY exclusively reference
    -- '000000' (231,736 OEWS rows + 50,653 QCEW rows; '000051' has zero of
    -- both). '000051' is therefore a phantom GEOGRAPHIES dup — flagged for
    -- the WID owner's data-QA backlog, NOT patched at load. Filter to
    -- '000000' explicitly so CROSS JOIN state_area downstream doesn't double
    -- every statewide row.
    SELECT
        g.Area      AS state_code,
        g.AreaName  AS state_label
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '01'
      AND g.Area = '000000'                            -- dedupe: see header comment
),

-- ─── LATEST ANNUAL YEAR IN INDUSTRY (statewide) ──────────────────────────────
latest_ind_year AS (
    SELECT MAX(i.PeriodYear) AS yr
    FROM WID.dbo.INDUSTRY i
    JOIN ind_vintage iv
      ON i.StFips = iv.StFips AND i.AreaType = iv.AreaType
     AND i.AreaTypeVersion = iv.AreaTypeVersion
    WHERE i.StFips = '51' AND i.AreaType = '01'
      AND i.PeriodType = '01' AND i.Period = '00'    -- annual full-year aggregate
),

-- ─── NAICS-2 SECTOR LOOKUP (QCEW supersector range encoding) ────────────────
-- BLS QCEW publishes three NAICS supersectors as combined 2-digit RANGES,
-- not as single 2-digit codes:
--   '31-33' Manufacturing  (covers NAICS 31, 32, 33)
--   '44-45' Retail Trade  (covers NAICS 44, 45)
--   '48-49' Transportation & Warehousing  (covers NAICS 48, 49)
-- WID.dbo.INDUSTRY stores IndCode literally as the hyphenated range string;
-- WID.dbo.NAICSSectors stores the sector under its LEADING 2-digit form ('31'
-- represents 31-33, etc.). This CTE bridges the two: wid_code = the IndCode
-- form (used in the IndCode JOIN below); naics_code = the leading 2-digit
-- form (used to look up the live label from WID.dbo.NAICSSectors AND emitted
-- into the JSON so the UI's sector keys stay consistent with the skeleton).
-- The sector LABEL is now sourced live from NAICSSectors via naics_dim below
-- — prior versions inlined a 3rd VALUES column (sector_name) which is gone.
naics_sectors AS (
    SELECT * FROM (VALUES
        ('11', '11'),
        ('21', '21'),
        ('22', '22'),
        ('23', '23'),
        ('31', '31-33'),
        ('42', '42'),
        ('44', '44-45'),
        ('48', '48-49'),
        ('51', '51'),
        ('52', '52'),
        ('53', '53'),
        ('54', '54'),
        ('55', '55'),
        ('56', '56'),
        ('61', '61'),
        ('62', '62'),
        ('71', '71'),
        ('72', '72'),
        ('81', '81'),
        ('92', '92')
    ) AS t(naics_code, wid_code)
),

-- ─── NAICS DIMENSION — live sector labels from WID.dbo.NAICSSectors ─────────
-- Per the project dimension-derived-labels standard, sector titles come live
-- from WID.dbo.NAICSSectors. This dim has no vintage column — it's a flat
-- 23-row reference dim ('00' Total + '10' Supersector totals + 20 BLS NAICS-2
-- sectors + '99' Unclassified). The 20 NAICS-2 codes match the naics_sectors
-- CTE one-to-one on naics_code; the SectorDesc column carries the BLS-published
-- range annotation directly ('Manufacturing (31-33)', 'Retail Trade (44 & 45)',
-- 'Transportation and Warehousing (48 & 49)').
--
-- KNOWN DATA-QA ISSUES on this WID install (probe RESULTS LOG P4):
--   '54' SectorDesc = 'Professiona.l Scientific & Technical Svc'   ← typo
--   '56' SectorDesc = 'Admin., Support, Waste Mgmt, Remediation'   ← abbreviated
-- These are surfaced verbatim — file the typos on the WID owner's data-QA
-- backlog (separate ticket). Do NOT patch in SQL or hand-curate over them.
naics_dim AS (
    SELECT
        RTRIM(ns.NAICSSector) AS naics_code,
        ns.SectorDesc          AS sector_label
    FROM WID.dbo.NAICSSectors ns
),

-- ─── STATEWIDE QCEW (BLS Total Covered row direct, no rollup) ───────────────
-- Ownership='00' = one row per (NAICS, area). mean_wage uses the BLS AvgAnnualPay
-- formula: TotalWages / QuarterAvgEmp on the PeriodType='01' Period='00' row.
-- To split by ownership instead, flip filter to IN ('10','20','30','50') and
-- use SUM(TotalWages) / NULLIF(SUM(QuarterAvgEmp), 0) per (NAICS, area).
state_qcew AS (
    SELECT
        ns.naics_code                                                          AS naics_code,
        TRY_CAST(i.TotalWages
                 / NULLIF(COALESCE(i.QuarterAvgEmp,
                                   (i.Month1Emp + i.Month2Emp + i.Month3Emp) / 3.0), 0) AS INT) AS mean_wage,
        TRY_CAST(COALESCE(i.QuarterAvgEmp,
                          (i.Month1Emp + i.Month2Emp + i.Month3Emp) / 3.0) AS INT) AS employment,
        TRY_CAST(i.Establishments AS INT)                                      AS establishments
    FROM WID.dbo.INDUSTRY i
    JOIN ind_vintage iv
      ON i.StFips = iv.StFips AND i.AreaType = iv.AreaType
     AND i.AreaTypeVersion = iv.AreaTypeVersion
    JOIN naics_sectors ns ON ns.wid_code = LTRIM(RTRIM(i.IndCode))   -- matches WID's hyphenated supersector ranges
    CROSS JOIN latest_ind_year ly
    WHERE i.StFips = '51'
      AND i.AreaType = '01'
      AND i.PeriodYear = ly.yr
      AND i.PeriodType = '01' AND i.Period = '00'
      AND i.Ownership = '00'
      -- Suppress filter intentionally OMITTED. INDUSTRY.Suppress='1' covers ~66%
      -- of VA annual rows (per validate.sql diagnostic) — too broad to be BLS
      -- confidentiality. Values on flagged rows are populated and reconcile to
      -- statewide totals at 99.96% — likely flags imputation/quality, not
      -- non-publishability. Revisit if WID load semantics are documented.
),

-- ─── PER-LWDA QCEW (Ownership='00' = BLS Total Covered row) ────────────────
lwda_qcew AS (
    SELECT
        ld.lwda_code                                                           AS area_id,
        ns.naics_code                                                          AS naics_code,
        TRY_CAST(i.TotalWages
                 / NULLIF(COALESCE(i.QuarterAvgEmp,
                                   (i.Month1Emp + i.Month2Emp + i.Month3Emp) / 3.0), 0) AS INT) AS mean_wage,
        TRY_CAST(COALESCE(i.QuarterAvgEmp,
                          (i.Month1Emp + i.Month2Emp + i.Month3Emp) / 3.0) AS INT) AS employment,
        TRY_CAST(i.Establishments AS INT)                                      AS establishments
    FROM WID.dbo.INDUSTRY i
    JOIN ind_vintage iv
      ON i.StFips = iv.StFips AND i.AreaType = iv.AreaType
     AND i.AreaTypeVersion = iv.AreaTypeVersion
    JOIN lwda_dim ld                                          -- 3-col composite (StFips+AreaType+Area).
      ON i.StFips = ld.StFips AND i.AreaType = ld.AreaType    -- AreaTypeVersion is intentionally NOT in the
     AND i.Area = ld.lwda_code                                -- join condition: fact vs dim vintages are
                                                              -- independent. ind_vintage pins INDUSTRY to its
                                                              -- MAX, geo_vintage pins GEOGRAPHIES to its MAX;
                                                              -- they may differ.
    JOIN naics_sectors ns ON ns.wid_code = LTRIM(RTRIM(i.IndCode))   -- matches WID's hyphenated supersector ranges
    CROSS JOIN latest_ind_year ly
    WHERE i.StFips = '51'
      AND i.AreaType = '15'
      AND i.PeriodYear = ly.yr
      AND i.PeriodType = '01' AND i.Period = '00'
      AND i.Ownership = '00'
      -- Suppress filter intentionally OMITTED. INDUSTRY.Suppress='1' covers ~66%
      -- of VA annual rows (per validate.sql diagnostic) — too broad to be BLS
      -- confidentiality. Values on flagged rows are populated and reconcile to
      -- statewide totals at 99.96% — likely flags imputation/quality, not
      -- non-publishability. Revisit if WID load semantics are documented.
),

-- ─── COMBINE ALL CELLS ───────────────────────────────────────────────────────
all_industry_cells AS (
    SELECT area_id, naics_code, mean_wage, employment, establishments,
           area_id AS area_sort_key
    FROM lwda_qcew

    UNION ALL

    -- Statewide row. area_id = the statewide area code sourced live from
    -- GEOGRAPHIES at AreaType='01' (NOT the legacy hardcoded 'virginia').
    SELECT sa.state_code     AS area_id, naics_code, mean_wage, employment, establishments,
           'zzz-' + sa.state_code AS area_sort_key
    FROM state_qcew
    CROSS JOIN state_area sa
),

-- ─── HAND-BUILD sector.areas KEYED OBJECT ────────────────────────────────────
sector_areas_blob AS (
    SELECT
        aic.naics_code,
        '{' + STRING_AGG(
            CAST(
                '"' + aic.area_id + '":{'
                    + '"mean_wage":'      + ISNULL(CONVERT(VARCHAR(20), aic.mean_wage),      'null') + ','
                    + '"employment":'     + ISNULL(CONVERT(VARCHAR(20), aic.employment),     'null') + ','
                    + '"establishments":' + ISNULL(CONVERT(VARCHAR(20), aic.establishments), 'null')
                + '}'
                AS NVARCHAR(MAX)                  -- prevents 8000-char STRING_AGG truncation
            ),
            ','
        ) WITHIN GROUP (ORDER BY aic.area_sort_key) + '}' AS areas_json
    FROM all_industry_cells aic
    GROUP BY aic.naics_code
)

-- ─── FINAL OUTPUT — industries.json ──────────────────────────────────────────
SELECT
    JSON_QUERY((
        SELECT
            'WID.dbo.INDUSTRY (QCEW, T-SQL refresh)'          AS source,
            CONVERT(VARCHAR(33), SYSUTCDATETIME(), 126) + 'Z' AS extracted_at,
            TRY_CAST((SELECT yr FROM latest_ind_year) AS INT)  AS latest_year
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS meta,
    JSON_QUERY((
        SELECT id, label, areatype
        FROM (
            SELECT ld.lwda_code AS id, ld.lwda_label AS label, '15' AS areatype, ld.lwda_code AS sortk
            FROM lwda_dim ld
            UNION ALL
            SELECT sa.state_code, sa.state_label, '01' AS areatype, 'zzz-' + sa.state_code AS sortk
            FROM state_area sa
        ) src
        ORDER BY src.sortk
        FOR JSON PATH
    )) AS areas,
    JSON_QUERY((
        SELECT
            ns.naics_code                                AS naics,
            COALESCE(nd.sector_label, ns.naics_code)     AS label,
            JSON_QUERY(sab.areas_json)                   AS areas
        FROM naics_sectors ns
        JOIN sector_areas_blob sab ON sab.naics_code = ns.naics_code
        LEFT JOIN naics_dim nd ON nd.naics_code = ns.naics_code
        ORDER BY ns.naics_code
        FOR JSON PATH
    )) AS sectors
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO
