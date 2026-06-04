-- =============================================================================
-- EMPLOYER WAGE TOOL — Snowflake SQL (source-of-truth for T-SQL translation)
-- =============================================================================
-- Produces two JSON files:
--   1. apps/wage-tool-employer/data/wages.json   (OEWS occupation percentiles)
--   2. apps/wage-tool-employer/data/industries.json (QCEW sector summaries)
--
-- Source tables (WID_DB.WID schema, BLS WID standard):
--   IOWAGE          — OEWS occupation wage data (annual + hourly percentiles)
--   INDUSTRY        — QCEW industry data (employment, wages, establishments)
--   GEOGRAPHIES     — Area/AreaType dimension (names, FIPS)
--   SUBGEOGRAPHIES  — Sub-area crosswalk (county → LWDA mapping)
--   ONET_TITLES     — O*NET alternate titles for occupations (aliases)
--
-- AreaType codes:
--   '01' = statewide    '03' = MSA    '04'/'05' = county/city
--   '15' = LWDA (Local Workforce Development Area)
--
-- PREREQUISITES:
--   These tables must be loaded into WID_DB.WID before execution.
--   The stage @WID_DB.WID_STAGING.WID_STAGE is the load target.
--   Tables currently do not exist — they were previously loaded from BLS
--   flat-files and must be reloaded from the SQL Server WID 3.0 or fresh
--   BLS downloads.
--
-- SNOWFLAKE-SPECIFIC FUNCTIONS (flag for T-SQL translation):
--   • OBJECT_CONSTRUCT / OBJECT_AGG — JSON object assembly
--   • ARRAY_AGG / ARRAY_CONSTRUCT  — JSON array assembly
--   • LATERAL FLATTEN              — JSON array/object expansion
--   • LISTAGG                      — string aggregation (T-SQL: STRING_AGG)
--   • NULLIF / COALESCE            — portable (same in T-SQL)
--   • IFF                          — Snowflake ternary (T-SQL: IIF or CASE)
--   • REGEXP_REPLACE               — regex (T-SQL: limited, use REPLACE chain)
--   • TRY_CAST                     — safe cast (T-SQL: TRY_CAST, same name)
--   • :: cast syntax               — Snowflake shorthand (T-SQL: CAST(...AS...))
--   • QUALIFY                      — Snowflake window filter (T-SQL: subquery)
--   • PARSE_JSON / TO_JSON         — semi-structured (T-SQL: FOR JSON PATH)
--
-- When translating to T-SQL for SQL Server WID 3.0:
--   • Replace OBJECT_CONSTRUCT → FOR JSON PATH
--   • Replace ARRAY_AGG → STRING_AGG + JSON_QUERY wrapper
--   • Add AreaTypeVersion vintage anchors (MAX per StFips, AreaType)
--   • Column names may be PascalCase in SQL Server (e.g. OccCode vs OCCCODE)
-- =============================================================================


-- =============================================================================
-- FILE 1: wages.json
-- =============================================================================
-- Shape: { meta, areas, jobs }
--   meta: { source, extracted_at, latest_year }
--   areas: [ { id, label, areatype } ]   — 14 LWDAs + statewide Virginia
--   jobs:  [ { id, soc_code, label, major_group, aliases, areas } ]
--     areas.{area_id}: { p10, p25, p50, p75, p90, p10_h, p25_h, p50_h, p75_h, p90_h,
--                        employment, provenance }
-- =============================================================================

WITH
-- ─── VINTAGE ANCHORS ──────────────────────────────────────────────────────────
-- WID tables carry AreaTypeVersion; always filter to MAX to get current data.
iowage_vintage AS (
    SELECT STFIPS, AREATYPE, MAX(AREATYPEVERSION) AS AREATYPEVERSION
    FROM WID_DB.WID.IOWAGE
    WHERE STFIPS = '51'
    GROUP BY STFIPS, AREATYPE
),
geo_vintage AS (
    SELECT STFIPS, AREATYPE, MAX(AREATYPEVERSION) AS AREATYPEVERSION
    FROM WID_DB.WID.GEOGRAPHIES
    WHERE STFIPS = '51'
    GROUP BY STFIPS, AREATYPE
),
sg_vintage AS (
    SELECT STFIPS, AREATYPE, MAX(AREATYPEVERSION) AS AREATYPEVERSION
    FROM WID_DB.WID.SUBGEOGRAPHIES
    WHERE STFIPS = '51'
    GROUP BY STFIPS, AREATYPE
),

