<?php
/**
 * Inline wage comparison tool (apps/wage-tool), embedded directly in the page
 * DOM — no iframe. Replaces the old template-parts/embed.php iframe for the
 * job-seeker page so the tool grows/shrinks with its own content instead of
 * scrolling inside a fixed-height frame.
 *
 * The markup below is a faithful port of apps/wage-tool/wage-tool.html's <body>.
 * Its styles + script live in assets/embeds/wage-tool.css / wage-tool.js and are
 * enqueued (with echarts/tom-select/theme deps and the data-base path) from
 * functions.php, gated to this page. Everything is wrapped in `.wage-embed`, the
 * container the tool's design tokens are scoped to (was :root in the standalone).
 *
 * @package va-works
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}
?>
<section class="embed-section" aria-labelledby="wage-tool-heading">
	<div class="container">
		<h2 id="wage-tool-heading" class="embed-section__heading">Compare wages by occupation</h2>
		<p class="embed-note">Search an occupation to see its Virginia wage range and compare roles side by side, drawn from Bureau of Labor Statistics OEWS data.</p>

		<div class="wage-embed">
			<div class="page-wrap">
				<div class="frame">
					<header class="header">
						<div>
							<div class="header-title">Wage Comparison Tool</div>
							<div class="header-sub">Compare wages in your area · Bureau of Labor Statistics OEWS</div>
						</div>
						<button id="help-btn" class="help-btn" aria-haspopup="dialog" aria-controls="help-modal" title="How to read this chart">
							<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
								<circle cx="12" cy="12" r="9.5"/>
								<path d="M9.5 9 a2.5 2.5 0 1 1 4 2 c-.7 .5 -1.5 1 -1.5 2"/>
								<circle cx="12" cy="17" r=".6" fill="currentColor"/>
							</svg>
							Guide
						</button>
					</header>

					<section class="controls">
						<div class="control-grid">
							<div class="job-field">
								<div class="field-label">Current job</div>
								<input id="cur-job" class="field-input job-input" type="text" placeholder="e.g. sales associate, line cook, RN" autocomplete="off" />
								<div class="job-helper" data-for="cur-job" hidden>Type a title for matches</div>
								<ul class="job-suggest" data-for="cur-job" role="listbox" hidden></ul>
								<div class="match-hint" data-for="cur-job"></div>
							</div>
							<div>
								<div class="field-label">Current location</div>
								<select id="cur-area" class="field-select"></select>
							</div>
							<div>
								<div class="field-label">Current salary</div>
								<input id="cur-salary" class="field-input" type="text" placeholder="e.g. $48,000" inputmode="numeric" />
							</div>
						</div>
						<div class="control-grid cmp-controls">
							<div class="job-field">
								<div class="field-label">Comparison job</div>
								<input id="cmp-job" class="field-input job-input" type="text" placeholder="e.g. data analyst, project manager" autocomplete="off" />
								<div class="job-helper" data-for="cmp-job" hidden>Type a title for matches</div>
								<ul class="job-suggest" data-for="cmp-job" role="listbox" hidden></ul>
								<div class="match-hint" data-for="cmp-job"></div>
							</div>
							<div>
								<div class="field-label">Comparison location</div>
								<select id="cmp-area" class="field-select"></select>
							</div>
							<div>
								<div class="field-label">Comparison salary<button type="button" id="cmp-salary-reset" class="cmp-salary-reset" hidden title="Reset to current salary">reset</button></div>
								<input id="cmp-salary" class="field-input" type="text" placeholder="defaults to current" inputmode="numeric" />
							</div>
						</div>
					</section>

					<section class="chart-area">
						<div id="rows-container"></div>
						<div class="axis-row">
							<div id="axis-chart" class="axis-chart"></div>
						</div>
						<div class="legend-row">
							<div class="legend">
								<span class="legend-chip"><i style="background:var(--band-outer)"></i> 10th–90th percentile</span>
								<span class="legend-chip"><i style="background:var(--band-inner)"></i> 25th–75th percentile</span>
								<span class="legend-chip"><i class="tall" style="background:var(--ink)"></i> Median</span>
								<span class="legend-chip"><i class="dot" style="background:var(--hi)"></i> Your salary</span>
							</div>
							<button id="add-job" class="btn btn-primary">+ Add comparison job</button>
						</div>
						<div class="action-row">
							<span class="source-note" id="source-note"></span>
						</div>
					</section>
				</div>
			</div>

			<div id="help-modal" class="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="help-title" aria-hidden="true">
				<div class="modal-card">
					<div class="modal-head">
						<h2 id="help-title">How to read this chart</h2>
						<button class="modal-close" aria-label="Close">×</button>
					</div>
					<div class="modal-body">
						<p>Each row shows a single occupation's wage spread for the area you selected. The bar tells you how wages vary among workers in that job.</p>

						<svg class="help-illustration" viewBox="0 0 480 170" role="img" aria-label="Annotated example of a percentile bar">
							<!-- Bar -->
							<g transform="translate(40, 65)">
								<rect x="0"   y="6" width="400" height="28" rx="3" fill="#8aa0c4"/>
								<rect x="100" y="9" width="200" height="22" rx="2" fill="#3a5a8a"/>
								<line x1="180" y1="0" x2="180" y2="40" stroke="#1a1f2c" stroke-width="3" stroke-linecap="square"/>
								<circle cx="260" cy="20" r="7" fill="#b03a2e" stroke="#fff" stroke-width="2"/>
							</g>
							<!-- Callouts -->
							<!-- 10-90 -->
							<g fill="#3a4153" font-family="-apple-system, system-ui, sans-serif" font-size="11">
								<line x1="60"  y1="65" x2="60"  y2="40" stroke="#5a6376" stroke-width="1"/>
								<text x="62"  y="32" font-weight="600">10th–90th percentile</text>
								<text x="62"  y="46" fill="#5a6376">the widest band — 80% of workers</text>
							</g>
							<!-- 25-75 -->
							<g fill="#3a4153" font-family="-apple-system, system-ui, sans-serif" font-size="11">
								<line x1="280" y1="65" x2="280" y2="40" stroke="#5a6376" stroke-width="1"/>
								<text x="282" y="32" font-weight="600">25th–75th percentile</text>
								<text x="282" y="46" fill="#5a6376">the middle 50% — most workers</text>
							</g>
							<!-- Median -->
							<g fill="#3a4153" font-family="-apple-system, system-ui, sans-serif" font-size="11">
								<line x1="220" y1="105" x2="220" y2="130" stroke="#5a6376" stroke-width="1"/>
								<text x="222" y="146" font-weight="600">Median</text>
							</g>
							<!-- Salary -->
							<g fill="#3a4153" font-family="-apple-system, system-ui, sans-serif" font-size="11">
								<line x1="300" y1="105" x2="380" y2="130" stroke="#b03a2e" stroke-width="1"/>
								<text x="378" y="146" font-weight="600" fill="#b03a2e">Your salary</text>
							</g>
						</svg>

						<ul class="help-bullets">
							<li><span class="swatch" style="background:var(--band-outer)"></span><div><b>Outer light blue band</b> — the 10th to 90th percentile of workers in this job. Wages here include early-career, mid-career, and most senior workers.</div></li>
							<li><span class="swatch" style="background:var(--band-inner)"></span><div><b>Inner dark blue band</b> — the 25th to 75th percentile. Most workers in this occupation earn somewhere in this range.</div></li>
							<li><span class="swatch tick" style="background:var(--ink)"></span><div><b>Black tick</b> — the median. Half of workers earn less, half earn more.</div></li>
							<li><span class="swatch dot" style="background:var(--hi)"></span><div><b>Red dot</b> — a salary plotted on this row's scale. The current-role dot is your current salary; the comparison-role dot defaults to it too, but you can enter a different value to model a target wage in that occupation.</div></li>
						</ul>

						<p class="help-footnote">Sparklines at right show the annual wage trend (last 5 years) and the monthly employment trend. Hover any chart for exact values. Data: BLS Occupational Employment and Wage Statistics.</p>
					</div>
				</div>
			</div>

			<div id="diag" class="diag"></div>
		</div>
	</div>
</section>
