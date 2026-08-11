#!/usr/bin/env bash
#
# build-release.sh — assemble self-contained client-deliverable zips for the four
# ECharts apps. No hand-assembly: run this and get identical, reproducible bundles.
#
# Per app it:
#   1. stages the app into a temp dir and renames its HTML to index.html
#   2. strips everything between <!-- DEMO CHROME START --> / <!-- DEMO CHROME END -->
#   3. vendors the CDN libraries into vendor/ (echarts always; tom-select for the wage
#      tools; topojson for the map apps) and rewrites the CDN <script>/<link> refs
#   4. copies data/ (which already includes the locally-bundled counties-10m.json for
#      the map apps — the source fetch was repointed to data/counties-10m.json)
#   5. injects a fonts.css <link> (loaded after the inline <style>, before
#      va-works-theme.js, so it overrides the default font tokens and the charts pick
#      the client's font up), emits fonts.css + an empty fonts/ dir
#   6. writes the README, then zips folder-at-root
#
# It also SYNCs apps/wage-tool/data and apps/wage-tool-employer/data into the WP theme's
# assets/embeds/<tool>/data so those embedded copies can't silently drift.
#
# Usage:  scripts/build-release.sh            # build all four
#         scripts/build-release.sh wage-tool  # build one (by source dir name)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/releases"
WORK="$(mktemp -d)"
CACHE="$WORK/_cache"
mkdir -p "$OUT" "$CACHE"
trap 'rm -rf "$WORK"' EXIT

# Pinned CDN versions (reproducible builds; bump deliberately).
ECHARTS_VER="5.5.0"
TOMSELECT_VER="2.4.3"
TOPOJSON_VER="3.1.0"

log() { printf '  %s\n' "$*"; }

# ---- download the vendored libraries once into the cache -----------------------------
fetch() { # url dest
  curl -sSL --fail "$1" -o "$2" || { echo "FAILED to download $1" >&2; exit 1; }
}
prime_cache() {
  log "downloading vendored libraries (echarts@$ECHARTS_VER, tom-select@$TOMSELECT_VER, topojson-client@$TOPOJSON_VER)"
  fetch "https://cdn.jsdelivr.net/npm/echarts@${ECHARTS_VER}/dist/echarts.min.js"                 "$CACHE/echarts.min.js"
  fetch "https://cdn.jsdelivr.net/npm/tom-select@${TOMSELECT_VER}/dist/js/tom-select.complete.min.js" "$CACHE/tom-select.complete.min.js"
  fetch "https://cdn.jsdelivr.net/npm/tom-select@${TOMSELECT_VER}/dist/css/tom-select.css"         "$CACHE/tom-select.css"
  fetch "https://cdn.jsdelivr.net/npm/topojson-client@${TOPOJSON_VER}/dist/topojson-client.min.js" "$CACHE/topojson-client.min.js"
}

# ---- helpers (operate on a staged index.html) ---------------------------------------
strip_demo_chrome() { # index.html
  # Remove the simulated site chrome (only present in community-profiles). Anchor on the
  # comment delimiters (<!-- ... -->) so a prose mention of the marker names inside the
  # block can't end the range early.
  sed -i '' '/<!-- DEMO CHROME START/,/DEMO CHROME END -->/d' "$1"
}

vendor_lib() { # lib stagedir
  local lib="$1" stage="$2" html="$2/index.html"
  case "$lib" in
    echarts)
      cp "$CACHE/echarts.min.js" "$stage/vendor/echarts.min.js"
      # rewrite any echarts@... CDN src to the local vendor copy
      sed -i '' -E 's#https://cdn\.jsdelivr\.net/npm/echarts@[^"]*#vendor/echarts.min.js#g' "$html" ;;
    tomselect)
      cp "$CACHE/tom-select.complete.min.js" "$stage/vendor/tom-select.complete.min.js"
      cp "$CACHE/tom-select.css"             "$stage/vendor/tom-select.css"
      sed -i '' -E 's#https://cdn\.jsdelivr\.net/npm/tom-select@[^"]*complete\.min\.js#vendor/tom-select.complete.min.js#g' "$html"
      sed -i '' -E 's#https://cdn\.jsdelivr\.net/npm/tom-select@[^"]*tom-select\.css#vendor/tom-select.css#g' "$html" ;;
    topojson)
      cp "$CACHE/topojson-client.min.js" "$stage/vendor/topojson-client.min.js"
      sed -i '' -E 's#https://cdn\.jsdelivr\.net/npm/topojson-client@[^"]*#vendor/topojson-client.min.js#g' "$html" ;;
  esac
}

inject_fonts_link() { # index.html
  # Place fonts.css right after the inline stylesheet so it overrides the default
  # --vw-font-* tokens, and BEFORE va-works-theme.js so the charts read the override.
  # (perl, not sed — BSD/macOS sed won't expand \n in the replacement.)
  perl -0777 -i -pe 's#</style>#</style>\n  <link rel="stylesheet" href="fonts.css">#' "$1"
}

