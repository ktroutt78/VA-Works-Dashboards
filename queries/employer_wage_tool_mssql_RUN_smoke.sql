-- =============================================================================
-- EMPLOYER WAGE TOOL — SMOKE TEST variant of _RUN.sql
--
-- IDENTICAL SQL LOGIC to _RUN.sql except dbo.LWDA_Slugs is INLINED as a CTE.
-- Read-only — no DDL, no JOIN to dbo.LWDA_Slugs (which doesn't exist yet under
-- the read-only validation account). Lets you run end-to-end against live WID
-- and inspect the JSON output before any write-access operations.
--
-- NOT FOR HANDOFF. The eventual scheduled operator uses _RUN.sql with the
-- real dbo.LWDA_Slugs from _setup.sql. Keep these two files in sync if logic
-- changes — slug list lives in this file, in _setup.sql, and (eventually) in
-- the regenerated apps/wage-tool-employer/data/wages.json + industries.json
-- skeleton. Three copies; verify alignment before handoff.
--
-- USAGE: SSMS / Azure Data Studio. Each query (Q1 wages, Q2 industries) emits
-- one NVARCHAR(MAX) cell. Paste the first ~200 chars of each into chat to
-- diff envelope shape (meta + first 1-2 areas + first job/sector entry).
--
-- LWDA SLUGS BELOW are derived from Probe 2's GEOGRAPHIES output at
-- AreaTypeVersion='0002' (current vintage). Display labels strip " Region" /
-- " (LWDA <roman>)" suffixes. The skeleton JSON needs to be regenerated to
-- match these slugs after smoke-test confirms the SQL is correct.
--
--   code    | slug                  | label
--   --------+-----------------------+-------------------------
--   000441  | southwest             | Southwest
--   000442  | new-river-mt-rogers   | New River/Mt. Rogers
--   000443  | greater-roanoke       | Greater Roanoke
--   000444  | shenandoah-valley     | Shenandoah Valley
--   000455  | crater                | Crater
--   000446  | piedmont              | Piedmont
--   000447  | central               | Central
--   000448  | south-central         | South Central
--   000449  | capital               | Capital
--   000457  | west-piedmont         | West Piedmont
--   000451  | northern              | Northern
--   000452  | alexandria-arlington  | Alexandria/Arlington
--   000453  | bay-consortium        | Bay Consortium
--   000456  | hampton-roads         | Hampton Roads
--
-- Vintage note: this smoke test does NOT pin AreaTypeVersion in the slug join
-- (the handoff _RUN.sql does, via dbo.LWDA_Slugs). The fact-table vintage
-- anchors (iowage_vintage / ind_vintage) already constrain the fact rows to
-- their respective MAX vintages, so dropping the slug-side filter is safe for
-- the smoke test. If joins produce zero rows in the LWDA-level CTEs, suspect
-- a fact-table vintage that uses different Area codes than the GEOGRAPHIES
-- '0002' set above — re-run Probe 2 and reconcile.
-- =============================================================================


-- =============================================================================
-- QUERY 1: OEWS OCCUPATION WAGES  ->  wages.json (smoke output)
-- =============================================================================
WITH
-- Inline LWDA slug table — AreaTypeVersion now included for the 4-col composite
-- join via lwda_dim (parallels the handoff dbo.LWDA_Slugs schema).
lwda_slugs AS (
    SELECT * FROM (VALUES
        ('000441', '0002', 'southwest',            'Southwest'),
        ('000442', '0002', 'new-river-mt-rogers',  'New River/Mt. Rogers'),
        ('000443', '0002', 'greater-roanoke',      'Greater Roanoke'),
        ('000444', '0002', 'shenandoah-valley',    'Shenandoah Valley'),
        ('000455', '0002', 'crater',               'Crater'),
        ('000446', '0002', 'piedmont',             'Piedmont'),
        ('000447', '0002', 'central',              'Central'),
        ('000448', '0002', 'south-central',        'South Central'),
        ('000449', '0002', 'capital',              'Capital'),
        ('000457', '0002', 'west-piedmont',        'West Piedmont'),
        ('000451', '0002', 'northern',             'Northern'),
        ('000452', '0002', 'alexandria-arlington', 'Alexandria/Arlington'),
        ('000453', '0002', 'bay-consortium',       'Bay Consortium'),
        ('000456', '0002', 'hampton-roads',        'Hampton Roads')
    ) AS t(lwda_code, AreaTypeVersion, lwda_id, lwda_label)
),
geo_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY StFips, AreaType
),
-- LWDA dim — joins GEOGRAPHIES (with vintage anchor) to inline lwda_slugs.
-- Provides 4-col composite key (StFips, AreaType, AreaTypeVersion, Area) for
-- the IOWAGE / INDUSTRY join. Parallels the handoff _RUN.sql lwda_dim.
lwda_dim AS (
    SELECT
        g.StFips, g.AreaType, g.AreaTypeVersion, g.Area AS lwda_code,
        g.AreaName AS wid_name, sl.lwda_id, sl.lwda_label
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    JOIN lwda_slugs sl
      ON g.Area = sl.lwda_code AND g.AreaTypeVersion = sl.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
),

