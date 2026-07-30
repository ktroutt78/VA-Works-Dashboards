# Chart Data Manifest — Virginia Works visualizations

**Purpose.** One row per chart across all four front-end apps, mapping each visualization to the JSON artifact it reads, the SQL that produces that artifact, and the underlying WID tables/columns. Built by reading each app's chart configs and reconciling against `queries/*.sql` and `docs/handover/*.md`. This is the input spec for scheduled stored procedures: the **Artifact inventory** below is what a DBA needs to produce.

**Compiled:** 2026-07-29. Documentation only — no app code was changed. Verify against the live WID after any reload.

### Legend

**Query shorthand** (all under `queries/`):
- **CP-RUN** = `community_profiles_mssql_RUN.sql` → emits one blob → `apps/community-profiles/data/profiles.json`
- **LMD-RUN** = `labor_market_dashboard_mssql_RUN_v8.sql` → Q1 `employment_by_locality.json`, Q2 `unemployment_trend.json`, Q3 `jobs_by_industry.json`
- **WCT-RUN** = `wage_comparison_tool_mssql_RUN.sql` → Q1 `wages.json`, Q2 `employment_trend.json`
- **EWT-RUN** = `employer_wage_tool_mssql_RUN.sql` → Q1 `wages.json`, Q2 `industries.json`

**Status values:**
- **real** — chart is driven by real WID data via a scheduled query today.
- **real (grain-limited)** — real at some geography grains, falls back to mock at others (noted).
- **representative** — plausible values shaped to look real, not from a live query; may already sit in a JSON artifact.
- **mock** — deterministic in-browser generator (`genData()`), never from a query.
- **held / deferred / dead** — not currently rendered.

---

## Master table (one row per chart)

