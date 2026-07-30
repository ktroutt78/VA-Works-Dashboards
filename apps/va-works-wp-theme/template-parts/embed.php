<?php
/**
 * Reusable iframe embed section — SINGLE SOURCE OF TRUTH for embed markup.
 *
 * Used by front-page.php (dashboard) and page-im-a-job-seeker.php (wage tool).
 * Height + stacking breakpoint live per-variant on `.embed-frame.<variant>` in
 * style.css, so the markup is shared and only the measured numbers differ.
 *
 * Args (via get_template_part( 'template-parts/embed', null, array(...) )):
 *   - id      string  slug for aria-labelledby / element ids (e.g. 'dashboard')
 *   - heading string  section heading
 *   - note    string  one-line context under the heading (optional)
 *   - url     string  iframe src (a VA_*_URL constant value)
 *   - title   string  iframe title attribute (required for AT)
 *   - variant string  height modifier class, e.g. 'is-dashboard' | 'is-wage'
 *
 * @package va-works
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

$va_embed = wp_parse_args(
	$args ?? array(),
	array(
		'id'      => 'embed',
		'heading' => '',
		'note'    => '',
		'url'     => '',
		'title'   => '',
		'variant' => '',
	)
);

$va_embed_heading_id = sanitize_html_class( $va_embed['id'] ) . '-heading';
?>
<section class="embed-section" aria-labelledby="<?php echo esc_attr( $va_embed_heading_id ); ?>">
	<div class="container">
		<h2 id="<?php echo esc_attr( $va_embed_heading_id ); ?>" class="embed-section__heading">
			<?php echo esc_html( $va_embed['heading'] ); ?>
		</h2>
		<?php if ( '' !== $va_embed['note'] ) : ?>
			<p class="embed-note"><?php echo esc_html( $va_embed['note'] ); ?></p>
		<?php endif; ?>

		<iframe
			class="embed-frame <?php echo esc_attr( $va_embed['variant'] ); ?>"
			src="<?php echo esc_url( $va_embed['url'] ); ?>"
			title="<?php echo esc_attr( $va_embed['title'] ); ?>"
			loading="lazy"
		></iframe>
	</div>
</section>