iowage_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.IOWAGE
    WHERE StFips = '51'
    GROUP BY StFips, AreaType
),

latest_oews_year AS (
    SELECT MAX(w.PeriodYear) AS yr
    FROM WID.dbo.IOWAGE w
    JOIN iowage_vintage iv
      ON w.StFips = iv.StFips AND w.AreaType = iv.AreaType
     AND w.AreaTypeVersion = iv.AreaTypeVersion
    WHERE w.StFips = '51' AND w.AreaType = '01'
),

state_wages AS (
    SELECT
        REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')                                                          AS soc_code,
        -- OccName column does not exist in this WID install's IOWAGE table; label
        -- defaults to soc_code in the final SELECT. Production fix: load BLS SOC
        -- occupation-name reference (separate WID load-gap ticket).
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
      AND LEN(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')) = 6   -- SOC-6 (WID stores 6 digits; hyphen-tolerant via REPLACE)
      AND RIGHT(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), 1) <> '0'   -- SOC-6 detail only (BLS aggregates end in 0)
    GROUP BY REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')
),

lwda_wages AS (
    SELECT
        REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')                                                          AS soc_code,
        ld.lwda_id                                                                        AS area_id,
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
      AND w.AreaType = '15'
      AND w.PeriodYear = ly.yr
      AND w.RateType IN ('1','4')
      AND w.IndCodeType = '10' AND w.IndCode = '000000'   -- all-industries cross-industry row
      AND LEN(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', '')) = 6   -- SOC-6 (WID stores 6 digits; hyphen-tolerant via REPLACE)
      AND RIGHT(REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), 1) <> '0'   -- SOC-6 detail only (BLS aggregates end in 0)
    GROUP BY REPLACE(LTRIM(RTRIM(w.OccCode)), '-', ''), ld.lwda_id
),

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

-- Hardcoded BLS SOC major-group lookup (23 groups). Replaces the original
-- CTE that read XX-0000 rows from IOWAGE — those rows exist but have no
-- OccName column to source the group label from. SOC major groups are stable;
-- safe to inline.
major_groups AS (
    SELECT * FROM (VALUES
        ('11-0000', 'Management Occupations'),
        ('13-0000', 'Business and Financial Operations'),
        ('15-0000', 'Computer and Mathematical'),
        ('17-0000', 'Architecture and Engineering'),
        ('19-0000', 'Life, Physical, and Social Science'),
        ('21-0000', 'Community and Social Service'),
        ('23-0000', 'Legal'),
        ('25-0000', 'Educational Instruction and Library'),
        ('27-0000', 'Arts, Design, Entertainment, Sports, and Media'),
        ('29-0000', 'Healthcare Practitioners and Technical'),
        ('31-0000', 'Healthcare Support'),
        ('33-0000', 'Protective Service'),
        ('35-0000', 'Food Preparation and Serving Related'),
        ('37-0000', 'Building and Grounds Cleaning and Maintenance'),
        ('39-0000', 'Personal Care and Service'),
        ('41-0000', 'Sales and Related'),
        ('43-0000', 'Office and Administrative Support'),
        ('45-0000', 'Farming, Fishing, and Forestry'),
        ('47-0000', 'Construction and Extraction'),
        ('49-0000', 'Installation, Maintenance, and Repair'),
        ('51-0000', 'Production Occupations'),
        ('53-0000', 'Transportation and Material Moving'),
        ('55-0000', 'Military Specific Occupations')
    ) AS t(mg_code, major_group_name)
),

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
        sw.soc_code, ld.lwda_id  AS area_id,
        sw.p10, sw.p25, sw.p50, sw.p75, sw.p90,
        sw.p10_h, sw.p25_h, sw.p50_h, sw.p75_h, sw.p90_h,
        sw.employment,
        'statewide_fallback'    AS provenance,
        ld.lwda_id               AS area_sort_key
    FROM state_wages_repaired sw
    CROSS JOIN lwda_dim ld
    WHERE NOT EXISTS (
        SELECT 1 FROM lwda_wages_repaired lw2
        WHERE lw2.soc_code = sw.soc_code
          AND lw2.area_id  = ld.lwda_id
          AND lw2.p50 IS NOT NULL
    )

    UNION ALL

    -- The 'virginia' statewide row itself (always native)
    SELECT
        sw.soc_code, 'virginia'  AS area_id,
        sw.p10, sw.p25, sw.p50, sw.p75, sw.p90,
        sw.p10_h, sw.p25_h, sw.p50_h, sw.p75_h, sw.p90_h,
        sw.employment,
        'statewide'              AS provenance,
        'zzz-virginia'           AS area_sort_key
    FROM state_wages_repaired sw
),

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
                AS NVARCHAR(MAX)
            ),
            ','
        ) WITHIN GROUP (ORDER BY ac.area_sort_key) + '}' AS areas_json
    FROM all_cells ac
    GROUP BY ac.soc_code
)