| app | section | chart id | chart title | type | artifact file / field | source query | source tables / columns | geo grain | cadence | suppression | status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| front-page | Unemployment by Locality | `map-cell` | Unemployment Rate by Locality | choropleth map | `employment_by_locality.json` → `.counties[].{fips,unemployed_rate,labor_force,employed,region}` | LMD-RUN Q1 | `LABORFORCE` UnemployedRate/Employed/LaborForce (AreaType=04, PeriodType=03, Adjusted=0) + GEOGRAPHIES/SUBGEOGRAPHIES for region | county/city (133) | monthly | null rate → gray fill; NSA at county | real (deployed file predates v8 labels — see churn flags) |
| front-page | Unemployment by Locality | `kpi-va-value`,`kpi-us-value` | Virginia / U.S. rate + MoM delta | KPI tiles | `employment_by_locality.json` → `.kpi.{virginia,us_average}.{value,delta_pts}`, `.as_of` | LMD-RUN Q1 | `LABORFORCE` AreaType=01 Adjusted=1 (VA); SUM over states, HAVING COUNT>=50 (US) | VA statewide / US national (SA) | monthly | `delta_pts` 0.0 in deploy | real (delta not yet populated) |
| front-page | Unemployment by Locality | `kpi-county-value` | Selected county rate vs VA | KPI tile | derived: `.counties[].unemployed_rate` − `.kpi.virginia.value` | LMD-RUN Q1 | same as map | county | monthly | hidden until select | real |
| front-page | Unemployment Rate Trending | `line-cell` | Unemployment Rate Trending | line | `unemployment_trend.json` → `.months`, `.series.virginia`, `.series.us_national`, `.counties[].data` | LMD-RUN Q2 | `LABORFORCE` monthly UnemployedRate (VA 01/Adj1; US aggregate; county 04/Adj0; PeriodType=03) | VA + US + per-county | monthly (36-mo window) | `null` at 2025-10; `connectNulls:false` | real (predates v8 labels; county series is raw NSA LAUS, not smoothed; see C1) |
| front-page | Jobs Added by Industry | `bar-cell` | Jobs Added by Industry | horizontal bar | `jobs_by_industry.json` → `.statewide[]` / `.regions[].sectors[]` `{sector,jobs_added}` | LMD-RUN Q3 | `INDUSTRY` QuarterAvgEmp (PeriodType=02); private supersectors IndCode 1011–1027 Own=50 + Gov rollup; labels `NAICSSuperSectors.SuperTitle`; `jobs_added` = LAG(qtr) delta; top-5 by ROW_NUMBER | statewide + 14 LWDA | quarterly | negative bars styled; COALESCE→0 | real (predates v8 labels, no Gov in statewide top-5; region→statewide reconciles; see C1) |
| community-profiles | Hero | `vamap` | Community Profile region map | interactive choropleth | CDN `us-atlas counties-10m.json` + `profiles.json` `regions.lwda[].fips` (else hardcoded FIPS) | none (geometry); membership from CP-RUN `regions` | US-Atlas TopoJSON FIPS 51*; region membership CP-RUN `regions.lwda` + in-file GOVA VALUES | all 5 levels | static | n/a | real geometry; MSA boundaries via fallback |
| community-profiles | Sticky bar | `minimap` | Mini selection map | choropleth (silent) | same geometry | none | same | selected region | static | n/a | real geometry |
| community-profiles | Overview | `ov-unemp` card | Unemployment Rate | KPI card | `profiles.json` → `profiles[].unempLatest`,`unempLatestYear` | CP-RUN (`unemp_final`) | `LaborForce.UnemployedRate` (PeriodType=01 annual, PeriodYear=2025, Adjusted=0); native 01/04/31, LWDA+GOVA via SUM rollup | state/county/LWDA/GOVA native; MSA→mock | annual | LAUS not suppression-limited | real (mock at MSA) |
| community-profiles | Overview | `ov-gdp` card+spark | Gross Domestic Product | KPI + sparkline | `genData` `d.gdp`,`d.gdpTrend` | none (should read: BEA, not in WID) | representative by client decision | region | annual | n/a | representative |
| community-profiles | Overview | `ov-pop` card+spark | Population | KPI + sparkline | `genData` `d.population`,`d.popTrend` | none (WID pop tables empty — WID-LOAD-GAP-PopulationIncome) | Census/ACS | region | annual | n/a | mock |
| community-profiles | Overview | `ov-ind` card | Top 3 Industries | KPI list | `profiles.json` → `profiles[].industryEmployment` (top 3) | CP-RUN (`ind_by_region`) | `Industry.QuarterAvgEmp`/4 → `NAICSSectors.SectorDesc` (IndCodeType=10, Own=00, PeriodType=02, 2025) | native state/county/LWDA/MSA; GOVA rollup; MSA→mock | quarterly | QCEW small-cell (values present even when Suppress=1 here) | real (mock at MSA) |
| community-profiles | 01 Demographic | `c-demo-poptrend` | Total population over time | line/area | `demoData()[ARCH].pop` (`?arch=A/B`) | none (should read: Census pop by year) | not wired; ignores selected geography | archetype (Fairfax/Buchanan) | annual | n/a | mock (arch-driven) |
| community-profiles | 01 Demographic | `demo-bans` | Demographic BAN row | KPI cards | `demoData()[ARCH].bans` (hardcoded) | none | Census/ACS (median age, working-age %) | archetype | annual | n/a | mock |
| community-profiles | 01 Demographic | `c-edu` | Education | grouped bar (region vs VA) | `genData` `d.educationCompare {categories,msa,va}` | none (should read: ACS S1501) | `va[]` hardcoded in genData | region vs state | annual | n/a | mock |
| community-profiles | 01 Demographic | `hied-list` | Higher Education | list/directory (not a chart) | `higherEdData()[ARCH] {fourYear[],community[]}` | none | IPEDS sector 1/2/3 located-in + **VCCS service-region crosswalk (does not exist yet)** | locality / service-region | annual | n/a | mock (needs FIPS→VCCS crosswalk) |
| community-profiles | 02 Affordability | `k-hh-*`,`k-occ-*` | Housing Profile · Households | KPI cards | `genData` `d.afford.*` | none (should read: ACS) | mock-derived from population/housing | region | annual | n/a | mock |
| community-profiles | 02 Affordability | `c-rent` | Avg Rent · trend | line/area | `d.afford.rentTrend` | none | ACS median gross rent | region | annual | n/a | mock |
| community-profiles | 02 Affordability | `c-home` | Avg Home Price · trend | line/area | `d.afford.homeTrend` | none | ACS median home value | region | annual | n/a | mock |
| community-profiles | 02 Affordability | `c-burden` | Housing cost % income vs VA | grouped bar + markLine | `d.afford.burdenRegion/burdenVa` | none | ACS cost-burden; `burdenVa=[29.1,21.5,10.4]` hardcoded | region vs state | annual | n/a | mock |
| community-profiles | 02 Affordability | `c-medinc` | Median HH Income vs VA | compare bar | `d.afford.medianIncome/vaMedianIncome` | none | ACS median HH income; `vaMedianIncome=83200` hardcoded | region vs state | annual | n/a | mock |
| community-profiles | 02 Affordability | `c-disc` | Discretionary Income vs VA | compare bar | `d.afford.discretionary/vaDiscretionary` | none | derived; `vaDiscretionary=26100` hardcoded | region vs state | annual | n/a | mock |
| community-profiles | 02 Affordability | (s-col) | Cost of Living | on hold (no chart) | `d.costOfLiving` (computed, unused) | none | — | — | — | — | held |
| community-profiles | 03 Labor Force | `c-unemp-trend` | Unemployment Rate | line (region vs VA dashed) | `unemployment_trend.json` (`months`,`series.virginia`,`counties[].fips → .data`); else `d.unemployment` | LMD-RUN Q2 | `LaborForce` monthly UnemployedRate (NSA county, VA series); `fips='51'+RIGHT(Area,3)` | **County/City only** (real); other levels → mock | monthly | LAUS not suppression-limited | real (County/City); mock elsewhere |
| community-profiles | 03 Labor Force | `unemp-bans` | Latest rate + delta (region/VA) | KPI cards | derived from same series | LMD-RUN Q2 | same | County/City | monthly | — | real (County/City) |
| community-profiles | 04 Employers | `c-industry` | Industry employment + 5-yr trend | horizontal bar + arrows | `profiles.json` `industryEmployment[].value` (real) + `.growth` (**synthesized**) | CP-RUN (value); none (growth) | `Industry.QuarterAvgEmp`/4 (value only) | native state/county/LWDA/MSA; MSA→mock | quarterly | QCEW small-cell (supersector) | value real, growth mock (MSA all mock) |
| community-profiles | 04 Employers | `c-industry-lq` | Location Quotient | horizontal bar + 1.0× markLine | `industryEmployment[].lq` (**synthesized from name hash**) | none | LQ = local share ÷ VA share — derivable from QCEW, not computed in SQL | region | quarterly | QCEW suppression | mock (lq synthetic) |
| community-profiles | 04 Employers | `c-business` | New Business · Formation trend | bar + headline | `genData` `d.business {years,formations,lastYear}` | none | QCEW/ES-202 new employer establishments (definition = client decision) | region | quarterly | QCEW suppression | mock |
| community-profiles | 04 Employers | `c-business-industry` | New Business · By industry | horizontal bar | `d.business.byIndustry [{name,value}]` | none | QCEW/ES-202 latest-year NAICS split | region | quarterly | QCEW suppression | mock |
| community-profiles | 04 Employers | `c-appr-occ` | Apprenticeships · Top occupations | horizontal bar (top 10) | `d.apprenticeships.byOccupation` | none | RAPIDS apprentices by occupation | region floor (AreaType 9 likely) | annual | RAPIDS→region floor; county→LWDA note | representative (fixed across all geos) |
| community-profiles | 04 Employers | `c-appr-donut` + `k-appr-*` | Apprenticeships · By industry + BANs | donut (center BAN) + KPI | `d.apprenticeships.byIndustry` + `.summary` | none | RAPIDS apprentices by industry; summary counts | region floor | annual | RAPIDS suppression | representative (fixed; totals reconcile by construction) |
| community-profiles | 04 Employers | `c-emp-ownership` | Largest Employers · Ownership split | 100% stacked bar | `d.employers.ownership {privatePct,federalPct,statePct,localPct}` | none | `Industry` IndCode=10 Ownership (50/10/20/30), StFips=51, AreaType=04 | locality (per-region seed); rollup | quarterly | QCEW suppression | mock (per-region seeded) |
| community-profiles | 04 Employers | `emp-table` + CSV | Largest Employers · Named list | list/directory (not a chart) | `empTop50()` (50 hardcoded rows) | none | `VI_Top50Employers` (EmployerName, CodeTitle, OwnerTitle, SizeDesc band, AreaName/Type/Area, PeriodYear) | statewide (`empListScope()`; locality vs statewide unconfirmed) | static/annual | compliance: SizeDesc **band only, never a count** | representative (curated, constant) |
| community-profiles | 04 Employers | (deferred) | Employers by size | deferred (empty) | none | none | `VI_Top50Employers` SizeDesc band counts — pending disclosure clearance | — | — | not cleared | not populated |
| wage-tool | Occupation row | `pct-bar` (`mkPercentileBar`) | Percentile band p10–p90 | ECharts custom (bands + median + salary dot) | `wages.json` → `jobs[].areas["<code>"].{p10,p25,p50,p75,p90}` | WCT-RUN Q1 | `IOWAGE` Percentile10/25/75/90Wage, MedianWage; dims GEOGRAPHIES, SOCCodes | MSA (AreaType=31, 11) + statewide (01), by SOC-6 | annual (OEWS, ~5mo lag; pinned 2024) | `SuppressWage=0`; top-code repair p75/p90→239200; FE cascade-clamp | real |
| wage-tool | Occupation row | `wage-spark` (`mkSparkline`) | Wage trend · 5-yr | line sparkline | `wages.json` → `jobs[].areas["<code>"].trend[]` (aligned to `meta.trend_years`) | WCT-RUN Q1 | `IOWAGE.MedianWage` across 2021/2023/2024 | SOC-6 × MSA/state | annual | null-padded; 2022 absent from IOWAGE | real |
| wage-tool | Occupation row | `emp-spark` (`mkSparkline`) | Employment · 24 mo | line sparkline | `employment_trend.json` → `trends["<soc>__<code>"][24]`, `meta.months[]` | WCT-RUN Q2 | `IOWAGE.EmpCount` × `LABORFORCE.LaborForce` (PeriodType=03, Adjusted=0) seasonal weight | SOC-6 × MSA/state, monthly | levels annual, monthly shape from LAUS (24-mo) | `SuppressEmp=0`; statewide-curve fallback; missing→null | real |
| wage-tool | Shared axis | `axis-chart` (`mkAxis`) | Wage $ axis | value axis (no series) | client-computed domain (`computeDomain()`) | none | derived from loaded cells | matches rows | n/a | n/a | real (derived) |
| wage-tool | Occupation row KPI | `stat-median`,`stat-pct` | Median / your percentile | KPI tiles | `wages.json` p50 + user salary input | WCT-RUN Q1 (median); JS (percentile) | `IOWAGE.MedianWage` | SOC-6 × area | annual | as above | real / derived |
| wage-tool-employer | Industry summary | `industry-band` | Avg wage / Employment / Establishments | KPI tile band | `industries.json` → `sectors[].areas["<code>"].{mean_wage,employment,establishments}` | EWT-RUN Q2 | `INDUSTRY` TotalWages/QuarterAvgEmp/Establishments; NAICSSectors (Own=00 Total Covered) | NAICS-2 × LWDA (15, 14) / statewide | annual (QCEW, ~5mo lag; 2025) | **no Suppress filter (intentional)**; hourly = mean_wage/2080 in JS | real |
| wage-tool-employer | Pay bands | `chart` (`renderChart`) | Pay-band distribution (per SOC-6) | ECharts custom (bands + median + target diamond) | `wages.json` → `jobs[].areas["<code>"].{p10..p90,p10_h..p90_h,employment,provenance}` | EWT-RUN Q1 | `IOWAGE` annual (RateType=4) + hourly (RateType=1) percentiles, EmpCount; SOCCodes SOCParent walk | LWDA/statewide × SOC-6, grouped by SOC-3 family | annual (OEWS) | `SuppressWage/Emp=0`; `statewide_fallback` provenance; top-code 239200/115.00; FE drops null rows | real |
| wage-tool-employer | KPI strip | `budget-range`,`median-range`,`position-delta`,`hiring-pool` | Budget / Median / Market position / Workforce | KPI tiles | `wages.json` aggregated in JS across family + slider `targetPct` | EWT-RUN Q1 (client-aggregated) | `IOWAGE` percentiles + EmpCount summed across family | SOC-3 family × region | annual | inherits cell suppression | real (derived) |
| wage-tool-employer | Family header | `family-count`,`family-title` | Occupations count / family title | text | `wages.json` (`buildRows().length`, `minor_group`) | EWT-RUN Q1 | SOCCodes SOCParent walk (minor_code/minor_group) | SOC-3 family | annual | `minor_group` null (8/721) → major fallback | real |

