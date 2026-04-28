#!/usr/bin/env bash
# Build AirSink.app: compile Swift, write Info.plist with version stamps,
# bundle the patched uxplay binary, ad-hoc codesign.
#
# Output: build/AirSink.app
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="$(cat VERSION | tr -d ' \t\n\r')"
BUILD_NUMBER="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
BUILD_NUMBER="${BUILD_NUMBER:0:7}"

APP="build/AirSink.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "==> Building AirSink ${VERSION} (${BUILD_NUMBER})"

mkdir -p "$MACOS_DIR" "$RES_DIR"

# 1. Compile Swift sources
echo "==> Compiling Swift"
swiftc \
    -target arm64-apple-macos13 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -O \
    -framework AppKit -framework SwiftUI \
    -framework AVFoundation -framework CoreMedia -framework VideoToolbox \
    -framework Network -framework Combine \
    -o "$MACOS_DIR/AirSink" \
    Sources/*.swift

# 2. Bundle the patched uxplay (if built); otherwise skip — app falls back
# to /opt/homebrew/bin/uxplay (without our -tap flag) at runtime.
if [[ -x vendor/UxPlay/build/uxplay ]]; then
    echo "==> Bundling patched uxplay"
    cp vendor/UxPlay/build/uxplay "$RES_DIR/uxplay"
    chmod +x "$RES_DIR/uxplay"
else
    echo "==> Skipping uxplay bundle (vendor/UxPlay/build/uxplay not present)"
    echo "    Run ./vendor/build_uxplay.sh first for self-contained builds."
fi

# 3. Info.plist
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AirSink</string>
    <key>CFBundleIdentifier</key>
    <string>com.maslyankov.airsink</string>
    <key>CFBundleName</key>
    <string>AirSink</string>
    <key>CFBundleDisplayName</key>
    <string>AirSink</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
</dict>
</plist>
EOF

# 4. Codesign (ad-hoc by default; CI passes a real identity via env)
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> Codesigning with identity: ${SIGN_IDENTITY}"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo "==> Built ${APP}"
