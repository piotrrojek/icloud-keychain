#!/usr/bin/env bash
# Read the authoritative package version from build.zig.zon without executing it.
set -euo pipefail

usage() {
    echo "usage: version.sh [--check] [--manifest PATH]" >&2
    exit 2
}

CHECK=0
MANIFEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1; shift ;;
        --manifest)
            [ $# -ge 2 ] || usage
            MANIFEST="$2"
            shift 2
            ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${MANIFEST:-$ROOT/build.zig.zon}"

if [ ! -f "$MANIFEST" ]; then
    echo "error: manifest not found: $MANIFEST" >&2
    exit 1
fi

# Never source, eval, or compile the manifest. Accept one top-level
# .version = "X.Y.Z" field (optional trailing comma).
version=""
matches=0
invalid=0
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
        .version*)
            if [[ "$stripped" =~ ^\.version[[:space:]]*=[[:space:]]*\"([0-9]+\.[0-9]+\.[0-9]+)\"[[:space:]]*,?[[:space:]]*$ ]]; then
                version="${BASH_REMATCH[1]}"
                matches=$((matches + 1))
            else
                invalid=1
            fi
            ;;
    esac
done < "$MANIFEST"

if [ "$invalid" -ne 0 ] || [ "$matches" -ne 1 ] || [ -z "$version" ]; then
    echo "error: expected exactly one .version = \"X.Y.Z\" in $MANIFEST" >&2
    exit 1
fi

if [ "$CHECK" -eq 1 ]; then
    if [ -n "${VERSION:-}" ] && [ "$VERSION" != "$version" ]; then
        echo "error: VERSION=$VERSION does not match manifest $version" >&2
        exit 1
    fi
    if [ -n "${GITHUB_REF_NAME:-}" ]; then
        case "$GITHUB_REF_NAME" in
            v*)
                tag_version="${GITHUB_REF_NAME#v}"
                if [ "$tag_version" != "$version" ]; then
                    echo "error: tag $GITHUB_REF_NAME does not match manifest $version" >&2
                    exit 1
                fi
                ;;
        esac
    fi
fi

printf '%s\n' "$version"