-- ─── LWDA DIMENSION (14 Virginia LWDAs) ──────────────────────────────────────
-- SUBGEOGRAPHIES maps counties (SubArea, SubAreaType) → LWDA (Area, AreaType='15')
-- GEOGRAPHIES provides LWDA names. Exclude synthetic "Combined Projections Area".
lwda_dim AS (
    SELECT
        g.AREA          AS lwda_code,
        g.AREANAME      AS lwda_name,
        -- Clean display name: strip " Region" and " (LWDA X...)" suffix
        TRIM(REGEXP_REPLACE(
            REGEXP_REPLACE(g.AREANAME, '\\s*\\(LWDA\\s+[IVXLC]+\\)', ''),
            '\\s+Region$', ''
        )) AS lwda_short_name,
        -- Slugified ID for JSON (lowercase, spaces→hyphens)
        LOWER(REGEXP_REPLACE(
            TRIM(REGEXP_REPLACE(
                REGEXP_REPLACE(g.AREANAME, '\\s*\\(LWDA\\s+[IVXLC]+\\)', ''),
                '\\s+Region$', ''
            )),
            '[^a-zA-Z0-9]+', '-'
        )) AS lwda_id
    FROM WID_DB.WID.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.STFIPS = gv.STFIPS AND g.AREATYPE = gv.AREATYPE
     AND g.AREATYPEVERSION = gv.AREATYPEVERSION
    WHERE g.STFIPS = '51' AND g.AREATYPE = '15'
      AND g.AREANAME NOT LIKE '%Combined%'
),

-- ─── LATEST YEAR IN OEWS DATA ────────────────────────────────────────────────
latest_oews_year AS (
    SELECT MAX(PERIODYEAR) AS yr
    FROM WID_DB.WID.IOWAGE
    WHERE STFIPS = '51' AND AREATYPE = '01'
),

-- ─── STATEWIDE OEWS DATA (fallback source) ───────────────────────────────────
-- AreaType='01' = Virginia statewide
state_wages AS (
    SELECT
        TRIM(w.OCCCODE)   AS soc_code,
        w.OCCNAME         AS occ_name,
        -- Annual percentiles
        TRY_CAST(w.ANNWAGE10 AS NUMBER(10,0))  AS p10,
        TRY_CAST(w.ANNWAGE25 AS NUMBER(10,0))  AS p25,
        TRY_CAST(w.ANNWAGE50 AS NUMBER(10,0))  AS p50,
        TRY_CAST(w.ANNWAGE75 AS NUMBER(10,0))  AS p75,
        TRY_CAST(w.ANNWAGE90 AS NUMBER(10,0))  AS p90,
        -- Native hourly percentiles (NOT derived from annual ÷ 2080)
        TRY_CAST(w.HRWAGE10 AS NUMBER(10,2))   AS p10_h,
        TRY_CAST(w.HRWAGE25 AS NUMBER(10,2))   AS p25_h,
        TRY_CAST(w.HRWAGE50 AS NUMBER(10,2))   AS p50_h,
        TRY_CAST(w.HRWAGE75 AS NUMBER(10,2))   AS p75_h,
        TRY_CAST(w.HRWAGE90 AS NUMBER(10,2))   AS p90_h,
        -- Employment
        TRY_CAST(w.EMPCOUNT AS NUMBER(10,0))    AS employment
    FROM WID_DB.WID.IOWAGE w
    JOIN iowage_vintage iv
      ON w.STFIPS = iv.STFIPS AND w.AREATYPE = iv.AREATYPE
     AND w.AREATYPEVERSION = iv.AREATYPEVERSION
    CROSS JOIN latest_oews_year ly
    WHERE w.STFIPS = '51'
      AND w.AREATYPE = '01'          -- statewide
      AND w.PERIODYEAR = ly.yr
      AND LENGTH(TRIM(w.OCCCODE)) = 7  -- SOC-6 only (XX-XXXX)
      AND w.OCCCODE NOT LIKE '%-0000'  -- exclude major group totals
),

