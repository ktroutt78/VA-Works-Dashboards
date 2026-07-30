# Wage Comparison Tool

> **Living document.** Any change to the SQL in `queries/wage_comparison_tool_mssql_RUN.sql` (or the `_validate.sql` companion) must be reflected here — especially the join keys, the Validation Status table, and the unit-test SELECTs. Treat the Validation Status table as the source of truth for what has been verified against the live WID server.

---

## Part 1 — Overview

### What this tool does

The **Wage Comparison Tool** (`apps/wage-tool/`) lets a Virginia worker compare their salary against the market for one or two occupations in a chosen area. The user types a job (alias-aware search across O*NET alternate titles), picks an area (one of 11 MSAs or "Virginia statewide"), and optionally enters their salary. The tool renders:

- A **percentile band** (p10–p90) per occupation × area, with the user's salary positioned on the band.
- A **wage trend sparkline** — annual median wage over the last 4–5 OEWS years.
- An **employment sparkline** — 24 months of estimated employment, seasonally shaped.

Two UI variants ship side by side (`wage-tool.html` and `wage-tool-hero.html`) pending a stakeholder decision; both consume the same two JSON files and both received the id-migration changes described below.

### Where the data comes from

As of 2026-07-07 the data source is the **WID 3.0 SQL Server** (read-only Azure SQL instance hosted by VEC), replacing the original Snowflake/Cortex Code export. A scheduled job runs the two queries in `queries/wage_comparison_tool_mssql_RUN.sql`, captures each `FOR JSON PATH` result as a static `.json` file, and deploys alongside the HTML:

```
WID 3.0 SQL Server  ──►  RUN.sql (2 queries)  ──►  2 JSON files            ──►  ECharts (browser)
(authoritative           (scheduled refresh,       wages.json                   (percentile bands,
 BLS source data)         read-only)               employment_trend.json         sparklines, search)
```

Same JSON-on-disk architecture as the Employer Wage Tool and Front Page Dashboard: load-time performance, public-facing resilience, refresh cadence decoupled from traffic. There is **no elevated setup step** — MSA codes and labels come live from `WID.dbo.GEOGRAPHIES` on every refresh.

### Geography model (client decisions, 2026-07-07)

| Decision | Value |
|---|---|
| Area grain | **MSAs** — `AreaType='31'` exactly (never '32' Micropolitan, '33' Metro Division, '34' CSA) — plus statewide (`AreaType='01'`, `Area='000000'`) |
| Area identity | `area.id` = 6-digit `GEOGRAPHIES.Area` code. No synthetic slugs (project dimension-derived-labels standard). Front-end finds statewide via `area.areatype === '01'` |
| OMB vintages | Two delineation vintages per MSA (`AreaTypeVersion` `'2001'`, `'2301'`) with differing names AND definitions. Labels pin `MAX(AreaTypeVersion)` per Area — each MSA appears once, under its current name |
| State-part rows | `Area LIKE 'S%'` (e.g. `S47900` Washington "VA Part") are a different grain — **excluded** |
| Multi-state MSAs | **Included** as whole MSAs (Washington DC-VA-MD-WV, Virginia Beach VA-NC, Winchester VA-WV, Kingsport-Bristol TN-VA). Figures span state lines |
| Target year | **2024, pinned literal** — richest IOWAGE MSA year (874 occs / 41,858 rows); 2025 is partial/preliminary. Roll forward by editing the ONE literal in each query's `target_year` CTE and re-running validate P3 |
| Trend years | Data-derived, ≤5 years ending at the pin. **IOWAGE has no 2022 MSA rows**, so `trend_years = [2021,2023,2024]`; a 2022 backfill would flow through automatically |

### Migration notes (Snowflake → SQL Server)