---

## Artifact inventory

The distinct JSON artifacts a scheduled job must produce, their consumers, cadence, and a sample record (field names + types). This is the DBA output spec.

### 1. `apps/community-profiles/data/profiles.json` — CP-RUN (one NVARCHAR(MAX) blob)
**Consumers:** overview Unemployment KPI, overview Top-3 Industries, `c-industry` (value only), `c-industry-lq` (value filter only). Merged over `genData` in `selectRegion`; keys present define `realFields`.
**Cadence:** LAUS **annual** average + QCEW **quarterly** (both pinned to year 2025). Refresh the whole blob on the slower of the two.
**Current state:** INTERIM build (2026-07-09) — `meta.coverage` = "MSA regions+profiles stripped pending suffix-collision fix"; 157 profiles (state + 9 GOVA + 14 LWDA + 133 county), **no MSA**.
```jsonc
{ meta:   { generated:str, laus_year:str, qcew_year:str, coverage:str },
  regions:{ lwda:[ { id:str "000441", name:str, fips:[str "51720", …] } ] },  // msa MISSING in deploy
  profiles:[ { id:str "state"|"c-51059"|"000441"|"gov-3",
               unempLatest:number, unempLatestYear:str "2025",
               industryEmployment:[ { name:str /* raw SectorDesc */, value:int /* jobs */ } ] } ] }
```
Note: `industryEmployment[].name` is raw `NAICSSectors.SectorDesc` — carries a known typo (`"Professiona.l Scientific & Technical Svc"`) and BLS range suffixes (`"Retail Trade (44 & 45)"`, `"Manufacturing (31-33)"`). No `lq`, no `growth` in the real record.

