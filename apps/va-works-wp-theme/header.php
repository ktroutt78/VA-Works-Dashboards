<?php
/**
 * Header: thin utility bar, placeholder wordmark (left), uppercase primary nav
 * (right), and an accessible search toggle. Opens the #main landmark that the
 * skip link targets; footer.php closes it.
 *
 * @package va-works
 */

// Primary nav. Hand-authored for exact structure + aria-current control.
// aria-current is DERIVED FROM THE REQUEST, never hardcoded: each item maps to
// a slug, and the item whose slug matches the current request path is marked
// current (with a non-colour-only underline). On the home page and on any page
// not in this nav (e.g. the Dashboard), nothing is marked current — which is
// the honest answer. A hardcoded aria-current would lie to a screen reader.
$va_nav_items = array(
	'About'     => 'about',
	'Locations' => 'locations',
	'Newsroom'  => 'newsroom',
	'Events'    => 'events',
	'Policies'  => 'policies',
	'LMI'       => 'lmi',
	'Contact'   => 'contact',
);
global $wp;
$va_current_path = isset( $wp->request ) ? trim( (string) $wp->request, '/' ) : '';
?>
<!DOCTYPE html>
<html <?php language_attributes(); ?>>
<head>
	<meta charset="<?php bloginfo( 'charset' ); ?>">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<?php wp_head(); ?>
</head>
<body <?php body_class(); ?>>
<?php wp_body_open(); ?>

<a class="skip-link" href="#main">Skip to main content</a>

<header class="site-header" role="banner">

	<div class="utility-bar">
		<div class="container">
			<nav aria-label="Utility">
				<ul class="utility-links">
					<li><a href="#">Español</a></li>
					<li><a href="#">Contact</a></li>
					<li><a href="#">Log in</a></li>
				</ul>
			</nav>
		</div>
	</div>

	<div class="masthead">
		<div class="container masthead-inner">

			<?php // Placeholder wordmark — generic text + tile, NOT a state asset. ?>
			<a class="wordmark" href="<?php echo esc_url( home_url( '/' ) ); ?>">
				<span class="wordmark__mark" aria-hidden="true">WF</span>
				<span class="wordmark__text">
					<span class="wordmark__name">Workforce Portal</span>
					<span class="wordmark__tag">Demo / placeholder</span>
				</span>
			</a>

			<nav class="primary-nav" aria-label="Primary">
				<ul class="primary-nav__list">
					<?php
					foreach ( $va_nav_items as $label => $slug ) :
						$is_current = ( '' !== $va_current_path && $va_current_path === $slug );
						?>
						<li>
							<a
								href="<?php echo esc_url( home_url( '/' . $slug . '/' ) ); ?>"
								<?php echo $is_current ? 'aria-current="page"' : ''; ?>
							>
								<?php echo esc_html( $label ); ?>
							</a>
						</li>
					<?php endforeach; ?>
				</ul>

				<button
					type="button"
					class="search-toggle js-search-toggle"
					aria-expanded="false"
					aria-controls="site-search"
				>
					<svg class="search-toggle__icon" viewBox="0 0 20 20" aria-hidden="true" focusable="false">
						<path d="M8 2a6 6 0 014.9 9.46l4.32 4.33-1.42 1.42-4.33-4.32A6 6 0 118 2zm0 2a4 4 0 100 8 4 4 0 000-8z"/>
					</svg>
					<span>Search</span>
				</button>
			</nav>
		</div>

		<?php // Search panel — revealed by the toggle; JS moves focus to the input. ?>
		<div class="search-panel" id="site-search" hidden>
			<div class="container">
				<form role="search" method="get" class="search-form" action="<?php echo esc_url( home_url( '/' ) ); ?>">
					<div class="search-form__field">
						<label for="site-search-input">Search the site</label>
						<input
							type="search"
							id="site-search-input"
							name="s"
							placeholder="Search…"
							autocomplete="off"
						>
					</div>
					<button type="submit">Search</button>
				</form>
			</div>
		</div>
	</div>
</header>

<main id="main" class="site-main" tabindex="-1">
