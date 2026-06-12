# Employer Wage Tool (Pay-Band Planner)

> **Living document.** Any change to the SQL in `queries/employer_wage_tool_mssql_RUN.sql` (or the `_validate.sql` companion) must be reflected here — especially the ERD join keys, the Validation Status table, and the unit-test SELECTs. Treat the Validation Status table as the source of truth for what has been verified against the live WID server.

---

## Part 1 — Overview

### What this tool does

The **Pay-Band Planner** is a self-service tool for Virginia employers building or benchmarking a wage offer. The user picks an **industry** (NAICS sector), a **job family** (SOC major group), a **region** (one of 14 LWDAs or "Virginia statewide"), and a **target percentile** (10–90, default 60). The tool returns:

- A **pay-band chart** showing the full p10–p90 wage distribution for every SOC-6 occupation in the chosen family, with the target percentile rendered as a vertical line on each bar.
- An **industry summary band** at the top showing mean wage, hourly equivalent, employment, and establishment count for the chosen NAICS × region cell.
- A **KPI strip** with the suggested budget range across the family, median market position, and total hiring pool size.

The tool replaces the spreadsheet workflow that VEC's employer outreach team historically maintained — the same OEWS percentile tables, but interactive, regionally aware, and tied to a refreshable data pipeline.

### Where the data comes from

All data flows out of the **WID 3.0 SQL Server** (Workforce Information Database, read-only Azure SQL Server instance hosted by VEC). The tool does **not** call the database at page load. A scheduled job runs the two SQL queries in `queries/employer_wage_tool_mssql_RUN.sql`, captures each `FOR JSON PATH` result as a static `.json` file, and deploys those files alongside the HTML/JS bundle.

```
WID 3.0 SQL Server   ──►  RUN.sql (2 queries)   ──►  2 JSON files       ──►  ECharts (browser)
(authoritative          (scheduled refresh,           wages.json              (renders the pay-band
 BLS source data)        read-only;                   industries.json          chart and KPIs)
                         _validate optional
                         schema check)
                                                  ──►  2 static lookups       (client-side label
                                                       soc-titles.json         enrichment, see
                                                       soc-aliases.json        Part 4 — Static lookups)
```

There is **no elevated setup step**. LWDA codes AND labels come live from `WID.dbo.GEOGRAPHIES` on every refresh (see Part 3). LWDA additions, retirements, and renames flow through automatically with zero manual edits.

This is the same JSON-on-disk architecture as the Front Page Dashboard, for the same reasons: load-time performance, public-facing resilience, and a refresh cadence decoupled from page traffic.

### Refresh cadence

| Source | Update frequency | Driving release |
|---|---|---|
| IOWAGE (Q1 → `wages.json`) | Annual | BLS OEWS release (~5 months after the reference year) |
| INDUSTRY (Q2 → `industries.json`) | Annual | BLS QCEW annual release (~5 months after year-end) |

Both queries refresh on the same scheduled job. The tool's `meta.latest_year` field reads from `wages.json` and is the year displayed on screen.

### User flow

```
1. Empty state          ──►  user picks Industry (NAICS supersector dropdown)
2. Industry chosen      ──►  Industry summary band populates
3. + Family chosen      ──►  Pay-band chart renders, all SOC-6 jobs in family
4. + Region (default    ──►  All bars + summary band switch to that region's
   = Virginia statewide)     OEWS / QCEW data
5. + Target percentile  ──►  Vertical "target" line on each bar moves; KPI
   slider (10..90)           strip shows the suggested budget range
```

The region default is "Virginia" (statewide). When the user picks an LWDA, the tool reads the corresponding cell from each SOC's `areas` keyed object. If the LWDA cell is suppressed (BLS confidentiality), the cell falls back to the statewide value with `provenance: "statewide_fallback"` — see [Provenance handling](#provenance-handling) below.

### Provenance handling

OEWS percentile rows are suppressed by BLS when the underlying sample is too thin for the (occupation, geography) cell. The SQL handles this at extract time by computing a 3-state provenance flag per cell:

| Provenance value | Meaning |
|---|---|
| `lwda` | Native LWDA cell — the OEWS sample was large enough that BLS published it. |
| `statewide_fallback` | LWDA cell was suppressed; we copied the statewide value as the best available substitute. The number is statewide, not LWDA-specific. |
| `statewide` | This row IS the statewide cell (only set on the `virginia` area row). |

The front-end renders the provenance flag as a hint in the chart tooltip so the user knows when they're looking at a fallback vs. a native LWDA cell. The percentile values themselves are not interpolated — they are exact copies of what BLS published.

---

## Part 2 — Visualizations

The tool is a single-page interactive composed of three rendered zones, all driven by the same two JSON files.

| Zone | Source JSON | Renders from |
|---|---|---|
| **Industry summary band** (top) | `industries.json` | `sectors[naics].areas[regionId].{mean_wage, employment, establishments}` |
| **Pay-band chart** (center) | `wages.json` | `jobs[soc].areas[regionId].{p10..p90, p10_h..p90_h, employment, provenance}` for every SOC-6 in the chosen family |
| **KPI strip** (above chart) | `wages.json` (computed in JS) | Aggregates across the family: target-percentile range, median range, hiring pool size |

There is no separate "trend over time" view — OEWS is annual point-in-time, not time series. Year-over-year comparison would require multi-year data emission (not currently in scope).

### Q1 — `wages.json` (OEWS percentile wages)

**SQL output shape:**
```json
{
  "meta": {
    "source": "WID.dbo.IOWAGE (T-SQL refresh)",
    "extracted_at": "2026-06-12T18:08:21.233Z",
    "latest_year": 2025
  },
  "areas": [
    // area.id = the 6-digit GEOGRAPHIES.Area code; label = GEOGRAPHIES.AreaName verbatim.
    // LWDA rows have areatype "15"; the statewide row has areatype "01".
    // counties[] = the LWDA's county + independent-city membership, sourced live from
    // WID.dbo.SubGeographies (SubAreaType='04' — BLS lumps counties and indep cities here).
    // Statewide gets counties:[] (search shouldn't surface "Virginia" when typing a county).
    {
      "id":       "000449",
      "label":    "Capital Region (LWDA IX)",
      "areatype": "15",
      "counties": [
        "Charles City County", "Chesterfield County", "Goochland County",
        "Hanover County",      "Henrico County",      "New Kent County",
        "Powhatan County",     "Richmond city"
      ]
    },
    ...
    { "id": "000000", "label": "Virginia", "areatype": "01", "counties": [] }
  ],
  "jobs": [
    {
      "id":          "15-1211",
      "soc_code":    "15-1211",
      "label":       "Computer Systems Analysts",     // ← from soc_dim (SOCCodes); falls back to soc_code if dim missing
      "major_group": "Computer and Mathematical Occupations",
      "minor_code":  "15-1200",                        // ← BLS SOC-2018 minor-group code (NOT the SOC4-prefix structural derivation)
      "minor_group": "Computer Occupations",           // ← BLS SOC-2018 minor-group title; null if SOCParent walk fails
      "aliases":     [],                               // ← O*NET aliases (currently empty; see Part 4)
      "areas": {
        // Keys = the same lwda_code / statewide code from areas[].id above.
        "000449": {
          "p10": 84370,    "p25": 107680, "p50": 132220,
          "p75": 165690,   "p90": 209430,
          "p10_h":  40.56, "p25_h": 51.77, "p50_h": 63.57,
          "p75_h": 79.66,  "p90_h": 100.69,
          "employment": 7530,
          "provenance": "lwda"
        },
        ...
        "000000": {
          "p10": 83350, "p25": 106610, "p50": 136460, "p75": 171090, "p90": 211930,
          "p10_h": 40.07, "p25_h": 51.25, "p50_h": 65.61, "p75_h": 82.26, "p90_h": 101.89,
          "employment": 88280,
          "provenance": "statewide"
        }
      }
    },
    ...
  ]
}
```

> **Front-end data contract — required reading for any system that re-emits `wages.json` (replacement API, blob-delivery layer, etc.).** The browser consumes the following fields with the following semantics. Any replacement endpoint must match these shapes byte-for-byte or the front-end will silently degrade (empty regions, "Other" labels, blank charts) rather than fail loud.
>
> **`area.id`** — the 6-digit `GEOGRAPHIES.Area` code (LWDA `lwda_code` for `areatype === '15'`; the statewide area code for `areatype === '01'`). The UI never reads a slug literal. The default-region picker finds statewide via `area.areatype === '01'`. If a URL param exposes the selected region, the param value is the `lwda_code` (or statewide code), not a slug.
>
> **`area.label`** — `GEOGRAPHIES.AreaName` verbatim, including the "(LWDA …)" suffix. Rendered as-is in the region dropdown subtitle.
>
> **`area.counties`** — array of strings (county/city names from `GEOGRAPHIES.AreaName` at `AreaType='04'`). Powers the Region filter's **county-first search** UX: the dropdown flattens these into option rows, each tagged with its parent LWDA label, so an employer who types `"Henrico"` surfaces `"Henrico County → Capital Region (LWDA IX)"` and selecting it scopes the report to LWDA `000449`. **Statewide row MUST emit `counties: []`** (empty array, not omitted) — the front-end iterates `areas[].counties` unconditionally and an omitted field would surface "Virginia" mid-list when the user types unrelated text. A replacement endpoint that ships county names that don't match any actual VA county will produce phantom dropdown entries that route to wrong LWDAs.
>
> **`job.minor_code`** and **`job.minor_group`** — the BLS SOC-2018 **minor** group code and title resolved via SOCParent walk in `soc6_to_minor` CTE. Used by the front-end family-bucket title. **May be `null`** when the walk fails (SOC code not loaded in `SOCCodes` dim, or walks into the `'311100'` self-referencing-SOCParent anomaly — see [punchlist items 1 and 6](#)). Front-end falls back to `job.major_group` (the SOC major-group title) when `minor_group` is null. A replacement endpoint MUST either emit `minor_group` correctly OR emit `null` — emitting a wrong/stale value (e.g. the SOC4-prefix-based `XX-X000` structural derivation rather than the SOCParent-walked SOC-2018 minor) will produce "Computer and Mathematical Occupations" labels where "Computer Occupations" is correct, reintroducing the pre-2026-06-12 duplicate-major-group bug the client reported.
>
> **`job.major_group`** — the BLS SOC major group title (23-row reference set; `RIGHT(SOCCode, 4) = '0000'` rows). Always present; renders `'Other'` if the join misses. Treated as the fallback bucket label when `minor_group` is null.
>
> **`job.label`** — `SOCCodes.SOCTitle` for the SOC-6 detail row. Falls back to the hyphenated SOC code (e.g. `"21-1018"`) when the dim is missing that SOC. The `data/soc-titles.json` client-side fallback patches the missing-from-dim cases.
>
> **`job.areas`** — keyed object, keys = `area.id` values from above. Per-cell wage data with `provenance` field (`'lwda'` / `'statewide_fallback'` / `'statewide'`). A LWDA area_id key MAY be missing if the SOC has no statewide cell to fall back from — front-end treats missing keys as "no data, skip rendering this cell."

**Semantics:**
- Annual percentiles (`p10`..`p90`) are dollar amounts, integer-rounded.
- Hourly percentiles (`p10_h`..`p90_h`) are dollar amounts to 2 decimals (`DECIMAL(6,2)` in SQL). They are the OEWS-published hourly distribution, not annual / 2080.
- `employment` is the OEWS `EmpCount` for the (occupation, area) cell — used to size the hiring pool KPI.
- Top-code repair: BLS publishes `NULL` for p90 / p75 when the actual value exceeds the OEWS top-code threshold. The SQL applies a deterministic cap (`$239,200` annual / `$115.00` hourly) when the lower percentiles signal the cell is high-wage. This mirrors the v1 UI behavior — without it, high-wage management/medical SOCs would render with truncated bars.
- The `aliases` array is currently `[]` from SQL because the O*NET reference table is not yet loaded on this WID install — the front end soft-augments it from a separate static `soc-aliases.json` (see Part 4). The SQL has the alias-building CTE pre-written and commented out for the day WID exposes ONET_TITLES.
- **`counties[]` semantics**: sourced via `lwda_counties` CTE joining `SubGeographies` (vintage-pinned via `sgeo_vintage` MAX-anchor) → `GEOGRAPHIES` on the Sub* tuple. `SubAreaType='04'` lumps Virginia counties AND independent cities together by BLS convention (e.g. `Petersburg city` appears alongside `Dinwiddie County` in Crater LWDA's array). VA has 95 counties + 38 indep cities = 133 places total; the 14 LWDAs partition them exactly (no overlap, no gaps, verified by [Smoke Test 7](#smoke-test-7-lwda-tiling-partition-check) variant).
- **`minor_code` / `minor_group` semantics**: SOC-2018's hierarchy doesn't always put minor groups at `XX-X000` (e.g. `15-1200` Computer Occupations, `51-5100` Printing Workers, `29-1200` Healthcare Diagnosing or Treating Practitioners). A naive code-pattern filter (`RIGHT(SOCCode, 3) = '000'`) misses these — `soc6_to_minor` walks `SOCParent` instead, which is the BLS hierarchical definition and structurally agnostic to code patterns. ~99% of SOC-6 details resolve; 8 of 721 emit `null` on the 2026-06-12 refresh (5 because the SOC code isn't loaded in this WID install's `SOCCodes` dim, 3 because they walk into the `'311100'` self-ref anomaly — see [punchlist items 1 and 6](#)).

### Q2 — `industries.json` (QCEW industry summaries)

**SQL output shape:**
```json
{
  "meta": {
    "source": "WID.dbo.INDUSTRY (QCEW, T-SQL refresh)",
    "extracted_at": "2026-06-05T17:45:06.185Z",
    "latest_year": 2025
  },
  "areas": [
    // Same shape as wages.json areas[] EXCEPT no counties[] field — Q2's Region
    // dropdown was never replaced with county-first search (it serves the
    // industry summary band, not the chart). If the front-end is ever extended
    // so industries.json's Region filter also wants county search, mirror
    // wages.json's lwda_counties splice into Q2.
    // area.id is GEOGRAPHIES.Area (statewide is '000000' after Probe 12 dedupe,
    // not the phantom '000051' — see Q1 contract callout above).
    { "id": "000452", "label": "Alexandria/Arlington Region (LWDA XII)", "areatype": "15" },
    ...
    { "id": "000000", "label": "Virginia", "areatype": "01" }
  ],
  "sectors": [
    {
      "naics": "11",
      "label": "Agriculture, Forestry, Fishing & Hunting",
      "areas": {
        // Keys = the lwda_code / statewide code, matching areas[].id above.
        "000452": { "mean_wage": 48235, "employment": 31,   "establishments": 7 },
        ...
        "000000": { "mean_wage": 50912, "employment": 9842, "establishments": 1421 }
      }
    },
    ...
  ]
}
```

**Semantics:**
- `mean_wage` = `TotalWages / QuarterAvgEmp` on the annual aggregate row (`PeriodType='01' AND Period='00'`). This reproduces the BLS QCEW `AvgAnnualPay` methodology exactly. The derivation is needed because **this WID install does not expose the published `AvgAnnualPay` column** (a documented WID load gap — separate ticket).
- `employment` = `QuarterAvgEmp` on the annual aggregate row, with `(Month1Emp + Month2Emp + Month3Emp) / 3.0` as a fallback.
- `establishments` = `Establishments` count.
- All three values come from the BLS `Ownership='00'` (**Total Covered**) row, which is the sum of Federal (`'10'`) + State (`'20'`) + Local (`'30'`) + Private (`'50'`). **Do not** simultaneously filter on `'00'` and the four constituent codes — that double-counts. Note also that this WID install carries a separate `Ownership='80'` row (~343k VA rows) which is **industry-of-function government** employment (public teachers under NAICS 61, public-hospital nurses under NAICS 62, etc.) — it sits OUTSIDE Total Covered and is intentionally excluded by the `Ownership='00'` filter. P3 reconciliation (2026-06-10 audit) confirms `'00'` = `'10'+'20'+'30'+'50'` at ratio `1.0000`; `'80'` is supplemental, never a constituent of `'00'`. **Do not** widen the Q2 filter to `IN ('00','80')` — adds ~343k spurious workers already counted under their `'10'`/`'20'`/`'30'` ownership rows. Full background in `docs/client-tickets/wid-data-quality-punchlist.md` Note B.
- NAICS supersectors: 20 entries, covering all of NAICS 2-digit. **Three supersectors are stored as range strings** in the WID `IndCode` column — Manufacturing (`'31-33'`), Retail Trade (`'44-45'`), Transportation & Warehousing (`'48-49'`). The `naics_sectors` lookup CTE handles the mapping by storing both the WID-stored `wid_code` (used in the join) and the clean 2-digit `naics_code` (emitted to JSON).
- The Q2 query intentionally omits a `Suppress` filter. `INDUSTRY.Suppress='1'` covers ~66% of VA annual rows on this WID install — too broad to be BLS confidentiality. Values on flagged rows are populated and reconcile to statewide totals at 99.96% (per the `_validate.sql` diagnostic), suggesting the flag indicates imputation/quality rather than non-publishability. Revisit if WID load semantics are documented for this install.

---

## Part 3 — Data model (ERD)

The tool reads from **five** production WID 3.0 tables: `IOWAGE` and `INDUSTRY` (fact), `GEOGRAPHIES` (area dim), `SOCCodes` (occupation dim — SOC-6 titles AND the 23 SOC major-group titles), and `NAICSSectors` (sector dim — Q2 industry labels). There is **no local seed table** and **no setup step** — codes AND labels both come live from the WID dimensions on every refresh. LWDA additions, sector renames, and SOC-2018 → SOC-2028 transitions flow through automatically with zero manual edits.

> **Project-wide dimension-derived-labels standard.** Every human-readable label exposed in the dashboard comes from a WID 3.0 dimension table JOINed at refresh time. No hardcoded labels in CTEs, no labels in seed tables, no substring-parsing of dim fields. The one documented exception is the Front Page dashboard's `'Government'` rollup bar; this tool has no exceptions.

### Combined ERD — all tables and join keys

> **The 4-column geography join key** (StFips + AreaType + AreaTypeVersion + Area) is the canonical identity for any geographic row in WID. **`AreaTypeVersion` makes joins safe across BLS vintage rollovers** — without it, LWDA III's rename from "Western Virginia" (vintage 0000) to "Greater Roanoke Region" (vintage 0002) would silently corrupt joins. The Q1 + Q2 queries pin each fact table to its own `MAX(AreaTypeVersion)` via a vintage anchor CTE; the GEOGRAPHIES dimension is pinned to its own MAX independently. Fact and dimension vintages may legitimately differ — do not force them equal in joins.

```mermaid
erDiagram
    IOWAGE {
        varchar StFips PK "= '51' for Virginia"
        varchar AreaType PK "'01' state, '15' LWDA"
        varchar AreaTypeVersion PK "anchor to MAX() via vintage CTE"
        varchar Area PK "FIPS or BLS area code"
        varchar PeriodYear PK "= latest_oews_year"
        varchar OccCode PK "SOC-6, e.g. '11-1011' or '111011'"
        varchar RateType PK "'4'=annual, '1'=hourly"
        varchar IndCodeType "'10' = cross-industry rollup"
        varchar IndCode "'000000' = all industries"
        int EmpCount
        int Percentile10Wage
        int Percentile25Wage
        int MedianWage
        int Percentile75Wage
        int Percentile90Wage
        decimal MeanWage
        varchar SuppressWage "'0'=publishable, '1'=suppressed"
        varchar SuppressEmp  "'0'=publishable, '1'=suppressed"
    }

    INDUSTRY {
        varchar StFips PK "= '51'"
        varchar AreaType PK "'01' state, '15' LWDA"
        varchar AreaTypeVersion PK "anchor to MAX() via vintage CTE"
        varchar Area PK
        varchar PeriodYear PK "= latest_ind_year"
        varchar PeriodType PK "'01' = annual"
        varchar Period PK "'00' on annual rows = full-year aggregate"
        varchar IndCode PK "NAICS-2 or supersector range ('31-33', '44-45', '48-49')"
        varchar Ownership PK "'00' = Total Covered (used here)"
        bigint TotalWages
        int QuarterAvgEmp "annual avg lives here on PeriodType='01' rows"
        int Month1Emp
        int Month2Emp
        int Month3Emp
        int Establishments
        varchar Suppress "INTENTIONALLY NOT FILTERED — see Q2 semantics note"
    }

    GEOGRAPHIES {
        varchar StFips PK "= '51'"
        varchar AreaType PK "'15' = LWDA (lwda_dim), '01' = statewide (state_area)"
        varchar AreaTypeVersion PK "anchor to MAX() via vintage CTE"
        varchar Area PK "= LWDA code or statewide code; emitted as area.id"
        varchar AreaName "WID display name; emitted as area.label verbatim. '%Combined%' rows excluded for AreaType='15'."
    }

    SOCCodes {
        char SOCCode PK "CHAR(6) unhyphenated 6-digit SOC; e.g. '111011', '291141'"
        char SOCCodeType PK "vintage anchor — '19' = BLS SOC-2018 on this install"
        varchar SOCTitle "occupation label, Q1 `label` field"
        char SOCParent "tree pointer; major-group rows have SOCParent='000000'"
    }

    NAICSSectors {
        char NAICSSector PK "CHAR(2) leading 2-digit NAICS; e.g. '11','31','44','48','92'"
        varchar SectorDesc "sector label, Q2 `label` field"
    }

    SubGeographies {
        char StFips PK "= '51'"
        char AreaType PK "= '15' for LWDA→child edges"
        char AreaTypeVersion PK "anchor to MAX() via sgeo_vintage CTE — 3 vintages on this install (0000/0001/0002)"
        char Area PK "= the LWDA code (parent)"
        char SubStFips "= '51' (same state)"
        char SubAreaType "= '04' for counties + VA indep cities (BLS lumps both here)"
        char SubAreaTypeVersion "matches GEOGRAPHIES.AreaTypeVersion for the child row (used in JOIN)"
        char SubArea "= the county/city code (child)"
    }

    IOWAGE         }o--|| GEOGRAPHIES    : "(StFips, AreaType, Area) — Q1 LWDA cells"
    INDUSTRY       }o--|| GEOGRAPHIES    : "(StFips, AreaType, Area) — Q2 LWDA cells"
    IOWAGE         }o--|| SOCCodes       : "Q1: REPLACE(OccCode,'-','') = RTRIM(SOCCode), SOCCodeType anchored to '19'"
    INDUSTRY       }o--|| NAICSSectors   : "Q2: naics_sectors.naics_code = RTRIM(NAICSSector) (after wid_code-→-2-digit mapping)"
    SubGeographies }o--|| GEOGRAPHIES    : "(Area, AreaType='15') = LWDA parent row"
    SubGeographies }o--|| GEOGRAPHIES    : "(SubStFips, SubAreaType, SubAreaTypeVersion, SubArea) = county/city child row"
    SOCCodes       }o--|| SOCCodes       : "SOCParent self-join: SOC detail → broad → minor → major walk (soc6_to_minor CTE)"
```

**Join-key cheat sheet** (this is the most error-prone part of the codebase):

| Join | Composite key | Notes |
|---|---|---|
| `IOWAGE` ↔ `iowage_vintage` (anchor) | `(StFips, AreaType, AreaTypeVersion)` | Pins IOWAGE to its own `MAX(AreaTypeVersion)` per (StFips, AreaType) pair. |
| `GEOGRAPHIES` ↔ `geo_vintage` (anchor) | `(StFips, AreaType, AreaTypeVersion)` where `AreaType IN ('01','15')` | Pins GEOGRAPHIES to its own MAX per (StFips, AreaType), independently of IOWAGE/INDUSTRY. **May differ from the fact tables' vintages.** Covers AreaType `'01'` for the statewide row and `'15'` for LWDAs. |
| `INDUSTRY` ↔ `ind_vintage` (anchor) | `(StFips, AreaType, AreaTypeVersion)` | Same pattern as IOWAGE. |
| `IOWAGE` ↔ `lwda_dim` (Q1 LWDA cells) | `(StFips, AreaType, Area)` — **NOT** AreaTypeVersion | Vintages are pinned per table, joined on logical identity (StFips + AreaType + Area). Forcing AreaTypeVersion equality breaks rollovers. `lwda_dim` is built directly from GEOGRAPHIES at AreaType `'15'`. |
| `INDUSTRY` ↔ `lwda_dim` (Q2 LWDA cells) | `(StFips, AreaType, Area)` — **NOT** AreaTypeVersion | Same reason. |
| `state_area` CTE (built directly from GEOGRAPHIES at AreaType `'01'`) | (no further join) | Sources the statewide area code + label dynamically; no hardcoded `'virginia'` literal. |
| `INDUSTRY` ↔ `naics_sectors` (Q2 supersector lookup) | `INDUSTRY.IndCode = naics_sectors.wid_code` | `wid_code` is the WID-stored form (e.g. `'31-33'`); `naics_code` is the clean 2-digit form emitted to JSON. |
| `soc_dim` vintage filter (Q1) | `SOCCodeType = '19'` literal | Pinned to the BLS SOC-2018 vintage that IOWAGE rows are coded under. **Not** `MAX(SOCCodeType)` — see the inline header comment in `_RUN.sql`. If a second SOC vintage (e.g. SOC-2028 as `'20'`) ever loads, MAX would silently re-key every title against it before the OEWS load rolls forward, and labels would NULL out across the board. The literal fails LOUD instead — Spot-check A and the smoke tests catch it. Re-pin AND re-verify the IOWAGE↔SOCCodes intersection at the next vintage rollover. |
| `IOWAGE` ↔ `soc_dim` (Q1 SOC title) | `REPLACE(LTRIM(RTRIM(IOWAGE.OccCode)),'-','') = RTRIM(SOCCodes.SOCCode)` | IOWAGE stores SOC in either hyphenated or unhyphenated 6-digit form; SOCCodes is CHAR(6) unhyphenated. RTRIM is safe-by-default. |
| `soc_dim` → `major_group_dim` (Q1) | `RIGHT(soc_code,4)='0000' AND LEFT(soc_code,2)<>'00'` | The 23 SOC majors are derived from soc_dim itself — no separate table. The hardcoded 23-row VALUES CTE in prior versions is retired. |
| `naics_sectors` ↔ `naics_dim` (Q2 sector title) | `naics_sectors.naics_code = RTRIM(NAICSSectors.NAICSSector)` | naics_sectors still provides the IndCode → 2-digit mapping (wid_code/naics_code); naics_dim provides the SectorDesc label. No vintage column. |
| `SubGeographies` ↔ `sgeo_vintage` (anchor, Q1 only) | `(StFips, AreaType='15', AreaTypeVersion)` | Pins SubGeographies to its own `MAX(AreaTypeVersion)` per (StFips, AreaType). 3 vintages coexist on this install (`'0000'`/`'0001'`/`'0002'`, ~133 rows each) — without the pin, the 3× cartesian shows up as triplicated county names in `area.counties`. AreaType `'15'` only — we use SubGeographies only for the LWDA→child relationship; other parent tiers (PDC, MSA, etc.) aren't relevant. |
| `SubGeographies` ↔ `lwda_dim` (`lwda_counties` parent side) | `(SubGeographies.Area = lwda_dim.lwda_code)` after `WHERE AreaType='15'` | Identifies which LWDA each SubGeographies row points at. Pins to `sgeo_vintage`'s MAX. |
| `SubGeographies` ↔ `GEOGRAPHIES` (`lwda_counties` child side) | `(SubStFips, SubAreaType, SubAreaTypeVersion, SubArea)` → `(StFips, AreaType, AreaTypeVersion, Area)` | The full 4-column geo identity, BUT pinning to the **child** SubAreaTypeVersion column directly (not via a separate `geo_vintage_county` MAX-anchor). That's because SubGeographies's xwalk row stipulates "this LWDA points at THIS sub-area at THIS sub-vintage" — the child vintage tuple is authoritative for the relationship. AreaType `'04'` for counties + indep cities (BLS lumps both). Aliased `AreaName` flows through verbatim to `area.counties[]`. |
| `SOCCodes` ↔ `soc_dim` (Q1 minor-group dim) | `WHERE SOCCodeType='19' AND RIGHT(SOCParent, 4) = '0000' AND SOCCode <> SOCParent` | BLS-canonical definition of a SOC minor group: any row whose `SOCParent` is a major (parent ends in `'0000'`). NOT a code-pattern filter (`RIGHT(SOCCode,3)='000'`) — SOC-2018 has minor groups outside that pattern (`15-1200` Computer Occupations, `51-5100` Printing Workers, `29-1200` Healthcare Diagnosing or Treating Practitioners). The `SOCCode <> SOCParent` guard excludes the `'311100'` self-ref anomaly — see [punchlist item 6](../client-tickets/wid-data-quality-punchlist.md). Returns 97 rows (BLS spec: 98; missing Military `55-X000` which OEWS doesn't carry). |
| `SOCCodes` ↔ `SOCCodes` (self-join, `soc6_to_minor` walk) | 1-hop (`detail.SOCParent = minor.SOCCode`) OR 2-hop (`detail.SOCParent = broad.SOCCode AND broad.SOCParent = minor.SOCCode`) | The SOC hierarchy is fixed-depth — detail → broad → minor → major. Some details point directly at a minor (BLS skips the broad level), others through a broad. Two `LEFT JOIN`s + `COALESCE` cover both cases. ~99% of SOC-6 details resolve cleanly; 8 of 721 emit `null` on 2026-06-12 (5 because the SOC isn't in `SOCCodes` at all — [punchlist item 1](../client-tickets/wid-data-quality-punchlist.md); 3 because they walk through `'311100'` — [item 6](../client-tickets/wid-data-quality-punchlist.md)). |

### Q1 call-out — `wages.json`

```mermaid
erDiagram
    IOWAGE ||--o{ GEOGRAPHIES : "LWDA join (Q1 lwda_wages CTE — AreaType='15')"
    IOWAGE ||--o{ GEOGRAPHIES_state : "statewide join (state_wages CTE — AreaType='01')"
```

Filters applied:
- `StFips = '51'` (Virginia)
- `RateType IN ('1','4')` — `'4'` annual, `'1'` hourly, pivoted via conditional aggregation
- `IndCodeType = '10' AND IndCode = '000000'` — all-industries cross-industry row
- SOC-6 only: `LEN(REPLACE(LTRIM(RTRIM(OccCode)), '-', '')) = 6 AND RIGHT(...) <> '0'` (exclude BLS major-group aggregates which end in `0`)
- `SuppressWage = '0'` and `SuppressEmp = '0'` inside each conditional aggregate (so suppressed cells contribute `NULL`)
- Statewide-fallback logic: any (SOC, LWDA) cell where the LWDA `p50` is `NULL` after aggregation gets the statewide values copied in, with `provenance = 'statewide_fallback'`.

### Q2 call-out — `industries.json`

```mermaid
erDiagram
    INDUSTRY ||--o{ GEOGRAPHIES       : "LWDA join (Q2 lwda_qcew CTE — AreaType='15')"
    INDUSTRY ||--o{ GEOGRAPHIES_state : "statewide join (state_qcew CTE — AreaType='01')"
    INDUSTRY }o--|| naics_sectors     : "IndCode (wid form) → naics_code (clean form)"
```

Filters applied:
- `StFips = '51'`, `PeriodType = '01'`, `Period = '00'` (annual full-year aggregate)
- `Ownership = '00'` (BLS Total Covered row — already sums Federal + State + Local + Private)
- `IndCode` joined to the 20-row `naics_sectors` lookup. Joining on `IndCode` directly would silently drop Manufacturing / Retail / Transportation because of the hyphen-range storage format.

### LWDA tiling guarantee

The set of LWDAs is **inferred live from GEOGRAPHIES** at `AreaType='15'` after filtering `AreaName NOT LIKE '%Combined%'`. There is no hand-curated list to maintain. As a side effect, certain WID rows that look like LWDAs are filtered automatically:

- **`000491` — "Combined Projections Area (LWDA XI and XII)"**: a BLS-projections-only synthetic area aggregating Northern (`000451`) + Alexandria/Arlington (`000452`) for forecast modeling. It has no county membership in `SUBGEOGRAPHIES` — counties in that territory roll up directly to `000451` or `000452`. The `%Combined%` filter catches it; if a future vintage adds a new combined-projections supersector, the same filter catches it without code changes.
- **`000454` — "Greater Peninsula"**: a legacy LWDA boundary retired in an earlier vintage. The six localities formerly under Greater Peninsula — **York County, Hampton city, Newport News city, Poquoson city, Williamsburg city, James City County** — now all roll up to **Hampton Roads (`000456`)** in the current production vintage (`'0002'`). Verified against the 133-county SUBGEOGRAPHIES-derived roll-up shipped in the Front Page Dashboard's `employment_by_locality.json`: all six formerly-Peninsula localities carry `region = "000456"`, and the code `000454` appears in no county's `region` field. If BLS resurrects `000454` in a future vintage with its own AreaName (not matching `%Combined%`), the tool will pick it up automatically — verify the new tiling via [Smoke Test 7](#smoke-test-7-lwda-tiling-partition-check) before shipping.

**Coverage guarantee:** The LWDAs returned by the live `lwda_dim` CTE are expected to fully tile Virginia — every county / independent city in `SUBGEOGRAPHIES` (`AreaType='15'`, `SubAreaType='04'`) maps to exactly one of them, with no gaps and no double-homing. If this guarantee breaks (e.g. a new LWDA appears in GEOGRAPHIES but isn't reachable from SUBGEOGRAPHIES, or boundary overlaps appear during a vintage transition), the per-LWDA employment totals in `industries.json` and `wages.json` will drift **uniformly low** against the statewide row. The dedicated catch is [Smoke Test 7](#smoke-test-7-lwda-tiling-partition-check); the symptom it disambiguates is described in the Recon 2 failure-mode notes.

---

## Part 4 — Static lookups

Two static JSON files ship with the tool. They serve **different roles** post the SOCCodes wire-in:

| File | Role | What happens if missing |
|---|---|---|
| `data/soc-titles.json` | **NULL-only fallback.** The SQL now emits `SOCCodes.SOCTitle` live as `job.label` (see `soc_dim` CTE in `_RUN.sql` Q1). This file patches the rare cases where SOCCodes has no row for a SOC-6 (new BLS code not yet in the dim, or a vintage mismatch). | Job labels fall back to the SOC code (`"11-1011"` instead of `"Chief Executives"`) only for the missing rows. Tool remains usable. |
| `data/soc-aliases.json` | **LIVE alias source — NOT a fallback.** Carries curated O*NET ALTERNATE titles (e.g. SOC `29-1141` → `["RN", "Nurse Practitioner", "Cardiac Nurse"]`). Powers the family dropdown's alias-aware search. | Family dropdown falls back to literal-text search. Tool remains usable. |

**Why `soc-aliases.json` stays live (not retired) even though SOCCodes is now wired.** This is the most important nuance in the rewire. There are *three* candidate dim sources for aliases:

1. **`WID.dbo.OccupationXOccupation`** — the BLS WID 3.0 spec's SOC↔ONET↔alt-title crosswalk. **EMPTY** on this install (probe `P3` RESULTS LOG: 0 rows). This is the *right* dim and would replace `soc-aliases.json` entirely if loaded — file the load gap against the WID owner.
2. **`WID.dbo.ONETCodes`** — LOADED, but carries O*NET **formal** occupation titles, not alternate titles. Treating it as an alias source would (a) duplicate the SOCTitle on many SOC-6 rows, (b) miss the 2-5 curated colloquial labels per occupation that `soc-aliases.json` actually carries. This is the *wrong* dim. The SQL has a lossy-proxy CTE for it (commented out in `_RUN.sql` Q1) reserved for the day `soc-aliases.json` becomes unavailable AND `OccupationXOccupation` is still empty.
3. **`data/soc-aliases.json`** — the best-available source on this install. Curated against the real O*NET Alternate Titles file. **This is the live alias source today** and stays in production until `OccupationXOccupation` loads.

`soc-aliases.json` is not in the SQL pipeline because it doesn't need to be — its refresh cadence (~5 year BLS SOC vintage cycle) is decoupled from the WID monthly/annual refresh. Both files are loaded via `fetch(...).then(r => r.ok ? r.json() : {}).catch(() => ({}))` — soft-fail; they don't block refresh.

**Future state.** When `WID.dbo.OccupationXOccupation` is loaded, rewrite the commented aliases CTE in `_RUN.sql` Q1 against that table (not the ONETCodes-direct lossy proxy currently sketched in the block), uncomment, and retire `soc-aliases.json` to a NULL-only fallback like `soc-titles.json`. The load-gap ticket is in [Known WID 3.0 load gaps](#known-wid-30-load-gaps-on-this-install).

---

## Part 5 — Technical reference

### WID 3.0 conventions

| Convention | Detail |
|---|---|
| Schema | `WID.dbo.*` — production tables only. **No local seed tables.** |
| State filter | `StFips = '51'` for Virginia, always-quoted string |
| AreaType codes | `'01'` state, `'15'` LWDA (the tool does **not** read county-level rows) |
| AreaTypeVersion | Each table's vintage is independent; anchor via `MAX(AreaTypeVersion) GROUP BY (StFips, AreaType)` in a CTE. Fact and GEOGRAPHIES vintages may legitimately differ — pin each independently. |
| Read-only | The scheduled `_RUN.sql` job account has only `SELECT` rights. There is no elevated setup step — labels and codes come live from `GEOGRAPHIES` on every refresh. |
| Min version | SQL Server 2017+ for `STRING_AGG`; 2016+ for `FOR JSON PATH`. Azure SQL (the prod host) satisfies both. |

### High-variance columns

Renaming any of these in SQL = silent wrong numbers (no error). Confirm via `_validate.sql` Probe 1.

- **IOWAGE percentiles** are named `Percentile10Wage` / `Percentile25Wage` / `MedianWage` / `Percentile75Wage` / `Percentile90Wage` in this WID install. BLS-variant installs sometimes name them `A_PCT10` / `ANNUAL_PCT10_WAGE` / `AnnWage10`. Wrong column name = silent wrong numbers.
- **IOWAGE.RateType** values are `'4'` (annual, ~$67K median) and `'1'` (hourly, ~$32 median). Confirm via `_validate.sql` Probe 4. Wrong code = entire pivot collapses to NULL.
- **INDUSTRY.QuarterAvgEmp** is the source of truth for annual-average employment on `PeriodType='01' Period='00'` rows. The `(Month1Emp + Month2Emp + Month3Emp) / 3.0` form is the documented fallback — used only if `QuarterAvgEmp` is `NULL`.
- **INDUSTRY.Establishments** — confirm via Probe 1. Some BLS variants name this `AnnualAvgEst` or `QtrlyEstabs`.

### Known WID 3.0 load gaps on this install

These are documented gaps where this WID install lacks columns or tables the BLS WID 3.0 spec defines. Track separately as load-gap tickets to the WID owner — not workarounds to bake in permanently.

| Spec column / table | Status here | Workaround in this pipeline |
|---|---|---|
| `IOWAGE.OccName` | Missing — **no longer load-bearing.** | SOC-6 labels are now sourced live from `WID.dbo.SOCCodes.SOCTitle` via `soc_dim` (Q1). `data/soc-titles.json` is retained only as a NULL-only client-side fallback for SOC-6 rows missing from SOCCodes. The ticket remains open for spec completeness but the dashboard no longer needs it. |
| `INDUSTRY.AvgAnnualPay` | Missing | Computed inline as `TotalWages / NULLIF(QuarterAvgEmp, 0)` on `PeriodType='01' AND Period='00'` rows (matches BLS published `AvgAnnualPay` methodology). |
| `WID.dbo.OccupationXOccupation` | **Structurally present, EMPTY (0 rows).** This is the BLS WID 3.0 spec's SOC↔ONET↔alt-title crosswalk — the *correct* alias dimension. | `aliases` field emits `[]` from SQL. **`data/soc-aliases.json` is the LIVE alias source** (not a fallback) and stays in production until this crosswalk loads. `WID.dbo.ONETCodes` is LOADED but carries O*NET formal titles, not alt titles, so it's not a substitute — see [Part 4](#part-4--static-lookups) for the full reasoning. A lossy-proxy CTE against ONETCodes is sketched in `_RUN.sql` Q1 (commented) for the day `soc-aliases.json` goes away. |
| `WID.dbo.GEOGRAPHIES.ShortName` | Missing (no ShortName / Alias / DisplayName / Abbreviation column on this install — probe RESULTS LOG P6). | `areas[].label` is `GEOGRAPHIES.AreaName` verbatim — `"Alexandria/Arlington Region (LWDA XII)"` etc. — including the verbose `(LWDA …)` suffix. Acceptable for a dropdown; not blocking. Front-end UI may abbreviate at render time; the SQL never substring-parses. |

### Why JSON-on-disk instead of live SQL

Same rationale as the Front Page Dashboard:
- Public-facing tool — page load is the user-experience constraint.
- WID server is internal and not built for public traffic.
- Refresh cadence (annual) is far slower than employer outreach cycles — there is no business case for sub-second freshness.
- A failed refresh produces stale-but-correct data, not an outage.

### Validation Status

Each row marks whether an assumption has been **Confirmed** against the live WID server or is **Assumed (pending validation)**. Update this table whenever you re-run `_validate.sql` or spot-check the production output.

| # | Assumption | Status | Source of confirmation |
|---|---|---|---|
| 1 | `IOWAGE` exposes `Percentile10Wage`, `Percentile25Wage`, `MedianWage`, `Percentile75Wage`, `Percentile90Wage`, `MeanWage`, `EmpCount`, `RateType`, `OccCode`, `IndCode`, `IndCodeType`, `SuppressWage`, `SuppressEmp` | **Confirmed** | `_validate.sql` Probe 1, 2026-06-04 (header marker in `_RUN.sql:41–43`). |
| 2 | `IOWAGE.OccName` is **missing** — **no longer load-bearing** | **Confirmed** | Same probe. Documented load gap. SOC-6 labels now sourced live from `WID.dbo.SOCCodes.SOCTitle` via `soc_dim` (Q1) per probe RESULTS LOG P1; `data/soc-titles.json` demoted to NULL-only fallback. |
| 3 | `IOWAGE.RateType` values: `'4'` = Annual (~$67K median), `'1'` = Hourly (~$32 median) | **Confirmed** | `_validate.sql` Probe 4, 2026-06-04. |
| 4 | `IOWAGE.AreaType = '15'` for LWDAs | **Confirmed** | `_validate.sql` Probe 2 + Probe 3, 2026-06-04. |
| 5 | OEWS published at LWDA granularity (Probe 3 returned non-zero rows for `AreaType='15'`) | **Confirmed** | `_validate.sql` Probe 3, 2026-06-04. If a future refresh shows zero LWDA rows, every cell falls back to statewide — still valid output, but worth flagging in the UI. |
| 6 | `IOWAGE` stores SOC codes as 6 digits with hyphen optional (e.g. `'111011'` or `'11-1011'`) — the `REPLACE(..., '-', '')` normalization handles both forms | **Assumed — pending validation** | Defensive normalization; never been seen failing, but not separately probed. Run [Smoke Test 4 — SOC code format](#smoke-test-4-soc-code-format-in-iowage). |
| 7 | `INDUSTRY` exposes `TotalWages`, `QuarterAvgEmp`, `Establishments`, `Month1Emp`, `Month2Emp`, `Month3Emp`, `IndCode`, `Ownership`, `Suppress` | **Confirmed** | `_validate.sql` Probe 1, 2026-06-04. |
| 8 | `INDUSTRY.AvgAnnualPay` is **missing** (BLS spec column not loaded) | **Confirmed** | Probe 1 + `_RUN.sql:60–64` header note. Documented load gap. |
| 9 | `INDUSTRY.Ownership = '00'` is the BLS Total Covered row, equal to sum of `'10'+'20'+'30'+'50'` | **Confirmed** | `_validate.sql` Probe 4 + value reconciliation, 2026-06-04. |
| 10 | `INDUSTRY.PeriodType = '01'` annual, `Period = '00'` on annual rows = full-year aggregate | **Confirmed** | `_validate.sql` Probe 4, 2026-06-04. |
| 11 | NAICS supersectors are stored as range strings in `IndCode` — `'31-33'`, `'44-45'`, `'48-49'` (the other 17 are single 2-digit codes) | **Confirmed** | Spot-checked against `_RUN.sql:519–528` header note; resulting `industries.json` has all 20 sectors populated, confirming the join works. |
| 12 | `INDUSTRY.Suppress = '1'` covers ~66% of VA annual rows, with populated values reconciling to statewide totals at 99.96% — i.e. the flag indicates imputation/quality, not non-publishability | **Confirmed (architectural decision)** | `_validate.sql` diagnostic + `_RUN.sql:582–587` comment. The Q2 query intentionally does **not** filter on `Suppress`. Revisit if WID load semantics are documented for this install. |
| 13 | Fact tables (IOWAGE / INDUSTRY) and the GEOGRAPHIES dimension may carry **different** `AreaTypeVersion` values. Vintages should be pinned independently and joined on `(StFips, AreaType, Area)` only — not on `AreaTypeVersion`. | **Confirmed (architectural decision)** | Established pattern in `_RUN.sql:222–227` (with explicit inline comment). |
| 14 | LWDA codes AND labels resolved live from `WID.dbo.GEOGRAPHIES` at `AreaType='15'` (with `AreaName NOT LIKE '%Combined%'`). No seed table. Same pattern for the statewide row at `AreaType='01'`. | **Confirmed (architectural decision)** | `_RUN.sql` `lwda_dim` + `state_area` CTEs. Validated by [Smoke Test 7 — LWDA tiling partition check](#smoke-test-7-lwda-tiling-partition-check) on every refresh. Future LWDA changes (additions, retirements, renames) flow through automatically. |
| 15 | `WID.dbo.OccupationXOccupation` exists structurally but has **0 rows** on this install (prior versions had this row pointed at the BLS-spec name `ONET_TITLES`). This is the SOC↔ONET↔alt-title crosswalk — the correct alias dimension. | **Confirmed (load gap)** | `queries/dimension_resolution_probe.sql` P3 RESULTS LOG (2026-06-10). Aliases stay sourced from `data/soc-aliases.json` (the LIVE alias source — see [Part 4](#part-4--static-lookups)). The commented onet_aliases CTE in `_RUN.sql` Q1 sketches the ONETCodes-direct lossy proxy reserved for the day soc-aliases.json goes away. |
| 16 | Top-code repair thresholds (`$239,200` annual, `$115.00` hourly) match what the UI v1 used | **Confirmed (architectural decision)** | These are the documented OEWS top-codes for the relevant reference year. If BLS changes them, this constant moves with the SQL — flag any change here. |
| 17 | `WID.dbo.SOCCodes` is LOADED. 1,447 rows, distinct SOC-6 codes. SOC-6 titles AND the 23 SOC major-group labels both come live from this dim via `soc_dim` + `major_group_dim` CTEs in Q1. **Vintage pinned to the literal `SOCCodeType='19'`** (BLS SOC-2018) — deliberately NOT `MAX()`. If a second SOC vintage ever loads, MAX would silently re-key titles before IOWAGE rolls forward; the literal fails LOUD instead, surfacing the mismatch via Spot-check A. **Known coverage gap:** 5 SOC-2018 codes are referenced in `IOWAGE` but absent from `SOCCodes` at vintage `'19'` (`211018`, `252052`, `259045`, `512028`, `531047`). Those rows emit with the hyphenated SOC-6 as `label`; the client-side `data/soc-titles.json` covers them with human titles until the WID owner reloads `SOCCodes` against the current SOC-2018 reference file. Tracked in `docs/client-tickets/wid-data-quality-punchlist.md` item 1. | **Confirmed** | `queries/dimension_resolution_probe.sql` P1 + P9.a RESULTS LOG (2026-06-10). The hardcoded 23-row major_groups VALUES CTE in prior versions is retired. |
| 18 | `WID.dbo.NAICSSectors` is LOADED. 20 BLS NAICS-2 sectors with SectorDesc labels. Q2 `industries.json` sector labels come live from this dim via `naics_dim`. No vintage column — flat reference dim. | **Confirmed** | `queries/dimension_resolution_probe.sql` P4 RESULTS LOG (2026-06-10). The hardcoded `sector_name` column on the Q2 `naics_sectors` VALUES CTE is retired. |
| 19 | `WID.dbo.NAICSSectors.SectorDesc` has known typos on this install — `'54'` = "Professiona.l Scientific & Technical Svc"; `'56'` = "Admin., Support, Waste Mgmt, Remediation". These flow through verbatim and are filed against the WID data-QA backlog. Not patched in SQL. | **Confirmed (data-QA backlog ticket)** | `queries/dimension_resolution_probe.sql` P4 RESULTS LOG. Until WID fixes, the UI will display the typos. |
| 20 | `WID.dbo.GEOGRAPHIES` has **no** ShortName / Alias / DisplayName / Abbreviation column on this install. `areas[].label` is `AreaName` verbatim including the `(LWDA …)` suffix. | **Confirmed (load gap)** | `queries/dimension_resolution_probe.sql` P6 RESULTS LOG. Verbose emission is the standard-compliant interim until WID adds a short-name column. Front-end UI may abbreviate at render time; SQL never substring-parses dim fields. |
| 21 | `INDUSTRY.Ownership='80'` is industry-of-function government employment (~343k VA rows; public teachers under NAICS 61, public-hospital nurses under NAICS 62, Public Administration under NAICS 92). It sits **OUTSIDE** `'00'` Total Covered (P3 reconciliation: `Ownership IN ('10','20','30','50')` sums to `'00'` at ratio `1.0000`). Q2's `Ownership='00'` filter correctly excludes `'80'` — including it would double-count government workers already counted under `'10'`/`'20'`/`'30'` in their employer-ownership rows. **Do not** widen the Q2 filter to `IN ('00','80')`. | **Confirmed (architectural decision, 2026-06-10 audit)** | Commit `5a7d8da`. Full reasoning in `docs/client-tickets/wid-data-quality-punchlist.md` Note B; sister Front Page Validation Status row #17 carries the parallel Q3 isolation context (which uses a two-gate exclusion since Q3 needs the granular constituent rows for the Government rollup; Q2 doesn't, so the single `'00'` filter suffices). |

---

## Part 6 — Unit-test validation SQL

Run these SELECT statements directly in SQL Server Management Studio (SSMS) or Azure Data Studio against the WID server. All queries are read-only.

> **Anchor your expectations.** All hard-coded expected values in this section are anchored to the **2026-06-05 WID extract** (current production JSON deploy, `latest_year = 2025`). After any annual refresh, expected values for `latest_year`, `mean_wage`, percentile values, etc. will advance. A "fail" is when the *shape* changes (column count, distinct LWDA count, sector count, etc.) — not when the dollar amounts move.

### Tier 1 — Sanity counts

#### Smoke Test 1: Column inventory
Confirms all expected columns exist on the source tables. Resolves Validation Status rows **#1, #2, #7, #8**.

```sql
-- EXPECT: rows for every column listed in the ERD. Missing columns = the
-- query in _RUN.sql will fail or silently return wrong numbers.
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
FROM WID.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME IN ('IOWAGE','INDUSTRY','GEOGRAPHIES','ONET_TITLES')
ORDER BY TABLE_NAME, ORDINAL_POSITION;
```

#### Smoke Test 2: LWDA dimension sanity (replaces the retired LWDA_Slugs seed-integrity check)
The seed-integrity check from prior versions has been retired — there is no seed table to validate. This replacement confirms that the live `lwda_dim` CTE (used by `_RUN.sql` and Smoke Test 7) returns a sane LWDA list with non-NULL labels and an excluded-Combined count of zero.

```sql
-- EXPECT (anchored to the 2026-06-05 extract, GEOGRAPHIES vintage '0002'):
--   active_lwda_count          = 14
--   combined_filtered_count    = 1 (the '000491' Combined Projections Area)
--   null_or_empty_labels       = 0
--   null_or_empty_codes        = 0
-- A drift in active_lwda_count means BLS added or retired an LWDA in this
-- vintage. Re-run Smoke Test 7 to confirm the new set still tiles VA, then
-- re-deploy the JSON. No SQL edits required.
WITH geo_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY StFips, AreaType
)
SELECT
    SUM(CASE WHEN g.AreaName NOT LIKE '%Combined%' THEN 1 ELSE 0 END) AS active_lwda_count,
    SUM(CASE WHEN g.AreaName     LIKE '%Combined%' THEN 1 ELSE 0 END) AS combined_filtered_count,
    SUM(CASE WHEN g.AreaName NOT LIKE '%Combined%'
              AND (g.AreaName IS NULL OR g.AreaName = '') THEN 1 ELSE 0 END) AS null_or_empty_labels,
    SUM(CASE WHEN g.Area IS NULL OR g.Area = '' THEN 1 ELSE 0 END) AS null_or_empty_codes
FROM WID.dbo.GEOGRAPHIES g
JOIN geo_vintage gv
  ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
 AND g.AreaTypeVersion = gv.AreaTypeVersion
WHERE g.StFips = '51' AND g.AreaType = '15';
```

#### Smoke Test 3: IOWAGE rate-type pivot will work
Resolves Validation Status row **#3**.
```sql
-- EXPECT (anchored to 2026-06-05 extract):
--   RateType '1' (Hourly):  large count, MIN(MedianWage)  ≈ $10-15, MAX ≈ $100+
--   RateType '4' (Annual):  large count, MIN(MedianWage)  ≈ $25-30K, MAX ≈ $200K+
--   Any other RateType value present = a new code BLS introduced; the pivot
--   will silently emit NULL for those occupations.
SELECT
    RateType,
    COUNT(*)                     AS row_count,
    MIN(TRY_CAST(MedianWage AS DECIMAL(12,2))) AS min_median,
    MAX(TRY_CAST(MedianWage AS DECIMAL(12,2))) AS max_median
FROM WID.dbo.IOWAGE
WHERE StFips = '51'
GROUP BY RateType
ORDER BY RateType;
```

#### Smoke Test 4: SOC code format in IOWAGE
Resolves Validation Status row **#6**.
```sql
-- EXPECT (anchored to 2026-06-05 extract):
--   exactly one of (hyphenated, unhyphenated) is the dominant form;
--   the REPLACE(..., '-', '') normalization tolerates either.
--   If both forms are present in non-trivial counts, double-counting risk.
SELECT
    CASE WHEN CHARINDEX('-', OccCode) > 0 THEN 'hyphenated (XX-XXXX)'
         ELSE 'unhyphenated (XXXXXX)'
    END AS soc_format,
    COUNT(*) AS row_count,
    MIN(OccCode) AS sample_low,
    MAX(OccCode) AS sample_high
FROM WID.dbo.IOWAGE
WHERE StFips = '51'
GROUP BY CASE WHEN CHARINDEX('-', OccCode) > 0 THEN 'hyphenated (XX-XXXX)' ELSE 'unhyphenated (XXXXXX)' END;
```

#### Smoke Test 5: NAICS supersector coverage in INDUSTRY
Confirms Validation Status row **#11** still holds after refresh.
```sql
-- EXPECT (anchored to 2026-06-05 extract):
--   20 distinct supersector codes (matches the 20-row naics_sectors lookup)
--   Includes the three range strings: '31-33', '44-45', '48-49'.
SELECT
    LTRIM(RTRIM(IndCode)) AS ind_code,
    COUNT(*) AS row_count
FROM WID.dbo.INDUSTRY
WHERE StFips = '51'
  AND AreaType = '01'
  AND PeriodType = '01' AND Period = '00'
  AND Ownership = '00'
  AND LTRIM(RTRIM(IndCode)) IN (
      '11','21','22','23','31-33','42','44-45','48-49',
      '51','52','53','54','55','56','61','62','71','72','81','92'
  )
GROUP BY LTRIM(RTRIM(IndCode))
ORDER BY ind_code;
```

#### Smoke Test 6: ONET_TITLES presence
Resolves Validation Status row **#15**.

> **Gate on Smoke Test 1 — do not run this blind.** A direct `SELECT FROM WID.dbo.ONET_TITLES` errors with Msg 208 (`Invalid object name`) if the table is absent, which is noise that confuses the operator. Smoke Test 1 already surfaces presence safely via `INFORMATION_SCHEMA.COLUMNS`: if Test 1 returns **no** rows for `TABLE_NAME = 'ONET_TITLES'`, the table is not loaded — **skip Smoke Test 6** and mark Validation Status row #15 as Confirmed-missing (the `soc-aliases.json` static lookup remains the answer). Only run the query below when Test 1 confirmed `ONET_TITLES` rows.

```sql
-- EXPECT (only run if Smoke Test 1 returned ONET_TITLES columns):
--   A sample row showing ONETSOC_CODE format (8 chars, e.g. '11-1011.00')
--   + a non-null ALTERNATE_TITLE column.
SELECT TOP 5 *
FROM WID.dbo.ONET_TITLES;
```

#### Smoke Test 7: LWDA tiling partition check
Resolves the **Coverage guarantee** stated in Part 3. Confirms that the LWDAs returned by the live `lwda_dim` CTE (= `GEOGRAPHIES` at `AreaType='15'` with `AreaName NOT LIKE '%Combined%'`) fully tile Virginia — every county / independent city in `SUBGEOGRAPHIES` maps to exactly one active LWDA, with no gap (orphaned county) and no double-homing (county claimed by two LWDAs).

The check **reads membership directly from `GEOGRAPHIES` against `SUBGEOGRAPHIES`** — there is no seed table to consult and no list to keep in sync.
```sql
-- EXPECT (anchored to the 2026-06-05 extract, GEOGRAPHIES vintage '0002'):
--   counties_total              = 133
--   counties_mapped_to_active   = 133
--   counties_double_homed       = 0
--   counties_orphaned           = 0
--
-- Failure modes:
--   * counties_orphaned > 0      → a county in SUBGEOGRAPHIES rolls up to
--                                  an LWDA code that the lwda_dim CTE has
--                                  excluded. Most likely cause: the
--                                  GEOGRAPHIES row for that LWDA code has
--                                  an AreaName starting with "Combined"
--                                  (the lwda_dim filter excludes those),
--                                  or the LWDA row is absent from
--                                  GEOGRAPHIES entirely (a vintage-anchor
--                                  mismatch between SUBGEOGRAPHIES and
--                                  GEOGRAPHIES).
--                                  Resolution: run the DIAGNOSTIC query
--                                  below to see the orphan + reason.
--                                  Code change: usually none — the
--                                  AreaName filter is the safety net.
--   * counties_double_homed > 0  → a county appears under multiple active
--                                  LWDAs in SUBGEOGRAPHIES at the same
--                                  vintage. Only happens if SUBGEOGRAPHIES
--                                  carries overlapping boundary rows.
--                                  Resolution: re-check the sg_vintage
--                                  anchor and the SUBGEOGRAPHIES load.
--
-- This check is the disambiguator for Recon 2: a uniform sub-1.0 shortfall
-- on Recon 2 with this check PASSING points to vintage drift on the
-- INDUSTRY side; the same shortfall with this check FAILING points to a
-- tiling/coverage gap. Run both whenever Recon 2 drifts uniformly low.
WITH sg_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.SUBGEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY StFips, AreaType
),
geo_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY StFips, AreaType
),
lwda_dim_live AS (
    -- Mirrors lwda_dim in _RUN.sql exactly — the source of truth for which
    -- LWDA codes are "active" in this refresh.
    SELECT g.Area AS lwda_code
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
),
county_to_lwda AS (
    SELECT
        sg.SubArea                                            AS county_code,
        sg.Area                                               AS lwda_code,
        CASE WHEN ld.lwda_code IS NOT NULL THEN 1 ELSE 0 END  AS is_active
    FROM WID.dbo.SUBGEOGRAPHIES sg
    JOIN sg_vintage sgv
      ON sg.StFips = sgv.StFips AND sg.AreaType = sgv.AreaType
     AND sg.AreaTypeVersion = sgv.AreaTypeVersion
    LEFT JOIN lwda_dim_live ld
      ON ld.lwda_code = sg.Area
    WHERE sg.StFips = '51' AND sg.AreaType = '15' AND sg.SubAreaType = '04'
),
county_homes AS (
    SELECT county_code, SUM(is_active) AS active_homes
    FROM county_to_lwda
    GROUP BY county_code
)
SELECT
    COUNT(*)                                            AS counties_total,
    SUM(CASE WHEN active_homes >= 1 THEN 1 ELSE 0 END)  AS counties_mapped_to_active,
    SUM(CASE WHEN active_homes  > 1 THEN 1 ELSE 0 END)  AS counties_double_homed,
    SUM(CASE WHEN active_homes  = 0 THEN 1 ELSE 0 END)  AS counties_orphaned
FROM county_homes;
```

For diagnostic detail when the partition check fails, run this companion query — it returns every county whose LWDA assignment is excluded from `lwda_dim`, plus the reason for the exclusion (Combined-filtered vs. absent from GEOGRAPHIES):
```sql
-- DIAGNOSTIC: list orphaned counties + the unseeded LWDA + reason.
-- Run only when Smoke Test 7 reports counties_orphaned > 0.
WITH sg_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.SUBGEOGRAPHIES
    WHERE StFips = '51' AND AreaType = '15'
    GROUP BY StFips, AreaType
),
geo_vintage AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.GEOGRAPHIES
    WHERE StFips = '51' AND AreaType IN ('04','15')
    GROUP BY StFips, AreaType
),
lwda_dim_live AS (
    SELECT g.Area AS lwda_code
    FROM WID.dbo.GEOGRAPHIES g
    JOIN geo_vintage gv
      ON g.StFips = gv.StFips AND g.AreaType = gv.AreaType
     AND g.AreaTypeVersion = gv.AreaTypeVersion
    WHERE g.StFips = '51' AND g.AreaType = '15'
      AND g.AreaName NOT LIKE '%Combined%'
)
SELECT
    sg.SubArea                  AS county_code,
    gc.AreaName                 AS county_name,
    sg.Area                     AS orphan_lwda_code,
    gl.AreaName                 AS orphan_lwda_name,
    CASE
        WHEN gl.AreaName LIKE '%Combined%'  THEN 'Excluded by lwda_dim %Combined% filter (expected)'
        WHEN gl.AreaName IS NULL            THEN 'LWDA code present in SUBGEOGRAPHIES but absent from GEOGRAPHIES at current vintage'
        ELSE 'Present in GEOGRAPHIES but excluded for an unknown reason — investigate lwda_dim filter'
    END                         AS exclusion_reason
FROM WID.dbo.SUBGEOGRAPHIES sg
JOIN sg_vintage sgv
  ON sg.StFips = sgv.StFips AND sg.AreaType = sgv.AreaType
 AND sg.AreaTypeVersion = sgv.AreaTypeVersion
LEFT JOIN lwda_dim_live ld
  ON ld.lwda_code = sg.Area
LEFT JOIN WID.dbo.GEOGRAPHIES gc
  ON gc.StFips = '51' AND gc.AreaType = '04' AND gc.Area = sg.SubArea
LEFT JOIN geo_vintage gcv
  ON gcv.StFips = gc.StFips AND gcv.AreaType = gc.AreaType
 AND gcv.AreaTypeVersion = gc.AreaTypeVersion
LEFT JOIN WID.dbo.GEOGRAPHIES gl
  ON gl.StFips = '51' AND gl.AreaType = '15' AND gl.Area = sg.Area
WHERE sg.StFips = '51' AND sg.AreaType = '15' AND sg.SubAreaType = '04'
  AND ld.lwda_code IS NULL
ORDER BY sg.Area, sg.SubArea;
```

### Tier 2 — Spot-checks (anchored to 2026-06-05 extract)

#### Spot-check A — Software Developers (15-1252) statewide annual wages
```sql
-- EXPECT (anchored to the 2026-06-05 extract, OEWS reference year 2025):
--   p10 ≈ $73-80K, p50 ≈ $124-132K, p90 ≈ $200K+
-- These are derived from the Virginia row of jobs[15-1252].areas.virginia
-- in wages.json. Update these expected ranges when the JSON refreshes.
SELECT
    REPLACE(OccCode, '-', '') AS soc_code_normalized,
    RateType,
    TRY_CAST(Percentile10Wage AS INT)  AS p10,
    TRY_CAST(Percentile25Wage AS INT)  AS p25,
    TRY_CAST(MedianWage       AS INT)  AS p50,
    TRY_CAST(Percentile75Wage AS INT)  AS p75,
    TRY_CAST(Percentile90Wage AS INT)  AS p90,
    TRY_CAST(EmpCount         AS INT)  AS employment
FROM WID.dbo.IOWAGE w
WHERE w.StFips = '51' AND w.AreaType = '01'
  AND w.PeriodYear = (
      SELECT MAX(PeriodYear) FROM WID.dbo.IOWAGE WHERE StFips = '51' AND AreaType = '01'
  )
  AND w.IndCodeType = '10' AND w.IndCode = '000000'
  AND REPLACE(w.OccCode, '-', '') = '151252'   -- Software Developers
  AND w.RateType = '4'                          -- annual
  AND w.SuppressWage = '0';
```

#### Spot-check B — Northern LWDA Software Developers (regional wage premium)
```sql
-- EXPECT (anchored to the 2026-06-05 extract):
--   Northern LWDA (code '000451') median annual ≈ 1.10-1.25× of statewide
--   (NoVA labor market commands a premium). A ratio < 0.9 OR > 1.5 suggests
--   either a join breakage or a vintage misalignment.
SELECT
    g.AreaName,
    TRY_CAST(w.MedianWage AS INT) AS median_annual,
    TRY_CAST(w.EmpCount   AS INT) AS employment
FROM WID.dbo.IOWAGE w
JOIN WID.dbo.GEOGRAPHIES g
  ON g.StFips = w.StFips AND g.AreaType = w.AreaType AND g.Area = w.Area
WHERE w.StFips = '51' AND w.AreaType = '15'
  AND g.Area = '000451'                          -- Northern
  AND w.PeriodYear = (
      SELECT MAX(PeriodYear) FROM WID.dbo.IOWAGE WHERE StFips = '51' AND AreaType = '15'
  )
  AND w.IndCodeType = '10' AND w.IndCode = '000000'
  AND REPLACE(w.OccCode, '-', '') = '151252'
  AND w.RateType = '4'
  AND w.SuppressWage = '0';
```

#### Spot-check C — Manufacturing (NAICS 31-33) statewide industry summary
```sql
-- EXPECT (anchored to the 2026-06-05 extract, QCEW reference year 2025):
--   mean_wage     ≈ $68-78K
--   employment    ≈ 240-260K
--   establishments ≈ 5,000-6,000
-- Update these expected ranges when the JSON refreshes.
SELECT
    LTRIM(RTRIM(i.IndCode))                                         AS wid_ind_code,
    TRY_CAST(i.TotalWages / NULLIF(i.QuarterAvgEmp, 0) AS INT)       AS mean_wage,
    TRY_CAST(i.QuarterAvgEmp                          AS INT)        AS employment,
    TRY_CAST(i.Establishments                         AS INT)        AS establishments
FROM WID.dbo.INDUSTRY i
WHERE i.StFips = '51' AND i.AreaType = '01'
  AND i.PeriodYear = (
      SELECT MAX(PeriodYear) FROM WID.dbo.INDUSTRY
      WHERE StFips = '51' AND AreaType = '01'
        AND PeriodType = '01' AND Period = '00'
  )
  AND i.PeriodType = '01' AND i.Period = '00'
  AND i.Ownership = '00'
  AND LTRIM(RTRIM(i.IndCode)) = '31-33';            -- Manufacturing
```

### Tier 3 — Reconciliation

> The reconciliation tier is the most important check after a refresh. It catches **AreaTypeVersion vintage double-counting**, which is the failure mode the per-table vintage anchor pattern guards against. If the vintage anchors are silently misaligned (e.g. two IOWAGE vintages stacked), the sum across LWDAs will be ≈ 2× the statewide total — and the per-region percentiles will still look plausible.

#### Recon 1 — IOWAGE: sum of LWDA employment ≈ statewide employment (per SOC)
```sql
-- EXPECT (anchored to the 2026-06-05 extract):
--   For each high-employment SOC: sum_lwda_emp ≈ statewide_emp ± 15%
--   (slack accounts for legitimate LWDA suppression of cells with thin
--   samples that statewide nets out).
--   A ratio > 1.5 = vintage double-counting. < 0.5 = systemic suppression
--   or a missing LWDA row in the join.
WITH iv AS (
    SELECT StFips, AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.IOWAGE WHERE StFips='51' GROUP BY StFips, AreaType
),
ly AS (
    SELECT MAX(PeriodYear) AS yr FROM WID.dbo.IOWAGE w
    JOIN iv ON w.StFips=iv.StFips AND w.AreaType=iv.AreaType AND w.AreaTypeVersion=iv.AreaTypeVersion
    WHERE w.StFips='51' AND w.AreaType='01'
)
SELECT
    REPLACE(w.OccCode, '-', '') AS soc_code,
    SUM(CASE WHEN w.AreaType='15' THEN TRY_CAST(w.EmpCount AS INT) END) AS sum_lwda_emp,
    SUM(CASE WHEN w.AreaType='01' THEN TRY_CAST(w.EmpCount AS INT) END) AS statewide_emp,
    CAST(SUM(CASE WHEN w.AreaType='15' THEN TRY_CAST(w.EmpCount AS INT) END) * 1.0
       / NULLIF(SUM(CASE WHEN w.AreaType='01' THEN TRY_CAST(w.EmpCount AS INT) END), 0)
       AS DECIMAL(5,3)) AS ratio_should_be_0_85_to_1_15
FROM WID.dbo.IOWAGE w
JOIN iv ON w.StFips=iv.StFips AND w.AreaType=iv.AreaType AND w.AreaTypeVersion=iv.AreaTypeVersion
CROSS JOIN ly
WHERE w.StFips='51' AND w.AreaType IN ('01','15')
  AND w.PeriodYear = ly.yr
  AND w.RateType = '4'
  AND w.IndCodeType = '10' AND w.IndCode = '000000'
  AND w.SuppressEmp = '0'
  AND REPLACE(w.OccCode, '-', '') IN (
      '151252',   -- Software Developers (large, urban-concentrated)
      '291141',   -- Registered Nurses    (large, broadly distributed)
      '412031',   -- Retail Salespersons  (large, broadly distributed)
      '533032'    -- Heavy Truck Drivers  (large, broadly distributed)
  )
GROUP BY REPLACE(w.OccCode, '-', '')
ORDER BY soc_code;
```

#### Recon 2 — INDUSTRY: sum of per-LWDA employment ≈ statewide employment (per NAICS)
```sql
-- EXPECT (anchored to the 2026-06-05 extract):
--   For each NAICS supersector: sum_lwda_emp ≈ statewide_emp, ratio ∈ [0.95, 1.05].
--   This is a tighter tolerance than the OEWS reconciliation because QCEW
--   does not heavily suppress at the supersector level.
--
-- Failure-mode disambiguation (the key check after a refresh):
--   * Ratio ≈ 2.0 across MOST sectors                  → vintage double-counting.
--     A second INDUSTRY vintage has been silently stacked into the sum
--     (per-table AreaTypeVersion anchor missing or misaligned). Re-check
--     ind_vintage in _RUN.sql.
--
--   * Ratio ≈ 0.9 (or any uniform sub-1.0 value)
--     UNIFORMLY across ALL 20 sectors                  → LWDA tiling/coverage gap.
--     A real LWDA exists in INDUSTRY but isn't returned by lwda_dim (most
--     commonly because GEOGRAPHIES has it under a "Combined"-prefixed
--     AreaName, or because GEOGRAPHIES is missing the row entirely at the
--     current vintage). The LWDA's employment never reaches the per-sector
--     LWDA sum — every sector shorts by the same population share. This is
--     NOT vintage double-counting and the fix is different: run Smoke Test
--     7 (LWDA tiling partition check) to identify the orphaned LWDA(s) and
--     the exclusion reason. Usually no SQL edit is needed — the AreaName
--     filter is the safety net. If the orphan is legitimate and should be
--     included, the fix is in the GEOGRAPHIES dimension or the lwda_dim
--     filter, not in any seed table.
--
--   * Ratio scattered, a few sectors at 0.95 and others at 1.02         → legitimate
--     suppression or sector-specific reporting lag. Not a defect; QCEW
--     publishing cadence is uneven across sectors.
--
-- Run Smoke Test 7 FIRST whenever Recon 2 drifts uniformly low — it tells
-- you immediately whether to look for a vintage bug (Test 7 passes) or
-- a seed-table gap (Test 7 fails).
WITH iv AS (
    SELECT AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.INDUSTRY WHERE StFips='51' AND AreaType IN ('01','15')
    GROUP BY AreaType
),
ly AS (
    SELECT MAX(PeriodYear) AS yr FROM WID.dbo.INDUSTRY i
    JOIN iv ON i.AreaType=iv.AreaType AND i.AreaTypeVersion=iv.AreaTypeVersion
    WHERE i.StFips='51' AND i.AreaType='01' AND i.PeriodType='01' AND i.Period='00'
)
SELECT
    LTRIM(RTRIM(i.IndCode)) AS wid_ind_code,
    SUM(CASE WHEN i.AreaType='15' THEN i.QuarterAvgEmp END) AS sum_lwda_emp,
    SUM(CASE WHEN i.AreaType='01' THEN i.QuarterAvgEmp END) AS statewide_emp,
    CAST(SUM(CASE WHEN i.AreaType='15' THEN i.QuarterAvgEmp END) * 1.0
       / NULLIF(SUM(CASE WHEN i.AreaType='01' THEN i.QuarterAvgEmp END), 0)
       AS DECIMAL(5,3)) AS ratio_should_be_0_95_to_1_05
FROM WID.dbo.INDUSTRY i
JOIN iv ON i.AreaType=iv.AreaType AND i.AreaTypeVersion=iv.AreaTypeVersion
CROSS JOIN ly
WHERE i.StFips='51'
  AND i.AreaType IN ('01','15')
  AND i.PeriodType='01' AND i.Period='00'
  AND i.Ownership='00'
  AND i.PeriodYear = ly.yr
  AND LTRIM(RTRIM(i.IndCode)) IN (
      '11','21','22','23','31-33','42','44-45','48-49',
      '51','52','53','54','55','56','61','62','71','72','81','92'
  )
GROUP BY LTRIM(RTRIM(i.IndCode))
ORDER BY wid_ind_code;
```

#### Recon 3 — INDUSTRY: Ownership '00' = sum of '10'+'20'+'30'+'50'
Confirms Validation Status row **#9** still holds. This is the single most important check, because the Q2 query relies on `'00'` as a pre-computed sum.
```sql
-- EXPECT (anchored to the 2026-06-05 extract):
--   For each NAICS supersector, totals_match_pct ≈ 100.0%.
--   Anything below 99% suggests the constituents and the Total Covered
--   row have drifted out of sync — switch the Q2 query to use the
--   constituents-summed form (commented in the SQL header).
WITH iv AS (
    SELECT AreaType, MAX(AreaTypeVersion) AS AreaTypeVersion
    FROM WID.dbo.INDUSTRY WHERE StFips='51' AND AreaType='01'
    GROUP BY AreaType
)
SELECT
    LTRIM(RTRIM(i.IndCode)) AS wid_ind_code,
    SUM(CASE WHEN i.Ownership='00' THEN i.QuarterAvgEmp END)                          AS total_covered_00,
    SUM(CASE WHEN i.Ownership IN ('10','20','30','50') THEN i.QuarterAvgEmp END)      AS sum_constituents,
    CAST(SUM(CASE WHEN i.Ownership='00' THEN i.QuarterAvgEmp END) * 100.0
       / NULLIF(SUM(CASE WHEN i.Ownership IN ('10','20','30','50') THEN i.QuarterAvgEmp END), 0)
       AS DECIMAL(6,2)) AS totals_match_pct
FROM WID.dbo.INDUSTRY i
JOIN iv ON i.AreaType=iv.AreaType AND i.AreaTypeVersion=iv.AreaTypeVersion
WHERE i.StFips='51' AND i.AreaType='01'
  AND i.PeriodType='01' AND i.Period='00'
  AND i.PeriodYear = (
      SELECT MAX(PeriodYear) FROM WID.dbo.INDUSTRY
      WHERE StFips='51' AND AreaType='01' AND PeriodType='01' AND Period='00'
  )
  AND LTRIM(RTRIM(i.IndCode)) IN (
      '11','21','22','23','31-33','42','44-45','48-49',
      '51','52','53','54','55','56','61','62','71','72','81','92'
  )
GROUP BY LTRIM(RTRIM(i.IndCode))
ORDER BY wid_ind_code;
```

---

## Appendix — File map

```
HighCharts/
├── apps/
│   └── wage-tool-employer/                  ← deployed tool
│       ├── wage-tool-employer.html          ← all rendering, math, controls
│       ├── vercel.json                      ← deploy config
│       └── data/
│           ├── wages.json                   ← Q1 output (OEWS percentiles)
│           ├── industries.json              ← Q2 output (QCEW summaries)
│           ├── soc-titles.json              ← static lookup: SOC-6 → title
│           └── soc-aliases.json             ← static lookup: SOC-6 → aliases
└── queries/
    ├── employer_wage_tool_mssql_validate.sql   ← schema-discovery probes, run once during commissioning
    ├── employer_wage_tool_mssql_RUN.sql        ← the 2 queries that emit wages + industries
    ├── dimension_resolution_probe.sql          ← cross-tool probe of dim tables (SOCCodes, ONETCodes,
    │                                              OccupationXOccupation, NAICSSectors, NAICSSuperSectors,
    │                                              GEOGRAPHIES short-name); RESULTS LOG at the bottom
    │                                              drives the dimension-derived-labels rewires
    └── employer_wage_tool_snowflake.sql        ← legacy Snowflake reference (not deployed)
```

> **Migration note (from prior versions):** earlier versions of this tool used a hand-maintained `dbo.LWDA_Slugs` seed table populated by a `_setup.sql` script. Both have been removed under the dimension-derived-labels standard. If your WID server still has the table from a prior install, you can drop it after the new SQL deploys: `DROP TABLE dbo.LWDA_Slugs;` (requires elevated privileges; the read-only refresh account no longer touches the table). The companion `_RUN_smoke.sql` file (which inlined the seed for dev use) has also been removed.

### Order of operations for a clean install

1. Run `_validate.sql` against the live WID server to confirm schema assumptions. Capture the output for the Validation Status table in this doc. **Read-only — no elevated step required.**
2. Schedule `_RUN.sql` on the read-only account. Each invocation emits two `NVARCHAR(MAX)` cells — capture them as `wages.json` and `industries.json` respectively. LWDA codes + labels resolve live on every run; no setup needed.
3. Deploy the JSON files to `apps/wage-tool-employer/data/`. The Vercel build at the project root will pick them up on next push.
4. After the first deploy, run [Smoke Test 7](#smoke-test-7-lwda-tiling-partition-check) to confirm the live LWDA set fully tiles Virginia. Re-run Smoke Test 7 after any GEOGRAPHIES vintage rollover.
