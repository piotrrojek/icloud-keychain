#!/usr/bin/env python3
"""Release helper tests. No real keychain, signing, or network."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION_SH = ROOT / "scripts" / "version.sh"
SMOKE_SH = ROOT / "scripts" / "smoke-release.sh"
FORMULA_SH = ROOT / "scripts" / "homebrew-formula.sh"
SECRET_MARKERS = (
    "CERTIFICATE_P12",
    "CERTIFICATE_PASSWORD",
    "PROVISIONING_PROFILE",
    "APPLE_APP_PASSWORD",
    "-----BEGIN",
)


def run(args, *, env=None, cwd=None, check=True):
    merged = os.environ.copy()
    merged.pop("VERSION", None)
    merged.pop("GITHUB_REF_NAME", None)
    merged.pop("GITHUB_REPOSITORY", None)
    if env:
        for key, value in env.items():
            if value == "":
                merged.pop(key, None)
            else:
                merged[key] = value
    return subprocess.run(
        args,
        cwd=cwd or ROOT,
        env=merged,
        text=True,
        capture_output=True,
        check=check,
    )


def write_zon(path: Path, body: str) -> Path:
    path.write_text(body, encoding="utf-8")
    return path


FAKE_BIN = r"""#!/bin/bash
set -euo pipefail
version="${FAKE_VERSION:-2.0.0}"
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
    echo "icloud-keychain ${version}"
    if [ "${FAKE_EXTRA_VERSION_LINE:-}" = "1" ]; then
        echo "unexpected extra output"
    fi
    exit 0
fi
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    if [ "${FAKE_HELP_FAIL:-}" = "1" ]; then
        echo "help failed" >&2
        exit 1
    fi
    cat <<'HELP'
Usage:
  icloud-keychain set [options] <service> <account> [<password>|-]
  --stdin  --scope  --raw  --json
HELP
    exit 0
fi
if [ "${1:-}" = "set" ]; then
    stdin=0
    for arg in "$@"; do
        if [ "$arg" = "--stdin" ]; then stdin=1; fi
    done
    if [ "$stdin" -eq 1 ]; then
        pos=0
        for arg in "$@"; do
            case "$arg" in
                set|--stdin|--local|--sync|--raw|--allow-empty|--|--scope) ;;
                --scope=*) ;;
                *) pos=$((pos + 1)) ;;
            esac
        done
        if [ "$pos" -lt 2 ]; then
            echo "Error: MissingArguments" >&2
            exit 1
        fi
        data="$(cat || true)"
        if [ -z "$data" ]; then
            if [ "${FAKE_EMPTY_AS_SECURITY:-}" = "1" ]; then
                echo "SECURITY SecItemAdd" >&2
                exit 99
            fi
            echo "Error: EmptyPassword" >&2
            exit 1
        fi
    fi
    echo "SECURITY SecItemAdd" >&2
    exit 99
fi
if [ "${1:-}" = "delete" ]; then
    echo "deleted" >&2
    exit 0
fi
echo "error: unexpected" >&2
exit 1
"""

PLIST_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleVersion</key>
    <string>{version}</string>
    <key>CFBundleShortVersionString</key>
    <string>{short}</string>
</dict>
</plist>
"""


def make_tarball(
    work: Path,
    *,
    version: str,
    nested: bool = False,
    name: str | None = None,
    plist_version: str | None = None,
    plist_short: str | None = None,
) -> Path:
    stage = work / "stage"
    if nested:
        app = stage / "icloud-keychain.app" / "icloud-keychain.app"
    else:
        app = stage / "icloud-keychain.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True)
    binary = macos / "icloud-keychain"
    binary.write_text(FAKE_BIN, encoding="utf-8")
    binary.chmod(binary.stat().st_mode | stat.S_IEXEC)
    (app / "Contents" / "Info.plist").write_text(
        PLIST_TEMPLATE.format(
            version=plist_version or version,
            short=plist_short or plist_version or version,
        ),
        encoding="utf-8",
    )
    completion = stage / "completions" / "_icloud-keychain"
    completion.parent.mkdir(parents=True)
    completion.write_text("#compdef icloud-keychain\n", encoding="utf-8")
    tarball = work / (name or f"icloud-keychain-{version}-macos-universal.tar.gz")
    with tarfile.open(tarball, "w:gz") as tar:
        tar.add(stage / "icloud-keychain.app", arcname="icloud-keychain.app")
        tar.add(stage / "completions", arcname="completions")
    return tarball


class VersionHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="version-test-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_reads_repo_manifest(self):
        result = run([str(VERSION_SH)])
        self.assertEqual(result.stdout.strip(), "2.0.0")
        self.assertEqual(result.returncode, 0)

    def test_rejects_missing_version(self):
        zon = write_zon(self.tmp / "build.zig.zon", ".{\n    .name = .x,\n}\n")
        result = run([str(VERSION_SH), "--manifest", str(zon)], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected exactly one", result.stderr)

    def test_rejects_invalid_version(self):
        zon = write_zon(
            self.tmp / "build.zig.zon", '.{\n    .version = "not-a-version",\n}\n'
        )
        result = run([str(VERSION_SH), "--manifest", str(zon)], check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_does_not_execute_manifest(self):
        marker = self.tmp / "pwned"
        zon = write_zon(
            self.tmp / "build.zig.zon",
            'system("touch %s")\n.{\n    .version = "2.0.0",\n}\n' % marker,
        )
        result = run([str(VERSION_SH), "--manifest", str(zon)])
        self.assertEqual(result.stdout.strip(), "2.0.0")
        self.assertFalse(marker.exists())

    def test_rejects_code_like_version(self):
        zon = write_zon(
            self.tmp / "build.zig.zon",
            '.{\n    .version = system("true"),\n}\n',
        )
        result = run([str(VERSION_SH), "--manifest", str(zon)], check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_check_rejects_mismatched_env(self):
        result = run(
            [str(VERSION_SH), "--check"], env={"VERSION": "1.0.0"}, check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match manifest", result.stderr)

    def test_check_rejects_mismatched_tag(self):
        result = run(
            [str(VERSION_SH), "--check"],
            env={"GITHUB_REF_NAME": "v1.2.3", "VERSION": ""},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tag v1.2.3", result.stderr)

    def test_check_accepts_matching_tag(self):
        result = run(
            [str(VERSION_SH), "--check"],
            env={"GITHUB_REF_NAME": "v2.0.0", "VERSION": "2.0.0"},
        )
        self.assertEqual(result.stdout.strip(), "2.0.0")

    def test_check_ignores_branch_ref(self):
        result = run(
            [str(VERSION_SH), "--check"],
            env={"GITHUB_REF_NAME": "fix/macos-hardening"},
        )
        self.assertEqual(result.stdout.strip(), "2.0.0")


class FormulaTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="formula-test-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_formula_url_version_hash_layout(self):
        tarball = make_tarball(self.tmp, version="2.0.0")
        out = self.tmp / "icloud-keychain.rb"
        result = run([str(FORMULA_SH), str(tarball), str(out)])
        self.assertEqual(result.returncode, 0)
        text = out.read_text(encoding="utf-8")
        sha = run(["shasum", "-a", "256", str(tarball)]).stdout.split()[0]
        self.assertIn(
            'url "https://github.com/piotrrojek/icloud-keychain/releases/download/v2.0.0/icloud-keychain-2.0.0-macos-universal.tar.gz"',
            text,
        )
        self.assertIn(f'sha256 "{sha}"', text)
        self.assertIn('version "2.0.0"', text)
        self.assertIn("depends_on :macos => :ventura", text)
        self.assertIn('prefix.install "icloud-keychain.app"', text)
        self.assertIn("zsh_completion.install", text)
        self.assertIn('assert_equal "icloud-keychain #{version}\\n"', text)
        self.assertIn('assert_match "--stdin"', text)
        self.assertNotIn("icloud-keychain.app/icloud-keychain.app", text)
        for marker in SECRET_MARKERS:
            self.assertNotIn(marker, text)

    def test_rejects_wrong_tarball_name(self):
        tarball = make_tarball(self.tmp, version="2.0.0", name="wrong.tar.gz")
        result = run([str(FORMULA_SH), str(tarball)], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)


class SmokeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="smoke-test-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_smoke_ok_with_fake_bundle(self):
        tarball = make_tarball(self.tmp, version="2.0.0")
        result = run(
            [str(SMOKE_SH), str(tarball), "2.0.0"], env={"FAKE_VERSION": "2.0.0"}
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("smoke-release: ok", result.stdout)

    def test_smoke_rejects_version_mismatch(self):
        tarball = make_tarball(self.tmp, version="2.0.0", plist_version="9.9.9")
        result = run([str(SMOKE_SH), str(tarball), "9.9.9"], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--version", result.stderr)

    def test_smoke_rejects_version_prefix(self):
        tarball = make_tarball(self.tmp, version="2.0.0")
        result = run(
            [str(SMOKE_SH), str(tarball), "2.0.0"],
            env={"FAKE_VERSION": "2.0.00"},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly", result.stderr)

    def test_smoke_rejects_help_failure(self):
        tarball = make_tarball(self.tmp, version="2.0.0")
        result = run(
            [str(SMOKE_SH), str(tarball), "2.0.0"],
            env={"FAKE_HELP_FAIL": "1"},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--help", result.stderr)

    def test_smoke_rejects_extra_version_output(self):
        tarball = make_tarball(self.tmp, version="2.0.0")
        result = run(
            [str(SMOKE_SH), str(tarball), "2.0.0"],
            env={"FAKE_EXTRA_VERSION_LINE": "1"},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly", result.stderr)

    def test_smoke_requires_empty_password_error(self):
        tarball = make_tarball(self.tmp, version="2.0.0")
        result = run(
            [str(SMOKE_SH), str(tarball), "2.0.0"],
            env={"FAKE_EMPTY_AS_SECURITY": "1"},
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("EmptyPassword", result.stderr)

    def test_smoke_rejects_plist_mismatch(self):
        tarball = make_tarball(self.tmp, version="2.0.0", plist_version="1.0.0")
        result = run([str(SMOKE_SH), str(tarball), "2.0.0"], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Info.plist", result.stderr)

    def test_smoke_rejects_nested_app(self):
        tarball = make_tarball(self.tmp, version="2.0.0", nested=True)
        result = run([str(SMOKE_SH), str(tarball), "2.0.0"], check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nested .app", result.stderr)

    def test_artifacts_contain_no_secrets(self):
        for path in (
            ROOT / "scripts" / "version.sh",
            ROOT / "scripts" / "smoke-release.sh",
            ROOT / "scripts" / "homebrew-formula.sh",
            ROOT / "release.sh",
            ROOT / ".github" / "workflows" / "ci.yml",
        ):
            text = path.read_text(encoding="utf-8")
            for marker in ("CERTIFICATE_PASSWORD", "APPLE_APP_PASSWORD", "-----BEGIN"):
                self.assertNotIn(marker, text, path)


if __name__ == "__main__":
    unittest.main()