emit_fonts_css() { # dest
  cat > "$1" <<'CSS'
/* ============================================================================
   FONTS — the one file to edit if you want to use your own font.
   See "Using your own fonts" in the README for a full walk-through.

   Out of the box these apps use a Public Sans / system-font stack. They are fully
   functional as-is, need no internet, and require no font files. Changing the font
   is entirely optional.
   ============================================================================ */

:root {
  /* --vw-font-display : headings and large KPI numerals
     --vw-font-body    : body text, labels, tables, and chart text
     The two may be the same family. To use your own font, replace the first name
     in each stack with your family (keep the system fallbacks after it). */
  --vw-font-display: "Public Sans", system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  --vw-font-body:    "Public Sans", system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}

/* ----------------------------------------------------------------------------
   To use your own font:
     1. Drop your .woff2 (and optional .woff) files into the fonts/ folder that
        sits next to this file.
     2. Uncomment the @font-face blocks below; set the family name, file names,
        and weights to match your files.
     3. Set --vw-font-display / --vw-font-body above to your family name.
     4. Save and hard-refresh (Cmd/Ctrl + Shift + R).

   WORKED EXAMPLE — a family called "Acme Sans" with a regular and a bold weight.
   Note the family name in @font-face ("Acme Sans") matches the variable value
   exactly.

   @font-face {
     font-family: "Acme Sans";
     src: url("fonts/AcmeSans-Regular.woff2") format("woff2"),
          url("fonts/AcmeSans-Regular.woff")  format("woff");
     font-weight: 400;
     font-style: normal;
     font-display: swap;
   }
   @font-face {
     font-family: "Acme Sans";
     src: url("fonts/AcmeSans-Bold.woff2") format("woff2"),
          url("fonts/AcmeSans-Bold.woff")  format("woff");
     font-weight: 700;
     font-style: normal;
     font-display: swap;
   }

   ...then set the variables above to:

   --vw-font-display: "Acme Sans", system-ui, sans-serif;
   --vw-font-body:    "Acme Sans", system-ui, sans-serif;
   ---------------------------------------------------------------------------- */
CSS
}