- **Area ids changed** from hand-made slugs (`blacksburg-christiansburg`) to 6-digit codes (`047260`). The `employment_trend.json` key contract (`<soc>__<areaId>`) moved in lockstep. Both HTML variants updated: statewide is now resolved from `areatype === '01'` (legacy `'virginia'` slug retained only as a fallback for `wages.example.json`).
- The old export's junk rows (`"none"` area; duplicate Virginia Beach under both OMB vintages) are eliminated at the source by the vintage pin — the front-end's `cleanAreas()` dedupe remains as a harmless guard.
- **Area set changed**: 11 IOWAGE MSAs (including Washington DC-VA-MD-WV, newly available) vs the old export's 9 + statewide. (An early probe reported "15 MSAs" — that count was unscoped and included the 4 `S%` state-part rows; the VA-scoped whole-MSA count is 11, confirmed by validate P2/P3/P6.)
- **Aliases upgraded**: now a pure-SQL join to `WID.dbo.ONETAlternativeTitles` (the real O*NET alternate-titles crosswalk, 57,543 rows) instead of the Snowflake-era enrichment. The `data/raw/onet_alternate_titles.txt` file is no longer part of the pipeline.
- **Employment sparkline weighting upgraded**: each area's own monthly labor-force seasonality (LABORFORCE has full monthly MSA series), rather than the statewide curve applied to every area.

---

## Part 2 — The two files

### Q1 — `wages.json`

```
{ meta:  { source, extracted_at, latest_year, trend_years[] },
  areas: [ {id, label, areatype} ],                      // 11 MSAs ('31') + statewide ('01'), statewide sorts last
  jobs:  [ {id, soc_code, label, major_group, aliases[], areas{}} ] }

jobs[].areas — keyed object:
  { "<area_code>": { p10, p25, p50, p75, p90, employment, trend[] }, ... }
  trend[] = annual MEDIAN (p50) aligned index-for-index to meta.trend_years; null-padded.
```

- A (soc, area) cell is emitted **only** when it has a publishable (`SuppressWage='0'`) p50 at the target year. No statewide-fallback synthesis in SQL — the front-end handles missing cells.
- Top-code repair mirrors the employer tool: p75/p90 NULL/0 alongside a >$100K lower percentile → $239,200 (annual cap).
- SOC-6 detail occupations only; labels live from `SOCCodes` (`SOCCodeType='19'` pin); major groups = SOC rows `__0000`.

### Q2 — `employment_trend.json`

```
{ meta:   { source, extracted_at, months[], notes },     // 24 months "YYYY-MM": (target_year-1)..target_year
  trends: { "<soc-hyphenated>__<area_code>": [24 × int|null], ... } }
```

Methodology: annual `IOWAGE.EmpCount` for each (soc, area, year) is distributed across that year's months by the area's own labor-force seasonal weight — `LaborForce(area,yr,mo) / AVG month LaborForce(area,yr)` from unadjusted (`Adjusted='0'`) monthly (`PeriodType='03'`) LABORFORCE rows. Missing inputs emit `null` at the correct index. Keys exist only for pairs with EmpCount in ≥1 window year; the front-end falls back to the statewide series otherwise.

**Statewide-curve fallback**: LAUS files each MSA's monthly series under its *primary* state's StFips, so Kingsport-Bristol (TN-homed) and Washington (DC-homed) have no `StFips='51'` monthly rows. For those two areas the series `COALESCE`s to the statewide seasonal weight — the employment *level* is still the MSA's own IOWAGE count; only the monthly *shape* borrows the state curve (the original Snowflake export applied the state curve to every area). Without this, those areas emitted all-null series, which the front-end treats as present-but-empty local data instead of falling back to statewide. Found and fixed on the first real export (2026-07-07).

---

## Part 3 — Data model (join keys)

