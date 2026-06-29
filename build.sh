#!/bin/bash
set -e

APP_NAME="XDownloader"
BUILD_DIR="build"                     # keep the built bundle out of the repo root (gitignored)
BUNDLE_NAME="$BUILD_DIR/$APP_NAME.app"
CONFIG=${1:-release}   # debug | release (default: release)

echo "🔨 Building $APP_NAME ($CONFIG)..."
swift build -c "$CONFIG"

BINARY=".build/$CONFIG/$APP_NAME"

echo "📦 Creating app bundle..."
rm -rf "$BUNDLE_NAME"
mkdir -p "$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$BUNDLE_NAME/Contents/Resources"

cp "$BINARY" "$BUNDLE_NAME/Contents/MacOS/"
cp "Resources/Info.plist" "$BUNDLE_NAME/Contents/"
chmod +x "$BUNDLE_NAME/Contents/MacOS/$APP_NAME"

# Stamp version from nearest git tag so local builds match the latest release.
# CFBundleShortVersionString must stay a clean dotted number (Apple/Sparkle parse
# it as a version), so we use only the tag. CFBundleVersion holds the commit
# distance as an integer build number — dirty tree bumps it by 1.
if GIT_DESC=$(git describe --tags --long --dirty=-dirty 2>/dev/null); then
    # --long always yields TAG-COUNT-gSHA[-dirty], e.g. v1.3.0-2-gabc1234-dirty
    SHORT_VERSION="${GIT_DESC%%-[0-9]*}"   # v1.3.0
    SHORT_VERSION="${SHORT_VERSION#v}"     # 1.3.0
    REST="${GIT_DESC#*-}"                  # 2-gabc1234-dirty
    COUNT="${REST%%-*}"                    # 2
    case "$GIT_DESC" in *-dirty) BUILD=$((COUNT + 1));; *) BUILD=$((COUNT > 0 ? COUNT : 1));; esac
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString $SHORT_VERSION" \
        -c "Set :CFBundleVersion $BUILD" \
        "$BUNDLE_NAME/Contents/Info.plist"
    echo "📌 Stamped: $SHORT_VERSION (build $BUILD, $GIT_DESC)"
elif [ "$CONFIG" = "release" ]; then
    # The source Info.plist carries a 0.0.0 sentinel, so a release with no tag
    # would ship "0.0.0". Make the tag the single source of truth: fail loudly.
    echo "❌ No git tag found — release builds must come from a tagged commit so the" >&2
    echo "   version can be stamped. Tag first:  git tag vX.Y.Z && ./build.sh release" >&2
    exit 1
else
    echo "⚠️  No git tag found — leaving the 0.0.0 sentinel version (debug build)."
fi

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$BUNDLE_NAME/Contents/Resources/"
fi

echo ""
echo "✅ Build complete!  →  $BUNDLE_NAME"
echo ""
echo "   Run:  open $BUNDLE_NAME"
echo "   Move to Applications:  cp -r $BUNDLE_NAME /Applications/"
echo ""
