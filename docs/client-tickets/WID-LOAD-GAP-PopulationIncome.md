# WID 3.0 Load Gap — `Population` and `Income` tables are empty

**Filed:** 2026-07-09
**Source artifact:** `queries/community_profiles_mssql_validate.sql` Probes R2b, R2c, R3a, R3c
**Consuming query:** `queries/community_profiles_mssql_RUN.sql` (Community Profiles dashboard — Overview population card, Affordability median household income)

## Issue

Both `WID.dbo.Population` and `WID.dbo.Income` exist with the correct WID 3.0
standard schema but contain **zero rows** — not just no Virginia rows; the
tables are completely empty (probe R3c: `COUNT(*)` = 0 on each, no `StFips`
values at all).

The supporting dimension tables ARE loaded, which shows the concepts were
intended to be available on this install:

- `PopulationSources` is present (schema confirmed, probe P6a/R2b).
- `IncomeTypes` carries the full standard code list for `StFips '51'`,
  including **IncomeType '03' = "Median Household Income - United States
  Census"** and '04' Median Family Income, alongside the BEA personal-income
  family (probe R2c).
- `IncomeSources` carries '1' Census and '3' BEA for `StFips '51'`.

## WID 3.0 spec reference

The WID 3.0 standard defines both as core county-capable tables:

- `Population` — total population per area/year (Census/intercensal sources
  keyed by `PopSource`).
- `Income` — income values per area/year keyed by (`IncomeType`,
  `IncomeSource`), sourced from Census (median household/family income) and
  BEA (personal income and components).

Peer states routinely load both at county grain annually.

## Impact

The Community Profiles dashboard cannot source from WID:

1. **Overview "Population" card** (current count + 10-year trend sparkline) —
   remains on illustrative placeholder data.
2. **Affordability & Housing "Median Household Income"** — remains on
   illustrative placeholder data, even though IncomeType '03' is already
   defined in the loaded dim.

Both fields are wired to flip to real data automatically once rows land: the
refresh query (`community_profiles_mssql_RUN.sql`) can add the two joins
without schema changes, and the front end's per-chart provenance badges will
drop the "Illustrative" tag on those charts as soon as real values flow.

## Request

Load `Population` and `Income` per the WID 3.0 standard for Virginia
(`StFips '51'`), county grain (`AreaType '04'`) at minimum, ideally with the
same year depth as `LaborForce` (2010→current). For `Income`, the priority
types for the dashboard are '03' (Median Household Income) and '04' (Median
Family Income); the BEA types are welcome but not blocking.
