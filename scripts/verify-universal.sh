#!/bin/bash
# Assert a release .app bundle is universal (arm64 + x86_64) and correctly
# linked. Called by build.yml (PR smoke test), release.yml (pre-sign gate),
# and locally after ./build.sh release. Debug bundles are host-arch — don't
# run this on them.
set -e

APP="${1:?usage: verify-universal.sh path/to/XDownloader.app}"
APP_BIN="$APP/Contents/MacOS/XDownloader"
SPARKLE_BIN="$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"

test -x "$APP_BIN" || { echo "❌ Missing app binary: $APP_BIN" >&2; exit 1; }
test -d "$APP/Contents/Frameworks/Sparkle.framework" \
    || { echo "❌ Sparkle.framework not embedded" >&2; exit 1; }

for BIN in "$APP_BIN" "$SPARKLE_BIN"; do
    ARCHS=$(xcrun lipo -archs "$BIN" | xargs -n1 | sort | xargs)
    echo "🧬 $BIN: $ARCHS"
    if [ "$ARCHS" != "arm64 x86_64" ]; then
        echo "❌ $BIN must contain exactly arm64 + x86_64 (got: ${ARCHS:-none})" >&2
        exit 1
    fi
done

xcrun otool -l "$APP_BIN" | grep -q "@loader_path/../Frameworks" \
    || { echo "❌ rpath @loader_path/../Frameworks missing" >&2; exit 1; }

echo "✅ Universal bundle verified: $APP"
