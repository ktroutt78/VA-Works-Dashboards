# Highcharts legacy audit — front-page dashboard lineage

**Scope:** all four apps (community-profiles, dashboard-front-page-echarts, wage-tool, wage-tool-employer), `queries/`, and deployed `data/*.json`. Planning pass only — no code, SQL, or JSON changed. Compiled 2026-07-29.

## TL;DR

The front-page dashboard was ported Highcharts → ECharts. The port is clean in one important respect and dirty in exactly one:

- **Geometry is already ECharts-native.** Both map apps fetch US-Atlas county **TopoJSON**, convert with `topojson.feature`/`topojson.merge`, and register via `echarts.registerMap(...)` with GeoJSON whose `properties.name` = **5-digit FIPS**. The Highcharts original used a completely different `@highcharts/map-collection us/us-va-all` bundle joined by `joinBy:'hc-key'`; the port correctly abandoned it. **No Highcharts map-format assumption survives in the geometry path.** Nothing to do here.
- **The one live legacy artifact is the `hc_key` / `us-va-` join-key *format* on the data side.** The SQL emits `'us-va-' + RIGHT(Area,3)` (e.g. `"us-va-001"`); the browser immediately strips the prefix and prepends `51` to recover FIPS (`"51001"`) to join the already-FIPS-keyed GeoJSON. The prefix is a pure round-trip. It is the only Highcharts residue that reaches SQL, the JSON artifacts, and a scheduled stored proc — i.e. the only one that gets *expensive* after DBA handoff.
- Everything else (comments, `selectedHcKey`/`hcKey`/`mapData` variable names, the archived Highcharts design HTML) is cosmetic or historical.

**The nuance that decides the plan:** the `hc_key` **field is load-bearing** (the map genuinely needs a county id to join on), but its **value format is vestigial**. The GeoJSON join already happens in FIPS space. Both sides already agree on FIPS at the join point — `us-va-` is a detour the app builds and then unbuilds. The fix is to emit `fips` (5-digit) on the data side and delete the bridge.

Corroborating: `community_profiles_mssql_RUN.sql` already emits its county ids as `'51' + RIGHT(Area,3)` (validated, `community_profiles_mssql_validate.sql:198`, P3c), and `profiles.json` uses FIPS-style ids (`c-51059`). So the FIPS-from-`Area` construction is already proven on prod; the front-page SQL is the outlier still wearing the Highcharts key.

---

## Findings

Ordered by importance. **Disposition** is the column that matters: VESTIGIAL = serves no purpose; LOAD-BEARING = something real depends on it (the format may still be wrong).

### F1 — SQL emits the Highcharts key `hc_key = 'us-va-' + RIGHT(Area,3)`  ⚠ core
- **Files/lines:** `queries/labor_market_dashboard_mssql_RUN_v8.sql:193` (Q1 → `employment_by_locality.json`), `:306` (Q2 → `unemployment_trend.json`). Assumption flagged in the header (`:30–33`).
- **Today:** produces the county join key in Highcharts `us-va-NNN` form. The 3-digit suffix is the county FIPS; the full FIPS is `51`+suffix.
- **Disposition:** **field LOAD-BEARING, value format VESTIGIAL.** The map needs a county id; the `us-va-` prefix does not.
- **ECharts-native equivalent:** emit `'51' + RIGHT(Area,3) AS fips` (or `AS name`, the GeoJSON join field) — a 5-digit FIPS string. This is exactly what `community_profiles_mssql_RUN.sql` already does.
- **Co-change in same commit:** the two JSON artifacts it produces (F3) and every consumer (F4–F11), plus `docs/handover/front-page-dashboard.md` sample payloads + Smoke Test 4, plus `docs/chart-manifest.md`.

### F2 — `hcKeyToFips()` — the round-trip bridge
- **File/line:** `apps/dashboard-front-page-echarts/index.html:471–476`.
- **Today:** `'51' + hcKey.replace('us-va-','')`. Called at `:587` (map join key) and inline at `:510` (disambiguation).
- **Disposition:** **VESTIGIAL.** Exists only to undo F1. If F1 emits FIPS, this function has no reason to exist.
- **ECharts-native equivalent:** delete it; read the `fips` field directly.
- **Co-change:** `:587`, `:510` call sites (F5, F6).

