<?php
/**
 * Front page: intro band → three audience-segment cards → dashboard embed.
 *
 * The dashboard sits below the audience cards (segments high on the page,
 * matching the reference layout). All three sections come from shared template
 * parts; the iframe markup/heights live in one place (dashboard-embed part +
 * .dashboard-frame in style.css), so there is nothing to drift.
 *
 * @package va-works
 */

get_header();

get_template_part( 'template-parts/intro' );
get_template_part( 'template-parts/segments' );
get_template_part(
	'template-parts/embed',
	null,
	array(
		'id'      => 'dashboard',
		'heading' => 'Labor market snapshot',
		'note'    => 'Live labor market snapshot for Virginia localities and workforce regions.',
		'url'     => VA_DASHBOARD_URL,
		'title'   => 'Labor Market Snapshot dashboard',
		'variant' => 'is-dashboard',
	)
);

get_footer();
