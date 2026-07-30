<?php
/**
 * Page: "I'm an Employer" — auto-applied to the page with slug im-an-employer
 * via the template hierarchy (page-{slug}.php).
 *
 * Mirrors the reference page's structure only (breadcrumb, H1, intro + lead-in,
 * a grid of action links), then embeds the employer pay-band tool. Intro copy is
 * generic — the reference site's branded stats/wordmark are not lifted.
 *
 * @package va-works
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

// Action links mirror the reference page's four categories. Placeholder hrefs.
$va_actions = array(
	'Plan',
	'Develop',
	'Hire',
	'Retain and Grow',
);

get_header();
?>

<div class="page-content">
	<div class="container">

		<nav class="breadcrumb" aria-label="Breadcrumb">
			<ol>
				<li><a href="<?php echo esc_url( home_url( '/' ) ); ?>">Home</a></li>
				<li><span aria-current="page">I'm an employer</span></li>
			</ol>
		</nav>

		<h1>I'm an employer.</h1>

		<p class="lede">
			Find, train, and retain the talent your business needs. Explore wage and
			industry benchmarks, hiring and apprenticeship support, and workforce
			programs across the Commonwealth.
		</p>

		<p class="want-to">I want to . . .</p>

		<ul class="action-grid">
			<?php foreach ( $va_actions as $action ) : ?>
				<li>
					<a class="action-link" href="#"><?php echo esc_html( $action ); ?></a>
				</li>
			<?php endforeach; ?>
		</ul>

	</div>
</div>

<?php
get_template_part(
	'template-parts/embed',
	null,
	array(
		'id'      => 'employer-wage',
		'heading' => 'Build a competitive pay band',
		'note'    => 'Pick a region and job family to see full wage distributions and set a recommended pay range, drawn from Bureau of Labor Statistics OEWS and QCEW data.',
		'url'     => VA_EMPLOYER_WAGE_TOOL_URL,
		'title'   => 'Employer pay-band tool',
		'variant' => 'is-employer-wage',
	)
);

get_footer();
