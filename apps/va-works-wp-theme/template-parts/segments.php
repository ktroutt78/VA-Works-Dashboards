<?php
/**
 * Three audience-segment cards. Shared by front-page.php and index.php.
 *
 * @package va-works
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

$va_segments = array(
	array(
		'title' => 'Job Seekers',
		'desc'  => 'Find openings, training, and career tools, and explore local labor market data.',
		'cta'   => 'Explore job seeker services',
		'url'   => home_url( '/im-a-job-seeker/' ),
	),
	array(
		'title' => 'Employers',
		'desc'  => 'Post jobs, recruit talent, and access wage and industry benchmarks for your region.',
		'cta'   => 'Explore employer services',
		'url'   => home_url( '/im-an-employer/' ),
	),
	array(
		'title' => 'Workforce Partners',
		'desc'  => 'Program resources, regional performance, and data for boards and providers.',
		'cta'   => 'Explore partner resources',
		'url'   => '#',
	),
);
?>
<section class="segments" aria-labelledby="segments-heading">
	<div class="container">
		<h2 id="segments-heading" class="segments__heading">How can we help?</h2>
		<ul class="segment-grid">
			<?php foreach ( $va_segments as $seg ) : ?>
				<li>
					<a class="segment-card" href="<?php echo esc_url( $seg['url'] ); ?>">
						<h3><?php echo esc_html( $seg['title'] ); ?></h3>
						<p><?php echo esc_html( $seg['desc'] ); ?></p>
						<span class="segment-card__cta"><?php echo esc_html( $seg['cta'] ); ?></span>
					</a>
				</li>
			<?php endforeach; ?>
		</ul>
	</div>
</section>
