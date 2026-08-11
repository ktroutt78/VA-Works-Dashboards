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

// The wage comparison and employer pay-band tools are no longer iframed — they're
// embedded inline in their pages (see va_works_embed_assets below), so the old
// VA_WAGE_TOOL_URL / VA_EMPLOYER_WAGE_TOOL_URL iframe-src constants were removed.

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

/**
 * Enqueue the inline wage-tool embeds.
 *
 * The job-seeker and employer pages embed the ECharts wage tools directly in the
 * page DOM (template-parts/*-inline.php) instead of via an iframe, so each tool
 * grows with its own content. Their markup ships in the template parts; their
 * scoped CSS + JS live in assets/embeds/, and the CDN deps (echarts, tom-select,
 * fonts) plus the theme's ECharts theme registration are wired up here.
 *
 * Gated to the two page slugs so no other page pays for ~1MB of echarts + data.
 * The tool JS reads its data-directory URL from a localized global (window.vaWageTool
 * / window.vaEmployerWageTool) since the standalone apps fetched a relative "data/"
 * path that doesn't resolve once the markup is inlined into a WordPress route.
 */
function va_works_embed_assets() {
	$is_wage     = is_page( 'im-a-job-seeker' );
	$is_employer = is_page( 'im-an-employer' );
	if ( ! $is_wage && ! $is_employer ) {
		return;
	}

	// Shared CDN deps. echarts must load before va-works-theme (which calls
	// echarts.registerTheme) and before each tool script.
	wp_enqueue_style(
		'tom-select',
		'https://cdn.jsdelivr.net/npm/tom-select@2/dist/css/tom-select.css',
		array(),
		'2'
	);
	wp_enqueue_script(
		'echarts',
		'https://cdn.jsdelivr.net/npm/echarts@5/dist/echarts.min.js',
		array(),
		'5',
		true
	);
	wp_enqueue_script(
		'tom-select',
		'https://cdn.jsdelivr.net/npm/tom-select@2/dist/js/tom-select.complete.min.js',
		array(),
		'2',
		true
	);
	$theme_js_path = get_theme_file_path( 'assets/embeds/va-works-theme.js' );
	$theme_js_ver  = file_exists( $theme_js_path ) ? (string) filemtime( $theme_js_path ) : '1';
	wp_enqueue_script(
		'va-works-echarts-theme',
		get_theme_file_uri( 'assets/embeds/va-works-theme.js' ),
		array( 'echarts' ),
		$theme_js_ver,
		true
	);

	if ( $is_wage ) {
		wp_enqueue_style(
			'wage-tool-fonts',
			'https://fonts.googleapis.com/css2?family=Source+Serif+Pro:wght@600;700&family=JetBrains+Mono:wght@400;600&display=swap',
			array(),
			null
		);
		va_works_enqueue_embed(
			'wage-tool',
			'assets/embeds/wage-tool.css',
			'assets/embeds/wage-tool.js',
			'assets/embeds/wage-tool/data',
			'vaWageTool'
		);
	}

	if ( $is_employer ) {
		wp_enqueue_style(
			'employer-wage-tool-fonts',
			'https://fonts.googleapis.com/css2?family=Source+Serif+Pro:wght@400;600;700&family=Inter:wght@400;500;600;700&display=swap',
			array(),
			null
		);
		va_works_enqueue_embed(
			'employer-wage-tool',
			'assets/embeds/employer-wage-tool.css',
			'assets/embeds/employer-wage-tool.js',
			'assets/embeds/employer-wage-tool/data',
			'vaEmployerWageTool'
		);
	}
}
add_action( 'wp_enqueue_scripts', 'va_works_embed_assets' );

/**
 * Register one inline tool's scoped stylesheet + script, versioned by file mtime
 * (edits bust the cache) and handed its data-directory URL via a localized global.
 *
 * @param string $handle    Base handle / slug (e.g. 'wage-tool').
 * @param string $css_rel   Theme-relative path to the scoped CSS.
 * @param string $js_rel    Theme-relative path to the tool JS.
 * @param string $data_rel  Theme-relative path to the tool's data directory.
 * @param string $js_global JS global the tool reads its dataBase from.
 */
function va_works_enqueue_embed( $handle, $css_rel, $js_rel, $data_rel, $js_global ) {
	$css_path = get_theme_file_path( $css_rel );
	$js_path  = get_theme_file_path( $js_rel );
	$css_ver  = file_exists( $css_path ) ? (string) filemtime( $css_path ) : '1';
	$js_ver   = file_exists( $js_path ) ? (string) filemtime( $js_path ) : '1';

	wp_enqueue_style(
		$handle,
		get_theme_file_uri( $css_rel ),
		array( 'va-works', 'tom-select' ),
		$css_ver
	);
	wp_enqueue_script(
		$handle,
		get_theme_file_uri( $js_rel ),
		array( 'echarts', 'va-works-echarts-theme', 'tom-select' ),
		$js_ver,
		true
	);
	wp_localize_script(
		$handle,
		$js_global,
		array( 'dataBase' => trailingslashit( get_theme_file_uri( $data_rel ) ) )
	);
}
