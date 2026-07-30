/**
 * Header search toggle with focus management.
 *
 * - Toggles the search panel via the `hidden` attribute and keeps the button's
 *   aria-expanded state in sync.
 * - On open, moves focus into the search input.
 * - On Escape, closes and returns focus to the toggle button.
 * - Clicking outside the panel closes it (without stealing focus).
 */
(function () {
	'use strict';

	var btn = document.querySelector('.js-search-toggle');
	var panel = document.getElementById('site-search');
	if (!btn || !panel) {
		return;
	}
	var input = panel.querySelector('input[type="search"]');

	function isOpen() {
		return btn.getAttribute('aria-expanded') === 'true';
	}

	function open() {
		panel.hidden = false;
		btn.setAttribute('aria-expanded', 'true');
		if (input) {
			input.focus();
		}
	}

	function close(returnFocus) {
		panel.hidden = true;
		btn.setAttribute('aria-expanded', 'false');
		if (returnFocus) {
			btn.focus();
		}
	}

	btn.addEventListener('click', function () {
		if (isOpen()) {
			close(true);
		} else {
			open();
		}
	});

	document.addEventListener('keydown', function (e) {
		if (e.key === 'Escape' && isOpen()) {
			close(true);
		}
	});

	document.addEventListener('click', function (e) {
		if (isOpen() && !panel.contains(e.target) && !btn.contains(e.target)) {
			close(false);
		}
	});
})();
