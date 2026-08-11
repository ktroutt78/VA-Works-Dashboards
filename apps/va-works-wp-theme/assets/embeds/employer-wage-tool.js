    /* Data base URL. In the standalone app this was the relative "./data/" dir; when
       embedded in the WordPress theme, PHP passes the theme-assets path via
       window.vaEmployerWageTool.dataBase (see functions.php). Falls back to "./data/"
       so the file still runs standalone. */
    var DATA_BASE = (window.vaEmployerWageTool && window.vaEmployerWageTool.dataBase) || './data/';

    /* SOC-3 family-bucket KEY derivation: "15-1211" → "15-1000".
       Used purely as a grouping key in buildState — every SOC-6 detail
       whose 4-digit prefix matches goes into the same family bucket. The
       BLS SOC-2018 hierarchy doesn't always use this XX-X000 mold for its
       minor-group CODE (e.g. Computer Occupations is published as
       '15-1200', not '15-1000'), but the BUCKETING is internally consistent
       — all 15-1XXX details share the same SOC-2018 minor by construction.
       The family LABEL is sourced from j.minor_group (resolved server-side
       via SOCParent walk in RUN.sql's soc6_to_minor CTE) — see buildState
       below. Hand-curated SOC3_LABELS dict removed 2026-06-12; replaced by
       the data contract that ships j.minor_group per job. */
    function soc3of(soc6) { return soc6.substring(0, 4) + "000"; }

    /* ──────────────────────────────────────────────────────────────────
       Build STATE: groups jobs by SOC-3, builds dropdown option lists.
       Pure derivation — no DOM access. Called once after load.
    ────────────────────────────────────────────────────────────────────── */
    function buildState(wages, industries) {
      /* Group jobs by SOC-3. Each family = { code, label, jobs[] }. */
      const familyMap = {};
      wages.jobs.forEach(j => {
        const code = soc3of(j.soc_code);
        if (!familyMap[code]) {
          familyMap[code] = {
            code,
            /* Family label: prefer the SQL-resolved minor_group (BLS
               SOC-2018 minor title via SOCParent walk), fall back to
               major_group when the walk couldn't resolve (jobs whose
               SOC code isn't loaded in WID's SOCCodes dim, or that
               walk into the '311100' self-ref anomaly). About 8 of
               721 jobs hit the fallback on the 2026-06-12 refresh. */
            label: j.minor_group || j.major_group,
            jobs: [],
          };
        }
        familyMap[code].jobs.push(j);
      });
      const families = Object.values(familyMap)
        .sort((a, b) => a.code.localeCompare(b.code));

      /* Areas: keep the order from the data; statewide last for fallback semantics. */
      const areas = wages.areas;

      /* Industries: ordered by NAICS code. */
      const sectors = [...industries.sectors].sort(
        (a, b) => a.naics.localeCompare(b.naics));

      return {
        wages, industries,
        families,
        areas,
        sectors,
        /* current selections — initialized in init() */
        sel: { industryCode: null, regionId: null, familyCode: null, targetPct: 60 },
      };
    }

    /* ──────────────────────────────────────────────────────────────────
       Populate the four controls (3 Tom Selects + 1 native range).
       Called once after buildState. Wiring change handlers is task #5.
    ────────────────────────────────────────────────────────────────────── */
    function populateControls(state) {
      /* dropdownParent:'body' detaches each dropdown panel from the .frame
         container (which has overflow:hidden) so panels can extend past
         the frame's bottom edge — matters in the empty/industry-only
         states where the frame is shorter than the family panel. */
      const tsOpts = { allowEmptyOption: false, maxOptions: null, dropdownParent: 'body' };

      /* Industry — browse-only (no typing). Only 20 NAICS-2 sectors, easy
         to scan visually; the alias-search affordance that makes sense for
         703 occupations adds friction here. */
      window.__industrySel = new TomSelect("#industry-select", {
        ...tsOpts,
        controlInput: null,
        placeholder: "Select an industry...",
        options: state.sectors.map(s => ({
          value: s.naics,
          /* Name-first with the NAICS code in parens: "Utilities (22)".
             Sort order unchanged — state.sectors is pre-sorted by NAICS
             code and Tom Select preserves insertion order via $order. */
          text: `${s.label} (${s.naics})`,
        })),
      });

      /* Region — county-first searchable dropdown. Employers know counties
         and independent cities, not LWDA boundaries — so the dropdown options
         are the ~133 counties+cities (flattened from each area.counties[])
         plus the statewide row, and selecting a county RESOLVES to its
         parent LWDA's id behind the scenes for the report scope.
         dropdown_input plugin moves the search input into the panel (same
         pattern as the family dropdown). Tom Select requires unique option
         values, but multiple counties share the same lwda_code — so the
         option's `value` is the county name (unique in VA across the 95
         counties + 38 indep cities) and we store the LWDA code in a hidden
         lwda_id field. The change handler (line ~1487) translates value
         → lwda_id when setting state.sel.regionId. */
      window.__regionSel = new TomSelect("#region-select", {
        ...tsOpts,
        plugins: ['dropdown_input'],
        placeholder: "Type a county or city...",
        /* Search across county name (primary) + LWDA name (secondary, so
           typing "Capital" surfaces all 8 Capital Region members). */
        searchField: [
          { field: 'text',       weight: 4.0 },
          { field: 'lwda_label', weight: 1.0 },
        ],
        options: (() => {
          const opts = [];
          /* Statewide row first — its own scope, no LWDA subtitle.
             Identify by areatype rather than literal id. */
          const stateRow = state.areas.find(a => a.areatype === '01');
          if (stateRow) {
            opts.push({
              value: stateRow.id,
              text: stateRow.label + ' (statewide)',
              lwda_id: stateRow.id,
              lwda_label: '',
              isStatewide: true,
              sortk: '0',
            });
          }
          /* Then every county/city, flattened from each LWDA's counties
             array (sourced from WID.dbo.SubGeographies; SubAreaType='04'
             lumps counties + indep cities). Alphabetical. */
          state.areas
            .filter(a => a.areatype === '15')
            .forEach(a => {
              (a.counties || []).forEach(c => {
                opts.push({
                  value: c,                      /* county name — unique in VA */
                  text: c,
                  lwda_id: a.id,
                  lwda_label: a.label,
                  isStatewide: false,
                  sortk: '1' + c,
                });
              });
            });
          opts.sort((x, y) => x.sortk.localeCompare(y.sortk));
          return opts;
        })(),
        render: {
          option: function (data, escape) {
            if (data.isStatewide) {
              return '<div>' + escape(data.text) + '</div>';
            }
            return '<div class="region-option-dual">' +
                     '<div class="region-county">' + escape(data.text) + '</div>' +
                     '<div class="region-lwda">' + escape(data.lwda_label) + '</div>' +
                   '</div>';
          },
          item: function (data, escape) {
            if (data.isStatewide) {
              return '<div>' + escape(data.text) + '</div>';
            }
            return '<div class="region-item-dual">' +
                     '<div class="region-county">' + escape(data.text) + '</div>' +
                     '<div class="region-lwda">' + escape(data.lwda_label) + '</div>' +
                   '</div>';
          },
        },
      });

      /* Family dropdown — combobox with the search input MOVED into the
         dropdown panel (dropdown_input plugin). The main control shows just
         the selected family name cleanly; clicking opens the panel where a
         dedicated search field filters across both family labels and the
         hidden alias blob (every job title + O*NET alternate name within
         the family). Type "nurse" → 29-1000 surfaces. */
      window.__familySel = new TomSelect("#family-select", {
        ...tsOpts,
        placeholder: "Select a job family...",
        plugins: ['dropdown_input'],
        /* Custom score() didn't filter in this Tom Select / Sifter
           combination (returning 0 didn't exclude items), so rely on
           weighted searchField instead. Widening the weight gap so
           a hit in primary job labels dominates a hit in O*NET
           alternates — keeps "RN" → 29-1000 working while preventing
           weak alternate-only matches like "Nurse Informaticist" in
           15-1000 Computer from outranking real healthcare families. */
        searchField: [
          { field: 'text',    weight: 4.0 },
          { field: 'jobs',    weight: 3.0 },
          { field: 'aliases', weight: 0.2 },
        ],
        options: state.families.map(f => ({
          value: f.code,
          /* Name-first with the SOC-3 code in parens: "Healthcare Support
             Occupations (31-1000)". Search on the 'text' field still
             matches both tokens because the code is embedded in the
             string; the post-filter `\b<token>\b` regex below also matches
             the digits inside parens (e.g. "31-1000" passes \b boundaries
             between the parens and the digits). Sort order unchanged —
             state.families is pre-sorted by f.code and Tom Select
             preserves insertion order via $order. */
          text: `${f.label} (${f.code})`,
          jobs:    f.jobs.map(j => j.label).join(' | '),
          aliases: f.jobs.flatMap(j => j.aliases || []).join(' | '),
        })),
      });

      /* Post-filter the dropdown after each keystroke. Tom Select / Sifter
         prefix-AND matching surfaces "Nursery" (45-2000 Agricultural,
         37-1000 Building & Grounds) for the query "nurse" — weighted
         fields only re-rank, they don't exclude. Word-boundary regex
         here hides any rendered option that doesn't truly match.
         Custom score() would be cleaner but doesn't filter in this
         Tom Select build. */
      (function () {
        const escapeRe = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        window.__familySel.on('type', function (str) {
          const ts    = window.__familySel;
          const query = (str || '').trim().toLowerCase();
          if (!query) return;
          const tokens = query.split(/\s+/).filter(t => t.length > 0);
          if (!tokens.length) return;
          /* `\b<tok>s?\b` allows a trailing 's' so "nurse" matches
             "Nurses" / "Physician Assistant" matches "Physician
             Assistants" but neither matches "Nursery". */
          const tokenRes = tokens.map(t =>
            new RegExp('\\b' + escapeRe(t) + 's?\\b', 'i'));
          setTimeout(function () {
            const optionEls = ts.dropdown_content.querySelectorAll('[data-value]');
            optionEls.forEach(el => {
              const opt = ts.options[el.getAttribute('data-value')];
              if (!opt) return;
              const fields = (
                (opt.text || '') + ' ' + (opt.jobs || '') + ' ' + (opt.aliases || '')
              ).toLowerCase();
              const passes = tokenRes.every(re => re.test(fields));
              el.style.display = passes ? '' : 'none';
            });
          }, 0);
        });
      })();

      /* Empty-state model: industry and family start unselected; user
         picks them (or clicks "Try an example" to jump to a ready state).
         Region and target keep usable defaults so the slider/region
         dropdown aren't blank.

         The default region is "Virginia statewide" — identified by
         area.areatype === '01' rather than a hardcoded id literal. Under
         the dynamic LWDA contract, area.id is the 6-digit GEOGRAPHIES.Area
         code (LWDAs are areatype='15', statewide is areatype='01'); only
         the areatype field is stable enough to identify "the statewide
         row" without knowing the install's actual statewide code. */
      const defaultRegion = state.areas.find(a => a.areatype === "01") || state.areas[0];
      state.defaultRegionId = defaultRegion.id;   /* used by the header Reset button */
      window.__regionSel.setValue(defaultRegion.id, true);

      state.sel.industryCode = null;
      state.sel.regionId     = defaultRegion.id;
      state.sel.familyCode   = null;
      state.sel.targetPct    = 60;

      document.getElementById("target-slider").value = state.sel.targetPct;

      /* Industry placeholder painter (see CSS .show-ts-placeholder rule).
         controlInput:null suppresses the search input Tom Select's native
         placeholder relies on, so this CSS hook fills the empty control. */
      window.__industrySel.wrapper.classList.add('show-ts-placeholder');
    }

    /* ──────────────────────────────────────────────────────────────────
       Formatters + math helpers (ported from employer-data.jsx)
    ────────────────────────────────────────────────────────────────────── */
    const fmtK      = v => (v == null || !isFinite(v)) ? "—" : "$" + Math.round(v / 1000) + "K";
    const fmtMoney  = v => (v == null || !isFinite(v)) ? "—" : "$" + Math.round(v).toLocaleString();
    const fmtEmp    = v => (v == null) ? "—" : v.toLocaleString();
    const fmtHourly = v => (v == null || !isFinite(v)) ? "—" : "$" + v.toFixed(2) + "/hr";

    /* Safe [min, max] over an array that may contain null / NaN. Returns
       [null, null] if ANY element is missing. Use for family-wide hourly
       aggregations where BLS doesn't publish hourly for some occupations
       (pilots, flight attendants, postsecondary teachers, etc.) — bare
       Math.min/max of a NaN-laced array returns NaN, which then renders
       as the literal string "NaN" via toFixed. Callers must check for
       null and render "—" instead. */
    function safeMinMax(arr) {
      if (arr.some(v => v == null || !isFinite(v))) return [null, null];
      return [Math.min(...arr), Math.max(...arr)];
    }

    /* Linear interpolation from a 5-point percentile distribution to the
       value at an arbitrary percentile (clamped to [10, 90]). Works for
       both annual ({p10, p25, p50, p75, p90}) and hourly ({p10_h, ...}). */
    function wageAtPct(p, t) {
      const pts = [
        [10, p.p10 ?? p.p10_h], [25, p.p25 ?? p.p25_h],
        [50, p.p50 ?? p.p50_h], [75, p.p75 ?? p.p75_h],
        [90, p.p90 ?? p.p90_h],
      ];
      if (t <= 10) return pts[0][1];
      if (t >= 90) return pts[4][1];
      for (let i = 0; i < pts.length - 1; i++) {
        const [pa, va] = pts[i], [pb, vb] = pts[i + 1];
        if (t >= pa && t <= pb) return va + (t - pa) / (pb - pa) * (vb - va);
      }
      return pts[2][1];
    }

    /* Domain from min p10 / max p90, padded and snapped to 5K. */
    function computeDomain(rows) {
      const lo = Math.min(...rows.map(r => r.annual.p10));
      const hi = Math.max(...rows.map(r => r.annual.p90));
      return [
        Math.floor((lo * 0.92) / 5000) * 5000,
        Math.ceil((hi * 1.04) / 5000) * 5000,
      ];
    }

    /* Word-wrap a title to lines of ~maxChars each. Used to pre-wrap the
       y-axis occupation label because ECharts 5 rich-text `width`+`overflow`
       on individual {style|...} blocks doesn't actually trigger a wrap on
       axisLabel rich text (it only sizes the layout box) — and setting
       width/overflow on the outer axisLabel re-flows everything as one
       paragraph and swallows the \n we use to separate title from sub. */
    function wrapTitle(text, maxChars) {
      if (text.length <= maxChars) return [text];
      const words = text.split(' ');
      const lines = [];
      let cur = '';
      for (const w of words) {
        if (cur && (cur.length + 1 + w.length) > maxChars) {
          lines.push(cur);
          cur = w;
        } else {
          cur = cur ? cur + ' ' + w : w;
        }
      }
      if (cur) lines.push(cur);
      return lines;
    }

    /* Sub-line for the row label. Today it's "X jobs · Region". When the
       region label is long (e.g. "Alexandria/Arlington Region (LWDA XII)")
       the combined string overflows the 220px gutter and the tail gets
       drawn behind the box-plot bars. Split at the natural " · " into two
       lines when too long; statewide rows ("· Virginia") stay one line. */
    function wrapSub(jobsStr, locStr) {
      const SUB_MAX_CHARS = 36;
      const oneLine = jobsStr + ' · ' + locStr;
      return oneLine.length <= SUB_MAX_CHARS ? [oneLine] : [jobsStr, locStr];
    }

    /* ──────────────────────────────────────────────────────────────────
       Build per-row data for the chart from current state selections.
       Reads the family + region selections, applies the provenance
       stored in each cell (lwda / statewide / statewide_fallback).
    ────────────────────────────────────────────────────────────────────── */
    function buildRows(state) {
      const fam = state.families.find(f => f.code === state.sel.familyCode);
      if (!fam) return [];
      return fam.jobs
        .map(j => {
          const cell = j.areas[state.sel.regionId];
          if (!cell) return null;
          const annual = { p10: cell.p10, p25: cell.p25, p50: cell.p50, p75: cell.p75, p90: cell.p90 };
          const hourly = { p10: cell.p10_h, p25: cell.p25_h, p50: cell.p50_h, p75: cell.p75_h, p90: cell.p90_h };
          /* Drop rows where any annual percentile is null — BLS suppresses
             cells with too few employers and a NaN inside the chart's
             cartesian coord() blows up the whole series silently. Frontend
             can't recover from an api.coord([null, idx]) on one row. */
          if (annual.p10 == null || annual.p25 == null || annual.p50 == null
              || annual.p75 == null || annual.p90 == null) return null;
          return {
            job: j,
            annual, hourly,
            employment: cell.employment,
            provenance: cell.provenance,
            target_annual: wageAtPct(annual, state.sel.targetPct),
            target_hourly: wageAtPct(hourly, state.sel.targetPct),
          };
        })
        .filter(r => r !== null);
    }

    /* ──────────────────────────────────────────────────────────────────
       ECharts: percentile-band chart.
       One instance, custom series. renderItem draws bar shapes + diamond
       + right-column $/yr + $/hr text per row. Y-axis labels are rich
       text (occupation name + sub-line). X-axis is wage $ in K.
    ────────────────────────────────────────────────────────────────────── */
    const TOP_PAD       = 14;
    const BOT_PAD       = 34;   /* x-axis label area */
    const TITLE_MAX_CHARS = 30; /* chars per wrapped title line at width ~210px */
    const LINE_H        = 14;   /* per-line height for both name and sub */
    const ROW_PAD       = 14;   /* breathing room above + below the text block per row */
    let chart = null;

    function ensureChart() {
      if (!chart) chart = echarts.init(document.getElementById('chart'), 'vaWorks');
      return chart;
    }

    function renderChart(state) {
      const chart = ensureChart();
      const rows = buildRows(state);
      const region = state.areas.find(a => a.id === state.sel.regionId);

      /* Empty family fallback (shouldn't happen with current data). */
      if (!rows.length) { chart.clear(); return; }

      const domain = computeDomain(rows);

      /* Pre-wrap titles so we know the tallest row in the family. Each row
         must accommodate the longest wrapped title across the whole family
         (ECharts category axis uses one row height for all categories).
         Same pre-wrap for the sub-line so the rowH calc includes any
         "X jobs" / "Long LWDA Region" 2-line cases. */
      const wrapped = rows.map(r => wrapTitle(r.job.label, TITLE_MAX_CHARS));
      const subWrapped = rows.map(r => {
        const loc = r.provenance === 'statewide_fallback' ? 'Virginia' : region.label;
        return wrapSub(fmtEmp(r.employment) + ' jobs', loc);
      });
      const maxLines = Math.max(...wrapped.map(ls => ls.length));
      const maxSubLines = Math.max(...subWrapped.map(ls => ls.length));
      const rowH = Math.max(56, (maxLines + maxSubLines) * LINE_H + ROW_PAD);

      const chartH = TOP_PAD + rows.length * rowH + BOT_PAD;
      document.getElementById('chart').style.height = chartH + 'px';
      chart.resize();

      // Read the design tokens from the tool's scoping container: when embedded in
      // the WordPress theme they live on .wage-embed, not :root/documentElement.
      const tokens = getComputedStyle(document.querySelector('.wage-embed') || document.documentElement);
      const C = {
        ranLt: tokens.getPropertyValue('--range-lt').trim() || '#aab9d6',
        ranDk: tokens.getPropertyValue('--range-dk').trim() || '#34537d',
        med:   tokens.getPropertyValue('--median').trim()   || '#11151c',
        you:   tokens.getPropertyValue('--you').trim()      || '#b5392b',
        muted: tokens.getPropertyValue('--muted').trim()    || '#6b7280',
        line:  tokens.getPropertyValue('--card-line').trim()|| '#dfe2e8',
        ink:   tokens.getPropertyValue('--ink').trim()      || '#1b2536',
      };

      chart.setOption({
        animation: false,
        tooltip: {
          appendToBody: true,                       /* escape the card's overflow:hidden */
          trigger: 'item',
          confine: true,
          padding: [8, 10],
          backgroundColor: 'rgba(255,255,255,0.97)',
          borderColor: C.line,
          borderWidth: 1,
          textStyle: { color: C.ink, fontSize: 12, fontFamily: 'Inter, system-ui, sans-serif' },
          extraCssText: 'box-shadow: 0 6px 18px rgba(0,0,0,0.10); border-radius: 6px; max-width: 320px; white-space: normal; word-wrap: break-word;',
          formatter: (params) => {
            const idx = params.data[0];
            const r = rows[idx];
            const fmt  = v => (v == null || !isFinite(v)) ? '—' : '$' + Math.round(v).toLocaleString();
            const fmtH = v => (v == null || !isFinite(v)) ? '—' : '$' + v.toFixed(2);
            const pct  = state.sel.targetPct;
            const a = r.annual;
            const locationText = r.provenance === 'statewide_fallback'
              ? 'Virginia'
              : (r.provenance === 'statewide' ? 'Virginia' : (region ? region.label : ''));
            const header = '<div style="font-weight:600; font-size:14px; line-height:1.3;">'
              + (r.job.label || r.job.soc_code) + '</div>'
              + (locationText
                  ? '<div style="font-weight:400; font-size:11.5px; color:' + C.muted
                    + '; margin-bottom:4px; line-height:1.3;">' + locationText + '</div>'
                  : '');
            const body = [
              'Median: ' + fmt(a.p50),
              'P25–75: ' + fmt(a.p25) + '–' + fmt(a.p75),
              'P10–90: ' + fmt(a.p10) + '–' + fmt(a.p90),
              '<span style="color:' + C.you + '">Your target</span>: '
                + '<span style="color:' + C.you + '; font-weight:600">' + fmt(r.target_annual) + '</span>'
                + ' &nbsp;<span style="color:' + C.muted + '">('
                + pct + 'th pct · ' + fmtH(r.target_hourly) + '/hr)</span>',
            ].join('<br/>');
            return header + body;
          },
        },
        grid: { left: 230, right: 100, top: TOP_PAD, bottom: BOT_PAD, containLabel: false },
        xAxis: {
          /* Bottom axis treatment ported from apps/wage-tool/wage-tool.html mkAxis()
             — visible axis line, darker (ink) tick labels, slightly bolder weight,
             hideOverlap so edge ticks don't crowd. */
          type: 'value',
          min: domain[0], max: domain[1],
          axisLine:  { show: true, lineStyle: { color: C.line } },
          axisTick:  { show: true, length: 4, lineStyle: { color: C.muted } },
          axisLabel: {
            color: C.ink,
            fontFamily: 'Inter, system-ui, sans-serif',
            fontSize: 11,
            fontWeight: 500,
            margin: 6,
            hideOverlap: true,
            formatter: v => fmtK(v),
          },
          splitLine: { show: false },
        },
        yAxis: {
          type: 'category',
          inverse: true,
          data: rows.map((r, i) => i),
          axisLine:  { show: false },
          axisTick:  { show: false },
          axisLabel: {
            align: 'left',
            margin: 220,
            formatter: (idx) => {
              const r = rows[idx];
              const star = r.provenance === 'statewide_fallback' ? ' *' : '';
              /* Emit one {name|line} block per pre-wrapped title line, then
                 one {sub|line} block per pre-wrapped sub line. ECharts treats
                 each \n as a hard break, and with no outer width/overflow
                 nothing re-flows. */
              const titleLines = wrapped[idx];
              const titleBlock = titleLines.map((line, i) => {
                const text = (i === titleLines.length - 1) ? line + star : line;
                return `{name|${text}}`;
              }).join('\n');
              const subBlock = subWrapped[idx].map(line => `{sub|${line}}`).join('\n');
              return `${titleBlock}\n${subBlock}`;
            },
            rich: {
              name: {
                color: C.ink, fontSize: 11.5, fontWeight: 600,
                lineHeight: LINE_H, fontFamily: 'Inter, system-ui, sans-serif',
              },
              sub: {
                color: C.muted, fontSize: 10,
                lineHeight: LINE_H, fontFamily: 'Inter, system-ui, sans-serif',
              },
            },
          },
        },
        series: [{
          type: 'custom',
          coordinateSystem: 'cartesian2d',
          clip: false,        /* allow right-column text outside grid */
          z: 2,
          data: rows.map((r, i) => [
            i, r.annual.p10, r.annual.p25, r.annual.p50, r.annual.p75, r.annual.p90, r.target_annual, r.target_hourly,
          ]),
          renderItem: (params, api) => {
            const idx     = api.value(0);
            const p10     = api.value(1), p25 = api.value(2), p50 = api.value(3),
                  p75     = api.value(4), p90 = api.value(5);
            const target  = api.value(6);
            const targetH = api.value(7);

            const yc     = api.coord([p50, idx])[1];
            const xP10   = api.coord([p10, idx])[0];
            const xP25   = api.coord([p25, idx])[0];
            const xP50   = api.coord([p50, idx])[0];
            const xP75   = api.coord([p75, idx])[0];
            const xP90   = api.coord([p90, idx])[0];
            const xTgt   = api.coord([target, idx])[0];

            const halfBar = 7.5;
            const halfDmd = 5.5;

            /* Right column anchor: just past the grid's right edge. */
            const grid   = params.coordSys;
            const xRight = grid.x + grid.width + 8;

            return {
              type: 'group',
              children: [
                /* Whisker spine — thin horizontal line spanning the full plot
                   width, vertically centered on the row. Drawn FIRST so the
                   band sits on top. The portions visible on either side of the
                   light band (i.e. outside p10–p90) are the "whiskers" that
                   make the chart read as box-and-whisker rather than floating
                   rectangles. Ported from apps/wage-tool/wage-tool.html
                   renderPercentileItem (same color, same line weight). */
                { type: 'line',
                  shape: { x1: grid.x, y1: yc, x2: grid.x + grid.width, y2: yc },
                  style: { stroke: '#cdd3df', lineWidth: 1 } },
                /* Light range (10–90) */
                { type: 'rect',
                  shape: { x: xP10, y: yc - halfBar, width: Math.max(0, xP90 - xP10), height: 15, r: 2.5 },
                  style: { fill: C.ranLt } },
                /* Dark range (25–75) */
                { type: 'rect',
                  shape: { x: xP25, y: yc - halfBar, width: Math.max(0, xP75 - xP25), height: 15, r: 2 },
                  style: { fill: C.ranDk } },
                /* Median tick */
                { type: 'line',
                  shape: { x1: xP50, y1: yc - halfBar - 3, x2: xP50, y2: yc + halfBar + 3 },
                  style: { stroke: C.med, lineWidth: 2 } },
                /* Red diamond at target percentile */
                { type: 'polygon',
                  shape: { points: [
                    [xTgt, yc - halfDmd],
                    [xTgt + halfDmd, yc],
                    [xTgt, yc + halfDmd],
                    [xTgt - halfDmd, yc],
                  ] },
                  style: { fill: C.you, stroke: '#fff', lineWidth: 1.3 } },
                /* Right column: annual $ */
                { type: 'text',
                  style: {
                    x: xRight, y: yc - 7,
                    text: fmtMoney(Math.round(target / 500) * 500),
                    fill: C.you,
                    font: '600 14.5px "Greycliff CF", "Greycliff", "Public Sans", system-ui, sans-serif',
                    textAlign: 'left', textVerticalAlign: 'middle',
                  } },
                /* Right column: native $/hr */
                { type: 'text',
                  style: {
                    x: xRight, y: yc + 10,
                    text: fmtHourly(targetH),
                    fill: C.muted,
                    font: '400 11px Inter, system-ui, sans-serif',
                    textAlign: 'left', textVerticalAlign: 'middle',
                  } },
              ],
            };
          },
        }],
      }, /* notMerge */ true);
    }

    /* ──────────────────────────────────────────────────────────────────
       Dynamic placeholder updates — each updater touches one DOM region
       so we can call only the ones a given control change requires.
    ────────────────────────────────────────────────────────────────────── */
    function $(id) { return document.getElementById(id); }

    /* Industry summary band (top zone) — depends on Industry × Region. */
    function updateIndustryBand(state) {
      const sec = state.sectors.find(s => s.naics === state.sel.industryCode);
      if (!sec) return;
      const cell = sec.areas[state.sel.regionId];
      $('ind-naics-code').textContent = 'NAICS ' + sec.naics;
      $('ind-naics-name').textContent = sec.label;
      $('ind-mean').textContent       = cell ? fmtMoney(cell.mean_wage) : '—';
      $('ind-mean-hourly').textContent= cell ? fmtHourly(cell.mean_wage / 2080) : '—';
      $('ind-emp').textContent        = cell ? fmtEmp(cell.employment)    : '—';
      $('ind-est').textContent        = cell ? fmtEmp(cell.establishments): '—';
    }

    /* Family eyebrow + title + sub-line. Depends on Family × Region. */
    function updateFamilyHeader(state) {
      const fam    = state.families.find(f => f.code === state.sel.familyCode);
      const region = state.areas.find(a => a.id === state.sel.regionId);
      if (!fam) return;
      $('family-eyebrow').textContent = 'Job family · SOC ' + fam.code;
      $('family-title').textContent   = fam.label;
      $('family-region').textContent  = region.label;
      /* Use buildRows() — the same function the chart uses — so the count
         and the rendered bars stay in lockstep. fam.jobs.length includes
         occupations whose selected-region cell is missing or has NULL
         percentiles (e.g. Flight Attendants at Virginia statewide), which
         the chart correctly drops. */
      $('family-count').textContent   = buildRows(state).length;
      $('family-pct').textContent     = state.sel.targetPct + 'th percentile';
    }

    /* KPI strip + legend percentile text. Depends on Family × Region × targetPct. */
    function updateKpiStrip(state) {
      const rows = buildRows(state);
      if (!rows.length) return;
      const tgtA = rows.map(r => r.target_annual);
      const tgtH = rows.map(r => r.target_hourly);
      const med  = rows.map(r => r.annual.p50);
      const emp  = rows.reduce((s, r) => s + r.employment, 0);

      const budgetLo  = Math.min(...tgtA), budgetHi  = Math.max(...tgtA);
      const [budgetLoH, budgetHiH] = safeMinMax(tgtH);
      const medLo     = Math.min(...med),  medHi     = Math.max(...med);
      /* Market Position: mean-of-targets minus mean-of-medians across the
         family's occupations. Equivalent to averaging the per-occupation
         (target - median) gap — i.e. "the average $ premium/discount the
         offered pay band represents over each occupation's market median."
         At targetPct=50, target_annual === p50 per row (wageAtPct lands
         exactly on the p50 point), so the two means equal and the position
         nets to 0 — which is the right answer at "the median band."
         Budget and Median Range cards stay as min–max (the displayed
         endpoints); only Market Position uses means, because midrange-vs-
         mean was the prior bug (asymmetric distributions made midrange
         drift from mean even when comparing identical data sets). */
      const marketMid = med.reduce((s, m) => s + m, 0) / med.length;
      const bandMid   = tgtA.reduce((s, t) => s + t, 0) / tgtA.length;
      const positionDlt = bandMid - marketMid;

      $('budget-pct-label').textContent = state.sel.targetPct + 'th';
      $('budget-range').textContent     = `${fmtK(budgetLo)}–${fmtK(budgetHi)}`;
      $('budget-hourly').textContent    = budgetLoH == null
        ? '—'
        : `$${budgetLoH.toFixed(2)}–$${budgetHiH.toFixed(2)}/hr`;
      $('median-range').textContent     = `${fmtK(medLo)}–${fmtK(medHi)}`;
      $('position-delta').textContent   = (positionDlt >= 0 ? '+' : '−') + fmtK(Math.abs(positionDlt));
      /* Sub-line: "avg market median" makes it explicit the baseline is the
         mean of the family's per-occupation medians, not a single number.
         Prior wording "vs. median ($X)" read as if $X were THE median. */
      $('position-sub').textContent     = `vs. avg market median (${fmtK(marketMid)})`;
      $('hiring-pool').textContent      = fmtEmp(emp);

      $('legend-pct').textContent       = state.sel.targetPct + 'th';
    }

    /* Slider visual (fill width + handle position + value label). */
    function updateSlider(state) {
      const pct = state.sel.targetPct;
      const pos = ((pct - 10) / 80) * 100;       /* 10–90 → 0–100% */
      $('slider-fill').style.width = pos + '%';
      $('slider-handle').style.left = pos + '%';
      $('target-value').textContent = pct + 'th';
    }

    /* Region label echoed on each section header. Always reflects the
       current scope (the LWDA the picked county resolves to, or statewide)
       so each card is self-describing without reading the bar above. */
    function updateSectionRegions(state) {
      const region = state.areas.find(a => a.id === state.sel.regionId);
      const label = region ? region.label : '—';
      $('ind-region-label').textContent = label;
      $('pay-region-label').textContent = label;
    }

    /* Set body[data-state] from current selections. CSS uses this to
       toggle the empty-state card, industry band, and pay-band card.
       Four states because either selection is independently meaningful:
       the 1-2-3 step order in the empty card is a suggestion, not a
       requirement — picking just a family is also a valid entry. */
    function updateUIState(state) {
      const hasIndustry = !!state.sel.industryCode;
      const hasFamily   = !!state.sel.familyCode;
      const mode = hasIndustry && hasFamily ? 'ready'
                 : hasIndustry              ? 'industry-only'
                 : hasFamily                ? 'family-only'
                                            : 'empty';
      (document.querySelector('.wage-embed') || document.body).setAttribute('data-state', mode);
    }

    /* Full render — used on initial boot and on selection changes.
       Skips downstream updates when their inputs aren't selected yet. */
    function render(state) {
      updateUIState(state);
      updateSlider(state);
      updateSectionRegions(state);
      if (state.sel.industryCode) updateIndustryBand(state);
      if (state.sel.familyCode) {
        updateFamilyHeader(state);
        updateKpiStrip(state);
        renderChart(state);
      }
    }

    /* ──────────────────────────────────────────────────────────────────
       Change handlers — Tom Select 'change' fires with the new value.
       Slider uses native input event.
    ────────────────────────────────────────────────────────────────────── */
    function wireHandlers(state) {
      /* Industry — only affects the summary band. Pay bands are NOT filtered
         by industry per the README (BLS suppresses industry × occupation).
         Empty string from Tom Select normalizes to null so updateUIState
         can switch back to the empty mode if the user clears the selection. */
      window.__industrySel.on('change', (val) => {
        state.sel.industryCode = val || null;
        window.__industrySel.wrapper.classList.toggle('show-ts-placeholder', !state.sel.industryCode);
        updateUIState(state);
        if (state.sel.industryCode) updateIndustryBand(state);
      });

      /* Region — affects the summary band, family sub-line, KPI strip, and
         chart. The summary band only re-renders if there's an industry; the
         family-driven UI only re-renders if there's a family.

         val is the dropdown option's value, which under the county-first
         setup is the COUNTY NAME (e.g. "Henrico County") for county rows
         and the statewide area id (e.g. "000000") for the statewide row.
         The chart/report logic everywhere downstream keys on
         state.sel.regionId = the LWDA area id (or statewide id), so we
         translate via the option's hidden lwda_id field. Statewide rows
         have lwda_id = stateRow.id so the lookup is uniform. */
      window.__regionSel.on('change', (val) => {
        const opt = window.__regionSel.options[val];
        state.sel.regionId = (opt && opt.lwda_id) || val;
        updateSectionRegions(state);
        if (state.sel.industryCode) updateIndustryBand(state);
        if (state.sel.familyCode) {
          updateFamilyHeader(state);
          updateKpiStrip(state);
          renderChart(state);
        }
      });

      /* Family — affects header, KPI strip, chart. */
      window.__familySel.on('change', (val) => {
        state.sel.familyCode = val || null;
        updateUIState(state);
        if (state.sel.familyCode) {
          updateFamilyHeader(state);
          updateKpiStrip(state);
          renderChart(state);
        }
      });

      /* Target percentile — affects header, KPI strip, slider visual, chart.
         Native input fires on every step; rAF-throttle so the chart redraw
         keeps up while dragging without queuing. Slider visual always
         updates; chart-related updates only run when a family is selected. */
      const slider = $('target-slider');
      let pending = false;
      slider.addEventListener('input', () => {
        state.sel.targetPct = +slider.value;
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => {
          pending = false;
          updateSlider(state);
          if (state.sel.familyCode) {
            updateFamilyHeader(state);
            updateKpiStrip(state);
            renderChart(state);
          }
        });
      });

      /* Try-an-example button: jump to a known-good demo configuration
         (Finance & Insurance, Financial Clerks, Virginia, 60th percentile).
         setValue fires the change events which run the normal update path. */
      const tryBtn = document.getElementById('try-example-btn');
      if (tryBtn) {
        tryBtn.addEventListener('click', () => {
          window.__industrySel.setValue('52');
          window.__familySel.setValue('43-3000');
        });
      }

      /* Reset — return to the initial empty state: clear industry + family,
         restore the statewide default region, and reset the slider to 60th.
         clear() / setValue() fire the normal change handlers; render() then
         settles every dependent region back to its empty presentation. */
      const resetBtn = document.getElementById('reset-btn');
      if (resetBtn) {
        resetBtn.addEventListener('click', () => {
          window.__industrySel.clear();
          window.__familySel.clear();
          window.__regionSel.setValue(state.defaultRegionId, false);
          state.sel.targetPct = 60;
          $('target-slider').value = 60;
          updateSlider(state);
          render(state);
        });
      }
    }

    /* ──────────────────────────────────────────────────────────────────
       Guide modal — open via Guide button, close via X / backdrop / Esc.
    ────────────────────────────────────────────────────────────────────── */
    function wireGuideModal() {
      const modal = document.getElementById('help-modal');
      const btn   = document.getElementById('help-btn');
      const close = modal.querySelector('.modal-close');
      const open  = () => { modal.classList.add('show');    modal.setAttribute('aria-hidden', 'false'); };
      const hide  = () => { modal.classList.remove('show'); modal.setAttribute('aria-hidden', 'true');  };
      btn.addEventListener('click', open);
      close.addEventListener('click', hide);
      modal.addEventListener('click', (e) => { if (e.target === modal) hide(); });
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && modal.classList.contains('show')) hide();
      });
    }

    /* ──────────────────────────────────────────────────────────────────
       Boot
    ────────────────────────────────────────────────────────────────────── */
    (async function boot() {
      try {
        const [wages, industries, socTitles, socAliases] = await Promise.all([
          fetch(DATA_BASE + 'wages.json').then(r => r.json()),
          fetch(DATA_BASE + 'industries.json').then(r => r.json()),
          /* SOC-6 occupation-name lookup. WID 3.0 in VA doesn't expose OccName
             on IOWAGE, so SQL emits soc_code as the label placeholder. Patch
             those at render time from a static BLS SOC-derived table. See
             docs/client-tickets/WID-LOAD-GAP-OccName.md. Soft-fail if the
             file is missing — labels just stay as SOC codes. */
          fetch(DATA_BASE + 'soc-titles.json').then(r => r.ok ? r.json() : {}).catch(() => ({})),
          /* O*NET alternate-titles per SOC. Powers the family dropdown's
             alias-aware search (type "nurse" → find 29-1000 family). 1MB
             file, lazy-cacheable. Soft-fail leaves the dropdown to its
             literal-text search behavior. */
          fetch(DATA_BASE + 'soc-aliases.json').then(r => r.ok ? r.json() : {}).catch(() => ({})),
        ]);
        /* Apply SOC titles where the label is still a SOC code (i.e. the
           code looks like the label). Attach aliases for the family search. */
        for (const j of wages.jobs) {
          const title = socTitles[j.soc_code];
          if (title && (j.label === j.soc_code || !j.label)) j.label = title;
          j.aliases = socAliases[j.soc_code] || [];
        }
        const state = buildState(wages, industries);
        window.__STATE = state;
        populateControls(state);
        wireHandlers(state);
        wireGuideModal();
        render(state);
        console.log('Loaded:',
          wages.jobs.length, 'jobs in',
          state.families.length, 'families ·',
          industries.sectors.length, 'sectors ·',
          state.areas.length, 'areas');
        document.getElementById('frame').classList.remove('loading');
      } catch (err) {
        console.error('Data load failed:', err);
      }
    })();

    /* Keep chart responsive to window resize. */
    window.addEventListener('resize', () => { if (chart) chart.resize(); });
