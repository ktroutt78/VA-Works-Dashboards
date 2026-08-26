# Repo State Audit — 2026-08-23
Commit: `8fb9ade` (community-profiles: punchlist v1 + client refinements)  Branch: `main`

This audit is read-only. No file was modified except this one. Every claim below
carries a `file:line` or a quoted snippet. Where a claim rests only on a comment
or doc, it is marked as such. `chart-manifest.md` is treated as a *claim*; the
code and data files are the *fact*.

---

## 1. Executive summary

1. **The three front-page JSON artifacts are still v3-era representative, NOT
   RUN_v8 output — and the v8 SQL exists and disagrees with them.** The deployed
   JSON carries bare labels (`"Hampton Roads"`, `"Trade & Transportation"`), no
   Government rollup, and `delta_pts: 0`. `labor_market_dashboard_mssql_RUN_v8.sql`
   emits verbose `AreaName` labels and a Government rollup. The SQL was never
   run into the deployed files. (Step 1)
2. **The `p50 = 0` leak is real in wage-tool and absent in wage-tool-employer.**
   `wage-tool/data/wages.json` has 57 cells with `p50 == 0` (and 39 monotonicity
   violations); `wage-tool-employer/data/wages.json` has zero. Both RUN.sql files
   gate on `p50 IS NOT NULL`, so the mechanism is present in both; only wage-tool's
   data currently exhibits it. (Step 2)
3. **The two `wages.json` files are still divergent artifacts, not unified.**
   wage-tool = latest_year 2024, `trend_years`, populated `aliases`, no native
   hourly. employer = latest_year 2025, native hourly (`*_h`), no trend, empty
   aliases. Different job counts (777 vs 721) and sizes (1.98 MB vs 2.41 MB). (Step 3)
4. **The two `unemployment_trend.json` copies are byte-identical** (same MD5
   `9730800545bec39b32922355811afdc5`). The duplication remains but they are in
   sync. (Step 4)
5. **Community Profiles is still ~90% mock.** Only `unempLatest`,
   `unempLatestYear`, and `industryEmployment` (value) come from `profiles.json`;
   every other chart reads `genData()` / `demoData()` / hardcoded constants. (Step 6)
6. **The deployed `profiles.json` is an interim build that predates its own
   RUN.sql.** File `meta.coverage` = "INTERIM DEPLOY: MSA regions+profiles
   stripped"; it has 157 profiles and **no `regions.msa`**. The committed
   `community_profiles_mssql_RUN.sql` (2 days newer) *does* emit MSA. So the app
   half of the MSA fix is ready (it reads `regions.msa` when present) but the data
   half was never deployed → MSA level falls back to 7 hardcoded slugs. (Step 6.5)
7. **Six chart configs are dead code.** `c-pyramid`, `c-growth`, `c-race`,
   `c-wages`, `c-unemp`, `c-ui` all have live `setOption` blocks but no matching
   DOM container, so `mk(id)` returns null and they never render. (Step 6.2)
8. **`lq` and `growth` are still synthesized in the front end**, not read from
   data. The manifest's line reference (~1098-1100, "hash of sector name") is
   stale, but the conclusion holds: `profiles.json` carries no `lq`/`growth`. (Step 6.3)
9. **Provenance is inconsistent and no artifact carries `schema_version`.**
   SQL-refresh artifacts have a `meta` block; the two v3-era front-page files
   have only `as_of`/`as_of_quarter`; `unemployment_trend.json` has no provenance
   at all. (Step 9)
10. **No automated validation harness exists** — only 3 hand-run `*_validate.sql`
    probe files and inline SMOKE-TEST blocks in two RUN.sql files. (Step 7)

---

## 2. Status table