### 2. `unemployment_trend.json` — LMD-RUN Q2 (⚠ TWO deployed copies)
**Copies:** `apps/dashboard-front-page-echarts/data/unemployment_trend.json` and `apps/community-profiles/data/unemployment_trend.json` (the community-profiles copy was hand-copied from the front-page app for the LAUS chart). Both should be regenerated from the same query.
**Consumers:** front-page `line-cell`; community-profiles `c-unemp-trend` + `unemp-bans` (community-profiles uses only `counties[]` and `series.virginia`; `us_national` is unused there).
**Cadence:** LAUS **monthly**, fixed 36-month window ending latest LABORFORCE month.
```jsonc
{ months: [str "2023-04", … "2026-03"],           // 36
  series: { virginia:   [num|null] /* SA, 36 */,
            us_national:[num|null] /* SA, 36 */ },
  counties:[ { fips:str "51001", data:[num|null] /* NSA monthly rate, 36 */ } ] }  // 133
}
```
Single `null` at index 30 (2025-10) across all arrays (documented source gap).

### 3. `apps/dashboard-front-page-echarts/data/employment_by_locality.json` — LMD-RUN Q1
**Consumers:** `map-cell` choropleth, all header KPI tiles, per-county KPI. **Cadence:** LAUS **monthly**.
```jsonc
{ as_of: str "2026-03",
  kpi:   { virginia:{ value:num, delta_pts:num }, us_average:{ value:num, delta_pts:num } },
  counties:[ { fips:str "51001", areaname:str, region:str "000456" /* 6-digit LWDA */,
               lwda_short_name:str, employment_rate:num, unemployed_rate:num,
               labor_force:int, employed:int } ] }  // 133
```

