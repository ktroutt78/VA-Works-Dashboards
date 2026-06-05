# Option B — Employer Pay-Band Planner

This folder is a self-contained handoff for the **Pay-Band Planner** design
(Option B of the employer wage tool). It mirrors the visual system of the
shipped job-seeker tool — same fonts, color tokens, header band, card
treatment, legend layout — and adds employer-specific affordances on top.

Open `Employer Wage Tool.html` in a browser to see it running.

---

## Files

| File | What it is | Need it? |
|------|------------|----------|
| `Employer Wage Tool.html` | Host page — loads fonts, scripts, and a Tweaks panel for state changes. | **Yes** — wiring reference + font setup |
| `employer-data.jsx` | Data model + design tokens + shared chart primitives (`Bar`, `Axis`, `GuideHeader`, `Field`, `LegendChip`, etc). | **Yes** — every primitive you need is here |
| `employer-views.jsx` | The design itself. Contains `PayBandPlanner` (Option B, what to build) and `FamilyOverview` (Option A, **ignore**). | **Yes** — read `PayBandPlanner` only |
| `employer-app.jsx` | App shell — shows how Tweaks state maps to component props (`industry`, `family`, `region`, `targetPct`). | Yes — shows the prop contract |
| `design-canvas.jsx` | Wireframe presentation wrapper (pan/zoom canvas). | **Skip** — not part of the design |

---

## What to build

Only the **`PayBandPlanner`** component in `employer-views.jsx`. Treat
that file as the source of truth for layout, spacing, and typography.

Inputs (props):
- `industry: string` — NAICS sector key (drives only the Industry Summary band)
- `family: string`   — SOC-3 minor group key (drives the pay-band card)
- `region: string`   — region key (drives both)
- `targetPct: number` — 10–90 in steps of 5

Data sources (real implementation):
- **OEWS** (Bureau of Labor Statistics) — occupation percentiles, annual and **native hourly** (do not derive hourly via ÷ 2080)
- **QCEW** (Bureau of Labor Statistics) — industry mean wage, employment, establishments

---

## Visual system

Match the shipped job-seeker tool exactly. All tokens live in `T` in
`employer-data.jsx`:

- Navy header band (`#1b2536`) with serif title + "GUIDE" button
- Warm paper background (`#f3f0e9`) for the outer shell
- White chart card with a red left-border accent (`#b5392b`)
- A cooler-tinted band (`#eceff5`) for the Industry Summary — visually
  distinct so the QCEW mean is never read as a percentile statistic
- Source Serif Pro for headings + large numbers; Inter for body
- Percentile bar: light fill `#aab9d6` (10–90), dark fill `#34537d`
  (25–75), median tick `#11151c`, red diamond `#b5392b` at target pct

---

## Design brief — what this revision changed (from prior Option B)

### Controls (split into two rows, in reading order)
1. **Industry** (NAICS) + **Region** — drive ONLY the Industry Summary
   band below. Industry × occupation data is suppressed for privacy, so
   industry never affects the occupation bands.
2. **Industry Summary band** — appears between the two control rows.
3. **Job Family** (SOC-3 minor group) + **Target Percentile** (slider) —
   drive the detailed Pay-Band card. Target Percentile is the primary
   lever.

### Top zone — Industry × Region Summary
- **Industry avg wage · all roles (QCEW mean)** — labeled explicitly as
  a mean so it can't be confused with percentile statistics. Annual
  figure with derived hourly underneath (QCEW does not publish native
  hourly at this grain — annual ÷ 2080 is the standard convention).
- **Industry employment** — headcount for industry × region.
- **Establishments** — count for industry × region (optional, see §8).

### KPI strip (pay-band zone)
- **Budget at the Nth** — dynamic, moves with the slider. Annual range
  + hourly range. Per-role envelope across the family's occupations.
- **Family median range** — static anchor (range of occupation medians).
  Sitting next to Budget-at-N makes the contrast legible.
- **Position vs market median** — neutral readout (e.g., "+$5K above
  family-avg median"). No red/green semantics.
- **Hiring pool** — sum of employment across the family. Provisional;
  see §8.

### Band chart (per SOC-6 occupation)
- 10–90 light range, 25–75 dark range, median tick (unchanged).
- **Red diamond** at target percentile — was a blue diamond previously.
- **Removed**: the red dashed "YOU PAY · $X" reference line. (It broke
  when occupations sat above it.)
- **Fixed**: occupation labels wrap instead of being ellipsis-truncated.
- **Right-side value per row** = pay at the target percentile, shown as
  **annual + native hourly** (pull from OEWS; do NOT derive ÷ 2080).
  The old "+$XK vs you" delta is removed.

### Data provenance (regional fallback)
When the selected region's cell is suppressed for an occupation, that
row falls back to **statewide** data. Mark the row with:
- `*` after the occupation name
- A muted "VA statewide" tag where the region name would normally appear

See `FALLBACK` and `resolveRow()` in `employer-data.jsx` for the
mechanism — the demo uses a static map; the real implementation should
check OEWS suppression flags per (region, SOC-6) cell.

### Legend
- 10–90 (light), 25–75 (dark), median tick, **red diamond = pay at
  target percentile (recommended)**
- Statewide-fallback note
- **Removed**: "What you pay now" entry

### Statistical labeling
The top zone uses a **mean** (QCEW); the occupation zone uses
**medians/percentiles** (OEWS). Labels and visual treatment keep these
two lenses legible so they aren't read as the same kind of number.

---

## Provisional / open

- Both employment figures (industry headcount + occupation hiring pool)
  are retained pending a stakeholder decision on whether to keep both.
- The red diamond carries a faint "alert" connotation; chosen
  deliberately to free up red after removing the dashed line. Flag if it
  reads wrong in context.
- Establishment count in the Industry Summary band is included by
  default but was originally listed as optional.

---

## Implementation notes for Claude Code

- **Render in ECharts if rebuilding the bar.** The current JSX uses
  inline SVG for the bar primitive (`Bar` in `employer-data.jsx`); when
  porting to ECharts, use a `custom` series with `renderItem` for the
  three-rect-plus-tick shape and add the red diamond as either another
  custom shape or a `markPoint` per row. The user-salary-line pattern
  from the job-seeker tool's ECharts spec does NOT apply here — there's
  no user-salary line in Option B.
- **Industry × occupation suppression** is real BLS behavior — the
  industry control deliberately does not filter the pay bands. Make this
  explicit in the UI (the help-icon next to "Industry · NAICS" should
  explain it).
- **Native hourly** is published by OEWS at every percentile —
  `wageAtPct(row.ph, targetPct)` shows the pattern for using it.
- The percentile slider is the primary interaction. Make sure it feels
  smooth — the chart should re-render at 60fps when dragging (debouncing
  is fine; visual lag is not).

---

## Acceptance checklist

- [ ] Two control rows, each sitting directly above the zone it drives
- [ ] Industry Summary band visually distinct (cool tint); labeled as a
      QCEW mean; annual + hourly shown
- [ ] KPI strip: Budget at Nth (annual + hourly), Family median range,
      Position vs market median, Hiring pool
- [ ] Red diamond at the target percentile in every row
- [ ] No "YOU PAY" reference line or red dashed line
- [ ] Long occupation labels wrap, do not truncate
- [ ] Right-side per row: annual $ + native $/hr (not derived)
- [ ] Fallback rows show `*` + "VA statewide" sub-label
- [ ] Legend reflects the above; "What you pay now" entry is gone
- [ ] Footer notes both data sources (QCEW + OEWS)
- [ ] Industry control does not affect the pay-band card
