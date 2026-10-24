#!/bin/bash
# Link check before a release: build the app from this checkout and let it
# download every link on the private list with its own code, on this Mac's
# network and browser login. A passing run on a clean tree leaves a stamp for
# the commit; pushing a version tag needs one (see scripts/install-hooks.sh).
#
#   scripts/check-links.sh [--no-build] [--list <file>] [--timeout <seconds>]
#
# The list is private and never committed (the repo is public). Default:
#   ~/Library/Application Support/XDownloader/check-links.json
# Format: docs/check-links.example.json
set -euo pipefail

cd "$(dirname "$0")/.."
SUPPORT="$HOME/Library/Application Support/XDownloader"
LIST="$SUPPORT/check-links.json"
TIMEOUT=180
BUILD=1
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=0 ;;
        --list) LIST="$2"; shift ;;
        --timeout) TIMEOUT="$2"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ ! -f "$LIST" ]; then
    echo "❌ No link list at: $LIST" >&2
    echo "   Copy docs/check-links.example.json there and put real links in it." >&2
    exit 2
fi

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

COMMIT="$(git rev-parse HEAD)"
DIRTY=""
[ -n "$(git status --porcelain --untracked-files=no)" ] && DIRTY=1

if [ "$BUILD" = 1 ]; then
    # This Mac's architecture only, signed ad hoc: nothing here is shipped.
    XD_NATIVE_ARCH=1 CODESIGN_IDENTITY=- ./build.sh release >/dev/null
fi
APP="build/XDownloader.app/Contents/MacOS/XDownloader"
[ -x "$APP" ] || { echo "❌ No built app at $APP" >&2; exit 2; }

REPORTS="$SUPPORT/check-reports"
mkdir -p "$REPORTS"
REPORT="$REPORTS/release-$(date +%Y%m%d-%H%M%S).json"

echo "🔗 Checking $(grep -c '"url"' "$LIST") links from the private list…"
set +e
"$APP" --check-links "$LIST" --report "$REPORT" --timeout "$TIMEOUT"
STATUS=$?
set -e
echo "   report: $REPORT"

STAMPS="$(git rev-parse --git-common-dir)/xdownloader-link-check-passes"
if [ "$STATUS" -eq 0 ]; then
    if [ -n "$DIRTY" ]; then
        echo "⚠️  All links passed, but the tree has uncommitted changes — no stamp written."
        echo "   Commit, then run this again before tagging."
    else
        echo "$COMMIT $(date +%s)" >>"$STAMPS"
        echo "✅ All links passed — stamped ${COMMIT:0:7} for a version tag (valid 24h)."
    fi
else
    echo "❌ The link check did not pass (exit $STATUS) — fix it before releasing." >&2
fi
exit "$STATUS"
