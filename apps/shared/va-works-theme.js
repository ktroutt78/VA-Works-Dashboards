/*
 * Virginia Works — shared ECharts theme ("vaWorks")
 * ---------------------------------------------------------------------------
 * CANONICAL SOURCE. This governs APPEARANCE only (fonts, axis text, gridlines,
 * tooltip chrome, legend style, and the default color sequence for new/unstyled
 * series). It never dictates chart geometry: series that set an explicit
 * itemStyle.color / lineStyle.color always win over this theme, so approved
 * colors (wage-tool pay bands + red system, Front Page map ramp) are safe by
 * construction. See VA_WORKS_DESIGN_SYSTEM.md §4 (theme-vs-config boundary).
 *
 * Deploy note: each app deploys with its Vercel Root Directory scoped to its own
 * apps/<name>/ subfolder, so a file outside that folder would 404 in production.
 * An identical copy of this file therefore lives in each app root; edit THIS
 * canonical copy first, then re-sync the per-app copies.
 *
 * Load AFTER the echarts CDN <script>, then pass 'vaWorks' to echarts.init().
 * Font stacks request the licensed brand faces (Greycliff CF for titles, Avenir
 * for body) and fall back to a blocky sans where those files are not bundled.
 */
(function () {
  var TITLE_FONT = "'Greycliff CF','Greycliff','Public Sans',system-ui,-apple-system,'Segoe UI',sans-serif";
  var BODY_FONT  = "'Avenir Next','Avenir','Public Sans',system-ui,-apple-system,'Segoe UI',sans-serif";

  var INK      = '#1C2A3A'; // text, median ticks
  var MUTED    = '#5A6572'; // axis labels, captions (AA-passing; replaces #6B7785)
  var GRIDLINE = '#E3E1DA'; // value-axis split lines

  // Default sequence for series that do NOT set an explicit color.
  // Navy / green / gray are the workhorses; maroon is the calm accent;
  // orange is demoted to last (rare categorical use only).
  var COLORS = ['#003595', '#2A7050', '#9F2842', '#9FB4D8', '#00246B', '#8A94A3', '#EE7625'];

  var categoryAxis = {
    axisLine:  { show: false },
    axisTick:  { show: false },
    axisLabel: { color: MUTED, fontFamily: BODY_FONT, fontSize: 12 },
    splitLine: { show: false }
  };

  var valueAxis = {
    axisLine:  { show: false },
    axisTick:  { show: false },
    axisLabel: { color: MUTED, fontFamily: BODY_FONT, fontSize: 12 },
    splitLine: { show: true, lineStyle: { color: GRIDLINE } }
  };

  var theme = {
    color: COLORS,
    textStyle: { fontFamily: BODY_FONT, color: INK },

    title: {
      textStyle:    { fontFamily: TITLE_FONT, fontWeight: 700, fontSize: 16, color: INK },
      subtextStyle: { fontFamily: BODY_FONT, color: MUTED, fontSize: 12 }
    },

    categoryAxis: categoryAxis,
    valueAxis:    valueAxis,
    logAxis:      valueAxis,
    timeAxis:     categoryAxis,

    legend: {
      bottom: 0,
      icon: 'roundRect',
      itemWidth: 12,
      itemHeight: 8,
      itemGap: 14,
      textStyle: { color: MUTED, fontFamily: BODY_FONT, fontSize: 12 }
    },

    tooltip: {
      backgroundColor: '#ffffff',
      borderColor: GRIDLINE,
      borderWidth: 1,
      textStyle: { color: INK, fontFamily: BODY_FONT, fontSize: 12 },
      extraCssText: 'box-shadow:0 4px 16px rgba(0,0,0,0.08);border-radius:6px;padding:8px 10px;'
    }
  };

  if (typeof echarts !== 'undefined' && echarts.registerTheme) {
    echarts.registerTheme('vaWorks', theme);
  }
  if (typeof window !== 'undefined') {
    window.vaWorksTheme = theme;
  }
})();
