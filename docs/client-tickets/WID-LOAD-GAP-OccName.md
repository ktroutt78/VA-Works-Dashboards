# WID 3.0 Load Gap — Missing `OccName` column / `OCCUPATIONS` table

**Filed:** 2026-06-05
**Source artifact:** `queries/employer_wage_tool_mssql_validate.sql` Probe 1 (INFORMATION_SCHEMA inventory)
**Consuming query:** `queries/employer_wage_tool_mssql_RUN.sql` (state_wages + lwda_wages CTEs, final SELECT)

## Issue

The `WID.dbo.IOWAGE` table in this WID 3.0 deployment does not expose
occupation names. The `OccName` column (or any equivalent text label
column) is absent from `IOWAGE`, and the standard companion dimension
table `OCCUPATIONS` is not present in the WID schema at all.

## BLS source column

BLS OEWS (Occupational Employment and Wage Statistics) publishes
**occupation titles** as a first-class field alongside wage percentiles.
In BLS OEWS CSV downloads the title field is published as `occ_title`
(e.g. "Chief Executives" for SOC code `11-1011`).

BLS also maintains the **Standard Occupational Classification (SOC)
structure** as a publicly-downloadable reference file mapping every SOC
code at every aggregation level (major, minor, broad, detail) to a
canonical title. See:

- BLS OEWS Data Files: https://www.bls.gov/oes/tables.htm
- BLS SOC 2018 Structure: https://www.bls.gov/soc/2018/soc_structure_2018.xlsx

## WID 3.0 spec reference

The BLS Workforce Information Database (WID) 3.0 standard, maintained by
the Projections Managing Partnership / LMI Institute, defines:

- An **`OccName`** column on `IOWAGE` rows (or)
- A standalone **`OCCUPATIONS`** dimension table joined to `IOWAGE.OccCode`

This deployment of WID 3.0 includes neither. The `OccCodeType` column
exists on `IOWAGE`, suggesting the load was intended to support multiple
occupation classification systems (SOC, O*NET-SOC, etc.), but the actual
title strings are not stored alongside the codes nor in a companion table.

## Observed state (Virginia WID 3.0, 2026-06-05)

**`WID.dbo.IOWAGE` columns** (per `INFORMATION_SCHEMA.COLUMNS`):

```
StFips, AreaType, AreaTypeVersion, Area, PeriodYear, PeriodType, Period,
IndCodeType, IndCode, OccCodeType, OccCode, WageSource, EmpCount, RateType,
ResponseRate, MeanWage, EntryWage, ExperiencedWage,
Percentile10Wage, Percentile25Wage, MedianWage, Percentile75Wage,
Percentile90Wage, UserDefinedPct, UserDefinedPctWage, UserDefinedRangeLoPct,
UserDefinedRangeHiPct, UserDefinedRangeMean, WageRelativePctError,
EmpRelativePctError, PanelCode, SuppressWage, SuppressAll, SuppressEmp
```

No `OccName`, `OccTitle`, `OccupationName`, `JobTitle`, or any text label.

**Tables in `WID` database:**

```
Geographies, Industry, IOWage, LaborForce, SubGeographies
```

No `Occupations`, no `OccupationCodes`, no `SOC_Structure`, no ONET_TITLES.

## Current workaround in `_RUN.sql`

1. **Per-occupation label** defaults to the SOC code itself:

   ```sql
   STUFF(sw.soc_code, 3, 0, '-')            AS label        -- placeholder; OccName not in WID load
   ```

   This produces JSON like `"label":"11-1011"` instead of
   `"label":"Chief Executives"`.

2. **Major-group labels** are hardcoded as a 23-row `VALUES` lookup of the
   BLS SOC structure inside the query itself:

   ```sql
   major_groups AS (
       SELECT * FROM (VALUES
           ('11-0000', 'Management Occupations'),
           ('13-0000', 'Business and Financial Operations'),
           …23 rows…
       ) AS t(mg_code, major_group_name)
   ),
   ```

   This is in the query because it's small and stable. Detail-level SOC-6
   titles (~800 occupations) are NOT hardcoded — that would belong in a
   reference table, which is what's missing.

## Business impact

**Functional:** The Employer Wage Tool UI currently displays SOC codes
(e.g. "11-1011") where it should display human-readable occupation titles
(e.g. "Chief Executives"). Users have to either memorize SOC codes or
cross-reference the BLS SOC structure separately.

This is the most user-visible WID load gap — every occupation row in the
UI shows a meaningless 7-character code instead of its title.

**Risk:**
- **Tool unusable for non-specialist audiences.** Most employers and HR
  staff don't recognize SOC codes. The tool's "browse occupations"
  affordance becomes nearly useless without titles.
- **Search/autocomplete won't work.** A user searching for "accountant"
  can't find SOC 13-2011 because the row has no title to match against.
  This blocks one of the tool's primary intended interactions.
- **Aliases also blocked.** The O*NET Alternate Titles reference (used
  for synonym matching — e.g. "Accountant" → 13-2011 → "Auditor", "CPA",
  "Tax Accountant") cannot be wired up because the alternate-titles
  table also isn't loaded (`WID.dbo.ONET_TITLES` doesn't exist).

## Requested action

Either of the following resolves this gap:

1. **Preferred:** Load the standard BLS SOC structure reference as
   `WID.dbo.OCCUPATIONS` with columns `(OccCodeType, OccCode, OccName)`.
   Source: https://www.bls.gov/soc/2018/soc_structure_2018.xlsx.
   This also enables future joins against O*NET Alternate Titles when
   that table is loaded.

2. **Alternative:** Denormalize `OccName` as a column on `IOWAGE` rows
   during the WID load (BLS OEWS source files include `occ_title` on
   every record, so it's available at load time).

Once available, `_RUN.sql` can JOIN on `OccCode` and the per-occupation
`label` will populate with real titles instead of SOC codes.

## Related

- Sister ticket: `WID-LOAD-GAP-AvgAnnualPay.md` (parallel issue on
  INDUSTRY side).
- Discovery query: `queries/employer_wage_tool_mssql_validate.sql` Probe 1.
- The O*NET aliases CTE in `_RUN.sql` is commented out pending this same
  reference data being loaded.
