#!/usr/bin/env bash
# Smoke a release tarball without touching the real keychain.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: smoke-release.sh <tarball> <expected-version>" >&2
    exit 2
fi

TARBALL="$1"
EXPECTED="$2"
if [ ! -f "$TARBALL" ]; then
    echo "error: tarball not found: $TARBALL" >&2
    exit 1
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/icloud-keychain-smoke.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

tar -xzf "$TARBALL" -C "$WORKDIR"

APP="$WORKDIR/icloud-keychain.app"
BIN="$APP/Contents/MacOS/icloud-keychain"
COMPLETION="$WORKDIR/completions/_icloud-keychain"
PLIST="$APP/Contents/Info.plist"

if [ -d "$APP/icloud-keychain.app" ]; then
    echo "error: nested .app in tarball" >&2
    exit 1
fi
if [ ! -x "$BIN" ]; then
    echo "error: missing executable at icloud-keychain.app/Contents/MacOS/icloud-keychain" >&2
    exit 1
fi
if [ ! -f "$COMPLETION" ]; then
    echo "error: missing completions/_icloud-keychain" >&2
    exit 1
fi
if [ ! -f "$PLIST" ]; then
    echo "error: missing Info.plist" >&2
    exit 1
fi

nested="$(find "$WORKDIR" -name '*.app' -type d | wc -l | tr -d ' ')"
if [ "$nested" -ne 1 ]; then
    echo "error: expected exactly one .app bundle, found $nested" >&2
    exit 1
fi

bundle_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
bundle_short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
if [ "$bundle_ver" != "$EXPECTED" ] || [ "$bundle_short" != "$EXPECTED" ]; then
    echo "error: Info.plist versions ($bundle_ver / $bundle_short) != $EXPECTED" >&2
    exit 1
fi

version_out="$("$BIN" --version)"
if [ "$version_out" != "icloud-keychain $EXPECTED" ]; then
    echo "error: --version must be exactly 'icloud-keychain $EXPECTED':" >&2
    echo "$version_out" >&2
    exit 1
fi

set +e
help_out="$("$BIN" --help 2>&1)"
help_status=$?
set -e
if [ "$help_status" -ne 0 ]; then
    echo "error: --help exited $help_status" >&2
    echo "$help_out" >&2
    exit 1
fi
for flag in --stdin --scope --raw --json; do
    case "$help_out" in
        *"$flag"*) ;;
        *)
            echo "error: --help missing $flag" >&2
            echo "$help_out" >&2
            exit 1
            ;;
    esac
done

svc="icloud-keychain-smoke/$(uuidgen | tr '[:upper:]' '[:lower:]')"
acc="dummy-account"

# Empty and incomplete stdin must fail in the parser (EmptyPassword / MissingArguments)
# before Security.framework. --local is explicit. Never use a fixed service name.
set +e
empty_out="$( : | "$BIN" set --local --stdin -- "$svc" "$acc" 2>&1 )"
empty_status=$?
invalid_out="$( "$BIN" set --stdin 2>&1 )"
invalid_status=$?
set -e

cleanup_own_dummy() {
    "$BIN" delete --local -- "$svc" "$acc" >/dev/null 2>&1 || true
}

if [ "$empty_status" -eq 0 ]; then
    cleanup_own_dummy
    echo "error: empty stdin set succeeded; expected EmptyPassword" >&2
    echo "$empty_out" >&2
    exit 1
fi
case "$empty_out" in
    *EmptyPassword*) ;;
    *)
        echo "error: empty stdin must report EmptyPassword:" >&2
        echo "$empty_out" >&2
        exit 1
        ;;
esac

if [ "$invalid_status" -eq 0 ]; then
    echo "error: invalid set --stdin succeeded; expected parser rejection" >&2
    echo "$invalid_out" >&2
    exit 1
fi
case "$invalid_out" in
    *MissingArguments*|*Usage*|*usage*) ;;
    *)
        echo "error: invalid set --stdin must report parser rejection:" >&2
        echo "$invalid_out" >&2
        exit 1
        ;;
esac

echo "smoke-release: ok $EXPECTED"