| Plan item | Manifest claim | Actual state | Verdict | Evidence |
|---|---|---|---|---|
| S0 Artifacts present | 8-9 named JSONs | all 9 present at expected paths | DONE | `find apps -name '*.json'` |
| S0 Unexpected additions | n/a | `dist/` releases+staging+vendor-cache, `va-works-wp-theme` app, `wage-tool-hero.html`, bundled `counties-10m.json` ×2, wp-theme embed data copies | DONE (reported) | tree; `apps/*/` listings |
| S1A lwda labels | v3-era (bare) | bare `"Hampton Roads"` → v3-era | NOT DONE (v8 not deployed) | emp_by_locality distinct `lwda_short_name` |
| S1B sector labels | v3-era | `"Trade & Transportation"` → v3-era | NOT DONE | jobs_by_industry statewide sectors |
| S1C Government rollup | absent (v3) | absent from `statewide[]` | NOT DONE | jobs_by_industry `statewide[]` |
| S1D region labels | short (v3) | short (`"Capital"`, `"Hampton Roads"`) | NOT DONE | regions[].label |
| S1E delta_pts | not populated | all `0` | NOT DONE | `.kpi` |
| S1 SQL vs JSON | should agree | v8 SQL emits verbose+Gov; JSON does not | **DISAGREE** | RUN_v8.sql:66-77,469-475 vs JSON |
| S2 p50=0 leak (wage-tool) | exists | 57 cells p50=0; 39 non-monotonic | DONE (leak present) | jq counts |
| S2 p50=0 leak (employer) | renders broken band | 0 cells p50=0 (not currently triggered) | PARTIAL | jq counts |
| S2 SQL gate | `IS NOT NULL` | `p50 IS NOT NULL` both files | DONE | WCT:267, EWT:653-654 |
| S2 wage-tool clamp | cascades | cascade-clamp present | DONE | wage-tool.html:720-738 |
| S2 employer drop | on null only | drops on `== null` only | DONE | wage-tool-employer.html:1272-1273 |
| S3 two wages.json | divergent | divergent (year/hourly/trend/aliases differ) | NOT DONE (not unified) | meta blocks |
| S4 dup unemployment_trend | two copies | two copies, byte-identical | PARTIAL | MD5 match |
| S5 data path config | hardcoded relative | all hardcoded `data/*.json`, no base URL | DONE (still hardcoded) | fetch lines below |
| S5 map geometry | — | bundled local `counties-10m.json`, no CDN | DONE | CP:261, dash:570-573 |
| S5 fetch hardening | — | mixed: CP/dash/wage-tool guarded; employer unguarded core fetch | PARTIAL | see Step 5 |
| S5 404 fallback | wages.example only | only wage-tool has `wages.example.json` | DONE | Step 8 |
| S6.1 genData present | present | present, ~157 lines (846-1002) | DONE | index.html:846 |
| S6.2 dead configs | some | 6 configs live, containers absent | DONE (dead) | see Step 6.2 |
| S6.3 lq/growth fabricated | hash of name | synthesized (share ratio + bias array), not from data | DONE (still mock) | genData:870-871 |
| S6.4 hardcoded VA benchmarks | several | `vaMedianIncome`,`burdenVa`,edu `vaPct`,empTop50 hardcoded; `vaDiscretionary` dropped | PARTIAL | 907,994,998,1022 |
| S6.5 MSA grain | slugs + no msa | app reads `regions.msa` when present; JSON lacks it → 7-slug fallback | PARTIAL (both halves needed) | 348-361; profiles.json |
| S6.7 CP-RUN coverage | unemp+industry | 19 CTEs; emits unemp + industryEmployment only | DONE (as claimed) | RUN.sql |
| S6.8 apprenticeships 1240 | fixed | fixed `active:1240` all geos | DONE | index.html:977 |
| S6.9 higher ed | arch-driven | arch-driven illustrative, no VCCS/IPEDS/radius | DONE (still mock) | 1200,1747-1764 |
| S7 validation tooling | — | 3 validate.sql + r4; SMOKE blocks in 2 RUN.sql; no JS tests | DONE (reported) | find + grep |
| S8 static deps | soc-titles 762 / aliases 690 | 762 / 690 confirmed; example present | DONE | jq counts |
| S8 _localities/geojson unreferenced | — | zero runtime refs in CP | DONE | grep |
| S9 schema versioning | — | no `schema_version` anywhere; provenance inconsistent | DONE (reported) | jq paths |

---

## 3. Findings by step

### STEP 0 — Orientation

