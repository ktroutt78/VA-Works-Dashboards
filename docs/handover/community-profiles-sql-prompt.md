# Community Profiles — SQL build prompt (for Claude.ai)

Handoff prompt to drive the T-SQL that will populate every chart in
`apps/community-profiles/index.html` via `data/profiles.json`.

**Decision (2026-08-20):** the client will LOAD the missing Census/ACS-family
data INTO their WID SQL Server following WID 3.0 conventions. So we write SQL
against WID tables now (even empty/absent ones) and file a load-gap ticket per
missing table; each chart flips to real data when rows land.

This work is being done in a separate Claude.ai chat (no repo access), so the
prompt below is self-contained. Attach the files listed first.

---

## Files to attach in the Claude.ai chat

1. `queries/community_profiles_mssql_RUN.sql` — the existing production query (the pattern to extend)
2. `queries/community_profiles_mssql_validate.sql` **and** `queries/community_profiles_mssql_validate_r4.sql` — the logged schema probes (ground truth on what WID holds)
3. The `genData(region) → {...}` contract block from `apps/community-profiles/index.html` (lines ~810-1001) — the exact field shapes the front end consumes
4. The Community Profiles rows of `docs/chart-manifest.md` (the per-chart source table)

---

## The prompt

```
You are extending a production T-SQL query that drives a data dashboard called
"Community Profiles" for Virginia. The query runs read-only against a client
SQL Server database built to the WID 3.0 standard (a BLS-style labor-market
warehouse) and emits ONE JSON blob that the front end loads as
data/profiles.json. I've attached the existing query, the schema-probe files
(with results logged inline), the front-end data contract, and the chart
source map. Read all four before writing anything.

GOAL
Produce SQL that drives EVERY chart on the page, not just the two that are real
today (unemployment + industry employment). We have decided the client will
LOAD the missing Census/ACS-family data INTO their WID SQL Server following WID
3.0 table conventions. So: write SQL against the WID tables now, even where a
table is currently empty or not yet loaded; each such chart flips to real data
automatically when rows land. For every table you depend on that is empty or
absent today, also produce a short "load gap" ticket (table, grain, year depth,
priority) in the style of the existing WID-LOAD-GAP tickets.

WHAT THE WID DATABASE ACTUALLY HAS (from the attached probe logs — trust these)
- LOADED and usable now:
  * LaborForce (LAUS) — unemployment, labor force, monthly + annual
  * Industry (QCEW) — QuarterAvgEmp, Ownership codes, Establishments,
    TotalWages, by NAICS; native grain at state/county/LWDA/MSA
  * VI_Top50Employers — largest employers (EmployerName, CodeTitle,
    OwnerTitle, SizeDesc BAND, AreaName/Type/Area, PeriodYear)
  * Demographics — FULL Census age x sex x race per area/year + MedianAge
    (~18 age brackets Total/Female/Male, race + Hispanic-origin splits)
  * Geographies / SubGeographies — geography dims + membership
  * NAICSSectors — sector labels (2-digit key; fact IndCode stores ranges
    like '31-33'; join accordingly; labels carry a known typo, emit verbatim)
- EXIST but EMPTY (load gap already filed): Population, Income
  (IncomeTypes '03' = Median Household Income is defined in the dim)
- EXIST as WID 3.0 tables, unprobed / no data yet ("future-tranche shelf"):
  Commute, BED (business formations), BuildingPermits, UIClaims,
  Supply / ProgramCompleters / Schools (education programs), TransferPayments,
  CPI/CPIPlus/CPIItems
- DO NOT EXIST in WID at all (no table shape): housing tenure / median rent /
  median home value / cost burden, ACS educational attainment, LFPR,
  IPEDS/VCCS higher-ed, DOL RAPIDS apprenticeships, BEA GDP. For these you must
  either (a) map them onto the closest WID 3.0 concept if one fits, or
  (b) SPECIFY a new table (columns, keys, grain) the client should create and
  load, then write the SQL against that spec. Flag every (b) clearly.

GEOGRAPHY MODEL (critical — follow the attached RUN.sql exactly)
- Region ids emitted in profiles[]: 'state' | 'c-51xxx' counties (fips) |
  6-digit LWDA codes | 6-digit MSA Area codes | 'gov-1'..'gov-9' (GO Virginia).
- Membership: this is the aggregation key. The RUN.sql builds region_members
  (each region -> its member county Areas). Real per-region values come from
  NATIVE-grain fact rows where they exist (Industry has native state/LWDA/MSA/
  county; LaborForce has native state/MSA/county but NO LWDA). Roll up from
  member counties ONLY where no native grain exists (LWDA unemployment;
  GO Virginia everything; COALESCE fallback). NO state-boundary trimming: report
  whatever the tables carry at the chosen grain. MSA membership uses the
  two-predicate VA pin (StFips='51' AND SubStFips='51') — see the attached
  MSA suffix-collision handling; do not regress it.
- Expected profile count when MSAs are included: 168 (1 state + 11 MSA +
  9 GOVA + 14 LWDA + 133 counties).

PINNED LITERALS / CONVENTIONS (keep consistent with RUN.sql)
- Vintage anchors: MAX(AreaTypeVersion) per (StFips, AreaType) per table.
- LAUS year 2025 (PeriodType 01 annual, Adjusted 0). QCEW year 2025
  (PeriodType 02, 4 quarters; annual avg = SUM(QuarterAvgEmp)/4.0,
  Ownership '00', IndCodeType '10'). Make every pinned year a single literal
  that's trivial to roll forward, and comment the roll-forward.
- Suppression: values are present even when Suppress='1' on this install; note
  it, don't silently drop cells.
- Labels come from dimension tables verbatim (dimension-derived-labels
  standard), including known typos.
- Output pattern: FOR JSON PATH, one NVARCHAR(MAX) cell -> save verbatim to
  data/profiles.json. Keep the existing meta / regions / profiles[] structure
  and ADD fields to each profiles[] record; do not rename existing fields.

THE PER-CHART CONTRACT (emit these fields into each profiles[] record; exact
names/types/grain are in the attached genData contract — match them so the
front end reads real data with no JS change). Group and source them as:

Overview KPIs
- unempLatest, unempLatestYear  [DONE — LaborForce]
- industryEmployment: [{name, value}]  [DONE — Industry/QCEW; ADD lq and growth]
    * lq = local sector share / VA sector share (derive from Industry; no new
      table)
    * growth = 5-yr % change in sector employment (Industry prior-year rows)
- population + popTrend  [Population table (empty) OR sum Demographics brackets]
- gdp + gdpTrend  [BEA — not in WID; spec a table or mark representative]

01 Demographic  [Demographics table — LOADED, wire it]
- ageCohorts: [{age, male, female}] 18 cohorts  [Demographics age x sex]
- populationChange: [{year, value}] + projectedFrom  [Population/Demographics]
- race: [{name, value}]  [Demographics race + Hispanic splits]
- MedianAge  [Demographics.MedianAge]
- educationCompare: {categories, msa[], va[]}  [ACS S1501 — needs table spec
  or map to Supply/ProgramCompleters if the client prefers program data]

02 Affordability & Housing  [MOSTLY not in WID — spec tables]
- afford.medianIncome + vaMedianIncome  [Income table, IncomeType '03' (empty)]
- housing {owner, renter, vacant, medianHomeValue, medianRent}  [no WID table —
  spec an ACS housing table: tenure, occupancy, median rent, median home value]
- afford.rentTrend / homeTrend  [same housing table, by year]
- afford.burdenRegion/burdenVa (cost burden %)  [ACS SMOCAPI/GRAPI — table spec]
- householdIncome brackets, totalUnits, occupied, avgHHSize  [ACS DP04/S1101 —
  table spec]

03 Labor Force
- unemployment trend + lfpr  [unemployment monthly = already real via a separate
  query (unemployment_trend.json); LFPR = ACS S2301, table spec]

04 Employers & Industry
- employers.list  [VI_Top50Employers — LOADED; confirm statewide vs locality
  scope; SizeDesc is a BAND label, never a count — COMPLIANCE]
- employers.ownership {privatePct, federalPct, statePct, localPct}  [Industry
  Ownership codes 50/10/20/30 — LOADED]
- employers.sizeDist small/med/large  [Industry Establishments by size band, or
  VI_Top50Employers SizeDesc counts if disclosure-cleared]
- business {years, formations, byIndustry}  [BED table — exists, unprobed;
  probe it, then wire; new-establishment definition is a client decision]
- apprenticeships {summary, byOccupation, byIndustry}  [DOL RAPIDS — not in WID;
  table spec]
- commutePlaces {to, from}  [Commute table exists (unprobed) OR LEHD LODES;
  GEOGRAPHY-AGNOSTIC CONTRACT: aggregate member FIPS, collapse intra-area flows
  into one {self:true} row, list top external {area, workers}]

DELIVERABLES
1. The extended T-SQL query (one file), emitting the full profiles.json.
2. For every table you touched that is empty/unprobed/nonexistent, a probe
   query (INFORMATION_SCHEMA column dump + a TOP 20 sample) so we can confirm
   its real schema before trusting the join — same style as the attached
   validate files.
3. A load-gap ticket per missing/empty table (table, grain, StFips '51',
   AreaType, year depth, priority for the dashboard).
4. Smoke tests at the end (profile count, a spot-check rollup, label sanity),
   matching the SMOKE TESTS block in the attached RUN.sql.

Ask me before assuming any schema you can't see in the attached probe logs.
Start by listing which charts you can wire against CONFIRMED-loaded tables
(Industry, LaborForce, Demographics, VI_Top50Employers) vs which need a probe
or a new-table spec, then write the query for the confirmed set first.
```

---

## Notes on the sourcing buckets

- **Wire first (confirmed loaded):** industry LQ + growth, demographics
  (age/race/median age), employers list + ownership split. Real data you can
  ship immediately.
- **Probe then wire (exists, unconfirmed schema):** business formations (BED),
  commuting (Commute), education programs (Supply/ProgramCompleters/Schools).
- **Blocked on load (WID table empty):** population, median household income.
- **Needs a new table spec (no WID shape):** housing tenure / rent / home value
  / cost burden, ACS educational attainment, LFPR, RAPIDS apprenticeships, BEA
  GDP. Housing is the one true gap — WID 3.0 has no tenure/rent/home-value
  table, so a new table must be defined.
