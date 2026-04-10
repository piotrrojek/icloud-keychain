#!/bin/bash
# release.sh — Build, bundle, sign, notarize, and package for distribution.
#
# Prerequisites:
#   1. Developer ID Application certificate installed
#   2. Developer ID provisioning profile downloaded from Apple Developer portal
#      and placed at: ./DeveloperID.provisionprofile
#   3. Notarization credentials stored:
#      xcrun notarytool store-credentials "notary-profile" \
#          --apple-id "YOUR_EMAIL" --team-id "RE4JN752MW"
#   4. Xcode installed (for cross-compilation SDK)
#
# Usage: ./release.sh [path/to/DeveloperID.provisionprofile]

set -euo pipefail

VERSION="1.0.0"
IDENTITY="Developer ID Application: Otherland Labs sp. z o.o. (RE4JN752MW)"
INSTALLER_IDENTITY="Developer ID Installer: Otherland Labs sp. z o.o. (RE4JN752MW)"
BUNDLE_ID="com.otherlandlabs.icloud-keychain"
NOTARY_PROFILE="notary-profile"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/release-build"
APP="$BUILD_DIR/icloud-keychain.app"

# Find provisioning profile
PROFILE="${1:-$SCRIPT_DIR/DeveloperID.provisionprofile}"
if [ ! -f "$PROFILE" ]; then
    echo "Error: Provisioning profile not found at: $PROFILE"
    echo "Download your Developer ID provisioning profile from:"
    echo "  https://developer.apple.com/account/resources/profiles"
    echo "Then either:"
    echo "  - Place it at $SCRIPT_DIR/DeveloperID.provisionprofile"
    echo "  - Or pass the path: ./release.sh /path/to/profile.provisionprofile"
    exit 1
fi

# Find Xcode SDK (needed for cross-compilation)
XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [ ! -d "$XCODE_SDK" ]; then
    echo "Error: Xcode SDK not found. Install Xcode from the App Store."
    exit 1
fi

echo "Building universal binary (arm64 + x86_64)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Zig cross-compiles both architectures using the Xcode SDK for framework headers.
# We use zig build-exe directly (instead of zig build) because cross-compilation
# needs explicit sysroot and framework paths that the build system doesn't auto-detect.
cd "$SCRIPT_DIR"

zig build-exe src/main.zig -OReleaseSafe \
    -target aarch64-macos \
    --sysroot "$XCODE_SDK" \
    -F "$XCODE_SDK/System/Library/Frameworks" \
    -idirafter "$XCODE_SDK/usr/include" \
    -framework Security -framework CoreFoundation \
    -femit-bin="$BUILD_DIR/icloud-keychain-arm64"
echo "  arm64: OK"

zig build-exe src/main.zig -OReleaseSafe \
    -target x86_64-macos \
    --sysroot "$XCODE_SDK" \
    -F "$XCODE_SDK/System/Library/Frameworks" \
    -idirafter "$XCODE_SDK/usr/include" \
    -framework Security -framework CoreFoundation \
    -femit-bin="$BUILD_DIR/icloud-keychain-x86_64"
echo "  x86_64: OK"

lipo -create \
    -output "$BUILD_DIR/icloud-keychain" \
    "$BUILD_DIR/icloud-keychain-arm64" \
    "$BUILD_DIR/icloud-keychain-x86_64"
rm "$BUILD_DIR/icloud-keychain-arm64" "$BUILD_DIR/icloud-keychain-x86_64"

echo "  universal: OK ($(du -h "$BUILD_DIR/icloud-keychain" | cut -f1 | xargs))"

echo ""
echo "Creating .app bundle"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD_DIR/icloud-keychain" "$APP/Contents/MacOS/"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>icloud-keychain</string>
    <key>CFBundleName</key>
    <string>icloud-keychain</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 Piotr Rojek — https://piotrrojek.io</string>
</dict>
</plist>
EOF
echo "  Bundle created"

echo ""
echo "Signing with Developer ID"
codesign -f -s "$IDENTITY" \
    --timestamp \
    --options runtime \
    --entitlements "$SCRIPT_DIR/entitlements.plist" \
    "$APP/Contents/MacOS/icloud-keychain"

codesign -f -s "$IDENTITY" \
    --timestamp \
    --options runtime \
    --entitlements "$SCRIPT_DIR/entitlements.plist" \
    --identifier "$BUNDLE_ID" \
    "$APP"

# Verify
codesign -vvv --deep --strict "$APP"
echo "  Signature verified"

echo ""
echo "Notarizing"
# Package for submission
ditto -c -k --keepParent "$APP" "$BUILD_DIR/icloud-keychain.zip"

xcrun notarytool submit "$BUILD_DIR/icloud-keychain.zip" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# Staple the notarization ticket to the .app
xcrun stapler staple "$APP"
echo "  Notarization complete"

echo ""
echo "Building installer package"
PKG_ROOT="$BUILD_DIR/pkg-root"
PKG_SCRIPTS="$BUILD_DIR/pkg-scripts"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
mkdir -p "$PKG_ROOT/usr/local/lib"
mkdir -p "$PKG_SCRIPTS"
cp -R "$APP" "$PKG_ROOT/usr/local/lib/"

# Post-install script creates the symlink so `icloud-keychain` is on PATH
cat > "$PKG_SCRIPTS/postinstall" << 'POSTINSTALL'
#!/bin/bash
mkdir -p /usr/local/bin
ln -sf /usr/local/lib/icloud-keychain.app/Contents/MacOS/icloud-keychain /usr/local/bin/icloud-keychain
POSTINSTALL
chmod +x "$PKG_SCRIPTS/postinstall"

# Pre-uninstall info (shown if user wants to remove manually)
cat > "$PKG_SCRIPTS/preinstall" << 'PREINSTALL'
#!/bin/bash
# Remove previous installation if present
rm -f /usr/local/bin/icloud-keychain
rm -rf /usr/local/lib/icloud-keychain.app
exit 0
PREINSTALL
chmod +x "$PKG_SCRIPTS/preinstall"

PKG="$BUILD_DIR/icloud-keychain-${VERSION}-macos-universal.pkg"

pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$PKG_SCRIPTS" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --sign "$INSTALLER_IDENTITY" \
    "$PKG"

echo "  Package built"

rm -rf "$PKG_ROOT" "$PKG_SCRIPTS" "$BUILD_DIR/icloud-keychain.zip" "$BUILD_DIR/icloud-keychain"

echo ""
echo "Notarizing installer package"
xcrun notarytool submit "$PKG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

xcrun stapler staple "$PKG"
echo "  Installer notarized"

echo ""
echo " Done "
echo "Distribution package:"
echo "  $PKG"