### F3 — JSON artifacts carry `hc_key`
- **Files:** `apps/dashboard-front-page-echarts/data/employment_by_locality.json` (`counties[].hc_key`), `apps/dashboard-front-page-echarts/data/unemployment_trend.json` (`counties[].hc_key`), **and `apps/community-profiles/data/unemployment_trend.json`** (a second, manually-maintained copy of the Q2 output — `counties[].hc_key`).
- **Today:** the deployed payloads the front-ends actually read.
- **Disposition:** **LOAD-BEARING format-carrier.** These are the sync point: if SQL emits `fips` while a deployed JSON still has `hc_key` (or vice-versa), the choropleth silently produces all-gray (no join match). The two `unemployment_trend.json` copies must change **together**.
- **ECharts-native equivalent:** `counties[].fips: "51001"`.
- **Co-change:** F1 (producer), F4–F11 (consumers). Note the community-profiles copy's refresh path is manual today (it was hand-copied from the front-page app), so it will not auto-track a proc change — call this out to the DBA.

### F4 — Front-page trend lookup keyed by `hc_key`
- **File/lines:** `apps/dashboard-front-page-echarts/index.html:1012` (`STATE.trendCountyMap = fromEntries(trend.counties.map(c => [c.hc_key, c.data]))`), consumed at `:664` (`STATE.trendCountyMap[selectedCounty.hcKey]`).
- **Disposition:** **LOAD-BEARING, vestigial key format.** The per-county trend series lookup is real; it's keyed in `hc_key` space (internally consistent, never touches FIPS).
- **Native equivalent:** key by `fips`; `selectedCounty.fips`.
- **Co-change:** F3 (unemployment_trend.json), F7 (selection state).

### F5 — Map data join key built via the bridge
- **File/line:** `apps/dashboard-front-page-echarts/index.html:587` (`name: hcKeyToFips(c.hc_key)`), plus attached metadata `hcKey: c.hc_key` at `:593`.
- **Disposition:** `name:` assignment is **LOAD-BEARING** (this is the actual GeoJSON join); it just launders `hc_key` through F2. The `hcKey` metadata field is **LOAD-BEARING but renameable** (read back in selection/tooltip).
- **Native equivalent:** `name: c.fips` (no function call); metadata `fips: c.fips`.
- **Co-change:** F2, F3, F6–F8.

### F6 — City/County disambiguation parses FIPS out of `hc_key`
- **File/lines:** `apps/dashboard-front-page-echarts/index.html:503–514` (`parseInt(c.hc_key.replace('us-va-',''),10)`; cities ≥500).
- **Disposition:** **LOAD-BEARING logic** (the 500+ city/county split is real and correct), **vestigial parse path.**
- **Native equivalent:** `parseInt(c.fips.slice(2),10)` — or compare `c.fips >= '51500'`.
- **Co-change:** F3.

### F7 — Selection state / dropdown / filter keyed by `hc_key`
- **File/lines:** `apps/dashboard-front-page-echarts/index.html:447` (`selectedHcKey`), `:888`,`:893`,`:895`,`:908`,`:910`,`:915`, `:922–925` (`selectCountyByKey(hcKey)`), `:940` (`opt.value = c.hc_key`), `:950`,`:961` (`counties.find(c => c.hc_key === sel)`).
- **Disposition:** **LOAD-BEARING plumbing** (map click ↔ dropdown ↔ line-chart selection all key off this id), **vestigial format + naming.**
- **Native equivalent:** rename to `selectedFips` / `selectByFips(fips)` and key everything by the 5-digit FIPS. Pure mechanical rename once F3/F5 provide `fips`.
- **Co-change:** F3, F4, F5.

### F8 — `mapData` variable + `selectedHcKey` naming
- **File/lines:** `apps/dashboard-front-page-echarts/index.html:457` (`mapData`), `:447` (`selectedHcKey`), `:593` (`hcKey`), `:867`,`:876`,`:892` (mapData usage).
- **Disposition:** **cosmetic.** `mapData` is a Highcharts term but here just a local array; `selectedHcKey`/`hcKey` are tied to the F7 rename.
- **Native equivalent:** optional rename `mapData → mapSeriesData`; `selectedHcKey`/`hcKey` fold into F7.
- **Co-change:** none required; bundle with F7 if renaming.

