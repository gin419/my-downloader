#!/bin/bash
set -e

APP_NAME="XDownloader"
BUNDLE_NAME="$APP_NAME.app"
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

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$BUNDLE_NAME/Contents/Resources/"
fi

echo ""
echo "✅ Build complete!  →  $BUNDLE_NAME"
echo ""
echo "   Run:  open $BUNDLE_NAME"
echo "   Move to Applications:  cp -r $BUNDLE_NAME /Applications/"
echo ""
