<?php
/**
 * Fallback template. Renders the landing sections (intro band + audience cards)
 * from the same shared parts the front page uses, minus the dashboard embed.
 * The front page itself is rendered by front-page.php.
 *
 * @package va-works
 */

get_header();

get_template_part( 'template-parts/intro' );
get_template_part( 'template-parts/segments' );

get_footer();
