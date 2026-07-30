<?php
/**
 * Template Name: Dashboard
 *
 * Embeds the Labor Market Snapshot dashboard in a fixed-height iframe. The src
 * comes from the single VA_DASHBOARD_URL constant (see functions.php) so the
 * embed can be repointed in one place. The iframe carries a `title` for AT.
 *
 * NOTE: an iframe does NOT confer accessibility on its contents. The embedded
 * dashboard must independently meet WCAG 2.1 AA. See the handover doc.
 *
 * @package va-works
 */

get_header();
?>

<div class="dashboard-page">
	<div class="container">
		<?php while ( have_posts() ) : the_post(); ?>
			<h1><?php the_title(); ?></h1>
		<?php endwhile; ?>

		<p class="dashboard-note">
			Live labor market snapshot for Virginia localities and workforce regions.
		</p>

		<iframe
			class="dashboard-frame"
			src="<?php echo esc_url( VA_DASHBOARD_URL ); ?>"
			title="Labor Market Snapshot dashboard"
			loading="lazy"
		></iframe>
	</div>
</div>

<?php
get_footer();
