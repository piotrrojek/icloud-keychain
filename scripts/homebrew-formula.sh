#!/usr/bin/env bash
# Generate a Homebrew formula from a built tarball. Does not write the tap.
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: homebrew-formula.sh <tarball> [output.rb]" >&2
    exit 2
fi

TARBALL="$1"
if [ ! -f "$TARBALL" ]; then
    echo "error: tarball not found: $TARBALL" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$("$ROOT/scripts/version.sh")"
REPO="${GITHUB_REPOSITORY:-piotrrojek/icloud-keychain}"
ASSET="icloud-keychain-${VERSION}-macos-universal.tar.gz"
URL="https://github.com/${REPO}/releases/download/v${VERSION}/${ASSET}"

base="$(basename "$TARBALL")"
if [ "$base" != "$ASSET" ]; then
    echo "error: tarball name $base does not match $ASSET" >&2
    exit 1
fi

SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ ${#SHA256} -ne 64 ]; then
    echo "error: failed to hash tarball" >&2
    exit 1
fi

formula="$(cat <<EOF
class IcloudKeychain < Formula
  desc "macOS Keychain CLI with optional iCloud sync"
  homepage "https://github.com/${REPO}"
  url "${URL}"
  sha256 "${SHA256}"
  version "${VERSION}"
  license "MIT"

  depends_on :macos => :ventura

  def install
    prefix.install "icloud-keychain.app"
    bin.install_symlink prefix/"icloud-keychain.app/Contents/MacOS/icloud-keychain"
    zsh_completion.install "completions/_icloud-keychain"
  end

  test do
    assert_equal "icloud-keychain #{version}\n", shell_output("#{bin}/icloud-keychain --version")
    assert_match "--stdin", shell_output("#{bin}/icloud-keychain --help")
  end
end
EOF
)"

if [ $# -eq 2 ]; then
    printf '%s\n' "$formula" > "$2"
else
    printf '%s\n' "$formula"
fi
