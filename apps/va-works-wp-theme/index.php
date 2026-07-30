<?php
/**
 * Landing template: minimal intro band (no hero video) followed by the three
 * audience-segment cards. Also the theme's fallback template.
 *
 * @package va-works
 */

$va_segments = array(
	array(
		'title' => 'Job Seekers',
		'desc'  => 'Find openings, training, and career tools, and explore local labor market data.',
		'cta'   => 'Explore job seeker services',
	),
	array(
		'title' => 'Employers',
		'desc'  => 'Post jobs, recruit talent, and access wage and industry benchmarks for your region.',
		'cta'   => 'Explore employer services',
	),
	array(
		'title' => 'Workforce Partners',
		'desc'  => 'Program resources, regional performance, and data for boards and providers.',
		'cta'   => 'Explore partner resources',
	),
);

get_header();
?>

<section class="intro">
	<div class="container">
		<h1>Workforce services for every path</h1>
		<p>Connect to jobs, talent, training, and regional labor market insight in one place.</p>
	</div>
</section>

<section class="segments" aria-labelledby="segments-heading">
	<div class="container">
		<h2 id="segments-heading" class="segments__heading">How can we help?</h2>
		<ul class="segment-grid">
			<?php foreach ( $va_segments as $seg ) : ?>
				<li>
					<a class="segment-card" href="#">
						<h3><?php echo esc_html( $seg['title'] ); ?></h3>
						<p><?php echo esc_html( $seg['desc'] ); ?></p>
						<span class="segment-card__cta"><?php echo esc_html( $seg['cta'] ); ?></span>
					</a>
				</li>
			<?php endforeach; ?>
		</ul>
	</div>
</section>

<?php
get_footer();