-- ─── LWDA-LEVEL OEWS DATA ────────────────────────────────────────────────────
-- AreaType='15' = LWDA direct rows (if they exist in IOWAGE)
-- Note: OEWS may not publish at LWDA level. If IOWAGE only has MSA (AreaType='03')
-- or state ('01'), the LWDA rows will be empty and everything falls back to statewide.
lwda_wages AS (
    SELECT
        TRIM(w.OCCCODE)   AS soc_code,
        w.AREA            AS lwda_code,
        -- Annual percentiles
        TRY_CAST(w.ANNWAGE10 AS NUMBER(10,0))  AS p10,
        TRY_CAST(w.ANNWAGE25 AS NUMBER(10,0))  AS p25,
        TRY_CAST(w.ANNWAGE50 AS NUMBER(10,0))  AS p50,
        TRY_CAST(w.ANNWAGE75 AS NUMBER(10,0))  AS p75,
        TRY_CAST(w.ANNWAGE90 AS NUMBER(10,0))  AS p90,
        -- Native hourly percentiles
        TRY_CAST(w.HRWAGE10 AS NUMBER(10,2))   AS p10_h,
        TRY_CAST(w.HRWAGE25 AS NUMBER(10,2))   AS p25_h,
        TRY_CAST(w.HRWAGE50 AS NUMBER(10,2))   AS p50_h,
        TRY_CAST(w.HRWAGE75 AS NUMBER(10,2))   AS p75_h,
        TRY_CAST(w.HRWAGE90 AS NUMBER(10,2))   AS p90_h,
        -- Employment
        TRY_CAST(w.EMPCOUNT AS NUMBER(10,0))    AS employment
    FROM WID_DB.WID.IOWAGE w
    JOIN iowage_vintage iv
      ON w.STFIPS = iv.STFIPS AND w.AREATYPE = iv.AREATYPE
     AND w.AREATYPEVERSION = iv.AREATYPEVERSION
    JOIN lwda_dim ld ON w.AREA = ld.lwda_code
    CROSS JOIN latest_oews_year ly
    WHERE w.STFIPS = '51'
      AND w.AREATYPE = '15'           -- LWDA
      AND w.PERIODYEAR = ly.yr
      AND LENGTH(TRIM(w.OCCCODE)) = 7
      AND w.OCCCODE NOT LIKE '%-0000'
),

-- ─── TOP-CODE REPAIR ─────────────────────────────────────────────────────────
-- BLS uses '#' sentinel for wages >= $239,200/yr (top-coded).
-- Rules:
--   • If p90 is NULL/0 AND p75 > $100,000 → set p90 = 239200
--   • If p75 is NULL/0 AND p50 > $100,000 → set p75 = 239200
--   • Same logic for hourly: threshold $115.00/hr (239200/2080 ≈ 115.00)
--   • If p90_h is NULL/0 AND p75_h > $50/hr → set p90_h = 115.00
--   • If p75_h is NULL/0 AND p50_h > $50/hr → set p75_h = 115.00

state_wages_repaired AS (
    SELECT
        soc_code, occ_name, employment,
        p10, p25, p50,
        -- Annual top-code repair
        CASE WHEN (p75 IS NULL OR p75 = 0) AND p50 > 100000 THEN 239200 ELSE p75 END AS p75,
        CASE WHEN (p90 IS NULL OR p90 = 0) AND COALESCE(p75, 0) > 100000 THEN 239200
             WHEN (p90 IS NULL OR p90 = 0) AND p50 > 100000 THEN 239200
             ELSE p90 END AS p90,
        p10_h, p25_h, p50_h,
        -- Hourly top-code repair
        CASE WHEN (p75_h IS NULL OR p75_h = 0) AND p50_h > 50.00 THEN 115.00 ELSE p75_h END AS p75_h,
        CASE WHEN (p90_h IS NULL OR p90_h = 0) AND COALESCE(p75_h, 0) > 50.00 THEN 115.00
             WHEN (p90_h IS NULL OR p90_h = 0) AND p50_h > 50.00 THEN 115.00
             ELSE p90_h END AS p90_h
    FROM state_wages
),

