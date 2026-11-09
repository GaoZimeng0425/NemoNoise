#!/bin/bash
set -euo pipefail

SCHEME="NemoNoise"
PROJECT="NemoNoise.xcodeproj"
BUILD_DIR="build"
APP_NAME="NemoNoise"
DMG_NAME="NemoNoise"

# Extract version from Xcode project
VERSION=$(xcodebuild -project "$PROJECT" -showBuildSettings \
  -configuration Release 2>/dev/null \
  | grep -m1 MARKETING_VERSION \
  | awk '{print $3}')
VERSION="${VERSION:-1.0}"

BUILD_NUMBER=$(xcodebuild -project "$PROJECT" -showBuildSettings \
  -configuration Release 2>/dev/null \
  | grep -m1 CURRENT_PROJECT_VERSION \
  | awk '{print $3}')
BUILD_NUMBER="${BUILD_NUMBER:-1}"

echo "==> Version: $VERSION (build $BUILD_NUMBER)"

# ── Local-deploy signing: stable self-signed identity ─────────────────────
# ad-hoc 每次构建换 cdhash,重装进 /Applications 在 TCC/Keychain 眼里都是
# 陌生 app(麦克风/语音识别授权反复重弹);自签证书让重装保持同一身份。
# fail-closed:身份解析不到就地失败,绝不静默回退 ad-hoc。
# 生成/重建证书: sh scripts/make-signing-cert.sh
# 显式逃生口(临时 ad-hoc): NEMONOISE_SIGNING_IDENTITY='-'
SIGNING_IDENTITY="${NEMONOISE_SIGNING_IDENTITY:-NemoNoise Local Code Signing}"
if [ "$SIGNING_IDENTITY" != "-" ]; then
  probe=$(mktemp) && printf 'probe' > "$probe"
  if ! codesign -f -s "$SIGNING_IDENTITY" "$probe" >/dev/null 2>&1; then
    echo "✋ 签名身份 '$SIGNING_IDENTITY' 解析不到 — 拒绝静默回退 ad-hoc。"
    echo "   重建: sh scripts/make-signing-cert.sh"
    echo "   临时显式回退: NEMONOISE_SIGNING_IDENTITY=- ./build.sh"
    rm -f "$probe"
    exit 1
  fi
  rm -f "$probe"
fi
echo "==> Signing identity: $SIGNING_IDENTITY"

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$BUILD_DIR/$SCHEME.xcarchive" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  | tail -1

echo "==> Exporting .app..."
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/$SCHEME.xcarchive" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist ExportOptions.plist

echo "==> Signing ($SIGNING_IDENTITY)..."
codesign --force --deep --sign "$SIGNING_IDENTITY" "$BUILD_DIR/export/$APP_NAME.app"

echo "==> Creating DMG..."
DMG_STAGING="$BUILD_DIR/dmg_staging"
mkdir -p "$DMG_STAGING"
cp -R "$BUILD_DIR/export/$APP_NAME.app" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$BUILD_DIR/$DMG_NAME.dmg"

DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"
DMG_SIZE=$(stat -f%z "$DMG_PATH")
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo "==> Generating Sparkle appcast.xml..."
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S %z")
cat > "$BUILD_DIR/appcast.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>NemoNoise</title>
    <link>https://github.com/GaoZimeng0425/NemoNoise/releases/latest</link>
    <description>NemoNoise release feed</description>
    <language>en</language>
    <item>
      <title>NemoNoise $VERSION</title>
      <description>Release $VERSION of NemoNoise</description>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/GaoZimeng0425/NemoNoise/releases/download/v$VERSION/NemoNoise.dmg"
        sparkle:edSignature=""
        length="$DMG_SIZE"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF

echo ""
echo "==> Build complete!"
echo "    DMG:       $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "    Appcast:   $BUILD_DIR/appcast.xml"
echo "    Version:   v$VERSION ($BUILD_NUMBER)"
echo "    SHA-256:   $DMG_SHA256"

# ----------------------------------------------------------------------------
# Deploy: kill the running app, replace the /Applications copy, relaunch.
# ----------------------------------------------------------------------------
APP_BUNDLE="$BUILD_DIR/export/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

echo "==> Closing running $APP_NAME..."
# Graceful quit first, then force-kill any survivors. Ignore errors so a
# not-yet-running app doesn't abort the script.
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
sleep 1
pkill -x "$APP_NAME" 2>/dev/null || true

echo "==> Installing to $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
cp -R "$APP_BUNDLE" "$INSTALL_PATH"

echo "==> Launching $APP_NAME..."
open "$INSTALL_PATH"
echo "==> All done. $APP_NAME is running from /Applications."
