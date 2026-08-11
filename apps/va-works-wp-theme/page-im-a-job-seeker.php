<?php
/**
 * Page: "I'm a Job Seeker" — auto-applied to the page with slug im-a-job-seeker
 * via the template hierarchy (page-{slug}.php), no template assignment needed.
 *
 * Matches the reference page's structure only: breadcrumb, H1, intro + lead-in,
 * a grid of action links, then the wage comparison tool embed. No other
 * sections (the real page has none beyond these).
 *
 * @package va-works
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

// Action links. Placeholder hrefs (#); labels mirror the reference page.
$va_actions = array(
	'Browse Jobs',
	'Explore Registered Apprenticeship',
	'Get Support While You Job Search',
	'Find My Local Center',
	'Get Veteran Support',
	'Transfer a License',
	'Explore Federal Workforce Resources',
	'Get UI Claim Support',
	'Selected for RESEA?',
	'Sign up for Career Connections',
	'Join Virtual Job Club',
	'Find Training',
);

get_header();
?>

<div class="page-content">
	<div class="container">

		<nav class="breadcrumb" aria-label="Breadcrumb">
			<ol>
				<li><a href="<?php echo esc_url( home_url( '/' ) ); ?>">Home</a></li>
				<li><span aria-current="page">I'm a job seeker</span></li>
			</ol>
		</nav>

		<h1>I'm a job seeker.</h1>

		<p class="lede">
			Whether you're starting out, changing careers, or returning to work, the
			workforce system connects you to jobs, training, and support across the Commonwealth.
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
// Wage comparison tool, embedded inline (no iframe) so it grows with its own
// content. Assets are enqueued in functions.php, gated to this page slug.
get_template_part( 'template-parts/wage-tool-inline' );

get_footer();