lwda_wages_repaired AS (
    SELECT
        soc_code, lwda_code, employment,
        p10, p25, p50,
        CASE WHEN (p75 IS NULL OR p75 = 0) AND p50 > 100000 THEN 239200 ELSE p75 END AS p75,
        CASE WHEN (p90 IS NULL OR p90 = 0) AND COALESCE(p75, 0) > 100000 THEN 239200
             WHEN (p90 IS NULL OR p90 = 0) AND p50 > 100000 THEN 239200
             ELSE p90 END AS p90,
        p10_h, p25_h, p50_h,
        CASE WHEN (p75_h IS NULL OR p75_h = 0) AND p50_h > 50.00 THEN 115.00 ELSE p75_h END AS p75_h,
        CASE WHEN (p90_h IS NULL OR p90_h = 0) AND COALESCE(p75_h, 0) > 50.00 THEN 115.00
             WHEN (p90_h IS NULL OR p90_h = 0) AND p50_h > 50.00 THEN 115.00
             ELSE p90_h END AS p90_h
    FROM lwda_wages
),

-- ─── O*NET ALTERNATE TITLES (aliases) ────────────────────────────────────────
-- Maps SOC-6 → array of alternate job titles for search/autocomplete.
-- Source: O*NET Alternate Titles file loaded into WID_DB.WID.ONET_TITLES
-- (columns: ONETSOC_CODE, TITLE, ALTERNATE_TITLE, SHORT_TITLE, SOURCES)
-- ONETSOC_CODE is "XX-XXXX.XX" (O*NET granularity); we group to SOC-6 "XX-XXXX".
onet_aliases AS (
    SELECT
        SUBSTRING(ONETSOC_CODE, 1, 7) AS soc_code,
        ARRAY_AGG(DISTINCT ALTERNATE_TITLE) WITHIN GROUP (ORDER BY ALTERNATE_TITLE) AS aliases
    FROM WID_DB.WID.ONET_TITLES
    WHERE ALTERNATE_TITLE IS NOT NULL
      AND ALTERNATE_TITLE != ''
    GROUP BY SUBSTRING(ONETSOC_CODE, 1, 7)
),

-- ─── OCCUPATION HIERARCHY (for major_group labels) ───────────────────────────
-- Derive major group from SOC structure: XX-0000 entries in IOWAGE are the
-- major group headers. We join on the 2-digit prefix.
major_groups AS (
    SELECT DISTINCT
        TRIM(OCCCODE) AS soc_code,
        OCCNAME AS major_group_name
    FROM WID_DB.WID.IOWAGE
    WHERE STFIPS = '51' AND AREATYPE = '01'
      AND OCCCODE LIKE '__-0000'
      AND PERIODYEAR = (SELECT yr FROM latest_oews_year)
),

-- ─── RESOLVE EACH (occupation, LWDA) CELL ────────────────────────────────────
-- provenance: 'lwda' if direct LWDA cell exists, 'statewide_fallback' if not
all_cells AS (
    -- Direct LWDA cells
    SELECT
        lw.soc_code,
        ld.lwda_id   AS area_id,
        ld.lwda_code,
        lw.p10, lw.p25, lw.p50, lw.p75, lw.p90,
        lw.p10_h, lw.p25_h, lw.p50_h, lw.p75_h, lw.p90_h,
        lw.employment,
        'lwda' AS provenance
    FROM lwda_wages_repaired lw
    JOIN lwda_dim ld ON lw.lwda_code = ld.lwda_code
    WHERE lw.p50 IS NOT NULL  -- suppress truly empty cells

    UNION ALL

    -- Statewide fallback for suppressed LWDA cells
    SELECT
        sw.soc_code,
        ld.lwda_id   AS area_id,
        ld.lwda_code,
        sw.p10, sw.p25, sw.p50, sw.p75, sw.p90,
        sw.p10_h, sw.p25_h, sw.p50_h, sw.p75_h, sw.p90_h,
        sw.employment,
        'statewide_fallback' AS provenance
    FROM state_wages_repaired sw
    CROSS JOIN lwda_dim ld
    WHERE NOT EXISTS (
        SELECT 1 FROM lwda_wages_repaired lw
        WHERE lw.soc_code = sw.soc_code
          AND lw.lwda_code = ld.lwda_code
          AND lw.p50 IS NOT NULL
    )

    UNION ALL

    -- Statewide row (always included as a native area)
    SELECT
        sw.soc_code,
        'virginia'   AS area_id,
        '000000'     AS lwda_code,  -- placeholder code for statewide
        sw.p10, sw.p25, sw.p50, sw.p75, sw.p90,
        sw.p10_h, sw.p25_h, sw.p50_h, sw.p75_h, sw.p90_h,
        sw.employment,
        'statewide' AS provenance
    FROM state_wages_repaired sw
),