### F9 — community-profiles LAUS lookup reconstructs `hc_key`
- **File/lines:** `apps/community-profiles/index.html:252` (`this.lausByKey[c.hc_key] = c.data`), `:1565` (`const key = 'us-va-' + String(fips).slice(-3)`), comments `:248–249`,`:1560`.
- **Today:** community-profiles already holds the 5-digit FIPS (`this.current.fips[0]`), then **rebuilds** the `us-va-NNN` key just to look up the shared trend JSON.
- **Disposition:** **LOAD-BEARING lookup, doubly-vestigial format** (it destroys FIPS it already has to match a Highcharts key).
- **Native equivalent:** `this.lausByKey[c.fips] = c.data` and `this.lausByKey[fips]` — drops the reconstruction entirely (simpler than today).
- **Co-change:** F3 (the community-profiles copy of unemployment_trend.json).

### F10 — Highcharts references in comments
- **File/lines (front-page):** `apps/dashboard-front-page-echarts/index.html:117, 430, 454, 479, 625, 675, 778, 851, 986` — all comments explaining the port lineage ("matches the Highcharts version", "ECharts analog of Highcharts' update(oneToOne:true)"). `:430` references a path `../dashboard-front-page-original/` that no longer exists (now `docs/dashboard-front-page-design/`).
- **Disposition:** **cosmetic / documentary.** Harmless; a couple are mildly misleading (stale path at `:430`).
- **Native equivalent:** leave, or tidy the stale path. Not required for correctness.
- **Co-change:** none.

### F11 — Archived Highcharts implementation
- **File:** `docs/dashboard-front-page-design/VA Works Dashboard.html` — the original Highcharts dashboard: `Highcharts.mapChart`, `map:'countries/us/us-va-all'`, `joinBy:'hc-key'` (`:647`), region-membership arrays of `us-va-*` keys (`:507–510`), `mapNavigation`, etc.
- **Disposition:** **VESTIGIAL by design — this is the historical record.** It is the *origin* of the `us-va-` convention. **Do not modify.** Keep as the archive; it is why `hc_key` exists.
- **Native equivalent:** n/a (archive).
- **Co-change:** none.

### Confirmed clean (no action)
- **Geometry / `registerMap`:** `apps/dashboard-front-page-echarts/index.html:548–560, 1020`; `apps/community-profiles/index.html:237–238, 402, 418, 451`. US-Atlas TopoJSON → GeoJSON keyed by FIPS → `echarts.registerMap`. ECharts-native. The CDN fetch/filter is **not** Highcharts-shaped.
- **No leaked Highcharts option keys** (`plotLines`, `plotOptions`, `joinBy`, `dataLabels`, `colorAxis`, `nullColor`, `pointFormat`, `turboThreshold`) in any deployed ECharts config. (`e.categories` at community-profiles:1142 is a data array named "categories", not the Highcharts `xAxis.categories` option — benign.)
- **wage-tool / wage-tool-employer:** zero Highcharts fingerprints. No maps, no `hc_key`, no legacy option names. Nothing to do.

---

## Remediation plan

**Objective:** replace the `hc_key` (`us-va-NNN`) join key with a native 5-digit `fips` field across SQL → JSON → all consumers, with no intermediate broken state, and land it **before the DBA handoff** so the scheduled stored proc emits `fips` from day one.

**Why before handoff (urgency):** today the deployed `data/*.json` in the repo *are* the source of truth — no scheduled proc exists yet — so SQL, JSON, and front-ends can all change in one atomic commit with zero broken window. Once `hc_key` is written into a scheduled stored-procedure spec, changing it requires coordinating a proc redeploy with a front-end deploy across a live refresh boundary — the exact "SQL emits X while deployed JSON still has Y" failure the constraint warns about. **This is a pre-handoff cleanup or it becomes a permanent convention.**

### Primary path — atomic pre-handoff swap (recommended)

