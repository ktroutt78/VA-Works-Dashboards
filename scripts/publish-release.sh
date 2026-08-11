#!/usr/bin/env bash
#
# publish-release.sh <version> — one command to ship a round of client deployment-test
# builds. It:
#   1. runs scripts/build-release.sh <version> to produce the four zips
#   2. creates-or-updates the four GitHub releases and (re)attaches their zips
#   3. deploys wage-comparison-tool to production and repoints its custom alias — its
#      git-push deploy auto-cancels and `vercel --prod` won't move the alias on its own,
#      so this handles that quirk automatically every round
#
# Re-runnable: existing releases are updated (asset clobbered, notes refreshed) rather
# than duplicated, so re-releasing a round is cheap.
#
# Usage:  scripts/publish-release.sh 0.9
#
set -euo pipefail

VERSION="${1:?usage: scripts/publish-release.sh <version>   e.g. 0.9}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/dist/releases"
REPO="ktroutt78/VA-Works-Dashboards"
TEAM="ktroutt78s-projects"
TARGET_BRANCH="main"     # releases tag the current tip of this branch

# ---- 1. build --------------------------------------------------------------------------
echo "== building v$VERSION =="
"$ROOT/scripts/build-release.sh" "$VERSION"

# ---- release notes ---------------------------------------------------------------------
common_note() {
  cat <<'NOTE'
**Deployment-test build for your dev pages — not a final deliverable.**

Already queued, so please hold feedback on these:
- A **data refresh** — placeholder numbers will change (most visibly on Community Profile).
- A **color / typography pass** from your designer.

**Self-contained:** unzip and serve the folder over HTTP (it will not run from a
double-clicked file — see the README). No backend and no internet required — the
charting libraries and the map are bundled. Swap in your own font via `fonts.css`
(step-by-step in the README).
NOTE
}
WAGE_NOTE='Includes the **VA Works design-system rebrand** (commit `1aecc69`). v1.0 was pre-branding, so this build looks noticeably different — that visual change is intended, not a regression.'

# ---- 2. create/update a release --------------------------------------------------------
publish_one() { # tag  zipbase  version  "Title"  latest(true/false)  extra_note
  local tag="$1" zipbase="$2" version="$3" title="$4" latest="$5" extra="$6"
  local zip="$OUT/$zipbase-v$version.zip"
  [ -f "$zip" ] || { echo "  ERROR missing zip: $zip" >&2; exit 1; }
  local body; body="$(common_note)"
  [ -n "$extra" ] && body="$extra"$'\n\n'"$body"
  local rtitle="$title — v$version (deployment test)"
  if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    echo "  updating $tag"
    gh release edit   "$tag" --repo "$REPO" --title "$rtitle" --notes "$body" --latest="$latest"
    gh release upload "$tag" "$zip" --repo "$REPO" --clobber
  else
    echo "  creating $tag"
    gh release create "$tag" "$zip" --repo "$REPO" --target "$TARGET_BRANCH" \
      --title "$rtitle" --notes "$body" --latest="$latest"
  fi
}

echo "== publishing GitHub releases =="
#           tag                         zipbase                   version    "Title"                   latest   extra
publish_one "wage-tool-v1.1"            "wage-comparison-tool"    "1.1"      "Wage Comparison Tool"    true     "$WAGE_NOTE"
publish_one "employer-wage-tool-v$VERSION" "employer-pay-band-tool" "$VERSION" "Employer Pay-Band Tool" false    ""
publish_one "dashboard-v$VERSION"       "labor-market-dashboard"  "$VERSION" "Labor Market Dashboard"  false    ""
publish_one "community-profiles-v$VERSION" "community-profile"     "$VERSION" "Community Profile"       false    ""

# ---- 3. wage-comparison-tool production deploy + alias ---------------------------------
# wage-comparison-tool's git-push build auto-cancels, and its public URL is a custom
# alias that a new production deployment does NOT repoint automatically. Do it here.
echo "== wage-comparison-tool: production deploy + alias =="
DEPLOY_URL="$(vercel --prod --yes --cwd "$ROOT/apps/wage-tool" 2>&1 \
  | grep -oE 'https://[a-z0-9.-]+\.vercel\.app' | tail -1 || true)"
if [ -n "${DEPLOY_URL:-}" ]; then
  echo "  new production deployment: $DEPLOY_URL"
  vercel alias set "$DEPLOY_URL" wage-comparison-tool.vercel.app --scope "$TEAM" \
    || echo "  WARN: alias set failed — run: vercel alias set $DEPLOY_URL wage-comparison-tool.vercel.app --scope $TEAM" >&2
  # verify the public alias now serves the new build (branded, no Google Fonts)
  if curl -s "https://wage-comparison-tool.vercel.app/" | grep -q 'vw-font-display'; then
    echo "  OK: wage-comparison-tool.vercel.app serves the new build"
  else
    echo "  WARN: alias set but the public URL doesn't show the new build yet — check manually" >&2
  fi
else
  echo "  WARN: could not determine a production URL (deploy may have been canceled)." >&2
  echo "        Deploy manually:  vercel --prod --yes --cwd apps/wage-tool" >&2
  echo "        then:             vercel alias set <new-url> wage-comparison-tool.vercel.app --scope $TEAM" >&2
fi

echo ""
echo "Done. Releases: https://github.com/$REPO/releases"