### 4. `apps/dashboard-front-page-echarts/data/jobs_by_industry.json` — LMD-RUN Q3
**Consumers:** `bar-cell` (statewide default; per-LWDA on region select). **Cadence:** QCEW **quarterly**.
```jsonc
{ as_of_quarter: str "2025-Q4",
  statewide:[ { sector:str, jobs_added:int } ],                         // top 5
  regions:[ { key:str "000452" /* LWDA */, label:str,
              sectors:[ { sector:str, jobs_added:int } ] } ] }          // 14 × top 5
```

### 5. `apps/wage-tool/data/wages.json` — WCT-RUN Q1  (1.98 MB, real)
**Consumers:** percentile band, wage-trend sparkline, median/percentile tiles. **Cadence:** annual (OEWS).
```jsonc
{ meta:  { source:str, extracted_at:str, latest_year:int 2024, trend_years:[int] [2021,2023,2024] },
  areas: [ { id:str "013980", label:str, areatype:str "31"|"01" } ],   // 11 MSA + statewide
  jobs:  [ { id:str "11-1011", soc_code:str, label:str, major_group:str, aliases:[str],
             areas:{ "<code>": { p10:int,p25:int,p50:int,p75:int,p90:int,
                                 employment:int, trend:[int|null] /* len 3 */ } } } ] }
```