-- ─── ASSEMBLE JSON: areas[] ──────────────────────────────────────────────────
areas_json AS (
    SELECT ARRAY_AGG(
        OBJECT_CONSTRUCT(
            'id', area_id,
            'label', area_label,
            'areatype', areatype
        )
    ) WITHIN GROUP (ORDER BY sort_key) AS areas
    FROM (
        -- 14 LWDAs
        SELECT lwda_id AS area_id, lwda_short_name AS area_label, '15' AS areatype, lwda_id AS sort_key
        FROM lwda_dim
        UNION ALL
        -- Statewide
        SELECT 'virginia', 'Virginia', '01', 'zzz-virginia'
    )
),

-- ─── ASSEMBLE JSON: jobs[] ───────────────────────────────────────────────────
-- Each job has nested areas object with wage data per area
job_areas AS (
    SELECT
        ac.soc_code,
        OBJECT_AGG(
            ac.area_id,
            OBJECT_CONSTRUCT(
                'p10', ac.p10, 'p25', ac.p25, 'p50', ac.p50, 'p75', ac.p75, 'p90', ac.p90,
                'p10_h', ac.p10_h, 'p25_h', ac.p25_h, 'p50_h', ac.p50_h, 'p75_h', ac.p75_h, 'p90_h', ac.p90_h,
                'employment', ac.employment,
                'provenance', ac.provenance
            )
        ) AS areas_obj
    FROM all_cells ac
    GROUP BY ac.soc_code
),

jobs_json AS (
    SELECT ARRAY_AGG(
        OBJECT_CONSTRUCT(
            'id', sw.soc_code,
            'soc_code', sw.soc_code,
            'label', sw.occ_name,
            'major_group', COALESCE(mg.major_group_name, 'Other'),
            'aliases', COALESCE(oa.aliases, ARRAY_CONSTRUCT()),
            'areas', ja.areas_obj
        )
    ) WITHIN GROUP (ORDER BY sw.soc_code) AS jobs
    FROM state_wages_repaired sw
    JOIN job_areas ja ON sw.soc_code = ja.soc_code
    LEFT JOIN major_groups mg ON SUBSTRING(sw.soc_code, 1, 2) || '-0000' = mg.soc_code
    LEFT JOIN onet_aliases oa ON sw.soc_code = oa.soc_code
)

-- ─── FINAL OUTPUT ────────────────────────────────────────────────────────────
SELECT OBJECT_CONSTRUCT(
    'meta', OBJECT_CONSTRUCT(
        'source', 'WID_DB.WID.IOWAGE + ONET_TITLES',
        'extracted_at', CURRENT_TIMESTAMP()::VARCHAR,
        'latest_year', (SELECT yr FROM latest_oews_year)
    ),
    'areas', (SELECT areas FROM areas_json),
    'jobs',  (SELECT jobs FROM jobs_json)
) AS wages_json;


-- =============================================================================
-- FILE 2: industries.json
-- =============================================================================
-- Shape: { meta, areas, sectors }
--   meta: { source, extracted_at, latest_year }
--   areas: [ { id, label } ]  — same 14 LWDAs + statewide Virginia
--   sectors: [ { naics, label, areas } ]
--     areas.{area_id}: { mean_wage, employment, establishments }
--
-- Uses QCEW data from WID_DB.WID.INDUSTRY at annual level (Period='00').
-- NAICS-2 codes are IndCode values like '11','21','22','23','31','42','44',
-- '48','51','52','53','54','55','56','61','62','71','72','81','92'.
-- INDUSTRY at AreaType='15' provides LWDA-level data directly.
-- =============================================================================

