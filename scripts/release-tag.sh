#!/bin/bash
# Tag a release after the link check passes:
#
#   scripts/release-tag.sh v1.12.6
#
# Requires: on main, clean, equal to origin/main, and the tag free locally
# and on GitHub. Runs scripts/check-links.sh, then tags and pushes — the push
# starts the signed release build (release.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 vX.Y.Z" >&2; exit 2; }

git fetch --quiet --tags origin
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "❌ Not on main." >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "❌ Uncommitted changes." >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "❌ main differs from origin/main — pull or push first." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "❌ $TAG is already taken — pick the next number." >&2
    exit 1
fi

scripts/check-links.sh

git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"
echo "🚀 Pushed $TAG — the release build is running on GitHub."
