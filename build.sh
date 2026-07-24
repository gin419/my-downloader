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

# Embed Sparkle.framework (SPM binaryTarget artifact). ditto preserves the
# framework's symlink structure — a flattening copy breaks its code signature.
SPARKLE_FW=$(find .build/artifacts -type d -name "Sparkle.framework" -path "*macos*" | head -1)
if [ -z "$SPARKLE_FW" ]; then
    echo "❌ Sparkle.framework not found under .build/artifacts — run swift build first." >&2
    exit 1
fi
mkdir -p "$BUNDLE_NAME/Contents/Frameworks"
ditto "$SPARKLE_FW" "$BUNDLE_NAME/Contents/Frameworks/Sparkle.framework"
# SPM links the binary against the artifact's absolute path; inside the bundle
# it must resolve to Contents/Frameworks. Editing load commands invalidates the
# linker's ad-hoc signature — the re-sign happens at the END of this script,
# because codesign binds Info.plist, so it must run after version stamping.
install_name_tool -add_rpath "@loader_path/../Frameworks" "$BUNDLE_NAME/Contents/MacOS/$APP_NAME"

# Stamp version from nearest git tag so local builds match the latest release.
# CFBundleShortVersionString must stay a clean dotted number (Apple/Sparkle parse
# it as a version), so we use only the tag. CFBundleVersion must rise with every
# release for Sparkle's comparison, so it derives from the tag too:
# MAJOR*10000 + MINOR*100 + PATCH  (1.7.0 → 10700). Never the commit distance —
# that reset to 1 on every exact-tag CI build.
if GIT_DESC=$(git describe --tags --long --dirty=-dirty 2>/dev/null); then
    # --long always yields TAG-COUNT-gSHA[-dirty], e.g. v1.3.0-2-gabc1234-dirty
    SHORT_VERSION="${GIT_DESC%%-[0-9]*}"   # v1.3.0
    SHORT_VERSION="${SHORT_VERSION#v}"     # 1.3.0
    IFS=. read -r V_MAJOR V_MINOR V_PATCH <<<"$SHORT_VERSION"
    # 10# forces base 10: a zero-padded segment (e.g. a v1.08.0 tag) would
    # otherwise be read as octal — and in bash 3.2 that fails silently, leaving
    # BUILD empty and shipping a bundle with no version.
    BUILD=$((10#$V_MAJOR * 10000 + 10#$V_MINOR * 100 + 10#${V_PATCH:-0}))
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

# Sign LAST: install_name_tool broke the linker's signature above, and codesign
# binds Info.plist — so the bundle must be final (version-stamped, icon copied)
# before signing.
#
# If a Developer ID Application identity is available — env CODESIGN_IDENTITY, or
# one auto-detected in the keychain — do the full inside-out Developer ID sign
# (Sparkle nested code + hardened runtime + secure timestamp + entitlements) via
# scripts/sign-notarize.sh, so a local `./build.sh` produces a distributable,
# notarizable bundle. Otherwise fall back to the historical ad-hoc signature so
# dev builds and the secret-less CI build check (build.yml) still work.
# Escape hatch: CODESIGN_IDENTITY=- forces the ad-hoc path.
SIGN_SCRIPT="$(dirname "$0")/scripts/sign-notarize.sh"
DETECTED_ID="${CODESIGN_IDENTITY:-}"
if [ -z "$DETECTED_ID" ]; then
    DETECTED_ID=$({ security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"'; } || true)
fi
if [ -n "$DETECTED_ID" ] && [ "$DETECTED_ID" != "-" ] && [ -x "$SIGN_SCRIPT" ]; then
    echo "🔏 Developer ID signing: $DETECTED_ID"
    CODESIGN_IDENTITY="$DETECTED_ID" "$SIGN_SCRIPT" sign "$BUNDLE_NAME"
else
    echo "🔏 Ad-hoc signing (no Developer ID identity found)"
    codesign --force -s - "$BUNDLE_NAME/Contents/MacOS/$APP_NAME"
fi

echo ""
echo "✅ Build complete!  →  $BUNDLE_NAME"
echo ""
echo "   Run:  open $BUNDLE_NAME"
echo "   Move to Applications:  cp -r $BUNDLE_NAME /Applications/"
echo ""
