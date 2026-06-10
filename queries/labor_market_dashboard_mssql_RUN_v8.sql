-- =============================================================================
-- LABOR MARKET SNAPSHOT DASHBOARD — SQL Server (T-SQL) — JSON-emitting "RUN" build (v8)
--
-- Same three queries as queries/labor_market_dashboard_mssql.sql (v3, tabular),
-- but each final SELECT is wrapped with FOR JSON PATH so SQL Server emits the
-- exact JSON the Highcharts front-end (apps/dashboard-front-page-original) reads.
-- Each query returns ONE NVARCHAR(MAX) cell = one .json file:
--
--   Q1 -> employment_by_locality.json
--   Q2 -> unemployment_trend.json
--   Q3 -> jobs_by_industry.json
--
-- REGION SCHEME: 14 Virginia LWDAs (AreaType '15'), NOT the legacy 5 macro
-- regions. Every county carries its lwda_code as `region`; the bar/line cross
-- filter and REGION_LABELS key off lwda_code.
--
-- SHAPE NOTES (front-end consumes arrays, not data-keyed objects):
--   * trend `counties` and jobs `regions` are ARRAYS of objects.
--   * `months` and each trend series/`data` are ARRAYS OF SCALARS — FOR JSON
--     PATH cannot emit scalar arrays, so they are built with STRING_AGG and
--     spliced in via JSON_QUERY. Arrays are aligned to a 36-row month dimension
--     with LEFT JOINs so source gaps (e.g. Oct 2025) become JSON `null` at the
--     correct index (front-end uses connectNulls:false).
--
-- KPI semantics: `kpi.*.value` = UNEMPLOYMENT rate, `delta_pts` = unemployment-
--   rate change vs prior period (the -original app renders these directly). The
--   v3 tabular query computed an EMPLOYMENT-rate delta (opposite sign); here the
--   delta is recomputed from unemployment values.
--
-- ASSUMPTION (flag): hc_key = 'us-va-' + RIGHT(Area, 3). This assumes the last
--   three chars of LABORFORCE.Area are the 3-digit VA county/independent-city
--   FIPS (works for '000001', '51001', or '001' encodings). Verify against one
--   known row (Alexandria -> us-va-510) before trusting the choropleth join.
--
-- REQUIRES: SQL Server 2017+ for STRING_AGG (Azure SQL — the production host —
--   qualifies). FOR JSON PATH needs 2016+. Read-only; no temp tables.
-- =============================================================================