### 6. `apps/wage-tool/data/employment_trend.json` — WCT-RUN Q2  (629 KB, real)
**Consumers:** employment sparkline. **Cadence:** monthly shape over annual OEWS levels (24-mo).
```jsonc
{ meta:   { source:str, extracted_at:str, months:[str] /* 24 "2023-01"… */, notes:str },
  trends: { "<soc>__<area_code>": [int|null] /* len 24, e.g. "29-1141__013980" */ } }
```

### 7. `apps/wage-tool-employer/data/wages.json` — EWT-RUN Q1  (2.4 MB, real, 721 jobs)
**Consumers:** pay-band chart, KPI strip, family header. **Cadence:** annual (OEWS).
```jsonc
{ meta:  { source:str, extracted_at:str, latest_year:int 2025 },       // NOTE: no trend_years
  areas: [ { id:str "000441", label:str "Southwest Region (LWDA I)", areatype:str "15"|"01",
             counties:[str] } ],                                        // 14 LWDA + statewide
  jobs:  [ { id, soc_code, label, major_group, minor_code:str "11-1000", minor_group:str|null, aliases:[],
             areas:{ "<code>": { p10:int,…,p90:int, p10_h:num,…,p90_h:num /* native hourly 2dp */,
                                 employment:int, provenance:str "lwda"|"statewide"|"statewide_fallback" } } } ] }
```
Provenance distribution in the deployed file: lwda 5375 / statewide 703 / statewide_fallback 4523.

### 8. `apps/wage-tool-employer/data/industries.json` — EWT-RUN Q2  (25 KB, real)
**Consumers:** industry summary band. **Cadence:** annual (QCEW).
```jsonc
{ meta:    { source:str, extracted_at:str, latest_year:int 2025 },
  areas:   [ { id:str, label:str, areatype:str } ],                    // 14 LWDA + statewide, NO counties[]
  sectors: [ { naics:str "11", label:str,
               areas:{ "<code>": { mean_wage:int, employment:int, establishments:int } } } ] }  // 20 NAICS-2
```

### Static / non-pipeline / external dependencies (no `RUN.sql` produces these)
| file | role | consumers | cadence | note |
|---|---|---|---|---|
| CDN `us-atlas@3/counties-10m.json` | choropleth geometry | front-page `map-cell`, community-profiles `vamap`/`minimap` | static (external) | live fetch from jsdelivr, filtered to FIPS 51; **not WID, not a deployed artifact** — a CDN outage/version bump breaks the maps independently of any refresh |
| `apps/wage-tool-employer/data/soc-titles.json` | SOC code → title lookup (762) | employer job labels (null fallback) | static (~5yr SOC vintage) | curated vs BLS, not a query |
| `apps/wage-tool-employer/data/soc-aliases.json` | SOC → alt titles (690) | employer family search (LIVE alias source) | static | `OccupationXOccupation` empty on this install, so SQL ships `aliases:[]`; FE patches from this file |
| `apps/wage-tool/data/wages.example.json` | 8-job fallback | wage-tool if `wages.json` 404s | static | same shape as #5 |
| `apps/community-profiles/data/_localities.json`, `va-localities.geojson` | reference | none at runtime | static | app fetches CDN us-atlas instead; both unused live |
| community-profiles in-file `genData(region)` | deterministic mock generator | every community-profiles chart not covered by #1/#2 | n/a | contract documented at index.html lines ~759–790 |

---

## Gaps

### A. Charts with no real source (mock/representative, no query today)
All of community-profiles except overview Unemployment + Top-3 Industries (real) and the section-03 Unemployment trend (real, County/City): **GDP, Population, all of Demographic Profile, all of Affordability & Housing, New Business (both), Apprenticeships (both), Higher Education, and the LQ chart** are mock or representative with no producing query. Front-page **Unemployment Rate Trending** is real (raw NSA county LAUS wired to LMD-RUN Q2; the earlier curated-smooth read was corrected, see C1).

