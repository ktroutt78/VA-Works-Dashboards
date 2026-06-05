-- =============================================================================
-- EMPLOYER WAGE TOOL — one-time DDL + seed for dbo.LWDA_Slugs
-- =============================================================================
-- Requires WRITE access (the scheduled-job account is read-only by design —
-- see [[sqlserver_data_pipeline]]). Run once with elevated creds; afterward
-- _RUN.sql joins to this table on every refresh via the lwda_dim CTE
-- (GEOGRAPHIES + dbo.LWDA_Slugs, 4-col composite identity at the LWDA boundary).
--
-- WHY a physical table instead of a CTE: the slug → display-label → JSON id
-- mapping is the UI contract. Putting it in version-controlled DDL gives ops
-- a single place to audit the mapping, makes the join key (lwda_code +
-- AreaTypeVersion) explicit, and survives query rewrites.
--
-- VALUES BELOW are populated from _validate.sql Probe 2 results (verified
-- against VA WID 3.0 on 2026-06-05). Slugs match
-- apps/wage-tool-employer/data/wages.json + industries.json exactly.
-- If you re-run Probe 2 against a newer GEOGRAPHIES vintage, update
-- AreaTypeVersion across all 14 rows AND re-verify the lwda_code values.
-- =============================================================================

IF OBJECT_ID('dbo.LWDA_Slugs', 'U') IS NOT NULL
    DROP TABLE dbo.LWDA_Slugs;
GO

CREATE TABLE dbo.LWDA_Slugs (
    lwda_code         VARCHAR(10)   NOT NULL,
    lwda_id           VARCHAR(80)   NOT NULL,   -- JSON slug; UI's area.id key
    lwda_label        NVARCHAR(120) NOT NULL,   -- human display label
    AreaTypeVersion   VARCHAR(10)   NOT NULL,   -- pin to a specific vintage
    CONSTRAINT PK_LWDA_Slugs PRIMARY KEY (lwda_code, AreaTypeVersion)
);
GO

-- 14 Virginia LWDAs at GEOGRAPHIES.AreaTypeVersion='0002' (current vintage).
-- Synthetic "Combined Projections Area (LWDA XI and XII)" at code 000491 and
-- the legacy-only Greater Peninsula at 000454 are intentionally excluded.
-- Roman numerals appear in the comments only — they're the LWDA designation
-- in the source AreaName but not a sort key.
INSERT INTO dbo.LWDA_Slugs (lwda_code, lwda_id, lwda_label, AreaTypeVersion) VALUES
    ('000441', 'southwest',            'Southwest',             '0002'),  -- LWDA I
    ('000442', 'new-river-mt-rogers',  'New River/Mt. Rogers',  '0002'),  -- LWDA II
    ('000443', 'greater-roanoke',      'Greater Roanoke',       '0002'),  -- LWDA III
    ('000444', 'shenandoah-valley',    'Shenandoah Valley',     '0002'),  -- LWDA IV
    ('000455', 'crater',               'Crater',                '0002'),  -- LWDA V
    ('000446', 'piedmont',             'Piedmont',              '0002'),  -- LWDA VI
    ('000447', 'central',              'Central',               '0002'),  -- LWDA VII
    ('000448', 'south-central',        'South Central',         '0002'),  -- LWDA VIII
    ('000449', 'capital',              'Capital',               '0002'),  -- LWDA IX
    ('000457', 'west-piedmont',        'West Piedmont',         '0002'),  -- LWDA X
    ('000451', 'northern',             'Northern',              '0002'),  -- LWDA XI
    ('000452', 'alexandria-arlington', 'Alexandria/Arlington',  '0002'),  -- LWDA XII
    ('000453', 'bay-consortium',       'Bay Consortium',        '0002'),  -- LWDA XIII
    ('000456', 'hampton-roads',        'Hampton Roads',         '0002');  -- LWDA XIV
GO

-- Sanity check — should return 14 rows
SELECT lwda_code, lwda_id, lwda_label, AreaTypeVersion
FROM dbo.LWDA_Slugs
ORDER BY lwda_id;
GO