WITH
-- ─── VINTAGE ANCHORS ──────────────────────────────────────────────────────────
ind_vintage AS (
    SELECT STFIPS, AREATYPE, MAX(AREATYPEVERSION) AS AREATYPEVERSION
    FROM WID_DB.WID.INDUSTRY
    WHERE STFIPS = '51' AND AREATYPE IN ('01', '15')
    GROUP BY STFIPS, AREATYPE
),
geo_vintage AS (
    SELECT STFIPS, AREATYPE, MAX(AREATYPEVERSION) AS AREATYPEVERSION
    FROM WID_DB.WID.GEOGRAPHIES
    WHERE STFIPS = '51' AND AREATYPE = '15'
    GROUP BY STFIPS, AREATYPE
),

-- ─── LWDA DIMENSION ──────────────────────────────────────────────────────────
lwda_dim AS (
    SELECT
        g.AREA AS lwda_code,
        TRIM(REGEXP_REPLACE(
            REGEXP_REPLACE(g.AREANAME, '\\s*\\(LWDA\\s+[IVXLC]+\\)', ''),
            '\\s+Region$', ''
        )) AS lwda_short_name,
        LOWER(REGEXP_REPLACE(
            TRIM(REGEXP_REPLACE(
                REGEXP_REPLACE(g.AREANAME, '\\s*\\(LWDA\\s+[IVXLC]+\\)', ''),
                '\\s+Region$', ''
            )),
            '[^a-zA-Z0-9]+', '-'
        )) AS lwda_id
    FROM WID_DB.WID.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.STFIPS = gv.STFIPS AND g.AREATYPE = gv.AREATYPE
     AND g.AREATYPEVERSION = gv.AREATYPEVERSION
    WHERE g.STFIPS = '51' AND g.AREATYPE = '15'
      AND g.AREANAME NOT LIKE '%Combined%'
),

-- ─── LATEST ANNUAL PERIOD IN INDUSTRY ────────────────────────────────────────
latest_ind_year AS (
    SELECT MAX(PERIODYEAR) AS yr
    FROM WID_DB.WID.INDUSTRY
    WHERE STFIPS = '51' AND AREATYPE = '01' AND PERIODTYPE = '01'  -- Annual
),

-- ─── NAICS-2 SECTOR LABELS ──────────────────────────────────────────────────
-- Standard 2-digit NAICS sectors
naics_sectors AS (
    SELECT * FROM (VALUES
        ('11', 'Agriculture, Forestry, Fishing & Hunting'),
        ('21', 'Mining, Quarrying & Oil/Gas Extraction'),
        ('22', 'Utilities'),
        ('23', 'Construction'),
        ('31', 'Manufacturing'),       -- 31-33 combined under '31'
        ('42', 'Wholesale Trade'),
        ('44', 'Retail Trade'),         -- 44-45 combined under '44'
        ('48', 'Transportation & Warehousing'), -- 48-49 combined under '48'
        ('51', 'Information'),
        ('52', 'Finance & Insurance'),
        ('53', 'Real Estate & Rental/Leasing'),
        ('54', 'Professional, Scientific & Technical'),
        ('55', 'Management of Companies'),
        ('56', 'Administrative & Support/Waste Mgmt'),
        ('61', 'Educational Services'),
        ('62', 'Health Care & Social Assistance'),
        ('71', 'Arts, Entertainment & Recreation'),
        ('72', 'Accommodation & Food Services'),
        ('81', 'Other Services (except Public Admin)'),
        ('92', 'Public Administration')
    ) AS t(naics_code, sector_name)
),

-- ─── QCEW DATA: STATEWIDE ───────────────────────────────────────────────────
-- Annual data (Period='00' or PeriodType='01') at AreaType='01'
-- Ownership='00' or '50' = all/private (depends on WID encoding)
state_qcew AS (
    SELECT
        TRIM(i.INDCODE)                           AS naics_code,
        TRY_CAST(i.AVGANNPAY AS NUMBER(10,0))     AS mean_wage,
        TRY_CAST(i.ANNUALAVGEMP AS NUMBER(10,0))  AS employment,
        TRY_CAST(i.ANNUALAVGEST AS NUMBER(10,0))  AS establishments
    FROM WID_DB.WID.INDUSTRY i
    JOIN ind_vintage iv
      ON i.STFIPS = iv.STFIPS AND i.AREATYPE = iv.AREATYPE
     AND i.AREATYPEVERSION = iv.AREATYPEVERSION
    CROSS JOIN latest_ind_year ly
    WHERE i.STFIPS = '51'
      AND i.AREATYPE = '01'
      AND i.PERIODYEAR = ly.yr
      AND i.PERIODTYPE = '01'     -- Annual
      AND i.OWNERSHIP IN ('0', '00', '50')  -- Total or Private
      AND TRIM(i.INDCODE) IN (SELECT naics_code FROM naics_sectors)
),