### B. Two charts disagree about the shape of the same underlying data
- **Unemployment (community-profiles).** The `genData` contract documents `unemployment:{years,msa,va,us}` (annual, 3-series region/VA/US) and the **dead** `c-unemp` config consumes exactly that; the **live** `c-unemp-trend` instead consumes `unemployment_trend.json` (monthly, 2-series, US dropped). Same LAUS metric, incompatible shapes — the contract comment is stale.
- **`unempLatest` (annual) vs the trend file (monthly).** Overview KPI uses annual-average `unempLatest`; section 03 uses monthly NSA from a different query/file. A county's annual KPI will not equal any single month in its own trend line. Document as two distinct series so the DBA spec doesn't conflate them.
- **Wage `wages.json` differs between the two apps.** wage-tool = `latest_year:2024` + `trend_years`; employer = `latest_year:2025`, **no** `trend_years`, plus native hourly `p*_h`. Same `IOWAGE` source, different pinned years and different meta shape — "the WID wages export" is really two artifacts.
- **`aliases` provenance splits by app.** wage-tool ships real `aliases[]` (from `ONETAlternativeTitles`); employer ships `aliases:[]` and patches from static `soc-aliases.json`. Same field, two sources; employer search silently degrades if that static file is dropped.
- **`industries.json.areas` lacks `counties[]`** while `wages.json.areas` has it (employer app). If the industry region control ever goes county-first, Q2 must mirror Q1's county splice.

### C. Convenience-shaped data — WILL CHURN WHEN REAL DATA ARRIVES  ⚠
These are shapes built for rendering convenience, not derived from natural query output. They are the high-risk items for a DBA hand-off.

1. **Front-page 3 JSONs predate the v8 SQL label contract (stale labels, REAL numbers).** Field structure matches LMD-RUN v8, but label *values* are the retired hardcoded short forms: `lwda_short_name` = `"Hampton Roads"` (v8 emits `GEOGRAPHIES.AreaName` verbatim, `"Hampton Roads (LWDA XIV)"`); `regions[].label` short vs verbose; `sectors[].sector` = `"Trade & Transportation"` (v8 sources `NAICSSuperSectors.SuperTitle`, `"Trade, Transportation and Utilities"`); and the statewide bar's top-5 omits the Government rollup v8 unions in. **These are all label observations; they do not bear on whether the numbers are real.** A direct numeric audit (2026-07-30) found the payloads ARE real WID/LAUS/QCEW values, not synthesized. Correcting the earlier "representative v3-era" conclusion, which rested only on those label mismatches:
   - **`employment_by_locality.json` — real numbers, stale labels.** All 133 rows internally consistent (`employment_rate + unemployed_rate = 100`; `(labor_force − employed)/labor_force` matches the stated rate to rounding on every row). `labor_force` sums to **4,488,781**, the correct magnitude for Virginia's civilian labor force, and the county-summed NSA rate is **3.80**, consistent with the reported VA KPI (3.8). Geographic spread is realistic, not uniform: coalfield/Southside high (Buchanan 7.7, Emporia 8.3, Petersburg 5.5), Northern Virginia and rural-mountain low (Bath 2.9, Arlington 3.2). Values are non-round with realistic dispersion.
   - **`unemployment_trend.json` — real numbers, stale labels.** Every county's 2026-03 value equals its `employment_by_locality` rate (0 mismatches across 133). The county series carry raw-NSA fingerprints a smoothed or generated series would not: a mean Dec→Jan rise of **+0.56pp** (the real January seasonal spike) and small localities markedly noisier than large ones (mean |month-over-month| **0.40 vs 0.22**, genuine small-area sampling volatility). Galax, Emporia, Pulaski show sharp single-month spikes typical of tiny-denominator LAUS. The `virginia`/`us_national` series are smooth only because SA statewide and national aggregates are smooth in reality (plateaus of uneven length plus a mid-series dip, not linear spacing). **The earlier "smoothed/curated, not raw LAUS" read (row 31, Gap A) was mistaken and is corrected.**
   - **`jobs_by_industry.json` — numbers real, stale labels.** Statewide and the 14 per-LWDA blocks come from one real dataset. Under top-5-DESC truncation, net-positive sectors reconcile region-sum to statewide in the correct direction and to within a couple of hidden small regions (Trade & Transportation 15,502 of 15,684; Education & Health 8,189 of 8,503); net-negative *statewide* sectors (Construction, Manufacturing) correctly fail to reconcile because their negative regional contributions fall out of each region's top 5. Independently fabricated region/statewide numbers would not produce this directional pattern. QCEW magnitudes were not externally re-verified against BLS, but the cross-grain consistency makes fabrication unlikely.

   **Net:** provenance is a real pre-v8 WID run carrying pre-v8 (short-form) labels, not representative/fabricated data. The front-end still renders these labels raw in tooltips/legends, so render-time abbreviation is still needed; but the churn on the first real v8 run is revision-level plus label restrings, not wholesale numeric replacement.
