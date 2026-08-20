#!/usr/bin/env bash
# BurstLab builds with the shared concept-speedrun pipeline, which owns the
# theme, the lesson tagging, and the build guards. This repo owns only content.
#
# Usage: ./publish.sh            build only, then open site/public
#        ./publish.sh --deploy   build and push to Cloudflare Pages
set -euo pipefail
cd "$(dirname "$0")"

SPEEDRUN=${SPEEDRUN:-$HOME/.claude/skills/concept-speedrun}
export CF_PAGES_PROJECT=${CF_PAGES_PROJECT:-burstlab}

[ -x "$SPEEDRUN/publish/publish.sh" ] || {
  echo "publish: concept-speedrun skill not found at $SPEEDRUN" >&2
  exit 1
}

exec "$SPEEDRUN/publish/publish.sh" "$@"
