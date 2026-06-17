# Virginia Works — Dashboards Monorepo

Static, client-side dashboards for Virginia Works. Each app is a self-contained
bundle (one or more HTML files + a `data/` folder of static JSON + its own
`vercel.json`) and deploys as its **own Vercel project**, with the project's
Root Directory scoped to that subfolder. There is no build step — the JSON is
generated upstream by a scheduled SQL refresh and committed alongside the app.

## Apps

| Folder | Product | Entry file | Charts | Status |
|---|---|---|---|---|
| `apps/dashboard-front-page-echarts/` | **Labor Market Snapshot** (front-page dashboard) | `index.html` | ECharts | Production — the sole front-page app |
| `apps/wage-tool/` | **Wage Comparison Tool** | `wage-tool.html` (+ `wage-tool-hero.html` variant) | ECharts | Live; two empty-state variants ship side-by-side pending a stakeholder decision |
| `apps/wage-tool-employer/` | **Employer Pay-Band Planner** | `wage-tool-employer.html` | ECharts | Active development on `dev`; demo data v1 |

> The Highcharts front-page variants (`dashboard-front-page/` and
> `dashboard-front-page-original/`) were retired on 2026-06-17. The migration to
> Apache ECharts is complete across all three apps; nothing in `apps/` uses
> Highcharts anymore.

## Deployment

Each app maps 1:1 to a git-connected Vercel project with a subfolder-scoped
build:

- **Labor Market Snapshot** → production at `dashboard-front-page-echarts.vercel.app`
- **Wage Comparison Tool** → Vercel project `wage-comparison-tool`
- **Employer Pay-Band Planner** → its own Vercel project

Pushes to `main` deploy production; pushes to `dev` produce preview URLs.

**Gotcha:** the Vercel Root Directory for an app occasionally gets cleared to
`null`, which makes it build the repo root instead of the subfolder (spot it via
a missing "Found .vercelignore" line in the build log). PATCH the Root Directory
back and push an empty commit to force a clean deploy.

## Data pipeline

Production data comes from **SQL Server (WID 3.0, read-only)** via a scheduled
refresh that emits static JSON (not a live API). The front-page dashboard's 3
JSON files are produced directly by `FOR JSON PATH`. Source queries live in
`queries/`:

| App | Primary query |
|---|---|
| Labor Market Snapshot | `queries/labor_market_dashboard_mssql_RUN_v8.sql` (tabular reference: `..._mssql.sql`) |
| Employer Pay-Band Planner | `queries/employer_wage_tool_mssql_RUN.sql` (+ `..._validate.sql`, `..._snowflake.sql`) |
| Wage Comparison Tool | sourced via Snowflake / Cortex Code with O*NET enrichment |

Standing data conventions: every visual label is JOIN-derived from a WID 3.0
dimension at refresh time (no seed/slug tables); descriptions resolve from
dimensions, never off fact rows; LWDA codes/labels come live from
`WID.dbo.GEOGRAPHIES` (14 LWDAs, not 5 macro-regions).

## Repo layout

```
apps/                     the three deployable dashboards (above)
docs/
  handover/               client-facing handover docs (keep in sync with SQL)
    front-page-dashboard.md
    employer-wage-tool.md
  client-tickets/         WID data-quality punchlist + load-gap tickets
  dashboard-front-page-design/   design mockups / canvases
  employer-wage-tool/            design mockups / canvases
queries/                  SQL Server + Snowflake source queries (see above)
```

Handover docs in `docs/handover/` are **living documents** — update them whenever
the corresponding SQL changes (ERD keys, validation status, spot-check anchors).

### Not part of the three products

A few first-commit leftovers sit at the repo root and in `docs/`:
`dashboard.html` (an unrelated Highcharts "Sales Demo") and the loose
`docs/*.jsx` design canvases (`app.jsx`, `design-canvas.jsx`, `wireframes.jsx`).
They are historical scratch, not wired to any Vercel project.
