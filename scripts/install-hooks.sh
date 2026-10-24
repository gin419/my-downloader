#!/bin/bash
# Installs this repository's git hooks without losing the machine-wide ones.
#
# git reads hooks from ONE directory (core.hooksPath). On a machine whose
# global config points that at a shared hooks folder, a repository hook
# can't simply be added: setting this repo's own core.hooksPath replaces the
# shared folder here. So every hook installed below first runs the shared
# hook of the same name, then — for pre-push only — the version-tag check
# (scripts/hooks/require-link-check).
#
# The hooks live in <git dir>/xd-hooks (untracked). Re-run after changing
# scripts/hooks/. Undo: git config --unset core.hooksPath
set -euo pipefail
cd "$(dirname "$0")/.."

COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
DIR="$COMMON/xd-hooks"
mkdir -p "$DIR"
install -m 755 scripts/hooks/require-link-check "$DIR/require-link-check"

# Runs the hook of the same name from the global hooks folder; with no
# global folder, from the repository's own .git/hooks, as git would.
cat >"$DIR/_delegate" <<'EOF'
#!/bin/sh
# Installed by scripts/install-hooks.sh — runs the machine-wide hook of this name.
event="${0##*/}"
global="$(git config --global --get core.hooksPath 2>/dev/null || true)"
case "$global" in "~"*) global="$HOME${global#\~}" ;; esac
if [ -n "$global" ]; then
    if [ -x "$global/$event" ]; then exec "$global/$event" "$@"; fi
    exit 0
fi
common="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
if [ -x "$common/hooks/$event" ]; then exec "$common/hooks/$event" "$@"; fi
exit 0
EOF
chmod 755 "$DIR/_delegate"

EVENTS="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit
prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge
post-rewrite reference-transaction push-to-checkout pre-auto-gc sendemail-validate"
for event in $EVENTS; do
    ln -sf _delegate "$DIR/$event"
done

# pre-push: the shared hook, then the tag check, each given the same stdin.
rm -f "$DIR/pre-push"
cat >"$DIR/pre-push" <<'EOF'
#!/bin/sh
# Installed by scripts/install-hooks.sh — machine-wide pre-push, then the tag check.
here="$(cd "$(dirname "$0")" && pwd)"
input="$(mktemp)"
trap 'rm -f "$input"' EXIT
cat >"$input"
"$here/_delegate-pre-push" "$@" <"$input"
st=$?
[ "$st" -ne 0 ] && exit "$st"
"$here/require-link-check" "$@" <"$input"
st=$?
exit "$st"
EOF
chmod 755 "$DIR/pre-push"
# The delegate names the hook after its own file name; give it the real one.
rm -f "$DIR/_delegate-pre-push"
sed 's/^event="\${0##\*\/}"$/event=pre-push/' "$DIR/_delegate" >"$DIR/_delegate-pre-push"
chmod 755 "$DIR/_delegate-pre-push"

git config core.hooksPath "$DIR"
echo "✅ Hooks installed in $DIR (core.hooksPath set for this repository)."