SELECT
    JSON_QUERY((
        SELECT
            'WID.dbo.IOWAGE'                                  AS source,
            CONVERT(VARCHAR(33), SYSUTCDATETIME(), 126) + 'Z' AS extracted_at,
            TRY_CAST((SELECT yr FROM latest_oews_year) AS INT) AS latest_year
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS meta,
    JSON_QUERY((
        SELECT id, label, areatype
        FROM (
            SELECT ld.lwda_id AS id, ld.lwda_label AS label, '15' AS areatype, ld.lwda_id AS sortk
            FROM lwda_dim ld
            UNION ALL
            SELECT 'virginia', 'Virginia', '01', 'zzz-virginia'
        ) src
        ORDER BY src.sortk
        FOR JSON PATH
    )) AS areas,
    JSON_QUERY((
        SELECT
            STUFF(sw.soc_code, 3, 0, '-')            AS id,
            STUFF(sw.soc_code, 3, 0, '-')            AS soc_code,
            STUFF(sw.soc_code, 3, 0, '-')            AS label,        -- placeholder; OccName not in WID load

            ISNULL(mg.major_group_name, 'Other')     AS major_group,
            JSON_QUERY('[]')                         AS aliases,
            JSON_QUERY(jb.areas_json)                AS areas
        FROM state_wages_repaired sw
        JOIN job_areas_blob jb ON jb.soc_code = sw.soc_code
        LEFT JOIN major_groups mg ON LEFT(sw.soc_code, 2) + '-0000' = mg.mg_code
        ORDER BY sw.soc_code
        FOR JSON PATH
    )) AS jobs
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO


-- =============================================================================
-- QUERY 2: QCEW INDUSTRY SUMMARIES  ->  industries.json (smoke output)
-- =============================================================================
WITH
-- Inline LWDA slug table — AreaTypeVersion now included for the 4-col composite
-- join via lwda_dim (parallels the handoff dbo.LWDA_Slugs schema).
lwda_slugs AS (
    SELECT * FROM (VALUES
        ('000441', '0002', 'southwest',            'Southwest'),
        ('000442', '0002', 'new-river-mt-rogers',  'New River/Mt. Rogers'),
        ('000443', '0002', 'greater-roanoke',      'Greater Roanoke'),
        ('000444', '0002', 'shenandoah-valley',    'Shenandoah Valley'),
        ('000455', '0002', 'crater',               'Crater'),
        ('000446', '0002', 'piedmont',             'Piedmont'),
        ('000447', '0002', 'central',              'Central'),
        ('000448', '0002', 'south-central',        'South Central'),
        ('000449', '0002', 'capital',              'Capital'),
        ('000457', '0002', 'west-piedmont',        'West Piedmont'),
        ('000451', '0002', 'northern',             'Northern'),
        ('000452', '0002', 'alexandria-arlington', 'Alexandria/Arlington'),
        ('000453', '0002', 'bay-consortium',       'Bay Consortium'),
        ('000456', '0002', 'hampton-roads',        'Hampton Roads')
    ) AS t(lwda_code, AreaTypeVersion, lwda_id, lwda_label)
),
geo_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY StFips, AreaType
),
-- LWDA dim — joins GEOGRAPHIES (with vintage anchor) to inline lwda_slugs.
-- Provides 4-col composite key (StFips, AreaType, AreaTypeVersion, Area) for
-- the IOWAGE / INDUSTRY join. Parallels the handoff _RUN.sql lwda_dim.
lwda_dim AS (
    SELECT
        g.StFips, g.AreaType, g.AreaTypeVersion, g.Area AS lwda_code,
        g.AreaName AS wid_name, sl.lwda_id, sl.lwda_label
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    JOIN lwda_slugs sl
      ON g.Area = sl.lwda_code AND g.AreaTypeVersion = sl.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
),

ind_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.INDUSTRY
    WHERE StFips = '51' AND AreaType IN ('01', '15')
    GROUP BY StFips, AreaType
),

