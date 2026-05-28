#!/bin/bash
set -e

APP_NAME="XDownloader"
BUNDLE_NAME="$APP_NAME.app"
SDK=$(xcrun --show-sdk-path)
ARCH=$(uname -m)

if [ "$ARCH" = "arm64" ]; then
    TARGET="arm64-apple-macosx14.0"
else
    TARGET="x86_64-apple-macosx14.0"
fi

echo "🔨 Compiling $APP_NAME..."

mkdir -p build

swiftc \
    -sdk "$SDK" \
    -target "$TARGET" \
    -parse-as-library \
    -Onone \
    Sources/*.swift \
    -o "build/$APP_NAME" 2>&1

echo "📦 Creating app bundle..."

rm -rf "$BUNDLE_NAME"
mkdir -p "$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$BUNDLE_NAME/Contents/Resources"

cp "build/$APP_NAME" "$BUNDLE_NAME/Contents/MacOS/"
cp "Resources/Info.plist" "$BUNDLE_NAME/Contents/"
chmod +x "$BUNDLE_NAME/Contents/MacOS/$APP_NAME"

# Icon
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$BUNDLE_NAME/Contents/Resources/"
    echo "   🎨 Icon included"
fi

echo ""
echo "✅ Build complete!  →  $BUNDLE_NAME"
echo ""
echo "   Run:  open $BUNDLE_NAME"
echo "   Move to Applications:  cp -r $BUNDLE_NAME /Applications/"
echo ""
