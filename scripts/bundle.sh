#!/bin/sh
# Build Upstage.app (and a DMG) from the SwiftPM products. macOS only.
#
#   sh scripts/bundle.sh                 # release, universal (arm64 + x86_64)
#   ARCHS=native sh scripts/bundle.sh    # release, current architecture only
#   SIGN_IDENTITY="Developer ID Application: ..." sh scripts/bundle.sh   # real signature
#
# Output: dist/Upstage.app, dist/Upstage-<version>.dmg, dist/Upstage-<version>.zip
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP_NAME=Upstage
VERSION=$(sed -n 's/.*public static let string = "\(.*\)".*/\1/p' Sources/UpstageCore/Version.swift)
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ARCHS=${ARCHS:-universal}
CONFIG=${CONFIG:-release}

echo "==> building $APP_NAME $VERSION ($CONFIG, $ARCHS)"
if [ "$ARCHS" = "universal" ]; then
  swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product "$APP_NAME"
  BIN=$(find .build/apple/Products -type f -name "$APP_NAME" -path "*$(echo "$CONFIG" | sed 's/./\U&/')*" | head -1)
  [ -n "$BIN" ] || BIN=$(find .build/apple/Products -type f -name "$APP_NAME" | head -1)
else
  swift build -c "$CONFIG" --product "$APP_NAME"
  BIN=$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME
fi
[ -f "$BIN" ] || { echo "binary not found"; exit 1; }
echo "    binary: $BIN"
lipo -info "$BIN" 2>/dev/null || true

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Keep the plist's version in step with Version.swift
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
BUILD_NUMBER=${GITHUB_RUN_NUMBER:-1}
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true

echo "==> icon"
mkdir -p "$DIST"
python3 scripts/make-icon.py "$DIST/AppIcon-1024.png" >/dev/null
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$DIST/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$DIST/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> signing"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  # Ad-hoc signature: runs on the build machine and on any Mac after the user
  # allows it in System Settings > Privacy & Security (Gatekeeper warns once).
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose=2 "$APP" || true

echo "==> packaging"
rm -f "$DIST/$APP_NAME-$VERSION.zip" "$DIST/$APP_NAME-$VERSION.dmg"
(cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME-$VERSION.zip")
STAGE="$DIST/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$APP_NAME-$VERSION.dmg" >/dev/null
rm -rf "$STAGE" "$ICONSET"
echo "==> done"
ls -la "$DIST"
