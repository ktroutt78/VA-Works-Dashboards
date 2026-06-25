# Handoff: Virginia Works — Community Profile

## Overview
An interactive "Community Profile" report for **Virginia Works** (Virginia Department of Workforce Development). The page lets a user choose a geography for Virginia — at one of five levels — and every chart and statistic below re-frames to that place. A large interactive map of Virginia anchors the header; the user picks a geography level, then either clicks a region on the map or uses an inline search/dropdown. As the user scrolls, the map collapses into a small sticky mini-map that keeps the current selection visible, and a left-hand "spine" navigation tracks progress through four themed report sections.

This is the **header + report shell**. The client has accepted this general direction; more report sections will be added under the same header over time.

## About the Design Files
The files in this bundle are **design references created in HTML** — a working prototype that demonstrates the intended look, layout, and interactions. **They are not production code to copy directly.** The task is to **recreate this design inside the target codebase's existing environment** (React, Vue, etc.), using its established component patterns, charting approach, and conventions. If no front-end environment exists yet, choose the most appropriate framework for the project and implement there.

Two important implementation realities the prototype works around:

1. **`Community Profile.dc.html` is a "Design Component" (DC).** It is authored against a small in-house runtime (`support.js`, also included) that turns an `<x-dc>` template + a `class Component extends DCLogic` into a live page. **Do not try to ship `support.js`.** Treat the DC file as a readable spec: the `<x-dc>…</x-dc>` block is the markup, and the `<script data-dc-script>` block is the logic (state, data generation, chart configs, interactions). Port both into idiomatic components in your stack.
2. **All data is illustrative placeholder data**, generated deterministically per-geography by a `genData(region)` function in the logic class. There is no backend. Replacing this generator with a real LMI data source is the main data-integration task (see **State Management → Data**).

## Fidelity
**High-fidelity (hifi).** Final colors, typography, spacing, chart styling, and interactions are all intended as shown. Recreate the UI as closely as possible using your codebase's existing libraries. The one exception is the *content of the data* (numbers), which is placeholder.