latest_ind_year AS (
    SELECT MAX(i.PeriodYear) AS yr
    FROM WID.dbo.INDUSTRY i
    JOIN ind_vintage iv
      ON i.StFips = iv.StFips AND i.AreaType = iv.AreaType
     AND i.AreaTypeVersion = iv.AreaTypeVersion
    WHERE i.StFips = '51' AND i.AreaType = '01'
      AND i.PeriodType = '01' AND i.Period = '00'
),

-- BLS QCEW supersector range encoding: '31-33' Mfg, '44-45' Retail,
-- '48-49' Transportation — WID stores these literally as hyphenated ranges.
-- See _RUN.sql naics_sectors header for the full explanation.
naics_sectors AS (
    SELECT * FROM (VALUES
        ('11', '11',    'Agriculture, Forestry, Fishing & Hunting'),
        ('21', '21',    'Mining, Quarrying & Oil/Gas Extraction'),
        ('22', '22',    'Utilities'),
        ('23', '23',    'Construction'),
        ('31', '31-33', 'Manufacturing'),
        ('42', '42',    'Wholesale Trade'),
        ('44', '44-45', 'Retail Trade'),
        ('48', '48-49', 'Transportation & Warehousing'),
        ('51', '51',    'Information'),
        ('52', '52',    'Finance & Insurance'),
        ('53', '53',    'Real Estate & Rental/Leasing'),
        ('54', '54',    'Professional, Scientific & Technical'),
        ('55', '55',    'Management of Companies'),
        ('56', '56',    'Administrative & Support/Waste Mgmt'),
        ('61', '61',    'Educational Services'),
        ('62', '62',    'Health Care & Social Assistance'),
        ('71', '71',    'Arts, Entertainment & Recreation'),
        ('72', '72',    'Accommodation & Food Services'),
        ('81', '81',    'Other Services (except Public Admin)'),
        ('92', '92',    'Public Administration')
    ) AS t(naics_code, wid_code, sector_name)
),

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
      -- Suppress filter intentionally OMITTED (see _RUN.sql for rationale).
),

lwda_qcew AS (
    SELECT
        ld.lwda_id                                                              AS area_id,
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
      -- Suppress filter intentionally OMITTED (see _RUN.sql for rationale).
),

all_industry_cells AS (
    SELECT area_id, naics_code, mean_wage, employment, establishments,
           area_id AS area_sort_key
    FROM lwda_qcew

    UNION ALL

    SELECT 'virginia' AS area_id, naics_code, mean_wage, employment, establishments,
           'zzz-virginia' AS area_sort_key
    FROM state_qcew
),

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
                AS NVARCHAR(MAX)
            ),
            ','
        ) WITHIN GROUP (ORDER BY aic.area_sort_key) + '}' AS areas_json
    FROM all_industry_cells aic
    GROUP BY aic.naics_code
)

SELECT
    JSON_QUERY((
        SELECT
            'WID.dbo.INDUSTRY (QCEW)'                         AS source,
            CONVERT(VARCHAR(33), SYSUTCDATETIME(), 126) + 'Z' AS extracted_at,
            TRY_CAST((SELECT yr FROM latest_ind_year) AS INT)  AS latest_year
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    )) AS meta,
    JSON_QUERY((
        SELECT id, label
        FROM (
            SELECT ld.lwda_id AS id, ld.lwda_label AS label, ld.lwda_id AS sortk
            FROM lwda_dim ld
            UNION ALL
            SELECT 'virginia', 'Virginia', 'zzz-virginia'
        ) src
        ORDER BY src.sortk
        FOR JSON PATH
    )) AS areas,
    JSON_QUERY((
        SELECT
            ns.naics_code                AS naics,
            ns.sector_name               AS label,
            JSON_QUERY(sab.areas_json)   AS areas
        FROM naics_sectors ns
        JOIN sector_areas_blob sab ON sab.naics_code = ns.naics_code
        ORDER BY ns.naics_code
        FOR JSON PATH
    )) AS sectors
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
GO
