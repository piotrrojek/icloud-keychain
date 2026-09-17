#!/bin/bash
# Build, bundle, sign, notarize, and package for distribution.
#
# Prerequisites:
#   1. Developer ID Application certificate installed
#   2. Developer ID provisioning profile at ./DeveloperID.provisionprofile
#      or passed as argv[1]
#   3. Notarization credentials stored in notarytool (not in shell dotfiles)
#   4. Zig 0.15.2 on PATH (see .zig-version)
#
# Usage: ./release.sh [path/to/DeveloperID.provisionprofile]
#
# Env overrides: IDENTITY, INSTALLER_IDENTITY, BUNDLE_ID, NOTARY_PROFILE, SDKROOT
# Use a compatible developer installation (CI pins Xcode 16.3); see README.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$("$SCRIPT_DIR/scripts/version.sh" --check)"
IDENTITY="${IDENTITY:-Developer ID Application: Otherland Labs sp. z o.o. (RE4JN752MW)}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-Developer ID Installer: Otherland Labs sp. z o.o. (RE4JN752MW)}"
BUNDLE_ID="${BUNDLE_ID:-com.otherlandlabs.icloud-keychain}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-profile}"

BUILD_DIR="$SCRIPT_DIR/release-build"
APP="$BUILD_DIR/icloud-keychain.app"

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

SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if [ -z "$SDKROOT" ] || [ ! -d "$SDKROOT" ]; then
    echo "Error: macOS SDK not found via xcrun --sdk macosx --show-sdk-path"
    exit 1
fi

echo "Version $VERSION"
echo "Building universal binary (arm64 + x86_64) with $SDKROOT"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cd "$SCRIPT_DIR"

build_arch() {
    local arch="$1"
    local dest="$2"
    local prefix="$BUILD_DIR/prefix-$arch"
    rm -rf "$prefix"
    zig build -Doptimize=ReleaseSafe -Dtarget="${arch}-macos" \
        --sysroot "$SDKROOT" \
        -p "$prefix"
    local built="$prefix/bin/icloud-keychain"
    if [ ! -f "$built" ]; then
        echo "error: missing $built" >&2
        exit 1
    fi
    cp "$built" "$dest"
    echo "  $arch: OK"
}

build_arch aarch64 "$BUILD_DIR/icloud-keychain-arm64"
build_arch x86_64 "$BUILD_DIR/icloud-keychain-x86_64"

lipo -create \
    -output "$BUILD_DIR/icloud-keychain" \
    "$BUILD_DIR/icloud-keychain-arm64" \
    "$BUILD_DIR/icloud-keychain-x86_64"
rm -f "$BUILD_DIR/icloud-keychain-arm64" "$BUILD_DIR/icloud-keychain-x86_64"
rm -rf "$BUILD_DIR/prefix-aarch64" "$BUILD_DIR/prefix-x86_64"

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
echo "  Bundle created ($VERSION)"

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

codesign --verify --deep --strict "$APP"
codesign -vvv --deep --strict "$APP"
echo "  Signature verified"

echo ""
echo "Notarizing"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/icloud-keychain.zip"

xcrun notarytool submit "$BUILD_DIR/icloud-keychain.zip" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

xcrun stapler staple "$APP"
echo "  Notarization complete"

echo ""
echo "Building installer package"
PKG_ROOT="$BUILD_DIR/pkg-root"
PKG_SCRIPTS="$BUILD_DIR/pkg-scripts"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
mkdir -p "$PKG_ROOT/usr/local/lib"
mkdir -p "$PKG_ROOT/usr/local/share/zsh/site-functions"
mkdir -p "$PKG_SCRIPTS"
cp -R "$APP" "$PKG_ROOT/usr/local/lib/"
cp "$SCRIPT_DIR/completions/_icloud-keychain" "$PKG_ROOT/usr/local/share/zsh/site-functions/"

cat > "$PKG_SCRIPTS/postinstall" << 'POSTINSTALL'
#!/bin/bash
mkdir -p /usr/local/bin
ln -sf /usr/local/lib/icloud-keychain.app/Contents/MacOS/icloud-keychain /usr/local/bin/icloud-keychain
POSTINSTALL
chmod +x "$PKG_SCRIPTS/postinstall"

cat > "$PKG_SCRIPTS/preinstall" << 'PREINSTALL'
#!/bin/bash
rm -f /usr/local/bin/icloud-keychain
rm -rf /usr/local/lib/icloud-keychain.app
rm -f /usr/local/share/zsh/site-functions/_icloud-keychain
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

echo ""
echo "Notarizing installer package"
xcrun notarytool submit "$PKG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

xcrun stapler staple "$PKG"
echo "  Installer notarized"

echo ""
echo "Creating Homebrew tarball"
TAR_STAGE="$BUILD_DIR/tar-stage"
rm -rf "$TAR_STAGE"
mkdir -p "$TAR_STAGE/completions"
cp -R "$APP" "$TAR_STAGE/"
cp "$SCRIPT_DIR/completions/_icloud-keychain" "$TAR_STAGE/completions/"
TAR="$BUILD_DIR/icloud-keychain-${VERSION}-macos-universal.tar.gz"
tar -czf "$TAR" -C "$TAR_STAGE" icloud-keychain.app completions
rm -rf "$TAR_STAGE" "$PKG_ROOT" "$PKG_SCRIPTS" "$BUILD_DIR/icloud-keychain.zip" "$BUILD_DIR/icloud-keychain"

"$SCRIPT_DIR/scripts/smoke-release.sh" "$TAR" "$VERSION"
"$SCRIPT_DIR/scripts/homebrew-formula.sh" "$TAR" "$BUILD_DIR/icloud-keychain.rb"

echo ""
echo " Done "
echo "Distribution package: $PKG"
echo "Homebrew tarball:     $TAR"
echo "Homebrew formula:     $BUILD_DIR/icloud-keychain.rb"