```
IOWAGE (fact — OEWS wages)
  StFips='51', AreaType IN ('01','31'), Area, AreaTypeVersion, PeriodYear,
  OccCode (SOC-6, hyphen-tolerant), RateType='4' (annual), IndCodeType='10',
  IndCode='000000', Percentile10/25/75/90Wage, MedianWage, EmpCount,
  SuppressWage, SuppressEmp
    │  vintage anchor: MAX(AreaTypeVersion) per (AreaType, Area, PeriodYear)
    │  — per-YEAR, not per-Area: early trend years may sit under OMB '2001'
    │
    ├── GEOGRAPHIES (dim — labels)      ON Area          @ MAX(AreaTypeVersion) per Area, AreaType='31', Area NOT LIKE 'S%'
    ├── SOCCodes (dim — titles)         ON SOC-6         @ SOCCodeType='19' (pinned literal)
    ├── ONETAlternativeTitles (dim)     ON LEFT(ONETCode,6) = SOC-6   @ ONETCodeType='12' (pinned literal)
    │     SEARCH-ONLY: joined to the post-aggregation jobs list, NEVER into wage aggregation
    │     (alias fanout would inflate every wage metric)
    └── LABORFORCE (fact — monthly LF)  ON (Area, PeriodYear[, Period])  @ PeriodType='03', Adjusted='0',
          same per-year vintage anchor; bounded to the 11 IOWAGE MSAs by the pairs join
```

Statewide anchor: `Area='000000'` (the `'000051'` GEOGRAPHIES row is a phantom dup — employer-tool Probe 12).

---

## Part 4 — Validation Status

| # | Assumption | Status | Evidence |
|---|---|---|---|
| P1 | MSA = `AreaType '31'` (AREATYPES dim) | ✅ CONFIRMED 2026-07-07 (client probe) | '31' = Metropolitan Statistical Area |
| P2 | Dual OMB vintages `'2001'`/`'2301'`; `'S%'` state-part rows | ✅ CONFIRMED 2026-07-07 (client probe) | Names/definitions differ per vintage |
| P3 | IOWAGE MSA grain: 11 whole MSAs; years {2021,2023,2024,2025} — **no 2022**; 2024 richest | ✅ CONFIRMED 2026-07-07 (first run) | 874 occs / 41,858 rows in 2024; 2025 partial (764 occs) |
| P3b | Year↔vintage matrix in IOWAGE | ✅ CONFIRMED 2026-07-07 (first run) — **anchor is load-bearing** | 2021/2023 → `'2001'`; 2024/2025 → `'2301'`. Per-Area MAX would have dropped 2021+2023 from the trend; keep the per-(Area, PeriodYear) anchor |
| P4 | `ONETAlternativeTitles`: 57,543 rows, `ONETCodeType='12'`, 8-digit unpunctuated `ONETCode`, `ONETJobTitle` populated | ✅ CONFIRMED 2026-07-07 (first run) | len(ONETCode)=8 exactly, 0 null titles; supersedes the employer doc's "crosswalk not loaded" note |
| P5 | LABORFORCE monthly MSA series: `PeriodType='03'`, 12 periods | ✅ CONFIRMED 2026-07-07 (first run), **with correction** | 12 MSAs at StFips 51, 2010–2026 — but LAUS homes each MSA under its primary state, so Kingsport-Bristol (TN) and Washington (DC) have no StFips-51 monthly rows. Q2 uses the statewide seasonal curve for those two (P5b matrix) |
| P6 | Every IOWAGE '31' area resolves to a GEOGRAPHIES label | ✅ CONFIRMED 2026-07-07 (first run) | 0 unresolved rows; code-as-label fallback should never fire |
| P7 | Statewide IOWAGE rows exclusively `Area='000000'` in the scan window | ✅ CONFIRMED 2026-07-07 (first run) | 231,736 rows, only `000000` |
| P8 | Post-run JSON smoke tests | ⚠️ Run after each refresh | See `_validate.sql` P8 checklist |

### P8 spot-check anchors (post-run)

1. `areas[]` = 12 entries (11 MSAs + statewide); exactly one Virginia Beach row named "Virginia Beach-Chesapeake-Norfolk" (the '2301' name); no `S`-prefixed id; no label equal to its id.
2. `meta.latest_year` = 2024; `meta.trend_years` = `[2021,2023,2024]` (2022 absent from IOWAGE — a 2022 entry means a backfill landed).
3. Jobs count near 874; SOC 29-1141 (Registered Nurses) has "RN"-style aliases.
4. `employment_trend.json` months = `2023-01`…`2024-12` (24); every trends key matches `^\d{2}-\d{4}__\d{6}$`; every referenced area id exists in `wages.json` areas.

