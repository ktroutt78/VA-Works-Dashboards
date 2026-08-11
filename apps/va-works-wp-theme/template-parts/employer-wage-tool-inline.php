<?php
/**
 * Inline employer pay-band tool (apps/wage-tool-employer), embedded directly in
 * the page DOM — no iframe. Replaces the old template-parts/embed.php iframe on
 * the employer page so the tool grows/shrinks with its own content instead of
 * scrolling inside a fixed-height frame.
 *
 * Faithful port of apps/wage-tool-employer/wage-tool-employer.html's <body>. Its
 * styles + script live in assets/embeds/employer-wage-tool.css / .js and are
 * enqueued (with echarts/tom-select/theme deps and the data-base path) from
 * functions.php, gated to this page. Everything is wrapped in `.wage-embed`, the
 * container the tool's design tokens are scoped to (was :root standalone). The
 * `data-state` attribute — which drives the empty/ready visibility CSS — lives on
 * that container too (was on <body> standalone) and is updated by the tool JS.
 *
 * @package va-works
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}
?>
<section class="embed-section" aria-labelledby="employer-wage-heading">
	<div class="container">
		<h2 id="employer-wage-heading" class="embed-section__heading">Build a competitive pay band</h2>
		<p class="embed-note">Pick a region and job family to see full wage distributions and set a recommended pay range, drawn from Bureau of Labor Statistics OEWS and QCEW data.</p>

		<div class="wage-embed" data-state="empty">
			<div class="page-wrap">
				<div class="frame loading" id="frame">

					<!-- Header band -->
					<div class="header">
						<div>
							<div class="header-title">Wage Comparison Tool</div>
							<div class="header-sub">Build a competitive pay band · BLS OEWS + QCEW</div>
						</div>
						<div class="header-actions">
							<button id="reset-btn" class="header-reset" type="button" title="Reset all selections">
								<span class="ic">↺</span>Reset
							</button>
							<button id="help-btn" class="header-guide" type="button" aria-haspopup="dialog" aria-controls="help-modal" title="How to read this page">
								<span class="q">?</span>Guide
							</button>
						</div>
					</div>

					<!-- Global region bar — drives the WHOLE page. Sits above both section
					     cards so the spanning relationship is structural, not just textual. -->
					<div class="region-bar">
						<div class="field region-field">
							<div class="field-label region-bar-label">
								<svg class="region-pin" viewBox="0 0 12 14" aria-hidden="true"><path d="M6 0C3.24 0 1 2.24 1 5c0 3.5 5 9 5 9s5-5.5 5-9c0-2.76-2.24-5-5-5zm0 6.8A1.8 1.8 0 116 3.2a1.8 1.8 0 010 3.6z"/></svg>
								Region
							</div>
							<select id="region-select"></select>
						</div>
						<div class="region-bar-note">
							<span class="region-bar-note-strong">Applies to both sections below</span>
							<span class="region-bar-note-sub">Industry summary &amp; pay bands update together</span>
						</div>
					</div>

					<div class="page-content">

						<!-- Section A · Industry summary (QCEW) -->
						<section class="section section-industry">
							<div class="section-head">
								<span class="section-eyebrow">Industry summary</span>
								<span class="section-source">BLS QCEW · <span id="ind-region-label" class="section-region">—</span></span>
							</div>
							<div class="section-body">
								<div class="field">
									<div class="field-label">Industry · NAICS</div>
									<select id="industry-select"></select>
								</div>

								<!-- Industry summary band -->
								<div class="industry-band" id="industry-band">
									<div class="ind-naics">
										<span class="ind-naics-code" id="ind-naics-code">NAICS —</span>
										<span class="ind-naics-name" id="ind-naics-name">—</span>
									</div>
									<div>
										<div class="ind-stat-label">Avg wage</div>
										<div class="ind-stat-value" id="ind-mean">—</div>
										<div class="ind-stat-sub" id="ind-mean-hourly">—</div>
									</div>
									<div>
										<div class="ind-stat-label">Employment</div>
										<div class="ind-stat-value" id="ind-emp">—</div>
									</div>
									<div>
										<div class="ind-stat-label">Establishments</div>
										<div class="ind-stat-value" id="ind-est">—</div>
									</div>
								</div>

								<div class="industry-empty" id="industry-empty">
									Pick an industry to see its workforce summary for the region above.
								</div>
							</div><!-- /.section-body -->
						</section><!-- /.section-industry -->

						<!-- Section B · Pay bands (OEWS) -->
						<section class="section section-payband">
							<div class="section-head">
								<span class="section-eyebrow">Pay bands</span>
								<span class="section-source">BLS OEWS percentiles · <span id="pay-region-label" class="section-region">—</span></span>
							</div>
							<div class="section-body">

								<!-- Controls row 2: Job Family + Target Percentile (drive the pay-band card) -->
								<div class="controls controls-2">
									<div>
										<div class="field-label">Job family · SOC-3</div>
										<select id="family-select"></select>
									</div>
									<div>
										<div class="field-label">Target percentile</div>
										<div class="slider-control">
											<span class="slider-value" id="target-value">60th</span>
											<div class="slider-track-wrap">
												<div class="slider-track">
													<div class="slider-fill" id="slider-fill" style="width: 62.5%;"></div>
													<div class="slider-handle" id="slider-handle" style="left: 62.5%;"></div>
												</div>
												<input type="range" id="target-slider" min="10" max="90" step="5" value="60" aria-label="Target percentile">
											</div>
										</div>
									</div>
								</div>

								<!-- Pay-band card -->
								<div class="card">
									<!-- Family header -->
									<div class="family-header">
										<div class="family-eyebrow" id="family-eyebrow">Job family · SOC —</div>
										<div class="family-title" id="family-title">—</div>
										<div class="family-sub">
											<span id="family-region">—</span> ·
											<span id="family-count">—</span> occupations ·
											pay band at the <span class="pct-emph" id="family-pct">60th percentile</span>
										</div>
									</div>

									<!-- KPI strip -->
									<div class="kpi-strip">
										<div>
											<div class="kpi-label">Budget at <span id="budget-pct-label">60th</span></div>
											<div class="kpi-value accent" id="budget-range">—</div>
											<div class="kpi-sub" id="budget-hourly">—</div>
										</div>
										<div>
											<div class="kpi-label">Median range</div>
											<div class="kpi-value" id="median-range">—</div>
										</div>
										<div>
											<div class="kpi-label">Market position</div>
											<div class="kpi-value" id="position-delta">—</div>
											<div class="kpi-sub" id="position-sub">—</div>
										</div>
										<div>
											<div class="kpi-label">Workforce size</div>
											<div class="kpi-value" id="hiring-pool">—</div>
										</div>
									</div>

									<!-- ECharts chart -->
									<div class="chart" id="chart"></div>

									<!-- Legend -->
									<div class="legend">
										<span class="legend-chip"><span class="sw bar lt"></span>10th–90th percentile</span>
										<span class="legend-chip"><span class="sw bar dk"></span>25th–75th percentile</span>
										<span class="legend-chip"><span class="sw tick"></span>Median</span>
										<span class="legend-chip"><span class="sw diamond"></span>Pay at <span id="legend-pct">60th</span> (target)</span>
										<span class="legend-fallback"><span class="star">*</span>Statewide fallback (regional cell suppressed)</span>
									</div>

									<!-- Card footer. Save/export deliberately omitted — see "Scope:
									     intentionally no save/export" note in docs/handover/employer-wage-tool.md. -->
									<div class="card-footer">
										<div class="footer-source">Industry summary: BLS QCEW (mean) · Pay band: BLS OEWS (percentiles)</div>
									</div>
								</div>

								<!-- Pay-band empty hint. Shown when no job family is picked. -->
								<div class="payband-empty" id="payband-empty">
									<div class="payband-empty-icon" aria-hidden="true">
										<svg viewBox="0 0 44 44" width="44" height="44">
											<circle cx="22" cy="22" r="20" fill="none" stroke="#b5392b" stroke-width="1.5"/>
											<line x1="8" y1="22" x2="36" y2="22" stroke="#aab9d6" stroke-width="6" stroke-linecap="round"/>
											<line x1="16" y1="22" x2="28" y2="22" stroke="#34537d" stroke-width="6" stroke-linecap="round"/>
											<polygon points="24,16 30,22 24,28 18,22" fill="#b5392b" stroke="#fff" stroke-width="1.5"/>
										</svg>
									</div>
									<div class="payband-empty-content">
										<div class="empty-state-eyebrow">Get started</div>
										<h2 class="empty-state-heading">Build a pay band for any job family</h2>
										<p class="empty-state-desc">Choose a job family to see full wage distributions for its occupations, then drag the target percentile to set a recommended range — all for the region above.</p>
										<div class="empty-state-cta">
											<button id="try-example-btn" class="empty-state-btn" type="button">Try an example →</button>
											<span class="empty-state-cta-note">Loads a Financial Clerks sample</span>
										</div>
									</div>
								</div>

							</div><!-- /.section-body -->
						</section><!-- /.section-payband -->

					</div><!-- /.page-content -->

				</div><!-- /.frame -->
			</div><!-- /.page-wrap -->

			<div id="help-modal" class="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="help-title" aria-hidden="true">
				<div class="modal-card">
					<div class="modal-head">
						<h2 id="help-title">How to read this page</h2>
						<button class="modal-close" aria-label="Close">×</button>
					</div>
					<div class="modal-body">
						<h3>Industry summary band</h3>
						<svg class="help-illustration" viewBox="0 0 700 134" role="img" aria-label="Annotated industry summary band">
							<rect x="2" y="2" width="696" height="72" rx="4" fill="#eef3f9" stroke="#dee5ef" stroke-width="1"/>
							<text x="20" y="26" font-family="-apple-system, system-ui, sans-serif" font-size="10" fill="#5a6376" letter-spacing="0.8" font-weight="600">NAICS 62</text>
							<text x="20" y="44" font-family="Greycliff CF, Greycliff, Public Sans, system-ui, sans-serif" font-size="14" font-weight="600" fill="#11151c">Health Care &amp; Social</text>
							<text x="20" y="60" font-family="Greycliff CF, Greycliff, Public Sans, system-ui, sans-serif" font-size="14" font-weight="600" fill="#11151c">Assistance</text>
							<text x="260" y="22" font-family="-apple-system, system-ui, sans-serif" font-size="9.5" fill="#6b7280" text-anchor="middle" letter-spacing="0.6">AVG WAGE</text>
							<text x="260" y="44" font-family="Greycliff CF, Greycliff, Public Sans, system-ui, sans-serif" font-size="17" font-weight="600" fill="#11151c" text-anchor="middle">$69,785</text>
							<text x="260" y="58" font-family="-apple-system, system-ui, sans-serif" font-size="10" fill="#6b7280" text-anchor="middle">$33.55/hr</text>
							<text x="425" y="22" font-family="-apple-system, system-ui, sans-serif" font-size="9.5" fill="#6b7280" text-anchor="middle" letter-spacing="0.6">EMPLOYMENT</text>
							<text x="425" y="44" font-family="Greycliff CF, Greycliff, Public Sans, system-ui, sans-serif" font-size="17" font-weight="600" fill="#11151c" text-anchor="middle">451,657</text>
							<text x="590" y="22" font-family="-apple-system, system-ui, sans-serif" font-size="9.5" fill="#6b7280" text-anchor="middle" letter-spacing="0.6">ESTABLISHMENTS</text>
							<text x="590" y="44" font-family="Greycliff CF, Greycliff, Public Sans, system-ui, sans-serif" font-size="17" font-weight="600" fill="#11151c" text-anchor="middle">42,069</text>
							<g font-family="-apple-system, system-ui, sans-serif" font-size="11" fill="#5a6376">
								<line x1="260" y1="80" x2="260" y2="96" stroke="#5a6376" stroke-width="1"/>
								<text x="222" y="110">Average Annual</text>
								<text x="231" y="124">Hourly Rate</text>
							</g>
							<g font-family="-apple-system, system-ui, sans-serif" font-size="11" fill="#5a6376">
								<line x1="425" y1="80" x2="425" y2="96" stroke="#5a6376" stroke-width="1"/>
								<text x="380" y="110">Workers in sector</text>
							</g>
							<g font-family="-apple-system, system-ui, sans-serif" font-size="11" fill="#5a6376">
								<line x1="590" y1="80" x2="590" y2="96" stroke="#5a6376" stroke-width="1"/>
								<text x="540" y="110">Number of employers</text>
							</g>
						</svg>
						<p>BLS QCEW data for the sector and region. <b>Industry doesn't filter the pay bands below</b>: BLS suppresses industry × occupation detail.</p>

						<h3>How Region affects the page</h3>
						<ul class="help-list">
							<li><b>Industry summary</b>: mean wage, employment, and establishments update for the selected region.</li>
							<li><b>Pay-band rows</b>: bars use LWDA-level OEWS data. Cells BLS suppresses (too few employers) fall back to Virginia statewide, marked with a <code>*</code>.</li>
						</ul>

						<h3>Target percentile slider</h3>
						<p>Drag to set the red diamond position on each row, your competitive pay target. KPIs above the chart update live.</p>

						<h3>Pay-band chart</h3>
						<svg class="help-illustration" viewBox="0 0 700 150" role="img" aria-label="Annotated example row matching what appears on the page">
							<!-- Top callouts: light + dark band labels -->
							<g fill="#3a4153" font-family="-apple-system, system-ui, sans-serif" font-size="11">
								<text x="190" y="14" font-weight="600">10th–90th percentile</text>
								<text x="190" y="26" fill="#5a6376">80% of workers</text>
								<line x1="230" y1="32" x2="230" y2="60" stroke="#5a6376" stroke-width="1"/>
							</g>
							<g fill="#3a4153" font-family="-apple-system, system-ui, sans-serif" font-size="11">
								<text x="345" y="14" font-weight="600">25th–75th percentile</text>
								<text x="345" y="26" fill="#5a6376">middle 50%</text>
								<line x1="380" y1="32" x2="380" y2="60" stroke="#5a6376" stroke-width="1"/>
							</g>
							<!-- Row: occupation label (left), bar (middle), $ figures (right) -->
							<text x="14" y="76" font-family="-apple-system, system-ui, sans-serif" font-size="12.5" font-weight="600" fill="#11151c">Library Technicians</text>
							<text x="14" y="89" font-family="-apple-system, system-ui, sans-serif" font-size="10.5" fill="#6b7280">2,580 jobs · Virginia</text>
							<g transform="translate(170, 58)">
								<rect x="0"   y="6" width="340" height="20" rx="3" fill="#aab9d6"/>
								<rect x="85"  y="9" width="170" height="14" rx="2" fill="#34537d"/>
								<line x1="145" y1="0" x2="145" y2="32" stroke="#11151c" stroke-width="2.5" stroke-linecap="square"/>
								<polygon points="204,9 212,16 204,23 196,16" fill="#b5392b" stroke="#fff" stroke-width="1.5"/>
							</g>
							<text x="540" y="76" font-family="-apple-system, system-ui, sans-serif" font-size="13" font-weight="600" fill="#b5392b">$48,000</text>
							<text x="540" y="89" font-family="-apple-system, system-ui, sans-serif" font-size="10.5" fill="#6b7280">$23.19/hr</text>
							<!-- Bottom callouts -->
							<g fill="#3a4153" font-family="-apple-system, system-ui, sans-serif" font-size="11">
								<line x1="315" y1="96" x2="315" y2="116" stroke="#5a6376" stroke-width="1"/>
								<text x="293" y="130" font-weight="600">Median</text>
							</g>
							<g fill="#3a4153" font-family="-apple-system, system-ui, sans-serif" font-size="11">
								<line x1="374" y1="82" x2="420" y2="116" stroke="#b5392b" stroke-width="1"/>
								<text x="395" y="130" font-weight="600" fill="#b5392b">Your target</text>
							</g>
							<g fill="#3a4153" font-family="-apple-system, system-ui, sans-serif" font-size="11">
								<line x1="565" y1="96" x2="565" y2="116" stroke="#5a6376" stroke-width="1"/>
								<text x="515" y="130"><tspan fill="#b5392b" font-weight="600">Annual</tspan><tspan fill="#5a6376"> · Hourly Rate</tspan></text>
							</g>
						</svg>

						<ul class="help-bullets">
							<li><span class="swatch" style="background:#aab9d6"></span><div><b>Outer light blue band</b>: 10th to 90th percentile. Entry-level through senior.</div></li>
							<li><span class="swatch" style="background:#34537d"></span><div><b>Inner dark blue band</b>: 25th to 75th percentile. The middle 50% of workers.</div></li>
							<li><span class="swatch tick" style="background:#11151c"></span><div><b>Black tick</b>: median. Half earn less, half more.</div></li>
							<li><span class="swatch diamond" style="background:#b5392b"></span><div><b>Red diamond</b>: your target percentile. Hover a row for values.</div></li>
						</ul>

						<p class="help-footnote">Data: BLS OEWS (pay bands), BLS QCEW (industry summary), Virginia WID (LWDAs).</p>
					</div>
				</div>
			</div>

		</div><!-- /.wage-embed -->
	</div>
</section>