2. **`community-profiles.industryEmployment` LQ/growth are fabricated.** Real record is `{name,value}`; the app synthesizes `lq` and `growth` **from a hash of the sector name** (index.html ~1098–1100). So `c-industry`'s growth arrows and the *entire* `c-industry-lq` chart are invented numbers sitting on real employment. QCEW LQ/growth will replace them, and axis labels change wording (clean editorial names → raw dim labels with the typo and range suffixes).
3. **`hc_key` round-trip — RESOLVED 2026-07-29.** Was: SQL emitted the Highcharts key `'us-va-'+RIGHT(Area,3)` and the browser converted it *back* to 5-digit FIPS to join the GeoJSON. Fixed: LMD-RUN Q1/Q2 now emit `fips = '51'+RIGHT(Area,3)` directly, the JSON artifacts carry `counties[].fips`, and the `hcKeyToFips()` bridge is deleted. See `docs/highcharts-legacy-audit.md` and the `hc_key→fips` commit series.
4. **Pre-pivoted scalar month arrays.** `months`, trend `series.*`, `counties[].data` are 36-wide null-padded arrays hand-built with `STRING_AGG` + `JSON_QUERY` (FOR JSON PATH can't emit scalar arrays). Natural query output is long-format `(Area, PeriodYear, Period, rate)` rows; the wide arrays exist only for the chart. High churn if the window length or gap-handling changes.
5. **Wage `jobs[].areas` keyed-object blob.** Both wage apps hand-build `{ "<area_code>": {...} }` with `STRING_AGG` — dynamic keys aren't natural SQL output. Faithful today, but any normalized replacement API (one row per soc×area) churns every consumer. wage-tool `trend[]` is also positionally aligned to `meta.trend_years` with no year labels — a 2022 backfill silently grows the array and breaks length-3 assumptions.
6. **Top-code / suppression zeros leak past the `p50` gate.** Q1 emits a cell when `p50 IS NOT NULL`, but a literal `0` (mishandled top-code) passes, and the top-code repair covers p75/p90 only — files contain `{p50:0, p25:178420}`. wage-tool compensates at render (cascade-clamp); the **employer tool drops rows only on `null`, so a `0` renders a broken band.** SQL and FE disagree on the contract — single most likely churn source.
7. **`community-profiles` apprenticeships are fixed across all geographies** (active 1240 everywhere; `summary.active` and `byIndustry` total reconcile to the donut center by construction). RAPIDS grain is expected to floor at region level; the county fallback note shows but the numbers don't move.
8. **Hardcoded VA benchmarks inside `genData`:** `educationCompare.va`, `afford.burdenVa=[29.1,21.5,10.4]`, `vaMedianIncome=83200`, `vaDiscretionary=26100`, etc. Convenience constants that need a real statewide ACS source.
9. **`community-profiles.employers.list`** is 50 hardcoded rows, statewide-constant, while the adjacent ownership-split card is per-region mock — one section, two different provenance behaviors.
10. **Hourly split (employer, documented but load-bearing):** industry band computes hourly as `mean_wage/2080` in JS; pay-band chart uses native OEWS `p*_h`. Two hourly numbers on one page from two methods — a maintainer "unifying" them would violate the QCEW-has-no-native-hourly contract.
11. **All KPI-tile / target-diamond values are client-derived** (budget, market position, "your percentile") — never in SQL, invisible to SQL-side validation. Fine as long as reviewers know the query only ships raw percentiles + employment.

### D. Dead code / retired layout (community-profiles)
Six chart configs still build ECharts options and read `genData` fields every render but never mount (no DOM container): `c-pyramid`, `c-growth`, `c-race`, `c-wages`, `c-unemp`, `c-ui`. Their `genData` fields (`ageCohorts`, `race`, `weeklyWage`, `wageAll`, `uiPayments`, `populationChange`, `occupations`, `commute`, `costOfLiving`, `householdIncome`) are generated but unused. The community-profiles `README.md` still documents this retired layout (population pyramid, race donut, weekly-wage bar, UI-payments line, occupation/commute charts) — it does **not** match the shipped app.

### E. MSA level is entirely illustrative (community-profiles)
The interim `profiles.json` stripped `regions.msa` + MSA profiles, and the app still uses hardcoded `msa-*` slug ids that key to no profile. So even charts that are real at other grains (unemployment, industry) fall back to mock at MSA. Two-sided fix: regenerate the full `profiles.json` (with MSA) **and** switch the app's MSA list to consume `regions.msa` (6-digit Area codes) instead of slugs.