Because the repo JSON is the deployed artifact, do it as **one commit** (or a tight sequence that's green at every step). Sequenced so a reviewer can verify each layer:

- **Commit 1 — SQL + regenerate all three JSON together.**
  - `labor_market_dashboard_mssql_RUN_v8.sql`: change Q1 `:193` and Q2 `:306` from `'us-va-' + RIGHT(...,3) AS hc_key` to `'51' + RIGHT(...,3) AS fips`. Update the header assumption note (`:30–33`) to describe FIPS directly (drop the `us-va-` framing; the FIPS construction is already validated in the CP validate suite).
  - Regenerate (or hand-edit) all three deployed payloads to `counties[].fips`: `dashboard-front-page-echarts/data/employment_by_locality.json`, `dashboard-front-page-echarts/data/unemployment_trend.json`, **and** `community-profiles/data/unemployment_trend.json` (the manual copy).
  - *App is broken between this commit and the next if deployed alone* — so land Commits 1–3 as one PR / one deploy. Within the PR, this ordering keeps the diff readable.

- **Commit 2 — front-page consumers.** In `apps/dashboard-front-page-echarts/index.html`: delete `hcKeyToFips` (F2); `buildMapData` `name: c.fips`, metadata `fips: c.fips` (F5); disambiguation `parseInt(c.fips.slice(2))` (F6); rename `selectedHcKey→selectedFips`, `selectCountyByKey→selectByFips`, dropdown `opt.value=c.fips`, filter `find(c=>c.fips===sel)`, `trendCountyMap` keyed by `fips` (F4, F7, F8). Optional: `mapData→mapSeriesData`.

- **Commit 3 — community-profiles consumer.** In `apps/community-profiles/index.html`: `lausByKey[c.fips]=c.data` (`:252`) and `lausByKey[fips]` (`:1565`, dropping the `'us-va-'+slice(-3)` reconstruction). Update comments `:248–249`,`:1560`.

- **Commit 4 — docs.** `docs/handover/front-page-dashboard.md`: sample payloads (`hc_key`→`fips`), Smoke Test 4 (now "`'51'+RIGHT(Area,3)` for Alexandria → `51510`"), Validation row 6 wording, the `STATE.selectedHcKey` walkthrough. `docs/chart-manifest.md`: retire convenience-flag #3 (round-trip resolved), update the three artifact sample records (`hc_key`→`fips`).

Ship Commits 1–4 in a **single PR / single deploy** so no deployed state ever mixes `hc_key` SQL/JSON with `fips` consumers. Verify the choropleth colors and a county click→line-series before merge (the all-gray failure mode is the tell if the join breaks).

### Fallback path — additive dual-key (only if this must happen AFTER a proc is scheduled)

If the migration slips past handoff and a live proc already emits `hc_key`, you cannot atomically update proc output and the front-end. Use an additive rollout where every intermediate state is valid:

1. **Proc/SQL adds `fips` alongside `hc_key`** (emit both). Deploy. JSON now has both keys; consumers still read `hc_key`; app unaffected.
2. **Front-ends switch to `fips`** (both apps). JSON still has both keys, so this is safe regardless of refresh timing. Deploy.
3. **After both front-ends are live on `fips`, drop `hc_key` from the proc.** Regenerate JSON without it. Consumers already ignore it.

Slower and it briefly bloats the payloads, but no step depends on proc-output and front-end deploying in lockstep.

### Non-goals this pass
- The archived `docs/dashboard-front-page-design/VA Works Dashboard.html` (F11) stays as-is — it is the historical record.
- Comment tidy-ups (F10) are optional; bundle the stale `../dashboard-front-page-original/` path fix into Commit 2 if convenient.
- The `mapData` variable rename (F8) is cosmetic — skip if it adds diff noise.

### One-line summary for the DBA handoff
> The front-page county join key should ship as 5-digit `fips` (`'51' + RIGHT(Area,3)`), **not** `hc_key`/`us-va-NNN`. The `us-va-` prefix is a dead Highcharts-era round-trip the front-end already unwinds, and `community_profiles_mssql_RUN.sql` already uses the FIPS form. Lock this in before scheduling the stored procedure.