---

## Part 5 — Unit-test validation SQL

```sql
-- T1: one label per MSA after the vintage pin (expect n_rows = n_areas)
SELECT COUNT(*) AS n_rows, COUNT(DISTINCT g.Area) AS n_areas
FROM WID.dbo.GEOGRAPHIES g
JOIN (SELECT Area, MAX(AreaTypeVersion) v FROM WID.dbo.GEOGRAPHIES
      WHERE StFips='51' AND AreaType='31' AND Area NOT LIKE 'S%' GROUP BY Area) mx
  ON mx.Area = g.Area AND mx.v = g.AreaTypeVersion
WHERE g.StFips='51' AND g.AreaType='31' AND g.Area NOT LIKE 'S%';

-- T2: alias index never inflates wages — cell count with vs without the alias join must match
--     (structural guarantee: onet_aliases joins post-aggregation; this catches regressions)
SELECT COUNT(*) FROM WID.dbo.IOWAGE w
WHERE w.StFips='51' AND w.AreaType='31' AND w.Area NOT LIKE 'S%'
  AND w.PeriodYear=2024 AND w.RateType='4'
  AND w.IndCodeType='10' AND w.IndCode='000000';
-- rerun any wage aggregate CTE with/without the alias JOIN — counts must be identical.

-- T3: seasonal weights average to ~1.0 per (area, year) — expect every row ≈ 1.0
SELECT Area, PeriodYear, AVG(TRY_CAST(LaborForce AS FLOAT))
       / NULLIF(AVG(AVG(TRY_CAST(LaborForce AS FLOAT))) OVER (PARTITION BY Area, PeriodYear),0) AS should_be_1
FROM WID.dbo.LABORFORCE
WHERE StFips='51' AND AreaType='31' AND PeriodType='03' AND Adjusted='0'
  AND PeriodYear IN (2023,2024)
GROUP BY Area, PeriodYear;
```

---

## Part 6 — Refresh cadence & roll-forward

| Source | Update frequency | Driving release |
|---|---|---|
| IOWAGE (Q1 wages + Q2 employment levels) | Annual | BLS OEWS release (~5 months after reference year) |
| LABORFORCE (Q2 monthly weights) | Monthly, but only consumed for the 24-month pinned window | BLS LAUS |

**Roll-forward checklist** (when a new OEWS year finalizes):
1. Update the `target_year` literal in **both** queries of `RUN.sql`.
2. Re-run validate P3/P3b (coverage + vintage matrix for the new year).
3. Run RUN.sql, capture both JSON files, run the P8 smoke tests.
4. Update this document's Validation Status table.

---

## Part 7 — Embedded in the WordPress demo ("I'm a Job Seeker" page)

This tool is embedded via `<iframe>` on the WordPress theme's job-seeker page
(`apps/va-works-wp-theme/page-im-a-job-seeker.php`), below the action-link grid.
The iframe `src` is the single `VA_WAGE_TOOL_URL` constant (`functions.php`),
default `http://localhost:8124/wage-tool.html`; repoint there or override in
`wp-config.php`. The iframe height is fixed to fit a **two-job comparison** (the
tool's core use); adding a third+ comparison job scrolls inside the frame.

**⚠ Fix before this page is client-facing — chart-manifest flag C6.** A literal
`0` can pass the `p50 IS NOT NULL` gate in Q1, and the front end currently
compensates with a render-time **cascade-clamp** so the broken cell doesn't draw
a zero-width band. That is a presentation-layer patch over a data defect: the
`0` should be suppressed/repaired at the **SQL level** (the p50 gate should
reject non-publishable `0`s, not just `NULL`s), not relied on the client to hide.
Until then the embedded tool can surface clamped cells. Not addressed in this
pass — logged here so it is fixed at source before the page goes public.