**Branch/commit:** `main` @ `8fb9ade`.

**git log (top):** `8fb9ade` punchlist v1; `ea0db9a` statewide education chart;
`ea2f771`/`48fc811`/`0bdf798` build/release scripts; `4a06e54` font tokens +
bundle counties-10m; `f0801e7` wp-theme inline embeds; `4736fc0` handover note on
the literal-0 p50 gate; older commits are the community-profiles redesign and the
`hc_key→fips` series.

**The 9 artifacts** (path — bytes — mtime — last commit):

| Artifact | bytes | mtime | last commit |
|---|---|---|---|
| dashboard-front-page/employment_by_locality.json | 23,868 | 2026-08-11 | 2026-07-29 `885f0d9` |
| dashboard-front-page/unemployment_trend.json | 22,499 | 2026-08-11 | 2026-07-29 `885f0d9` |
| dashboard-front-page/jobs_by_industry.json | 4,412 | 2026-07-13 | **2026-06-03 `506f00f`** |
| community-profiles/profiles.json | 177,801 | 2026-07-13 | 2026-07-13 `67b7ab7` |
| community-profiles/unemployment_trend.json | 22,499 | 2026-08-11 | 2026-07-29 `885f0d9` |
| wage-tool/wages.json | 1,982,114 | 2026-07-13 | 2026-07-07 `58245be` |
| wage-tool/employment_trend.json | 628,618 | 2026-07-13 | 2026-07-07 `29fb74f` |
| wage-tool-employer/wages.json | 2,409,052 | 2026-07-13 | 2026-06-12 `6c2bfdf` |
| wage-tool-employer/industries.json | 25,248 | 2026-07-13 | 2026-06-12 `6c2bfdf` |

All 9 present at expected paths; none missing or relocated.