## Tech used in the prototype (for reference)
- **Charts:** [Apache ECharts](https://echarts.apache.org/) 5.5 (loaded from CDN). All chart configs in the prototype are ECharts option objects and can be reused nearly verbatim if you adopt ECharts; otherwise translate them to your charting library.
- **Map:** ECharts `map` series. County/city geometry comes from the **US Atlas** TopoJSON (`us-atlas@3.0.1/counties-10m.json`), filtered to Virginia (FIPS prefix `51`). Region boundaries at coarser levels (MSA, GO Virginia, LWDA, State) are produced at runtime by **merging** county geometries with `topojson-client`'s `topojson.merge()`. A Virginia-only GeoJSON is also included in this project under `data/va-localities.geojson` for convenience.
- **Fonts:** Barlow and Barlow Condensed (Google Fonts).

---

## Screens / Views
This is a single scrolling page with three stacked zones: **Header/Hero**, **Sticky bar**, and **Report**.

### 1. Government utility bar (top)
- Full-width black bar, `background:#1A1A1A`, text `#cfd3da`, `font-size:.74rem`, padding `.5rem 1.5rem`.
- Left: bold "Virginia Works" + "An official website of the Commonwealth of Virginia".
- Right (auto-margin): "English ▾", "Find a Commonwealth Resource".

### 2. Site header
- White, `padding:1.05rem 1.5rem`, bottom border `1px solid #E2E0D8`.
- Left cluster: a 46×46 rounded logo tile (`linear-gradient(135deg,#0A2463,#2E6BD6)`, white "VW", Barlow Condensed 800), the wordmark "VIRGINIA / WORKS" (Barlow Condensed 800, `#0A2463`, uppercase), and a small two-line department label separated by a left border.
- Right nav (uppercase, `.82rem`, weight 600, `#5A6472`): About, Locations, Newsroom, Events, **LMI** (active, `#1B4DB1`), Contact.

### 3. Hero — region picker & map  `[data-screen-label="Hero — region picker & map"]`
- Background: `linear-gradient(120deg,#0A2463 0%,#1B4DB1 58%,#2E6BD6 128%)`, white text, `overflow:hidden`. A decorative `340px` circle outline sits top-right at low opacity.
- Inner grid: `max-width:1240px`, two columns `minmax(0,0.62fr) minmax(0,1.38fr)`, `gap:1rem`, vertically centered, `padding:2.8rem 1.5rem 2.4rem`.
- **Left column:**
  - Eyebrow "Labor Market Information" (`.82rem`, weight 700, letter-spacing `.16em`, `#9DC0F2`).
  - `<h1>` "Community Profile" — Barlow Condensed 800, `clamp(2.1rem,4vw,3.4rem)`, uppercase, `line-height:.95`, `white-space:nowrap` (single line).
  - Breadcrumb (`#crumb`): Home › LMI › Community Profiles › **[selected region]** (the last crumb, `#crumb-region`, is dynamic, white, weight 600).
  - Intro paragraph (`1.04rem`, `#D7E3F6`, `max-width:46ch`).
  - Inline meta line (`#heroMeta`): selected region name (Barlow Condensed 700, white) · its descriptor (if any) · "N localities" · "Updated Q4 2025" · an amber "Illustrative data" pill (`background:#E8A33D`, text `#3a2400`).
- **Right column (map area):** has `margin-right:-1.5rem` so the map bleeds toward the viewport edge.
  - **Level toolbar** label "Choose a geography level" (`.66rem`, weight 700, letter-spacing `.14em`, `#9DC0F2`), then a flex row containing the level buttons **and** the search box (`align-items:center`, `gap:.45rem`).
    - **Level buttons** (`#levelbar`, 5 of them): Barlow Condensed 700, `.95rem`, uppercase, `border-radius:8px`, `padding:.42rem .85rem`. Inactive = translucent white (`background:rgba(255,255,255,.10)`, `border:1.5px solid rgba(255,255,255,.4)`, text `#EaF1FB`). **Active = cream** (`background:#F5F1E8`, text `#0A2463`, subtle shadow). Labels: "County / City", "Metro (MSA)", "GO Virginia", "Workforce (LWDA)", "Statewide".
    - **Search/dropdown** (`#geoSearchWrap`, flex `1 1 180px`): a text input (`#geoSearch`) the **same height as the level buttons**, translucent-white styling matching inactive buttons, with right padding for a "▾" caret (`#geoCaret`) that rotates 180° when open. Results panel (`#geoResults`) drops below: white, `border-radius:10px`, shadow `0 18px 44px rgba(10,36,99,.3)`, `max-height:320px` scroll. Each result row shows the region name (Barlow Condensed 700, `#0A2463`) + meta (descriptor or "N localities"); the currently selected one is tinted `#EAF3E4` with a green ✓.
  - **Map** (`#vamap`): `height:498px`. While geometry loads, a centered spinner overlay (`#mapLoad`) shows "Loading Virginia geography…".
  - Caption (`#mapHint`) below the map, centered, `#9DC0F2`, updates per level.

### 4. Sticky bar  `#stickybar`
- `position:sticky; top:0; z-index:60`, translucent white (`rgba(255,255,255,.94)`, `backdrop-filter:blur(8px)`), bottom border, soft shadow. Appears pinned once the hero scrolls up.
- Contents (`max-width:1240px`, `padding:.5rem 1.5rem`, flex, `gap:1rem`): a **58×62 mini-map** (`#minimap`, the same selection drawn in blue on a light base), the selected region name (`#stickyName`, Barlow Condensed 700, `#0A2463`) + type (`#stickyType`, uppercase `.66rem`), and on the right a "Change geography" button (`#stickyPick`, `background:#0A2463`, white, Barlow Condensed 700) that opens the picker modal.

### 5. Report  `[data-screen-label="Report"]`
- `max-width:1240px`, `padding:2.4rem 1.5rem 4rem`.
- **Intro block:** green eyebrow "Community Profile", `<h2 id="reportTitle">` = selected region (Barlow Condensed 800, `clamp(1.9rem,3.4vw,2.8rem)`, uppercase, `#0A2463`), then a **KPI strip** (`#kpis`): 4 cards in a `repeat(4,1fr)` grid, each `background:#F5F1E8`, `border:1px solid #E2E0D8`, `border-radius:10px`. Big value in Barlow Condensed 800 `2rem` (`#0A2463`, except "Bachelor's or higher" which is green `#3A8A1E`), small uppercase label below. The four KPIs: Total population, Median household income, Bachelor's or higher (%), Net daily in-commuters.
- **Two-column body:** `grid-template-columns:236px 1fr; gap:3rem`.
  - **Left = spine nav** (`#rail`, `position:sticky; top:88px`). Header "In this profile" (Barlow Condensed 700, uppercase, bottom border). Below it, a single continuous vertical line (`2px`, `#E2E0D8`, absolutely positioned at `left:.78rem`) threads through all nodes:
    - **Theme nodes** (4): a filled `#0A2463` dot on the line + the theme name (Barlow Condensed 700, `1.05rem`, uppercase) + a "▾" chevron. Clicking the **name** smooth-scrolls to that section; clicking the **chevron** collapses/expands its children. Active theme → label turns green `#3A8A1E`, dot turns green.
    - **Scene children** (indented): a small hollow dot on the line + the scene title (`.86rem`). Clicking scrolls to that chart. Active scene → row tinted `#EAF3E4`, weight 700, dot fills green.
  - **Right = scenes** (`#scenes`): four theme banners, each followed by its scene sections.
    - **Theme banner:** "Section 0X of 04" (`.68rem`, uppercase, `#9DB4D6`), the theme name (Barlow Condensed 800, `1.9rem`, uppercase, `#0A2463`) with a green→transparent gradient rule trailing to the right, and a **static intro paragraph** (`1.02rem`, `#5A6472`, `max-width:74ch`) — this text is fixed per section and does **not** change with geography (copy listed below).
    - **Scene section** `[data-scene]`: green eyebrow (`.72rem`, uppercase, `#3A8A1E`), `<h3>` title (Barlow Condensed 800, `1.85rem`, uppercase, `#0A2463`), a one-line dynamic lede (`1.02rem`, `#5A6472`, `max-width:62ch`), then a white chart card (`border:1px solid #E2E0D8`, `border-radius:12px`, `padding:1.1rem`, shadow `0 2px 20px rgba(10,36,99,.06)`) holding the chart. Sections fade/slide in on scroll (opacity 0→1, `translateY(22px)→0`, `.6s ease`) via IntersectionObserver.

---

## Report structure (4 themes / 12 scenes)
Each scene has its own chart, all driven by the selected geography.

**Section 01 — Demographic Profile**
Static intro: *"Who lives in this geography. These measures describe the size, age, and educational makeup of the population — the foundation for understanding the available workforce and the community it supports."*
- Population & Age — horizontal **population pyramid** (male left / female right, stacked bar, 18 age cohorts).
- Education — grouped **bar** of educational attainment %, region vs Virginia vs U.S.

**Section 02 — Affordability & Housing**
Static intro: *"What it costs to live here. Household income, housing tenure and values, and the cost of living together gauge economic well-being and whether wages keep pace with the price of staying in the community."*
- Household Income — **bar** of income-bracket distribution (%).
- Housing Profile — **donut** (owner / renter / vacant) with center label showing median home value & rent.
- Cost of Living — **bar** index vs U.S.=100, with a dashed reference line at 100 (bars over 100 turn red `#D0596B`, under 100 green).

**Section 03 — Labor Force & Unemployment**
Static intro: *"How the community works. Participation and unemployment, the mix of occupations, and commuting patterns show how fully the population is engaged in the labor market and how it connects to jobs."*
- Labor Status & Participation — dual-axis **line** (labor force participation % + unemployment %).
- Occupation Profile — horizontal **bar** of major occupation groups.
- Commuting Patterns — **donut** of commute modes with center label = mean commute minutes.

**Section 04 — Employers & Industry**
Static intro: *"Where the jobs come from. The industry base, new business formation, apprenticeship pipelines, and largest employers reveal the engines of the local economy and where it may be heading."*
- Industry Trends — horizontal **bar** of employment by industry (largest = highlighted green).
- New Business Growth — **bar** of new business formations per year.
- Apprenticeships — grouped **bar** (active apprentices + completions per year).
- Largest Employers — **ranked list** (not a chart): two-column grid of numbered rows, alternating row backgrounds, a `#0A2463` circular rank badge per row.

---

## Geography model (core domain logic)
Five **levels**, each a `type` string used throughout:

| Level type | Toolbar label | What it is |
|---|---|---|
| `County / City` | County / City | All ~133 Virginia counties + independent cities |
| `Metro Area (MSA)` | Metro (MSA) | 7 curated metro areas |
| `GO Virginia Region` | GO Virginia | 9 GO Virginia regions |
| `Local Workforce Area (LWDA)` | Workforce (LWDA) | 15 local workforce areas |
| `State` | Statewide | The whole Commonwealth |

Each **region** object: `{ id, type, name, fips:[...], sub? }`, where `fips` is the list of county/city FIPS codes that compose it (`sub` is an optional descriptor, e.g. a GO Virginia region's nickname). Regions are keyed by `id` in `regionById`.

- **County/City** regions: one FIPS each (`id` = `c-<fips>`).
- **MSA** regions (`id` = `msa-*`): curated FIPS lists (Richmond, Virginia Beach–Norfolk–Newport News, Washington–Arlington–Alexandria (VA), Roanoke, Charlottesville, Lynchburg, Blacksburg–Christiansburg).
- **GO Virginia** regions (`id` = `gov-1`…`gov-9`): explicit locality→region composition encoded in the logic, each with a `sub` nickname (Region 1 = Southwest Virginia … Region 9 = Central Virginia & Piedmont).
- **LWDA** regions (`id` = `lwda-1`…`lwda-15`): **currently spatial placeholders** (grid-derived), not the official workforce-area boundaries.
- **State** (`id` = `state`): all VA FIPS.

> ⚠️ **Accuracy caveats to resolve with real data:** the **GO Virginia** memberships are a close reconstruction but a few border localities should be confirmed against the official list; the **LWDA** groupings are placeholders and must be replaced with the real 15 workforce areas. MSA membership is curated but should also be confirmed.

### How the map renders each level (`mapOption` + `ensureLevelMap`)
- For a given level, the prototype builds (and caches) an ECharts map by **merging** the county geometries of every region of that level into one feature per region (`topojson.merge`). It also merges **all uncovered localities** into a single light "rest of Virginia" base feature so the full state outline always shows (important for sparse levels like MSA). This also keeps every level visually aligned.
- Region fill: selected = green `#57B23A`; others = blue (`#93B4DE`, or `#C5D3E5` at County level); the "rest" base = very light blue, non-interactive. Borders white; coarser levels use thicker borders (`1.5px`) than County (`0.6px`).
- Map layout in the hero: `zoom:1.1`, `aspectScale:0.82`, `layoutCenter:['50%','50%']`, `layoutSize:'112%'` (tuned so the whole state reads large and the western tip clears the left content while the Eastern Shore stays in frame). The chart must be `.clear()`-ed before re-`setOption` when switching levels, or ECharts caches the old geo layout.

### Interactions
- **Pick a level button** → map redraws to that level's boundaries; the search box becomes a scoped dropdown of that level's members (placeholder updates, e.g. "Search a GO Virginia region…") and opens.
- **Click a region on the map** → selects it (`selectRegion(id)`).
- **Search/dropdown** → type to filter the current level's regions; Enter selects the first; clicking a row selects it. Current selection shows a green ✓.
- **`selectRegion(id)`** is the single hub: sets `current` + `level`, redraws hero map and mini-map (selected region green), regenerates data via `genData`, and updates every label (breadcrumb, hero meta, sticky name/type, report title), the KPI strip, and all charts.
- **Sticky "Change geography"** opens a modal picker (`#picker`) with type tabs + search + a scrollable list — a fuller version of the inline control.
- **Spine nav**: theme name = scroll to section; chevron = collapse/expand children; scene = scroll to chart. IntersectionObserver (`threshold:.18`, `rootMargin:'-8% 0px -45% 0px'`) sets the active node as you scroll.
- **Default selection on load:** `state` (Commonwealth of Virginia).

---

## State Management
- **`current`**: the selected region object. **`level`**: the active level type. **`data`**: the generated dataset for `current`.
- **Selection flow:** all selection paths (map click, search, modal, default) funnel through `selectRegion(id)`. Keep this single-entry pattern when porting — it's what keeps map, labels, KPIs, and charts in sync.
- **Data (the integration point):** `genData(region)` currently fabricates a full dataset deterministically (seeded by a hash of the region id, so a given region always yields the same numbers). **Replace this with real data fetching** keyed by the region's FIPS list / id. The dataset shape it returns (consume this as your API contract):
  - `population` (number), `ageCohorts` `[{age,male,female}]`, `populationChange` `[{year,value}]`, `race` `[{name,value}]`
  - `householdIncome` `[{name,value%}]`, `housing` `{owner,renter,vacant,medianHomeValue,medianRent}`, `costOfLiving` `{categories[],values[]}`
  - `laborForce` `{years[],participation[],unemployment[]}`, `occupations` `[{name,value}]`, `commute` `{modes:[{name,value%}],meanTravelMin}`
  - `industryEmployment` `[{name,value}]`, `business` `{years[],formations[]}`, `apprenticeships` `{years[],active[],completions[]}`, `topEmployers` `[string]`
  - `educationCompare` `{categories[],msa[],va[],us[]}`, plus scalars `baPct`, `medianIncome`, `netIn`, `wageAll`, `unemployment`, `uiPayments`.

---

## Design Tokens
**Colors**
- Cobalt (primary): `#0A2463`
- Blue: `#1B4DB1` · Bright blue: `#2E6BD6` · Map region blue: `#93B4DE` · Light blue (county/base): `#C5D3E5` / `#DCE4F0`
- Green (accent / selected): `#3A8A1E` · map-selected green: `#57B23A` · dark green: `#2C6916`
- Slate (body text/labels): `#5A6472`
- Hairline border: `#E2E0D8`
- Cream (cards / active button): `#F5F1E8` · alt cream rows: `#F8F6F0`
- Ink (default text): `#1A1A1A` · near-black bar: `#1A1A1A`
- Amber pill: `#E8A33D` (text `#3a2400`)
- Light hero text: `#D7E3F6` / `#B9CDEE` / `#9DC0F2`
- Chart categorical palette: `['#1B4DB1','#3A8A1E','#5BA3D0','#E8A33D','#9B6FB5','#D0596B','#7A8794']`
- Chart "over threshold" red: `#D0596B` · UI-payments purple: `#7A2E8E`

**Typography**
- Display/headings: **Barlow Condensed** (700/800), uppercase, tight line-height (`.9`–`1.02`).
- Body/UI: **Barlow** (400/500/600/700).
- Notable sizes: H1 `clamp(2.1rem,4vw,3.4rem)`; report H2 `clamp(1.9rem,3.4vw,2.8rem)`; theme banner `1.9rem`; scene H3 `1.85rem`; KPI value `2rem`; body `1.02–1.04rem`; eyebrows `.66–.82rem` with `.12–.16em` letter-spacing, uppercase.

**Radius:** buttons/inputs `8px`; cards `10–12px`; logo tile `8px`; pills `4–5px`.
**Shadow:** cards `0 2px 20px rgba(10,36,99,.06)`; popovers/dropdowns `0 16–18px 44–48px rgba(10,36,99,.30–.34)`; sticky bar `0 4px 18px rgba(10,36,99,.06)`.
**Layout width:** content `max-width:1240px`, gutters `1.5rem`.
**Sticky offsets:** sticky bar `top:0`; spine nav `top:88px`; scenes `scroll-margin-top:96px`.

## Assets
- **Fonts:** Barlow + Barlow Condensed via Google Fonts.
- **Map geometry:** US Atlas `counties-10m.json` (`us-atlas@3.0.1`) filtered to FIPS `51*`; coarser levels built at runtime via `topojson-client`. A Virginia-only GeoJSON (`data/va-localities.geojson`) and a `data/_localities.json` index are included in the project root for reference.
- **No raster images or icon fonts.** The "VW" logo is a CSS gradient tile with text; chevrons/checks are Unicode glyphs (▾ › ✓ ✕). Replace the logo tile with the official Virginia Works wordmark/logo in production.
- All charts are ECharts; no static images.

## Files
- `Community Profile.dc.html` — the full design (markup in the `<x-dc>` block, all logic — geography model, `genData`, every chart config, interactions — in the `<script data-dc-script>` block). **Primary reference.**
- `support.js` — the in-house DC runtime. **Reference only; do not ship.** Included so the prototype can be opened/run locally if helpful.
- (in the project root, not this folder) `data/va-localities.geojson`, `data/_localities.json` — Virginia geometry/index you may reuse.

## Suggested implementation order
1. Stand up the geography model (regions + level membership) and the `selectRegion` hub.
2. Build the map at all five levels (geometry merge + selected/base styling), then wire level buttons, map clicks, and the search/dropdown to `selectRegion`.
3. Lay out the report shell (sticky bar, spine nav with IntersectionObserver, theme banners with static intros, scene cards).
4. Implement the 12 charts against the `genData` data shape.
5. Swap `genData` for the real LMI data source and replace the placeholder GO Virginia / LWDA / MSA memberships with official boundaries.
