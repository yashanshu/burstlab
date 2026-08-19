#!/usr/bin/env bash
# docs/concepts/*.md -> homestead vault -> static site -> Cloudflare Pages.
# Usage: ./publish.sh            build only, then open site/public
#        ./publish.sh --deploy   build and push to Cloudflare Pages
set -euo pipefail
cd "$(dirname "$0")"

HOMESTEAD=${HOMESTEAD:-$HOME/csprojects/homestead/homestead}
PROJECT=${CF_PAGES_PROJECT:-burstlab}

# Sections are regenerated every run: docs/ is the only source of truth.
rm -rf site/posts site/pages site/public
mkdir -p site/posts site/pages

# Homestead titles pages from front matter, so mint some: the H1 becomes the
# title (and is dropped from the body, or the theme prints it twice), and the
# file mtime becomes the date.
copy() {
  local src=$1 dest=$2 title
  title=$(sed -n 's/^# //p' "$src" | head -1)
  title=${title#Concept sequence: }
  title=${title//\"/\'}
  {
    printf -- '---\ntitle: "%s"\ndate: %s\n---\n\n' "${title:-$(basename "$src" .md)}" "$(date -r "$src" +%F)"
    # Lesson/tracker cross-references are plain paths in the source; make them
    # tappable on the published site. Tracker rule runs first: it is a prefix
    # of the lesson rule.
    sed '0,/^# /{/^# /d;}' "$src" | sed -E \
      -e 's#docs/concepts/tracks/([a-z0-9-]+)\.md#[\1](/\1/)#g' \
      -e 's#docs/concepts/([a-z0-9-]+)\.md#[\1](/posts/\1/)#g'
  } > "$dest/$(basename "$src")"
}

for f in docs/concepts/*.md; do copy "$f" site/posts; done
for f in docs/concepts/tracks/*.md; do copy "$f" site/pages; done

(cd site && "$HOMESTEAD" build)

# The spoiler blocks are the point of a speedrun: fail loudly rather than
# publish a lesson with its answers already visible.
lesson=$(ls site/public/posts/*/index.html | head -1)
grep -q "<details" "$lesson" || { echo "publish: spoilers stripped from $lesson" >&2; exit 1; }
grep -q 'href="/posts/' site/public/*/index.html || { echo "publish: tracker lost its lesson links" >&2; exit 1; }

if [ "${1:-}" = "--deploy" ]; then
  pnpm dlx wrangler pages deploy site/public --project-name="$PROJECT" --commit-dirty=true
fi
