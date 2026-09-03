# LMI App — scorecard wireframe

Static wireframe for client layout sign-off on the fifth Virginia Works app.
Deploys as its own Vercel project with the Root Directory scoped to this folder.

**Every figure on this page is a placeholder.** Nothing here is a real Virginia
statistic. The page carries a visible "all figures are placeholders" badge and a
`noindex,nofollow` robots meta so invented numbers cannot surface in search.
Real values arrive once Step 0 verification (`queries/lmi_app_mssql_validate.sql`)
and the metric queries in `LMI_APP_BRIEF.md` §2 and §5 are complete.

## What it is

One self-contained `index.html`. No build step, no dependencies, no external
requests — inline SVG charts, no chart library, no webfont.

- **Scorecard** at `#/` — hero unemployment block, three-tile row, full-width
  QCEW rail, full-width wage card, cadence footnote.
- **Six drill grids** at `#/g/<id>` — one reusable shell (sortable columns,
  CSV export, row count, back link) over six datasets. Hash-routed so the
  whole thing stays a single double-clickable file.

## Styling

Type and surface values are lifted verbatim from
`apps/dashboard-front-page-echarts/index.html` so this sits in the same family
as the shipped apps. The percentile band on the wage card is ported from
`apps/wage-tool/wage-tool.html`. **Typography is an interim baseline pending the
graphic designer's direction** — see the comment block at the top of
`index.html`; the `:root` token block is the only place that should need to
change.

## Known divergence

The front page colours its KPI deltas green up / coral down. This page does not,
per the standing "no valence colouring on a government site" rule — direction is
carried by the arrow and the named comparison basis. The nonfarm jobs bars are
the one exception, and they use the front page's own `--coral`.

The unemployment insurance claims block was removed at the client's request
(2026-09-03), along with its weekly drill grid, its two series, the week-axis
helper, and its cadence row. `#/g/claims-weekly` now falls through to the
scorecard, which is what the router already does for any unknown id.