**queries/** (12 files): `community_profiles_mssql_RUN.sql` (23,110, `cdd48d4`
2026-07-11), `community_profiles_mssql_validate.sql` (`a1ea230`),
`community_profiles_mssql_validate_r4.sql` (`cdd48d4`), `dimension_resolution_probe.sql`,
`employer_wage_tool_mssql_RUN.sql`, `employer_wage_tool_mssql_validate.sql`,
`employer_wage_tool_snowflake.sql`, `labor_market_dashboard.sql`,
`labor_market_dashboard_mssql.sql`, **`labor_market_dashboard_mssql_RUN_v8.sql`
(26,998, `885f0d9` 2026-07-29 — current front-page RUN)**,
`wage_comparison_tool_mssql_RUN.sql`, `wage_comparison_tool_mssql_validate.sql`.

**Present but not in the manifest:** `dist/` (release zips v0.9/v1.1,
`.build-staging/community-profile/`, `.vendor-cache/` of echarts/topojson/
tom-select), the `va-works-wp-theme` app (WordPress theme with inline embeds of
all four tools under `assets/embeds/`), `apps/wage-tool/wage-tool-hero.html` (a
second wage-tool variant), and bundled `counties-10m.json` in both map apps.

### STEP 1 — Front-page artifact vintage

- **A:** distinct `lwda_short_name` = `Alexandria/Arlington`, `Bay Consortium`,
  `Capital`, `Central`, `Crater`, `Greater Roanoke`, **`Hampton Roads`**, `New
  River/Mt. Rogers`, `Northern`, `Piedmont`, `Shenandoah Valley`, `South Central`,
  `Southwest`, `West Piedmont`. Bare `"Hampton Roads"` → **v3-era**.
- **B:** distinct `statewide[].sector` = `Construction`, `Education & Health`,
  `Information`, `Manufacturing`, **`Trade & Transportation`** → **v3-era**.
- **C:** Government in `statewide[]`? **Absent** (`[]`) → **v3-era**. (Government
  *does* appear in `regions[].sectors[]`, but not the statewide rollup.)
- **D:** `regions[].label` = short (`Capital`, `Hampton Roads`, …) → **v3-era**.
- **E:** `kpi = {"virginia":{"value":3.8,"delta_pts":0},"us_average":{"value":4.4,"delta_pts":0}}`
  → delta_pts **not populated**.
- **F:** `as_of = "2026-03"`; `as_of_quarter = "2025-Q4"`.

**SQL vs JSON:** `labor_market_dashboard_mssql_RUN_v8.sql:66-77` — "the value is
the verbose … `AreaName`"; `:469-475` and `:533-539` construct a `'Government'`
rollup row. **The v8 SQL emits verbose labels and a Government rollup; the
deployed JSON has neither. They disagree — v8 was never run into these files.**

### STEP 2 — The `p50 = 0` leak

Counts over `.jobs[].areas[*]`:

| | wage-tool | employer |
|---|---|---|
| total cells | 5,026 | 10,601 |
| p10==0 | 18 | 0 |
| p25==0 | 26 | 0 |
| p50==0 | **57** | 0 |
| p75==0 | 57 | 0 |
| p90==0 | 57 | 0 |
| non-monotonic | 39 | 0 |

Example wage-tool p50=0: soc `11-1011` × areas `013980`, `016820`, `031340`.

- **SQL gate (WCT):** `wage_comparison_tool_mssql_RUN.sql:267` — `AND aw.p50 IS
  NOT NULL`. Percentiles built at `:231-235` via
  `MAX(CASE WHEN w.SuppressWage='0' THEN TRY_CAST(...) END)` — a real `0` survives.
- **SQL gate (EWT):** `employer_wage_tool_mssql_RUN.sql:653-654` — `lw.p50 IS NOT
  NULL`. Same `IS NOT NULL`, not `> 0`.
- **wage-tool JS still cascade-clamps:** `wage-tool.html:720-738`
  (`sanitizePercentiles()`), non-destructive: `if (e.p25 < e.p10) e.p25 = e.p10; …`.
  Note this clamps *ordering* but does **not** drop an all-zero cell, so a p50=0
  band collapses to zero rather than being removed.
- **employer JS drops only on null:** `wage-tool-employer.html:1272-1273` —
  `if (annual.p10 == null || … || annual.p50 == null … ) return null;` A literal
  `0` passes this guard and would render a broken band; the employer data simply
  has no zeros today.

### STEP 3 — The two `wages.json` files

| field | wage-tool | employer |
|---|---|---|
| top keys | `areas, jobs, meta` | `areas, jobs, meta` |
| `meta.latest_year` | 2024 | 2025 |
| `meta.trend_years` | `[2021,2023,2024]` | **absent** |
| native hourly (`p50_h`) | none (0 cells) | present (9,757 cells) |
| `aliases[]` populated | 772 / 777 jobs | **0 / 721 jobs (all empty)** |
| jobs count | 777 | 721 |
| bytes | 1,982,114 | 2,409,052 |
| `meta.source` | `WID.dbo.IOWAGE (T-SQL refresh)` | `WID.dbo.IOWAGE (T-SQL refresh)` |
| `extracted_at` | 2026-07-07 | 2026-06-12 |

**Still two divergent artifacts.** Different vintage year, different shape
(hourly vs trend), different alias population. Not unified.

### STEP 4 — Duplicate `unemployment_trend.json`

Both copies exist; **byte-identical** (MD5 `9730800545bec39b32922355811afdc5`
for both; `diff` clean). Shape: `months` 2023-04 … 2026-03 (36), `series` keys
`us_national`,`virginia`, `counties[]` length 133. No divergence to report.

### STEP 5 — Front-end deployment readiness

**Data fetch — all four hardcode relative `data/*.json`; no configurable base
URL, env var, or `window.__CONFIG__` anywhere.**
- wage-tool: `wage-tool.html:650-657` — `for (const path of ['data/wages.json',
  'data/wages.example.json']) { … fetch(path, {cache:'no-store'}) … }`; optional
  `data/employment_trend.json` at `:663-665`.
- employer: `wage-tool-employer.html:1778-1790` —
  `fetch('./data/wages.json').then(r=>r.json())`,
  `fetch('./data/industries.json')…`, and `soc-titles`/`soc-aliases` with
  `.then(r=>r.ok?r.json():{}).catch(()=>({}))`.
- community-profiles: `index.html:261` `fetch('data/counties-10m.json')`, `:273`
  `fetch('data/profiles.json')`, `:279` `fetch('data/unemployment_trend.json')`.
- dashboard: `index.html:1033-1035` fetches `employment_by_locality.json`,
  `unemployment_trend.json`, `jobs_by_industry.json`; `:572-573` `counties-10m.json`.

**Map geometry — bundled local, no CDN.** CP `index.html:261` "bundled locally
(us-atlas@3.0.1); no CDN call"; dashboard `:570-573` "Bundled locally … so the
map works on CDN-blocked networks." `counties-10m.json` is the **national**
us-atlas file (~842 KB), **not pre-filtered to FIPS 51.** ECharts + topojson-client
themselves still load from `cdn.jsdelivr.net` in all apps (e.g. CP `:10-11`).

**Fetch hardening — mixed:**
- wage-tool: fallback chain to `wages.example.json`, `fatal()` on CDN failure
  (`:644`), try/catch per fetch. Best-hardened.
- employer: has a loading state (`.frame.loading`, `wage-tool-employer.html:502,613`)
  but the **core `wages.json`/`industries.json` fetches have no `.catch`**
  (`:1778-1779`) — a 404 there is unhandled. No `as_of` surfaced (OEWS annual).
- community-profiles: try/catch on each fetch; geography-failure message at
  `:262`; surfaces `meta.generated` as "Data refreshed …" only when real fields
  exist, else an "Illustrative data" chip (`:714-716`).
- dashboard: surfaces `as_of` as an "Updated …" pill (`:557-558`); `catch(err)`
  handler at `:1053-1055`.

**404 fallback files:** only `apps/wage-tool/data/wages.example.json` exists (8
jobs). Employer, CP, and dashboard have no equivalent fallback file.

### STEP 6 — Community profile state

**6.1 genData present.** Yes — `index.html:846-1002` (~157 lines). Generates:
`population, ageCohorts, populationChange, projectedFrom, race,
industryEmployment (name/value/lq/growth), weeklyWage, wageAll, unemployment,
lfpr, commutePlaces, uiPayments, educationCompare, medianIncome, topEmployers,
employers (list/ownership/sizeDist), ovYears, popTrend, gdp, gdpTrend,
unempLatest, unempLatestYear, householdIncome, housing, costOfLiving,
laborForce, occupations, commute, business, apprenticeships, afford`. A separate
`demoData()` (`:2107`) supplies the Demographic section, and `empTop50()`
(`:1022`) the employer list.

**6.2 Dead configs.** `mk(id)` (`:1193`) returns null when
`document.getElementById(id)` is null. Static DOM containers present:
`c-medinc, c-rent, c-burden, c-demo-agebins, c-unemp-trend, c-lfpr-trend,
c-industry, c-industry-lq, c-business, c-business-industry, c-appr-occ,
c-appr-donut, c-emp-ownership, c-emp-size`. Only one chart is injected via the
scene template (`chart:'c-edu'`, `:1489`).

| config | config present | container present |
|---|---|---|
| c-pyramid | Y (`:1202`) | **N** (superseded by `c-demo-agebins`) |
| c-growth | Y (`:1211`) | **N** |
| c-race | Y (`:1220`) | **N** |
| c-wages | Y (`:1261`) | **N** |
| c-unemp | Y (`:1268`) | **N** (superseded by `c-unemp-trend`) |
| c-ui | Y (`:1316`) | **N** |

All six are orphaned `setOption` blocks that never render.

**6.3 Fabricated lq/growth.** Manifest says hash-of-name at ~1098-1100; that line
ref is stale. Current source is `genData:870-871`:
`lq:+(localShare/vaShare).toFixed(2), growth:+(indGrowthBias[i]+(rnd()-0.5)*5).toFixed(1)`
— `lq` = jittered share ratio, `growth` = a fixed `indGrowthBias` array plus RNG.
`c-industry-lq` (`:1248`) reads `d.industryEmployment[].lq`. `profiles.json`
`industryEmployment` objects carry only `{name, value}` (verified), so lq/growth
are never real. (Note: the merge at `:699` overwrites `d.industryEmployment`
wholesale with the profile array, so for real regions the mock lq/growth are
actually dropped to `undefined`.)

**6.4 Hardcoded VA benchmarks.**
- `vaMedianIncome = 83200` (`:994`), used at `:1387`. **Hardcoded.**
- `burdenVa: [29.1, 21.5, 10.4]` (`:998`), used at `:1382`. **Hardcoded.**
- education `vaPct = [3.6,6.1,25.9,21.0,7.9,21.8,13.7]` (`:907`). **Hardcoded.**
- `vaDiscretionary` — **not present** (dropped; `afford` object `:995-999` has no
  discretionary field). Manifest reference is stale.
- employer list — hardcoded in `empTop50()` (`:1022+`). Constant across geos.

**6.5 MSA grain — both halves needed, only the app half is ready.**
- App: `:348-350` uses `this.profileData.regions.msa` when present (6-digit Area
  codes); `:353-361` falls back to **7 hardcoded `msa-*` slugs**
  (`msa-richmond`, `msa-hamptonroads`, `msa-nova`, `msa-roanoke`,
  `msa-charlottesville`, `msa-lynchburg`, `msa-blacksburg`) when absent.
- Data: deployed `profiles.json` `.regions` has **only `lwda`** (no `msa`), 157
  profiles, and `meta.coverage` = "INTERIM DEPLOY: MSA regions+profiles stripped
  pending suffix-collision fix … MSA level renders curated fallback regions with
  illustrative data." So the app currently uses the 7-slug fallback and MSA
  regions get **no** real data. The app-side fix is done; the data-side is not.

**6.6 Per-section data source** — see Section 5 (chart inventory).

**6.7 CP-RUN coverage.** `community_profiles_mssql_RUN.sql` CTEs:
`g_vin, sg_vin, lf_vin, i_vin` (vintage anchors); `lwda_dim, lwda_members,
county_dim, msa_dim, msa_members, gova_members` (geography); `region_master,
region_members` (membership); `laus_county, laus_native, laus_rollup, unemp_final`
(LAUS unemployment); `sector_lookup, qcew_cell, ind_by_region` (QCEW industry).
Final `SELECT … FOR JSON` emits `meta`, `regions` (`lwda` + `msa`), and
`profiles[]` with `id, unempLatest, unempLatestYear, industryEmployment[{name,
value}]`. **Of the Step-6.6 sections it covers only Overview Unemployment,
Overview Top-3 Industries, and the Industry employment value.** Nothing for
GDP, Population, Demographic, Affordability, Labor-Force LFPR, New Business,
Apprenticeships, Higher Ed, or Location Quotient. (The committed RUN.sql *does*
emit `regions.msa` and MSA profiles — but the deployed JSON predates that.)

**6.8 Apprenticeships.** Fixed `summary:{ active:1240, activeYoyPct:12,
occupations:38, sponsors:52, topIndustry:'Construction' }` (`:977`), not jittered
— identical across every geography.

**6.9 Higher Ed.** `renderHigherEd()` (`:1200`) is commented "arch-driven
illustrative directory." The contract at `:1747-1764` documents the intended
IPEDS located-in + VCCS service-region model and states the VCCS locality-FIPS→
college crosswalk does not exist. **No VCCS crosswalk, no radius/drive-time
calc, no IPEDS-sourced data** — the section is still archetype-driven mock. There
is no `higherEdData()` function by that name; the section fills `#hied-list`
(`:1775, 1816`) from an arch archetype.

### STEP 7 — Validation tooling

No automated/CI test harness. Validation is hand-run SQL only:
`queries/community_profiles_mssql_validate.sql`,
`queries/community_profiles_mssql_validate_r4.sql`,
`queries/employer_wage_tool_mssql_validate.sql`,
`queries/wage_comparison_tool_mssql_validate.sql` — each is a probe file with
results logged inline as comments. Inline **SMOKE TESTS / assertion blocks**
exist in `community_profiles_mssql_RUN.sql` (S1-S9) and
`employer_wage_tool_mssql_RUN.sql`. No `*.test.*`, no assertion runner, no data-
schema validator in JS.

### STEP 8 — Static dependencies

| file | bytes | records |
|---|---|---|
| wage-tool-employer/data/soc-titles.json | 37,341 | **762** ✓ |
| wage-tool-employer/data/soc-aliases.json | 1,139,926 | **690** ✓ (live alias source) |
| wage-tool/data/wages.example.json | 13,087 | 8 jobs ✓ |
| community-profiles/data/_localities.json | 5,630 | 134 |
| community-profiles/data/va-localities.geojson | 1,696,803 | 134 features |

`_localities.json` and `va-localities.geojson` have **zero runtime references**
in `community-profiles/index.html` (the app fetches `counties-10m.json` instead).
Both are genuinely unreferenced at runtime.

### STEP 9 — Schema versioning

**No artifact carries `schema_version`.** Provenance is inconsistent:

| artifact | provenance |
|---|---|
| employment_by_locality.json | `as_of` only; **no `meta` block** (keys: as_of, counties, kpi) |
| unemployment_trend.json (both) | **none** (keys: months, series, counties) |
| jobs_by_industry.json | `as_of_quarter` only; **no `meta` block** |
| profiles.json | `meta{generated, laus_year, qcew_year, coverage}` |
| wage-tool/wages.json | `meta{source, extracted_at, latest_year, trend_years}` |
| wage-tool/employment_trend.json | `meta{source, extracted_at, months, notes}` |
| employer/wages.json | `meta{source, extracted_at, latest_year}` |
| employer/industries.json | `meta{source, extracted_at, latest_year}` |

The four SQL-refresh artifacts have `extracted_at` timestamps; the two v3-era
front-page files carry only an `as_of` string; `unemployment_trend.json` has no
provenance field of any kind.

---

## 4. Manifest discrepancies (chart-manifest.md dated 2026-07-29)

1. **Front-page vintage:** manifest calls the three JSONs "v3-era representative"
   — **confirmed true**, and this audit adds that RUN_v8 exists but was never run
   into them, so the SQL and deployed data disagree.
2. **CP `profiles.json` shape:** manifest §Artifact-inventory item 1 says "157
   profiles … no MSA" and coverage "MSA regions+profiles stripped" — **matches
   the deployed file exactly.** But the manifest does not flag that the committed
   `community_profiles_mssql_RUN.sql` was updated (2026-07-11) to emit MSA, so the
   deployed artifact now lags its own generator.
3. **lq/growth line reference:** manifest points at "~lines 1098-1100 … hash of
   sector name." Stale — the code is at `genData:870-871` and uses a share-ratio +
   `indGrowthBias` array, not a name hash. Conclusion (synthesized, not real) still
   holds.
4. **`vaDiscretionary`:** manifest lists it among hardcoded benchmarks; it has
   since been **removed** from `genData` (no discretionary field remains).
5. **`c-home` chart:** manifest §row `c-home` (Avg Home Price trend) — **no such
   id exists** in the current DOM or configs (0 hits). The home-price trend was
   folded elsewhere or dropped.
6. **`c-unemp` / `c-pyramid` etc.:** manifest still describes these as live
   charts; they are now **dead configs** with no container (Step 6.2).
7. **Manifest omits** the entire `va-works-wp-theme` app, the `dist/` release
   pipeline, and `wage-tool-hero.html` — all present in the repo.
8. **Employer fetch hardening:** manifest implies parity; in fact the employer
   tool's core data fetch is the one unguarded path (Step 5).

---

## 5. Community profile chart inventory

`real` = value comes from an emitted JSON artifact for the selected region;
`mock` = `genData()`/`demoData()`/hardcoded. Real fields today (per merge at
`index.html:699`, keys present in `profiles.json`): `unempLatest`,
`unempLatestYear`, `industryEmployment` (value) — and **not** at MSA level.

| chart id | section | data source | real / mock | artifact field |
|---|---|---|---|---|
| ov-unemp (KPI) | Overview | profiles.json | **real** (mock at MSA) | `profiles[].unempLatest` |
| ov-ind (Top-3) | Overview | profiles.json | **real** (mock at MSA) | `profiles[].industryEmployment` |
| ov-gdp (KPI+spark) | Overview | genData `d.gdp/gdpTrend` | mock | — (BEA representative) |
| ov-pop (KPI+spark) | Overview | genData `d.population/popTrend` | mock | — (Population WID empty) |
| c-demo-agebins | Demographic | demoData() arch | mock (ignores geography) | — (ACS DP05) |
| demo BANs (pop/age) | Demographic | demoData() arch | mock | — |
| c-edu | Demographic | genData `educationCompare`; `vaPct` hardcoded | mock | — (ACS S1501) |
| hied-list | Higher Ed | arch archetype | mock (no VCCS/IPEDS) | — |
| c-medinc | Affordability | genData `afford.medianIncome`; `vaMedianIncome` hardcoded | mock | — (ACS DP03 / WID Income empty) |
| c-rent | Affordability | genData `afford.rentTrend` | mock | — (ACS DP04) |
| c-burden | Affordability | genData `afford.burdenRegion`; `burdenVa` hardcoded | mock | — (ACS B25092/B25071) |
| household/occupancy KPIs | Affordability | genData `afford.*` | mock | — |
| c-unemp-trend | Labor Force | unemployment_trend.json | **real (County/City only)**; mock other levels | `counties[].data`, `series.virginia` |
| unemp BANs | Labor Force | derived from same trend | **real (County/City)** | same |
| c-lfpr-trend | Labor Force | genData `lfpr` | mock | — (ACS S2301) |
| c-industry | Employers | profiles.json value + synthesized growth arrow | **value real** (mock at MSA); growth mock | `industryEmployment[].value` |
| c-industry-lq | Employers | genData `industryEmployment[].lq` | mock (synthesized) | — |
| c-business | Employers | genData `business.formations` | mock | — (QCEW/BED) |
| c-business-industry | Employers | genData `business.byIndustry` | mock | — |
| c-appr-occ | Employers | genData `apprenticeships.byOccupation` | mock (fixed) | — (RAPIDS) |
| c-appr-donut + BANs | Employers | genData `apprenticeships` (`active:1240`) | mock (fixed all geos) | — |
| c-emp-ownership | Employers | genData `employers.ownership` | mock (per-region seed) | — (Industry Ownership) |
| c-emp-size | Employers | genData `employers.sizeDist` | mock | — |
| emp-table (list) | Employers | `empTop50()` | mock (hardcoded, statewide) | — (VI_Top50Employers) |
| c-pyramid, c-growth, c-race, c-wages, c-unemp, c-ui | — | orphaned configs, no container | **dead** | — |

---

## 6. Open questions

1. **Was RUN_v8 ever intended to ship to the front page?** The v8 SQL
   (`885f0d9`, 2026-07-29) postdates the deployed v3-era JSON but was never run
   into it. Settle by: running v8 and diffing its output against the three
   deployed files, or a decision that the v3 artifacts are the intended demo data.
2. **Why is the deployed `profiles.json` older than its RUN.sql?** The committed
   query emits MSA (168 profiles); the file has 157 and no MSA. Settle by
   re-running `community_profiles_mssql_RUN.sql` against WID and checking the
   profile count and `regions.msa` presence.
3. **wage-tool p50=0 provenance.** The 57 zero cells — are they BLS top-code
   markers mis-exported as 0 (as the clamp comment at `wage-tool.html:712-714`
   theorizes) or genuine suppression? Settle by inspecting the source `IOWAGE`
   rows for one example pair (soc `11-1011`, area `013980`).
4. **Employer core-fetch resilience.** `wage-tool-employer.html:1778-1779` has no
   `.catch`; is a 404 on `wages.json`/`industries.json` acceptable to fail hard,
   or should it degrade like wage-tool? Product decision.
5. **`counties-10m.json` size.** It is the national file (~842 KB) bundled in two
   apps; pre-filtering to FIPS 51 would cut payload. Was national kept
   deliberately (shared with a US context) or just not yet trimmed?
6. **Duplicate `unemployment_trend.json`.** Currently byte-identical; is the
   intent to keep two copies (per-app self-containment) or to symlink/share one?
