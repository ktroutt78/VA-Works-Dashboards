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

## 5. `INDUSTRY.Ownership` — encoding deviation from BLS QCEW spec; `'08'` Total Government coverage

**Table / field:** `WID.dbo.INDUSTRY.Ownership` (and parallel `IOWAGE.Ownership`).

**Observed (probe RESULTS LOG, validate.sql Probe 4).** The Virginia WID install stores QCEW Ownership codes in **2-digit form with trailing zero**:

| WID-stored | Meaning |
|---|---|
| `'00'` | Total Covered (= sum of `'10'+'20'+'30'+'50'`) |
| `'10'` | Federal |
| `'20'` | State |
| `'30'` | Local |
| `'50'` | Private |
| `'80'` | Other / unknown (~343k VA rows; not in standard BLS QCEW) |

BLS QCEW canonical Ownership codes are **single-digit**: `0` Total Covered, `1` Federal, `2` State, `3` Local, `5` Private. The 2-digit encoding adds a trailing zero on every code. **Plus,** BLS canonically publishes `'08'` (or single-digit `8`) as **Total Government** (= Federal + State + Local rollup), but this code is **not observed** on this install.

**Expected.** Either:
- (a) Document the 2-digit encoding as a deliberate WID-Virginia convention, and clarify what `'80'` represents (the 343k rows are populated, not garbage — possibly nonprofit / supplemental coverage that doesn't fit the standard codes); OR
- (b) Rebase to BLS single-digit codes to match the spec.

Either way, confirm whether `'08'` Total Government should be present and (if so) load it.

**Affects.** Both tools today silently work around this:
- **Employer Wage Tool** Q2 filters to `Ownership='00'` (Total Covered) — fine, since `'00'` IS the BLS-published total.
- **Front Page Dashboard** Q3 Government rollup uses `IndCode='10' + Ownership IN ('10','20','30')` (Fed+State+Local across all industries) instead of an Ownership='08' shortcut, because '08' isn't loaded. The current rollup produces the correct number (~749k VA, verified 2026-06-10 audit), but if BLS-canonical `'08'` were loaded, the Government bar could be sourced as a single row instead of a 3-ownership sum.

**Requested action.** Clarify the WID-Virginia ownership-encoding convention in the load-doc. Confirm whether `'80'` is intentional (and what it represents). Decide whether `'08'` Total Government should be loaded as a pre-summed convenience rollup — if yes, the Front Page Q3 Government rollup can simplify; if no, document so future SQL doesn't assume it.

---

## Closed items

_(Move resolved items here with a `**Resolved YYYY-MM-DD**` marker and a one-line summary of what changed. Keep entries as audit trail. Delete after one full vintage rollover.)_
