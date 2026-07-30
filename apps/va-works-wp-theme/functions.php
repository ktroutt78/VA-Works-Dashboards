<?php
/**
 * VA Works Demo — theme setup.
 *
 * Classic theme. Header/nav are hand-authored (see header.php) rather than the
 * core Navigation block, so we can guarantee the skip link, landmark structure,
 * aria-current, and search-toggle focus management demanded by WCAG 2.1 AA.
 *
 * @package va-works
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

/**
 * Single source of truth for the embedded dashboard URL.
 *
 * REPOINT HERE when the client stands up their own hosting. Guarded with
 * `defined()` so it can also be overridden without touching the theme, e.g. in
 * wp-config.php:  define( 'VA_DASHBOARD_URL', 'https://dashboard.example.gov/' );
 *
 * Default below is the local demo target used while the dashboard lives on a
 * temporary Vercel account; swap it for the Vercel demo or production URL.
 */
if ( ! defined( 'VA_DASHBOARD_URL' ) ) {
	define( 'VA_DASHBOARD_URL', 'http://localhost:8123/index.html' );
}

/**
 * Single source of truth for the wage comparison tool URL (apps/wage-tool).
 * Same rules as VA_DASHBOARD_URL: repoint here or override in wp-config.php;
 * default is the local demo target, no Vercel URL baked in.
 */
if ( ! defined( 'VA_WAGE_TOOL_URL' ) ) {
	define( 'VA_WAGE_TOOL_URL', 'http://localhost:8124/wage-tool.html' );
}

/**
 * Single source of truth for the employer pay-band tool URL (apps/wage-tool-employer).
 * Same rules: repoint here or override in wp-config.php; local demo default only.
 */
if ( ! defined( 'VA_EMPLOYER_WAGE_TOOL_URL' ) ) {
	define( 'VA_EMPLOYER_WAGE_TOOL_URL', 'http://localhost:8125/wage-tool-employer.html' );
}

/**
 * Theme supports.
 */
function va_works_setup() {
	add_theme_support( 'title-tag' );
	add_theme_support( 'automatic-feed-links' );
	add_theme_support(
		'html5',
		array( 'search-form', 'gallery', 'caption', 'style', 'script', 'navigation-widgets' )
	);
}
add_action( 'after_setup_theme', 'va_works_setup' );

/**
 * Enqueue the stylesheet and the header-interaction script.
 */
function va_works_assets() {
	// Version assets by file mtime so edits bust the browser cache automatically
	// (a static theme version would pin ?ver= and serve stale CSS/JS across edits).
	$css_path = get_theme_file_path( 'style.css' );
	$js_path  = get_theme_file_path( 'assets/header.js' );
	$css_ver  = file_exists( $css_path ) ? (string) filemtime( $css_path ) : wp_get_theme()->get( 'Version' );
	$js_ver   = file_exists( $js_path ) ? (string) filemtime( $js_path ) : wp_get_theme()->get( 'Version' );

	wp_enqueue_style( 'va-works', get_stylesheet_uri(), array(), $css_ver );

	wp_enqueue_script(
		'va-works-header',
		get_theme_file_uri( 'assets/header.js' ),
		array(),
		$js_ver,
		true // in footer
	);
	wp_script_add_data( 'va-works-header', 'defer', true );
}
add_action( 'wp_enqueue_scripts', 'va_works_assets' );