emit_readme() { # dest  "Title"
  local dest="$1" title="$2"
  cat > "$dest" <<README
# ${title}

A self-contained, static build. Everything it needs ships in this folder — no
backend, no database, no API keys, and (once served) no internet connection.

## Running it

**It must be served over HTTP.** Opening \`index.html\` straight from the file
system shows a blank app, because browsers block a page loaded via \`file://\` from
reading its own data files (\`fetch()\` is disabled there). Any static web host works
— your web server, a folder on your CMS, a storage bucket, or a one-line local
server for a quick look:

\`\`\`
cd path/to/this-folder     # the folder this README is in
python3 -m http.server 8080
# then open http://localhost:8080/
\`\`\`

Because all paths are relative, the folder can live at any URL or subdirectory.

## The data

The numbers are a **point-in-time snapshot**, baked into the \`data/\` folder as
static JSON. To refresh them later, replace the files in \`data/\` (or ask us for a
new build). There is no live pipeline to configure.

## Using your own fonts

Out of the box the app uses a **Public Sans / system-font stack** — clean,
readable, and fully functional with **no internet and no font files**. Swapping in
your own font is **optional**; if you never touch it, everything just works.

Only two things ever need to change:

- **\`fonts.css\`** — the single stylesheet you edit.
- **\`fonts/\`** — the folder your font files go into.

### Steps

1. Copy your font files into \`fonts/\`. Supply **\`.woff2\`** (and \`.woff\` too, for
   older browsers).
2. Open \`fonts.css\`, uncomment the \`@font-face\` block(s), and set the family name,
   file names, and weights to match your files.
3. Set the two variables at the top of \`fonts.css\` to your family name.
4. Save and **hard-refresh** (Cmd/Ctrl + Shift + R) to clear the cached stylesheet.

### Worked example

Say your font is called **Acme Sans** and you have a regular and a bold file. In
\`fonts.css\`:

\`\`\`css
@font-face {
  font-family: "Acme Sans";
  src: url("fonts/AcmeSans-Regular.woff2") format("woff2"),
       url("fonts/AcmeSans-Regular.woff")  format("woff");
  font-weight: 400;
  font-style: normal;
  font-display: swap;
}
@font-face {
  font-family: "Acme Sans";
  src: url("fonts/AcmeSans-Bold.woff2") format("woff2"),
       url("fonts/AcmeSans-Bold.woff")  format("woff");
  font-weight: 700;
  font-style: normal;
  font-display: swap;
}
\`\`\`

...then set the variables (the family name here **must match** the \`@font-face\`
name exactly):

\`\`\`css
:root {
  --vw-font-display: "Acme Sans", system-ui, sans-serif;
  --vw-font-body:    "Acme Sans", system-ui, sans-serif;
}
\`\`\`

### Which variable controls what

- **\`--vw-font-display\`** — headings and the large KPI numbers.
- **\`--vw-font-body\`** — body text, labels, tables, and all chart text.

They can be the **same family** (set both to it), or two different families if your
brand pairs a display face with a text face.

### Weights the app uses

The design uses weights **400 (regular), 500, 600, 700, and 800 (extrabold)** —
600/700 for headings, 800 for the big numerals, 400/500 for body. Supply at least
400, 600, and 700; include 500 and 800 for the closest match. Any weight you don't
provide falls back to the nearest one you do.

### Troubleshooting

- **Font isn't applying.** The family name in \`@font-face\` must match the variable
  value **exactly** (including capitalization).
- **404s in the browser console.** The file names/paths in \`@font-face\` must match
  the actual files in \`fonts/\`.
- **Still the old font.** You're likely seeing cached CSS — **hard-refresh**.
- **Blank / unstyled when double-clicked.** It must be **served over HTTP**, not
  opened from the file system (see "Running it").

### A note on licensing

Serving a font as a **webfont** (an \`@font-face\` file the browser downloads)
requires a license that covers **web embedding** — this is a different tier from a
desktop/print license. Worth confirming your font's license covers it before you
deploy. (Informational, not legal advice.)

### Already have your brand font on the page?

If you embed this app inside a page that **already loads your brand font**, you can
skip all of the above: delete the two \`--vw-font-*\` declarations from \`fonts.css\`
and the app will **inherit the surrounding page's font** automatically.
README
}

# ---- per-app build ------------------------------------------------------------------
build_app() { # srcdirname  srchtml  "Deliverable Title"  folder  "libs"
  local srcname="$1" srchtml="$2" title="$3" folder="$4" libs="$5"
  local src="$ROOT/apps/$srcname"
  local stage="$WORK/$folder"
  log "building: $folder  (from apps/$srcname/$srchtml; libs: $libs)"
  mkdir -p "$stage/vendor" "$stage/fonts"
  cp -R "$src/data" "$stage/data"
  rm -rf "$stage/data/raw"   # raw source artifacts the app never fetches — not for the client
  cp "$src/va-works-theme.js" "$stage/va-works-theme.js"
  cp "$src/$srchtml" "$stage/index.html"
  strip_demo_chrome "$stage/index.html"
  for lib in $libs; do vendor_lib "$lib" "$stage"; done
  inject_fonts_link "$stage/index.html"
  emit_fonts_css "$stage/fonts.css"
  emit_readme "$stage/README.md" "$title"
  # keep an empty fonts/ dir in the zip
  touch "$stage/fonts/.gitkeep" 2>/dev/null || true
  # sanity: no CDN refs should remain as a real dependency (src=/href=). A CDN name
  # inside a JS string — e.g. an error message — is fine and expected.
  if grep -qE '(src|href)="https?://cdn\.jsdelivr\.net' "$stage/index.html"; then
    echo "WARN: $folder/index.html still loads a lib from a CDN — vendoring missed one" >&2
    grep -nE '(src|href)="https?://cdn\.jsdelivr\.net' "$stage/index.html" >&2
  fi
  ( cd "$WORK" && rm -f "$OUT/$folder.zip" && zip -rq "$OUT/$folder.zip" "$folder" -x '*/.gitkeep' )
  log "  -> $OUT/$folder.zip"
}

# ---- keep the WP-theme data copies in sync ------------------------------------------
sync_theme_data() {
  local theme="$ROOT/apps/va-works-wp-theme/assets/embeds"
  if [ -d "$theme" ]; then
    log "syncing wage-tool data -> WP theme embeds"
    rsync -a --delete --exclude 'raw/' "$ROOT/apps/wage-tool/data/"          "$theme/wage-tool/data/"
    rsync -a --delete --exclude 'raw/' "$ROOT/apps/wage-tool-employer/data/" "$theme/employer-wage-tool/data/"
  fi
}

# ---- main ---------------------------------------------------------------------------
prime_cache
sync_theme_data

TARGET="${1:-all}"
run() { # srcname ...
  if [ "$TARGET" = "all" ] || [ "$TARGET" = "$1" ]; then build_app "$@"; fi
}
#    srcdir                         srchtml                    "Title"                    folder                    libs
run "wage-tool"                     "wage-tool.html"           "Wage Comparison Tool"     "wage-comparison-tool"    "echarts tomselect"
run "wage-tool-employer"            "wage-tool-employer.html"  "Employer Pay-Band Tool"   "employer-pay-band-tool"  "echarts tomselect"
run "dashboard-front-page-echarts"  "index.html"              "Labor Market Dashboard"   "labor-market-dashboard"  "echarts topojson"
run "community-profiles"            "index.html"              "Community Profile"        "community-profile"       "echarts topojson"

echo ""
echo "Done. Zips in: $OUT"
ls -lh "$OUT"/*.zip 2>/dev/null | awk '{print "  "$9"  "$5}'