-- ─── QCEW DATA: PER LWDA ────────────────────────────────────────────────────
lwda_qcew AS (
    SELECT
        ld.lwda_id,
        TRIM(i.INDCODE)                           AS naics_code,
        TRY_CAST(i.AVGANNPAY AS NUMBER(10,0))     AS mean_wage,
        TRY_CAST(i.ANNUALAVGEMP AS NUMBER(10,0))  AS employment,
        TRY_CAST(i.ANNUALAVGEST AS NUMBER(10,0))  AS establishments
    FROM WID_DB.WID.INDUSTRY i
    JOIN ind_vintage iv
      ON i.STFIPS = iv.STFIPS AND i.AREATYPE = iv.AREATYPE
     AND i.AREATYPEVERSION = iv.AREATYPEVERSION
    JOIN lwda_dim ld ON i.AREA = ld.lwda_code
    CROSS JOIN latest_ind_year ly
    WHERE i.STFIPS = '51'
      AND i.AREATYPE = '15'
      AND i.PERIODYEAR = ly.yr
      AND i.PERIODTYPE = '01'     -- Annual
      AND i.OWNERSHIP IN ('0', '00', '50')
      AND TRIM(i.INDCODE) IN (SELECT naics_code FROM naics_sectors)
),

-- ─── COMBINE ALL CELLS ───────────────────────────────────────────────────────
all_industry_cells AS (
    -- LWDA cells
    SELECT lwda_id AS area_id, naics_code, mean_wage, employment, establishments
    FROM lwda_qcew

    UNION ALL

    -- Statewide cells
    SELECT 'virginia' AS area_id, naics_code, mean_wage, employment, establishments
    FROM state_qcew
),

-- ─── ASSEMBLE JSON: sectors[] ────────────────────────────────────────────────
sector_areas AS (
    SELECT
        ns.naics_code,
        ns.sector_name,
        OBJECT_AGG(
            aic.area_id,
            OBJECT_CONSTRUCT(
                'mean_wage', aic.mean_wage,
                'employment', aic.employment,
                'establishments', aic.establishments
            )
        ) AS areas_obj
    FROM naics_sectors ns
    JOIN all_industry_cells aic ON ns.naics_code = aic.naics_code
    GROUP BY ns.naics_code, ns.sector_name
),

-- ─── AREAS ARRAY ─────────────────────────────────────────────────────────────
areas_json AS (
    SELECT ARRAY_AGG(
        OBJECT_CONSTRUCT('id', area_id, 'label', area_label)
    ) WITHIN GROUP (ORDER BY sort_key) AS areas
    FROM (
        SELECT lwda_id AS area_id, lwda_short_name AS area_label, lwda_id AS sort_key
        FROM lwda_dim
        UNION ALL
        SELECT 'virginia', 'Virginia', 'zzz-virginia'
    )
)

-- ─── FINAL OUTPUT ────────────────────────────────────────────────────────────
SELECT OBJECT_CONSTRUCT(
    'meta', OBJECT_CONSTRUCT(
        'source', 'WID_DB.WID.INDUSTRY (QCEW)',
        'extracted_at', CURRENT_TIMESTAMP()::VARCHAR,
        'latest_year', (SELECT yr FROM latest_ind_year)
    ),
    'areas', (SELECT areas FROM areas_json),
    'sectors', (SELECT ARRAY_AGG(
        OBJECT_CONSTRUCT(
            'naics', naics_code,
            'label', sector_name,
            'areas', areas_obj
        )
    ) WITHIN GROUP (ORDER BY naics_code) FROM sector_areas)
) AS industries_json;