-- =============================================================================
-- QUERY 1: EMPLOYMENT RATE BY LOCALITY  ->  employment_by_locality.json
-- =============================================================================
WITH
lf_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.LABORFORCE
    GROUP BY StFips, AreaType
),
g_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    GROUP BY StFips, AreaType
),
sg_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.SUBGEOGRAPHIES
    GROUP BY StFips, AreaType
),
region_mapping AS (
    -- lwda_short_name is now GEOGRAPHIES.AreaName verbatim (no substring-parse).
    -- Per the project dimension-derived-labels standard, dim fields cannot
    -- be substring-parsed for display. The JSON field name `lwda_short_name`
    -- is preserved for front-end compatibility, but the value is the verbose
    -- AreaName (e.g. 'Greater Roanoke Region (LWDA III)'). Front-end UI
    -- shortening is a separate concern and lives in the front end. Load gap
    -- against the WID owner: "GEOGRAPHIES has no ShortName / Alias column for
    -- LWDA rows" (probe RESULTS LOG P6). The verbose emission is the
    -- standard-compliant interim until WID adds a short-name column.
    SELECT
        sg.SubArea          AS Area,
        sg.SubAreaType      AS AreaType,
        sg.Area             AS lwda_code,
        g.AreaName          AS lwda_name,
        g.AreaName          AS lwda_short_name
    FROM WID.dbo.SUBGEOGRAPHIES sg
    JOIN sg_vintage sgv
      ON sg.StFips = sgv.StFips AND sg.AreaType = sgv.AreaType
     AND sg.AreaTypeVersion = sgv.AreaTypeVersion
    JOIN WID.dbo.GEOGRAPHIES g
      ON g.StFips = sg.StFips AND g.AreaType = sg.AreaType AND g.Area = sg.Area
    JOIN g_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    WHERE sg.StFips = '51' AND sg.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
),
latest_period AS (
    SELECT MAX(CONCAT(lf.PeriodYear, '-', lf.Period)) AS max_ym
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_vintage lfv
      ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
     AND lf.AreaTypeVersion = lfv.AreaTypeVersion
    WHERE lf.StFips = '51' AND lf.AreaType = '04'
      AND lf.Adjusted = '0' AND lf.PeriodType = '03'
      AND lf.UnemployedRate IS NOT NULL
),
current_month AS (
    SELECT SUBSTRING(max_ym, 1, 4) AS yr, SUBSTRING(max_ym, 6, 2) AS mo FROM latest_period
),
prior_month AS (
    SELECT
        CASE WHEN mo = '01' THEN CAST(CAST(yr AS INT) - 1 AS VARCHAR(4)) ELSE yr END AS yr,
        CASE WHEN mo = '01' THEN '12' ELSE RIGHT('0' + CAST(CAST(mo AS INT) - 1 AS VARCHAR(2)), 2) END AS mo
    FROM current_month
),
county_data AS (
    SELECT
        lf.Area, g.AreaName, lf.AreaType,
        lf.Employed, lf.LaborForce AS LF,
        lf.UnemployedRate,
        ROUND(100.0 - lf.UnemployedRate, 1) AS employment_rate,
        rm.lwda_code, rm.lwda_name, rm.lwda_short_name
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_vintage lfv
      ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
     AND lf.AreaTypeVersion = lfv.AreaTypeVersion
    JOIN WID.dbo.GEOGRAPHIES g
      ON g.StFips = lf.StFips AND g.AreaType = lf.AreaType AND g.Area = lf.Area
    JOIN g_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    LEFT JOIN region_mapping rm
      ON lf.Area = rm.Area AND lf.AreaType = rm.AreaType
    CROSS JOIN current_month cm
    WHERE lf.StFips = '51' AND lf.AreaType = '04'
      AND lf.Adjusted = '0' AND lf.PeriodType = '03'
      AND lf.PeriodYear = cm.yr AND lf.Period = cm.mo
),
va_current AS (
    SELECT lf.UnemployedRate
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_vintage lfv
      ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
     AND lf.AreaTypeVersion = lfv.AreaTypeVersion
    CROSS JOIN current_month cm
    WHERE lf.StFips = '51' AND lf.AreaType = '01'
      AND lf.Adjusted = '1' AND lf.PeriodType = '03'
      AND lf.PeriodYear = cm.yr AND lf.Period = cm.mo
),
va_prior AS (
    SELECT lf.UnemployedRate
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_vintage lfv
      ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
     AND lf.AreaTypeVersion = lfv.AreaTypeVersion
    CROSS JOIN prior_month pm
    WHERE lf.StFips = '51' AND lf.AreaType = '01'
      AND lf.Adjusted = '1' AND lf.PeriodType = '03'
      AND lf.PeriodYear = pm.yr AND lf.Period = pm.mo
),
us_current AS (
    SELECT
        ROUND(CAST(SUM(lf.Unemployed) AS FLOAT) / NULLIF(SUM(lf.LaborForce),0) * 100, 1) AS unemployedrate
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_vintage lfv
      ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
     AND lf.AreaTypeVersion = lfv.AreaTypeVersion
    CROSS JOIN current_month cm
    WHERE lf.AreaType = '01'
      AND lf.Adjusted = '1' AND lf.PeriodType = '03'
      AND lf.PeriodYear = cm.yr AND lf.Period = cm.mo
      AND lf.Unemployed IS NOT NULL
    HAVING COUNT(*) >= 50
),
us_prior AS (
    SELECT
        ROUND(CAST(SUM(lf.Unemployed) AS FLOAT) / NULLIF(SUM(lf.LaborForce),0) * 100, 1) AS unemployedrate
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_vintage lfv
      ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
     AND lf.AreaTypeVersion = lfv.AreaTypeVersion
    CROSS JOIN prior_month pm
    WHERE lf.AreaType = '01'
      AND lf.Adjusted = '1' AND lf.PeriodType = '03'
      AND lf.PeriodYear = pm.yr AND lf.Period = pm.mo
      AND lf.Unemployed IS NOT NULL
    HAVING COUNT(*) >= 50
)
SELECT
    (SELECT CONCAT(cm.yr, '-', cm.mo) FROM current_month cm) AS as_of,
    JSON_QUERY((
        SELECT
            CAST(vc.UnemployedRate AS DECIMAL(5,1))                          AS [virginia.value],
            CAST(ROUND(vc.UnemployedRate - vp.UnemployedRate, 1) AS DECIMAL(5,1)) AS [virginia.delta_pts],
            CAST(uc.unemployedrate AS DECIMAL(5,1))                          AS [us_average.value],
            CAST(ROUND(uc.unemployedrate - up.unemployedrate, 1) AS DECIMAL(5,1)) AS [us_average.delta_pts]
        FROM va_current vc CROSS JOIN va_prior vp
        CROSS JOIN us_current uc CROSS JOIN us_prior up
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS kpi,
    JSON_QUERY((
        SELECT
            'us-va-' + RIGHT(cd.Area, 3)               AS hc_key,
            cd.AreaName                                AS areaname,
            cd.lwda_code                               AS region,
            cd.lwda_short_name                         AS lwda_short_name,
            CAST(cd.employment_rate AS DECIMAL(5,1))   AS employment_rate,
            CAST(cd.UnemployedRate  AS DECIMAL(5,1))   AS unemployed_rate,
            cd.LF                                      AS labor_force,
            cd.Employed                                AS employed
        FROM county_data cd
        ORDER BY cd.AreaName
        FOR JSON PATH
    )) AS counties
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO


-- =============================================================================
-- QUERY 2: UNEMPLOYMENT RATE TRENDING  ->  unemployment_trend.json
--   series.virginia    — VA statewide, seasonally adjusted (always shown)
--   series.us_national — U.S. National, seasonally adjusted (always shown)
--   counties[]         — per county/independent city, NSA (on-click line)
-- =============================================================================
WITH
lf_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.LABORFORCE GROUP BY StFips, AreaType
),
latest AS (
    SELECT MAX(CONCAT(lf.PeriodYear, '-', lf.Period)) AS max_ym
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_vintage lfv
      ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
     AND lf.AreaTypeVersion = lfv.AreaTypeVersion
    WHERE lf.StFips = '51' AND lf.AreaType = '04'
      AND lf.Adjusted = '0' AND lf.PeriodType = '03'
      AND lf.UnemployedRate IS NOT NULL
),
end_date AS (
    SELECT CONVERT(date, SUBSTRING(max_ym, 1, 4) + '-' + SUBSTRING(max_ym, 6, 2) + '-01', 23) AS dt
    FROM latest
),
month_offsets AS (
    SELECT 0 AS n UNION ALL SELECT n + 1 FROM month_offsets WHERE n < 35
),
month_series AS (
    SELECT FORMAT(DATEADD(month, -mo.n, ed.dt), 'yyyy') AS yr,
           FORMAT(DATEADD(month, -mo.n, ed.dt), 'MM')   AS mo
    FROM end_date ed CROSS JOIN month_offsets mo
),
months_dim AS (
    SELECT yr, mo, CONCAT(yr, '-', mo) AS ym FROM month_series
),
virginia_trend AS (
    SELECT lf.PeriodYear, lf.Period, lf.UnemployedRate AS urate
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_vintage lfv
      ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
     AND lf.AreaTypeVersion = lfv.AreaTypeVersion
    JOIN month_series ms ON lf.PeriodYear = ms.yr AND lf.Period = ms.mo
    WHERE lf.StFips = '51' AND lf.AreaType = '01'
      AND lf.Adjusted = '1' AND lf.PeriodType = '03'
      AND lf.UnemployedRate IS NOT NULL
),
us_trend AS (
    SELECT lf.PeriodYear, lf.Period,
           ROUND(CAST(SUM(lf.Unemployed) AS FLOAT) / NULLIF(SUM(lf.LaborForce), 0) * 100, 1) AS urate
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_vintage lfv
      ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
     AND lf.AreaTypeVersion = lfv.AreaTypeVersion
    JOIN month_series ms ON lf.PeriodYear = ms.yr AND lf.Period = ms.mo
    WHERE lf.AreaType = '01'
      AND lf.Adjusted = '1' AND lf.PeriodType = '03'
      AND lf.Unemployed IS NOT NULL
    GROUP BY lf.PeriodYear, lf.Period
    HAVING COUNT(*) >= 50
),
county_trend AS (
    SELECT lf.Area, lf.PeriodYear, lf.Period, lf.UnemployedRate
    FROM WID.dbo.LABORFORCE lf
    JOIN lf_vintage lfv
      ON lf.StFips = lfv.StFips AND lf.AreaType = lfv.AreaType
     AND lf.AreaTypeVersion = lfv.AreaTypeVersion
    JOIN month_series ms ON lf.PeriodYear = ms.yr AND lf.Period = ms.mo
    WHERE lf.StFips = '51' AND lf.AreaType = '04'
      AND lf.Adjusted = '0' AND lf.PeriodType = '03'
),
county_list AS (
    SELECT DISTINCT Area FROM county_trend
)
SELECT
    JSON_QUERY('[' + (
        SELECT STRING_AGG('"' + md.ym + '"', ',') WITHIN GROUP (ORDER BY md.ym)
        FROM months_dim md
    ) + ']') AS months,
    JSON_QUERY((
        SELECT
            JSON_QUERY('[' + (
                SELECT STRING_AGG(ISNULL(CONVERT(VARCHAR(10), CAST(vt.urate AS DECIMAL(5,1))), 'null'), ',')
                       WITHIN GROUP (ORDER BY md.ym)
                FROM months_dim md
                LEFT JOIN virginia_trend vt ON vt.PeriodYear = md.yr AND vt.Period = md.mo
            ) + ']') AS virginia,
            JSON_QUERY('[' + (
                SELECT STRING_AGG(ISNULL(CONVERT(VARCHAR(10), CAST(ut.urate AS DECIMAL(5,1))), 'null'), ',')
                       WITHIN GROUP (ORDER BY md.ym)
                FROM months_dim md
                LEFT JOIN us_trend ut ON ut.PeriodYear = md.yr AND ut.Period = md.mo
            ) + ']') AS us_national
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS series,
    JSON_QUERY((
        SELECT
            'us-va-' + RIGHT(cl.Area, 3) AS hc_key,
            JSON_QUERY('[' + (
                SELECT STRING_AGG(ISNULL(CONVERT(VARCHAR(10), CAST(ct.UnemployedRate AS DECIMAL(5,1))), 'null'), ',')
                       WITHIN GROUP (ORDER BY md.ym)
                FROM months_dim md
                LEFT JOIN county_trend ct
                       ON ct.Area = cl.Area AND ct.PeriodYear = md.yr AND ct.Period = md.mo
            ) + ']') AS data
        FROM county_list cl
        ORDER BY cl.Area
        FOR JSON PATH
    )) AS counties
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO


-- =============================================================================
-- QUERY 3: JOBS ADDED BY INDUSTRY (TOP 5)  ->  jobs_by_industry.json
--   statewide[]  — top 5 sectors statewide (AreaType '01')
--   regions[]    — per LWDA (AreaType '15'), each with its own top 5
-- =============================================================================
WITH
i_vintage AS (
    SELECT AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.INDUSTRY
    WHERE StFips = '51' AND AreaType IN ('01', '15')
    GROUP BY AreaType
),
g_vintage AS (
    SELECT AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY AreaType
),
lwda_dim AS (
    -- See region_mapping (Q1) header — lwda_short_name is GEOGRAPHIES.AreaName
    -- verbatim, no substring-parse. JSON field name preserved for front-end
    -- compat; value carries the full LWDA name suffix.
    SELECT g.Area AS lwda_code,
           g.AreaName AS lwda_name,
           g.AreaName AS lwda_short_name
    FROM WID.dbo.GEOGRAPHIES g
    JOIN g_vintage gv
      ON g.AreaType = gv.AreaType AND g.AreaTypeVersion = gv.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
),

-- ─── BLS CES SUPERSECTOR DIMENSION — live labels from NAICSSuperSectors ─────
-- Replaces the hardcoded sector_name column on the industry_sectors VALUES
-- CTE below, per the project dimension-derived-labels standard. The 10 BLS
-- CES private supersector codes '1011'..'1027' all exist in this dim with
-- SuperTitle labels (e.g. '1013' = 'Manufacturing', '1024' = 'Professional
-- and Business Services'). No vintage column — flat reference dim.
--
-- The Government bar's label is NOT sourced here. The bar is rollup-derived
-- from IndCode='10' (Total all-industries) + Ownership IN ('10','20','30')
-- per the 2026-06-10 audit (see state_both_qtrs header below) — not a 1:1
-- supersector row. The dim's '10' row carries SuperTitle='Total, all
-- industries' which is not what the bar represents; the dim's '1028' row
-- carries 'Public Administration' which is also not what the bar represents.
-- Keeping 'Government' as the documented dim-label exception per the
-- [[feedback-dimension-derived-labels]] standard, applied in
-- gov_change_state / gov_change_region below.
super_dim AS (
    SELECT
        RTRIM(ss.NAICSSuper) AS super_code,
        ss.SuperTitle         AS super_label
    FROM WID.dbo.NAICSSuperSectors ss
),
latest_quarter AS (
    SELECT MAX(CONCAT(i.PeriodYear, '-', i.Period)) AS max_yq
    FROM WID.dbo.INDUSTRY i
    JOIN i_vintage iv
      ON i.AreaType = iv.AreaType AND i.AreaTypeVersion = iv.AreaTypeVersion
    WHERE i.StFips = '51' AND i.AreaType = '01' AND i.PeriodType = '02'
      AND i.Period <> '00'
),
current_q AS (
    SELECT SUBSTRING(max_yq, 1, 4) AS yr, SUBSTRING(max_yq, 6, 2) AS qtr FROM latest_quarter
),
prior_q AS (
    SELECT
        CASE WHEN qtr = '01' THEN CAST(CAST(yr AS INT) - 1 AS VARCHAR(4)) ELSE yr END AS yr,
        CASE WHEN qtr = '01' THEN '04' ELSE RIGHT('0' + CAST(CAST(qtr AS INT) - 1 AS VARCHAR(2)), 2) END AS qtr
    FROM current_q
),
industry_sectors AS (
    -- (indcode, ownership) pair only. The sector_name column was dropped per
    -- the project dimension-derived-labels standard; live labels come from
    -- super_dim above (WID.dbo.NAICSSuperSectors.SuperTitle). The ordering
    -- here is purely cosmetic — top5 selection is by jobs_added DESC.
    SELECT * FROM (VALUES
        ('1024','50'),
        ('1025','50'),
        ('1026','50'),
        ('1021','50'),
        ('1013','50'),
        ('1012','50'),
        ('1011','50'),
        ('1022','50'),
        ('1023','50'),
        ('1027','50')
    ) AS t(indcode, ownership)
),
state_both_qtrs AS (
    -- Pulls both the 10 private supersectors (1011..1027, Ownership='50') and
    -- the BLS pre-summed Total-all-industries row (IndCode='10', Ownership
    -- '10'/'20'/'30') used by the Government rollup downstream. '1028'
    -- (Public Administration) is intentionally OMITTED — the prior version
    -- summed 1028 + Ownership IN ('10','20','30') as "Government" but that
    -- only captures NAICS-92 government workers (~265k VA), not the full
    -- Fed+State+Local workforce (~749k VA — government employees in
    -- schools/hospitals/transit are under 1025 / 1021 / etc.). The IndCode='10'
    -- row is the BLS-published total across all supersectors and is the
    -- correct anchor. Verified 2026-06-10 with the A vs C audit:
    --   A=264,752  (IndCode 1028 only — the bug)
    --   B=748,815  (sum across 1011..1028 — partition check)
    --   C=748,907  (IndCode 10 — BLS canonical, used here)
    SELECT TRIM(i.IndCode) AS indcode, i.Ownership, i.PeriodYear, i.Period, i.QuarterAvgEmp
    FROM WID.dbo.INDUSTRY i
    JOIN i_vintage iv
      ON i.AreaType = iv.AreaType AND i.AreaTypeVersion = iv.AreaTypeVersion
    CROSS JOIN current_q cq CROSS JOIN prior_q pq
    WHERE i.StFips = '51' AND i.AreaType = '01' AND i.PeriodType = '02'
      AND i.IndCode IN ('10','1011','1012','1013','1021','1022','1023','1024','1025','1026','1027')
      AND i.Ownership IN ('10','20','30','50')
      AND ((i.PeriodYear = cq.yr AND i.Period = cq.qtr)
        OR (i.PeriodYear = pq.yr AND i.Period = pq.qtr))
),
state_change AS (
    SELECT indcode, Ownership, PeriodYear, Period,
           QuarterAvgEmp AS current_emp,
           LAG(QuarterAvgEmp) OVER (PARTITION BY indcode, Ownership ORDER BY PeriodYear, Period) AS prior_emp
    FROM state_both_qtrs
),
state_current_only AS (
    SELECT sc.indcode, sc.Ownership, sc.current_emp, sc.prior_emp
    FROM state_change sc
    WHERE EXISTS (SELECT 1 FROM current_q cq WHERE sc.PeriodYear = cq.yr AND sc.Period = cq.qtr)
),
private_change_state AS (
    -- sector_name is now sourced live from super_dim (WID.dbo.NAICSSuperSectors).
    -- COALESCE to the BLS code if the dim row is missing — keeps the bar
    -- visible with a code label rather than dropping it. lwda_name / lwda_short_name
    -- are NULL on statewide rows; the CAST width matches the per-LWDA branch
    -- (NVARCHAR(120)) so the downstream UNION ALL doesn't pick the narrower
    -- type.
    SELECT 'statewide' AS scope,
           CAST(NULL AS NVARCHAR(120)) AS lwda_name,
           CAST(NULL AS NVARCHAR(120)) AS lwda_short_name,
           COALESCE(sd.super_label, s.indcode) AS sector_name,
           COALESCE(sc.current_emp, 0) AS current_emp,
           COALESCE(sc.prior_emp, 0)   AS prior_emp,
           COALESCE(sc.current_emp, 0) - COALESCE(sc.prior_emp, 0) AS jobs_added
    FROM industry_sectors s
    LEFT JOIN state_current_only sc ON sc.indcode = s.indcode AND sc.Ownership = s.ownership
    LEFT JOIN super_dim sd ON sd.super_code = s.indcode
),
gov_change_state AS (
    -- 'Government' literal is the documented dim-label exception (see
    -- super_dim header). The bar is a rollup over IndCode='10' + Ownership IN
    -- ('10','20','30'), not the dim's '1028' Public Administration row.
    SELECT 'statewide' AS scope,
           CAST(NULL AS NVARCHAR(120)) AS lwda_name,
           CAST(NULL AS NVARCHAR(120)) AS lwda_short_name,
           CAST('Government' AS NVARCHAR(120)) AS sector_name,
           SUM(COALESCE(current_emp, 0)) AS current_emp,
           SUM(COALESCE(prior_emp, 0))   AS prior_emp,
           SUM(COALESCE(current_emp, 0)) - SUM(COALESCE(prior_emp, 0)) AS jobs_added
    FROM state_current_only
    -- IndCode='10' = BLS "Total, all industries" supersector row. Ownership
    -- IN ('10','20','30') restricts to Federal+State+Local employees across
    -- every industry (schools, hospitals, transit, etc.), not just NAICS-92
    -- Public Administration. See state_both_qtrs header for the audit numbers.
    WHERE indcode = '10' AND Ownership IN ('10','20','30')
),
region_both_qtrs AS (
    -- Per-LWDA twin of state_both_qtrs. Same Government-rollup correction:
    -- IndCode='10' replaces '1028' in the IN-list so each LWDA's Government
    -- bar sums Fed+State+Local across all industries, not just NAICS-92.
    -- ASSUMPTION (verify on first refresh): IndCode='10' rows exist at
    -- AreaType='15' with Ownership IN ('10','20','30'). If they don't, the
    -- per-LWDA Government row will be NULL — visible in the bar chart, file
    -- a load-gap ticket against the IndCode='10' / AreaType='15' rows.
    SELECT i.Area AS lwda_code, TRIM(i.IndCode) AS indcode, i.Ownership,
           i.PeriodYear, i.Period, i.QuarterAvgEmp AS total_emp
    FROM WID.dbo.INDUSTRY i
    JOIN i_vintage iv
      ON i.AreaType = iv.AreaType AND i.AreaTypeVersion = iv.AreaTypeVersion
    JOIN lwda_dim ld ON i.Area = ld.lwda_code
    CROSS JOIN current_q cq CROSS JOIN prior_q pq
    WHERE i.StFips = '51' AND i.AreaType = '15' AND i.PeriodType = '02'
      AND i.IndCode IN ('10','1011','1012','1013','1021','1022','1023','1024','1025','1026','1027')
      AND i.Ownership IN ('10','20','30','50')
      AND ((i.PeriodYear = cq.yr AND i.Period = cq.qtr)
        OR (i.PeriodYear = pq.yr AND i.Period = pq.qtr))
),
region_change AS (
    SELECT lwda_code, indcode, Ownership, PeriodYear, Period,
           total_emp AS current_emp,
           LAG(total_emp) OVER (PARTITION BY lwda_code, indcode, Ownership ORDER BY PeriodYear, Period) AS prior_emp
    FROM region_both_qtrs
),
region_current_only AS (
    SELECT rc.lwda_code, rc.indcode, rc.Ownership, rc.current_emp, rc.prior_emp
    FROM region_change rc
    WHERE EXISTS (SELECT 1 FROM current_q cq WHERE rc.PeriodYear = cq.yr AND rc.Period = cq.qtr)
),
private_change_region AS (
    SELECT ld.lwda_code AS scope,
           ld.lwda_name,
           ld.lwda_short_name,
           COALESCE(sd.super_label, s.indcode) AS sector_name,
           COALESCE(rc.current_emp, 0) AS current_emp,
           COALESCE(rc.prior_emp, 0)   AS prior_emp,
           COALESCE(rc.current_emp, 0) - COALESCE(rc.prior_emp, 0) AS jobs_added
    FROM lwda_dim ld
    CROSS JOIN industry_sectors s
    LEFT JOIN region_current_only rc
      ON rc.lwda_code = ld.lwda_code AND rc.indcode = s.indcode AND rc.Ownership = s.ownership
    LEFT JOIN super_dim sd ON sd.super_code = s.indcode
),
gov_change_region AS (
    -- 'Government' literal — same documented dim-label exception as
    -- gov_change_state. CAST to NVARCHAR(120) so the UNION ALL into
    -- all_sectors holds the verbose lwda_short_name from lwda_dim.
    SELECT ld.lwda_code AS scope,
           MAX(ld.lwda_name) AS lwda_name,
           MAX(ld.lwda_short_name) AS lwda_short_name,
           CAST('Government' AS NVARCHAR(120)) AS sector_name,
           SUM(COALESCE(rc.current_emp, 0)) AS current_emp,
           SUM(COALESCE(rc.prior_emp, 0))   AS prior_emp,
           SUM(COALESCE(rc.current_emp, 0)) - SUM(COALESCE(rc.prior_emp, 0)) AS jobs_added
    FROM lwda_dim ld
    LEFT JOIN region_current_only rc
      -- IndCode='10' = BLS Total-all-industries supersector (Fed+State+Local
      -- across every NAICS), per the audit; replaces the prior '1028' which
      -- only captured NAICS-92 Public Administration. See state_both_qtrs
      -- header for the audit numbers.
      ON rc.lwda_code = ld.lwda_code AND rc.indcode = '10' AND rc.Ownership IN ('10','20','30')
    GROUP BY ld.lwda_code
),
all_sectors AS (
    SELECT * FROM private_change_state
    UNION ALL SELECT * FROM gov_change_state
    UNION ALL SELECT * FROM private_change_region
    UNION ALL SELECT * FROM gov_change_region
),
ranked AS (
    SELECT scope, lwda_name, lwda_short_name, sector_name, current_emp, prior_emp, jobs_added,
           ROW_NUMBER() OVER (PARTITION BY scope ORDER BY jobs_added DESC) AS rn
    FROM all_sectors
),
top5 AS (
    SELECT scope, lwda_short_name, sector_name,
           CAST(jobs_added AS INT) AS jobs_added
    FROM ranked
    WHERE rn <= 5
),
region_scopes AS (
    SELECT scope, MAX(lwda_short_name) AS label
    FROM top5
    WHERE scope <> 'statewide'
    GROUP BY scope
)
SELECT
    (SELECT CONCAT(cq.yr, '-Q', CAST(CAST(cq.qtr AS INT) AS VARCHAR(1))) FROM current_q cq) AS as_of_quarter,
    JSON_QUERY((
        SELECT s.sector_name AS sector, s.jobs_added AS jobs_added
        FROM top5 s
        WHERE s.scope = 'statewide'
        ORDER BY s.jobs_added DESC
        FOR JSON PATH
    )) AS statewide,
    JSON_QUERY((
        SELECT
            rs.scope AS [key],
            rs.label AS label,
            JSON_QUERY((
                SELECT t.sector_name AS sector, t.jobs_added AS jobs_added
                FROM top5 t
                WHERE t.scope = rs.scope
                ORDER BY t.jobs_added DESC
                FOR JSON PATH
            )) AS sectors
        FROM region_scopes rs
        ORDER BY rs.label
        FOR JSON PATH
    )) AS regions
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO
