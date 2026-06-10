# WID 3.0 — Data-quality punch-list

> **Rolling list of small data-quality items** in the Virginia WID 3.0 deployment that affect dashboard labels but do not (individually) merit their own `WID-LOAD-GAP-*.md` ticket. Larger architectural gaps stay as standalone tickets (`WID-LOAD-GAP-AvgAnnualPay.md`, `WID-LOAD-GAP-OccName.md`). Add new items as they're discovered; close items in place with a `**Resolved YYYY-MM-DD**` marker before deleting.

**Conventions**
- **Table / field** — the WID 3.0 object that's affected.
- **Observed** — what the data looks like today.
- **Expected** — what the BLS / WID 3.0 spec says it should look like (or what a clean load would emit).
- **Affects** — which dashboard surface(s) carry the consequence today, and how.
- **Requested action** — what the WID owner needs to do to clear the item.

---

## 1. `SOCCodes` (type `'19'`) missing 5 SOC-2018 codes present in `IOWAGE`

**Table / field:** `WID.dbo.SOCCodes`, `(SOCCodeType, SOCCode)` pairs.

**Observed (2026-06-10).** `SOCCodes` carries 1,447 distinct SOC-6 codes under `SOCCodeType='19'` (BLS SOC-2018) on this install. `WID.dbo.IOWAGE` references 5 SOC-6 codes that are **not** in `SOCCodes` at that vintage:

| SOC-6 | Notes |
|---|---|
| `211018` | Community and Social Service occupation (newer SOC-2018 detail row not loaded into the dim) |
| `252052` | Educational Instruction and Library occupation |
| `259045` | Educational Instruction and Library occupation |
| `512028` | Production occupation |
| `531047` | Transportation and Material Moving occupation |

**Expected.** The SOC-2018 reference set the WID owner loaded should include every SOC-6 that BLS publishes wage data for. If `IOWAGE` is coded against SOC-2018 (which it is — `OccCodeType='19'` matches `SOCCodes.SOCCodeType='19'`), then 100% of `IOWAGE.OccCode` distinct values should resolve in `SOCCodes`.

Most likely root cause: the SOCCodes load used an outdated SOC-2018 snapshot pre-dating the BLS supplemental detail-code additions that IOWAGE has since picked up. The client should reload SOCCodes against the **current** SOC-2018 reference file (BLS publishes incremental detail-code updates between major SOC vintages).

**Affects.** **Employer Wage Tool** `wages.json` — the 5 SOCs above emit with `label = STUFF(soc_code, 3, 0, '-')` (the hyphenated SOC-6 fallback like `"21-1018"`) instead of the human title. The Q1 SELECT uses `COALESCE(sd.soc_title, hyphenated soc_code)`, so these rows render with code labels until the dim is reloaded. The `data/soc-titles.json` client-side fallback covers these 5 SOCs with human titles, so the UI stays usable in the interim — but the SQL-emitted JSON has the codes.

**Requested action.** Reload `WID.dbo.SOCCodes` from the current BLS SOC-2018 reference file. Verify the 5 codes above appear with their published titles. No SQL changes downstream — the existing `soc_dim` JOIN starts emitting the titles automatically on the next refresh after the dim updates.

---

## 2. `NAICSSectors.SectorDesc` — typos and embedded range annotations

**Table / field:** `WID.dbo.NAICSSectors.SectorDesc` (and `SectorDescLong`).

**Observed (probe RESULTS LOG P4).** Two label-quality issues in the live dim:

| NAICSSector | SectorDesc value | Issue |
|---|---|---|
| `'54'` | `Professiona.l Scientific & Technical Svc` | Stray period after "Professiona", missing comma between segments. `SectorDescLong` ("Professional., Scientific, and Technical Services") has the same typo. |
| `'56'` | `Admin., Support, Waste Mgmt, Remediation` | Heavily abbreviated. `SectorDescLong` is fuller. |
| `'31'` (and `'44'`, `'48'`) | `Manufacturing (31-33)` / `Retail Trade (44 & 45)` / `Transportation and Warehousing (48 & 49)` | The BLS supersector range annotation is embedded directly in the published label. Cosmetic, not wrong — but the redundant `(31-33)` etc. inside a UI that already groups by 2-digit sector is awkward. |

**Expected.** Clean BLS-canonical sector titles without trailing typos. Range annotations should ideally be in a separate column (or be dropped — the front end can render the range elsewhere).

**Affects.** **Employer Wage Tool** `industries.json` `sectors[].label` field. Labels flow verbatim from `naics_dim.sector_label` per the dimension-derived-labels standard. The typos and range annotations render directly in the sector dropdown.

**Requested action.** Fix the typos on `'54'` (and `SectorDescLong`) and `'56'`. For range annotations on `'31'` / `'44'` / `'48'`: either drop the parenthetical from `SectorDesc` (cleaner) or leave as-is (status-quo). No SQL changes downstream — fixes flow through on the next refresh.

---

## 3. `GEOGRAPHIES` — no LWDA short-name column

**Table / field:** `WID.dbo.GEOGRAPHIES`. Columns present: `StFips, AreaType, AreaTypeVersion, Area, AreaName, AreaDesc, Latitude, Longitude, GeoPrecisionCode`. Missing: any of `ShortName` / `Alias` / `DisplayName` / `Abbreviation`.

**Observed (probe RESULTS LOG P6).** `AreaName` for LWDA rows (AreaType `'15'`) is the verbose form including the `(LWDA …)` suffix:

```
000443  'Greater Roanoke Region (LWDA III)'
000452  'Alexandria/Arlington Region (LWDA XII)'
000456  'Hampton Roads (LWDA XIV)'                 ← irregular: no "Region"
```

There is no short-name column to source a compact display label from. Prior dashboard versions substring-parsed `AreaName` to extract a short label (`"Greater Roanoke"`, `"Alexandria/Arlington"`, `"Hampton Roads"`), which violated the project dimension-derived-labels standard (no substring-parsing of dim fields).

**Expected.** A `ShortName` / `Alias` column on `GEOGRAPHIES` for LWDA rows carrying the compact display label.

**Affects.** **Front Page Dashboard** `employment_by_locality.json` `counties[].lwda_short_name` and `jobs_by_industry.json` `regions[].label` both now emit the verbose `AreaName` verbatim per the standard. The front-end UI can abbreviate at render time, but the JSON payload is verbose. The longer labels affect bar-chart axis spacing and KPI-tile subtitles.

**Requested action.** Add a `ShortName` column to `GEOGRAPHIES` populated with the compact form for LWDA rows. The dim-derived JOIN updates trivially — swap `g.AreaName AS lwda_short_name` for `g.ShortName AS lwda_short_name` in the front-page `region_mapping` and `lwda_dim` CTEs.

---

## 4. `OccupationXOccupation` crosswalk — EMPTY (0 rows)

**Table / field:** `WID.dbo.OccupationXOccupation`. Columns present: `StFips CHAR(2), CodeType CHAR(2), Code CHAR(10), CodeType2 CHAR(2), Code2 CHAR(10)`. **Row count: 0.**

**Observed (probe RESULTS LOG P3).** The BLS WID 3.0 spec's SOC↔ONET↔alt-title crosswalk is structurally present but unpopulated. This is the *correct* dimension for SOC-6 → O*NET Alternate Titles lookups (e.g. SOC `29-1141` → `"RN"`, `"Nurse Practitioner"`, `"Cardiac Nurse"`).

**Expected.** The BLS O*NET Alternate Titles file loaded into this table with `CodeType='SOC-6'`, `CodeType2='ONET-AltTitle'` (or however WID 3.0 specs the relationship type).

**Affects.** **Employer Wage Tool** family-dropdown alias search. The SQL emits `aliases: []` from `wages.json`; the live alias source is the static client-side `data/soc-aliases.json` (curated O*NET alt titles). This works today but doesn't refresh automatically on BLS O*NET releases. The commented-out lossy-proxy CTE in `_RUN.sql` Q1 against `WID.dbo.ONETCodes` is **not** a substitute — `ONETCodes` carries formal O*NET titles, not alt titles, and would mistake "Chief Sustainability Officers" (a valid ONET detail title under SOC 11-1011) for an alias of "Chief Executives".

**Requested action.** Load `WID.dbo.OccupationXOccupation` from the current BLS O*NET Alternate Titles release. Once populated, rewrite the commented aliases CTE in `_RUN.sql` Q1 against the crosswalk (not the ONETCodes-direct lossy proxy currently sketched), uncomment, and retire `data/soc-aliases.json`.

---

## 5. `INDUSTRY.Ownership` — `'08'` Total Government convenience rollup not loaded

**Table / field:** `WID.dbo.INDUSTRY.Ownership`.

**Observed.** BLS QCEW canonically publishes a pre-summed `'08'` (or single-digit `8`) **Total Government** rollup row at every (NAICS, area) cell — equivalent to `Federal + State + Local`. This convenience code is not present on this WID install. The Ownership values that ARE present are: `'00'` Total Covered, `'10'` Federal, `'20'` State, `'30'` Local, `'50'` Private, and `'80'` (see [Documented encoding notes](#documented-encoding-notes) note B below for `'80'`).

**Expected.** Either Ownership `'08'` loaded as the pre-summed Fed+State+Local rollup per BLS QCEW convention, or a documented decision NOT to load it.

**Affects.** **Front Page Dashboard** Q3 Government rollup. Today the rollup is computed by SUMMING `IndCode='10' + Ownership IN ('10','20','30')` across the 3 constituent ownership rows (Fed/State/Local). This produces the correct number (~749k VA verified 2026-06-10 audit, commit `76a6515`) but requires the BLS Total-all-industries `IndCode='10'` row plus the 3-row sum. If `'08'` were loaded, the rollup could be sourced as a single row (`IndCode='10' AND Ownership='08'`), removing one source of arithmetic risk. No business-logic blocker today.

**Requested action.** Confirm whether `'08'` Total Government should be present per the WID-Virginia ownership-encoding convention. If yes, load it as the pre-summed rollup. If no, document the decision so future SQL doesn't assume it. Low priority — current Q3 rollup is correct and tested.

---

## Documented encoding notes

_Items in this section are documented WID behavior, not defects to fix. Recorded so future SQL maintainers don't mistake them for bugs and don't "fix" them by rebasing to spec form._

### Note A — `INDUSTRY.Ownership` 2-digit encoding (vs BLS single-digit spec)

**Observed.** The Virginia WID install stores QCEW Ownership codes in **2-digit form with trailing zero**: `'00'` Total Covered, `'10'` Federal, `'20'` State, `'30'` Local, `'50'` Private. BLS QCEW canonical encoding is single-digit: `0/1/2/3/5`. The trailing zero appears to be a WID-Virginia convention.

**Why this is a NOTE not a defect.** All downstream code uses the 2-digit form consistently (probe verified, no half-mixed encoding observed). Rebasing to single-digit would touch every Ownership filter in both tools (`Ownership='00'`, `Ownership IN ('10','20','30','50')`, etc.) for a purely cosmetic change. The 2-digit form works correctly today.

**Do not "fix".** Anyone tempted to rewrite the IN-lists to spec form should leave them alone unless the WID owner confirms a global encoding migration.

### Note B — `INDUSTRY.Ownership='80'` is industry-of-function government employment

**Observed.** Ownership `'80'` carries ~343k VA rows (annual statewide latest extract). Initial speculation classified these as "other/unknown" or "possibly nonprofit." The 2026-06-10 audit (P1/P2/P3 probes against the live WID, follow-up to the dimension-derived-labels rewire) resolved this definitively:

- **What it is.** `'80'` rows are **government employees classified by their industry of function**, not by their employer's ownership. Concrete examples: a public school teacher's employer is State or Local government (Ownership `'20'`/`'30'`), but their *industry of function* is Educational Services (NAICS 61) — so the same person also appears under Ownership `'80'`, IndCode `'61'`. Same for public-hospital nurses (Health Care, NAICS 62) and public-administration workers (NAICS 92). The rows concentrate in NAICS `'92'` / `'61'` / `'62'`.
- **Relationship to `'00'` Total Covered.** P3 reconciliation confirmed `Ownership IN ('10','20','30','50')` sums to `Ownership='00'` at ratio `1.0000` across every NAICS supersector at AreaType='01'. **`'80'` sits OUTSIDE `'00'`** — it is supplemental, not a constituent of Total Covered.
- **BLS / QCEW status.** This is a documented BLS QCEW construct ("classified by industry") published as a parallel view of government employment. It is NOT dirty data, NOT a load defect, and NOT unique to the Virginia WID install.

**Why this is a NOTE not a defect.** Both dashboards already handle `'80'` correctly by design:

- **Employer Wage Tool** Q2 filters to `Ownership='00'` (Total Covered) — `'80'` is intentionally excluded. Verified by P3 reconciliation (`'00'` sums to constituents without `'80'`); the JSON shows the BLS-canonical Total Covered without double-counting.
- **Front Page Dashboard** Q3 excludes `'80'` at two independent levels: upstream (`state_both_qtrs` / `region_both_qtrs` filter `Ownership IN ('10','20','30','50')`) AND downstream (`gov_change_state` / `gov_change_region` filter `Ownership IN ('10','20','30')`). Including `'80'` in the Government rollup would double-count government workers already counted under `'10'`/`'20'`/`'30'` (the same person counted once as "State employee" AND once as "works in Education"). The exclusion is load-bearing for the rollup's integrity — see Smoke Test 8 in `docs/handover/front-page-dashboard.md` for the structurally-parallel private-bar leak guard.

**If a future analysis ever wants the industry-of-function government view** (e.g. "show me total government employment by NAICS sector"), pull `Ownership='80'` alone — it's the right code. Never combine with the `'10'/'20'/'30'` rollup.

---

## Closed items

_(Move resolved items here with a `**Resolved YYYY-MM-DD**` marker and a one-line summary of what changed. Keep entries as audit trail. Delete after one full vintage rollover.)_
