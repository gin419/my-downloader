#!/bin/bash
# Installs the nightly link check (04:30 daily) for the current user:
# copies nightly.sh to Application Support and loads a LaunchAgent for it.
# Undo: launchctl bootout gui/$(id -u)/com.gin.xdownloader.linkcheck
#       rm ~/Library/LaunchAgents/com.gin.xdownloader.linkcheck.plist
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.gin.xdownloader.linkcheck"
DEST="$HOME/Library/Application Support/XDownloader/linkcheck"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/XDownloader-linkcheck.log"

mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 755 "$HERE/nightly.sh" "$DEST/nightly.sh"
# Paths may hold spaces and "&" never; escape what sed's replacement needs.
esc() { printf '%s' "$1" | sed 's/[\/&]/\\&/g'; }
sed -e "s/__SCRIPT__/$(esc "$DEST/nightly.sh")/" -e "s/__LOG__/$(esc "$LOG")/" \
    "$HERE/$LABEL.plist.template" >"$PLIST"
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✅ Nightly link check loaded ($LABEL, 04:30). Log: $LOG"
