# WID 3.0 Load Gap — Missing `AvgAnnualPay` column in `WID.dbo.INDUSTRY`

**Filed:** 2026-06-05
**Source artifact:** `queries/employer_wage_tool_mssql_validate.sql` Probe 1 (INFORMATION_SCHEMA inventory)
**Consuming query:** `queries/employer_wage_tool_mssql_RUN.sql` (state_qcew + lwda_qcew CTEs)

## Issue

The `WID.dbo.INDUSTRY` table in this WID 3.0 deployment does not expose the
`AvgAnnualPay` column that the BLS WID standard schema defines for QCEW
industry rows. The column is absent — not present-but-empty.

## BLS source column

BLS QCEW publishes **"Average Annual Pay"** as a canonical computed metric on
every published industry × area × year record. The BLS QCEW Open Data
documentation defines it as:

> Average annual pay = Total annual wages ÷ Annual average employment

It is published as a first-class column in BLS QCEW CSV downloads (commonly
`avg_annual_pay`) and is documented in the BLS QCEW Data Layouts reference.

## WID 3.0 spec reference

The BLS Workforce Information Database (WID) 3.0 standard, maintained by the
Projections Managing Partnership / LMI Institute, defines the `INDUSTRY` table
schema to mirror BLS QCEW published fields. The standard column name in WID
3.0 documentation for this metric is **`AvgAnnualPay`** (alongside `AvgWeeklyWage`,
`AnnualAvgEmp`, etc.). The WID 3.0 INDUSTRY layout includes:

- `TotalWages` ✓ (present in this load)
- `AvgWeeklyWage` ✓ (present in this load)
- `AvgAnnualPay` ✗ **(missing in this load)**
- `AnnualAvgEmp` ✗ (missing in this load — `QuarterAvgEmp` present instead)
- `AnnualAvgEst` ✗ (missing in this load — `Establishments` present instead)

## Observed state (Virginia WID 3.0, 2026-06-05)

Full column inventory of `WID.dbo.INDUSTRY` returned by
`INFORMATION_SCHEMA.COLUMNS`:

```
StFips, AreaType, AreaTypeVersion, Area, PeriodYear, PeriodType, Period,
IndCodeType, IndCode, Ownership, Prelim, Firms, Establishments,
QuarterAvgEmp, Month1Emp, Month2Emp, Month3Emp, TopEmployerAvgEmp,
TotalWages, AvgWeeklyWage, TaxableWages, UIContributions, Suppress
```

No `AvgAnnualPay`, no `AvgAnnPay`, no `MeanWage`, no `AvgPay`, no column
matching "annual" + "pay" / "wage" / "earn" in any form.

## Current workaround in `_RUN.sql`

`mean_wage` is derived inline as:

```sql
TRY_CAST(i.TotalWages
         / NULLIF(COALESCE(i.QuarterAvgEmp,
                           (i.Month1Emp + i.Month2Emp + i.Month3Emp) / 3.0), 0) AS INT) AS mean_wage
```

Applied on `PeriodType='01' AND Period='00'` rows (annual full-year
aggregate). This reproduces BLS QCEW's published `avg_annual_pay`
methodology exactly: annual total wages divided by annual average
employment, with `NULLIF` guard for suppressed/zero-employment cells.

## Business impact

**Functional:** None — the derived value is mathematically equivalent to the
canonical BLS published `avg_annual_pay` for any row where `TotalWages` and
`QuarterAvgEmp` are both populated. The Employer Wage Tool's industry mean
wage display is correct under current data.

**Risk:**
- **Methodology drift if WID load changes column population rules.** If
  `TotalWages` or `QuarterAvgEmp` become NULL on certain rows due to a WID
  load policy change, the derived `mean_wage` silently goes to NULL while a
  loaded `AvgAnnualPay` column would have remained populated.
- **Cross-tool inconsistency.** Other dashboards or downstream consumers
  reading `INDUSTRY` from this WID and expecting the spec-canonical
  `AvgAnnualPay` column will hit `Invalid column name` errors, the same way
  this query did during initial validation.
- **Audit difficulty.** Reconciling against BLS-published QCEW values
  requires re-deriving rather than direct column comparison.

## Requested action

Load `AvgAnnualPay` into `WID.dbo.INDUSTRY` per the WID 3.0 spec, either by:

1. Adding the column to the WID load pipeline directly from BLS QCEW source
   files (where it ships as `avg_annual_pay`), or
2. Materializing it as a computed column on `INDUSTRY` using the same
   `TotalWages / AnnualAvgEmp` formula BLS publishes.

Once available, `_RUN.sql` can be simplified to read `i.AvgAnnualPay`
directly and the derivation block can be removed.

## Related

- Sister ticket: `WID-LOAD-GAP-OccName.md` (parallel issue on IOWAGE side).
- Discovery query: `queries/employer_wage_tool_mssql_validate.sql` Probe 1.
