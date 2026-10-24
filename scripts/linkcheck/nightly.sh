#!/bin/bash
# Nightly link check, run by the LaunchAgent that scripts/linkcheck/install.sh
# sets up. Uses the installed app when it supports the check, otherwise a
# fresh build of origin/main in a private clone. Keeps the newest 30 reports
# and posts a notification when anything fails.
set -uo pipefail

SUPPORT="$HOME/Library/Application Support/XDownloader"
LIST="$SUPPORT/check-links.json"
REPORTS="$SUPPORT/check-reports"
WORK="$HOME/Library/Caches/XDownloader-linkcheck"
REPO_URL="https://github.com/gin419/my-downloader.git"
INSTALLED_APP="/Applications/XDownloader.app"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

notify() {
    osascript -e "display notification \"$1\" with title \"XDownloader link check\"" >/dev/null 2>&1 || true
}

mkdir -p "$REPORTS"
echo "== $(date '+%Y-%m-%d %H:%M:%S') nightly link check"
if [ ! -f "$LIST" ]; then
    notify "No link list at Application Support/XDownloader/check-links.json"
    exit 2
fi

if [ "$(/usr/libexec/PlistBuddy -c 'Print :XDLinkCheckVersion' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null)" -ge 1 ] 2>/dev/null; then
    APP="$INSTALLED_APP/Contents/MacOS/XDownloader"
    echo "using the installed app"
else
    echo "the installed app has no link check yet — building origin/main"
    if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    mkdir -p "$WORK"
    if [ ! -d "$WORK/repo/.git" ]; then
        git clone --quiet "$REPO_URL" "$WORK/repo" || { notify "Could not fetch the app's source"; exit 2; }
    fi
    # A private clone used only by this script, so resetting it is safe.
    (cd "$WORK/repo" && git fetch --quiet --tags origin && git checkout --quiet --detach origin/main \
        && git reset --quiet --hard origin/main) || { notify "Could not update the app's source"; exit 2; }
    (cd "$WORK/repo" && XD_NATIVE_ARCH=1 CODESIGN_IDENTITY=- ./build.sh release) \
        || { notify "Could not build the app for the check"; exit 2; }
    APP="$WORK/repo/build/XDownloader.app/Contents/MacOS/XDownloader"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPORTS/nightly-$STAMP.json"
LOG="$REPORTS/nightly-$STAMP.log"
"$APP" --check-links "$LIST" --report "$REPORT" >"$LOG" 2>&1
STATUS=$?
cat "$LOG"

# Newest 30 reports (and their logs) stay.
ls -t "$REPORTS"/*.json 2>/dev/null | tail -n +31 | while read -r old; do
    rm -f "$old" "${old%.json}.log"
done

SUMMARY="$(grep '^SUMMARY' "$LOG" | tail -1)"
FAILED="$(echo "$SUMMARY" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"
TOTAL="$(echo "$SUMMARY" | sed -n 's/.*total=\([0-9]*\).*/\1/p')"
case "$STATUS" in
    0) echo "all passed" ;;
    1) notify "XDownloader link check: ${FAILED:-?} of ${TOTAL:-?} failed" ;;
    *) notify "XDownloader link check could not run (exit $STATUS)" ;;
esac
exit "$STATUS"
