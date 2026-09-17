#!/usr/bin/env python3
"""Subprocess smoke tests that must not mutate a real keychain.

Requires a built executable via ICLOUD_KEYCHAIN or argv[1]. Missing the
binary is a failure. Independent of login/keychain state: --help/--version,
invalid args, empty/over-limit stdin, closed stdout.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import uuid
from pathlib import Path

STDIN_MAX = 4 * 1024 * 1024
ROOT = Path(__file__).resolve().parents[1]


def manifest_version() -> str:
    text = (ROOT / "build.zig.zon").read_text()
    match = re.search(r'\.version\s*=\s*"([^"]+)"', text)
    if not match:
        raise SystemExit("build.zig.zon: missing .version")
    return match.group(1)


def run(
    binary: str,
    args: list[str],
    stdin: bytes | None = None,
    stdout: int | None = subprocess.PIPE,
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [binary, *args],
        input=stdin,
        stdout=stdout,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
    )


def main() -> int:
    binary = os.environ.get("ICLOUD_KEYCHAIN") or (
        sys.argv[1] if len(sys.argv) > 1 else ""
    )
    if not binary:
        print("usage: tests/cli_smoke.py <icloud-keychain>", file=sys.stderr)
        return 2
    if not os.path.isfile(binary) or not os.access(binary, os.X_OK):
        print(f"not an executable: {binary}", file=sys.stderr)
        return 2

    passed = 0
    version = manifest_version()
    service = f"cli-smoke/{uuid.uuid4()}"
    account = "cli-smoke"

    def ok(name: str) -> None:
        nonlocal passed
        passed += 1

    def expect_nonzero(
        proc: subprocess.CompletedProcess[bytes], name: str, token: str | None = None
    ) -> None:
        if proc.returncode == 0:
            raise SystemExit(
                f"{name}: expected nonzero exit, got 0 stdout={proc.stdout!r} stderr={proc.stderr!r}"
            )
        if token is not None and token.encode() not in proc.stderr:
            raise SystemExit(f"{name}: stderr missing {token!r}: {proc.stderr!r}")
        ok(name)

    help_proc = run(binary, ["--help"])
    if help_proc.returncode != 0:
        raise SystemExit(
            f"--help: expected 0, got {help_proc.returncode} stderr={help_proc.stderr!r}"
        )
    stdout = help_proc.stdout
    for needle in (b"Usage:", b"--allow-empty", b"4 MiB", b"LF or CRLF", b"--local"):
        if needle not in stdout:
            raise SystemExit(f"--help: missing {needle!r} in {stdout!r}")
    if help_proc.stderr:
        raise SystemExit(f"--help: expected empty stderr, got {help_proc.stderr!r}")
    ok("help")

    version_proc = run(binary, ["--version"])
    if version_proc.returncode != 0:
        raise SystemExit(f"--version: expected 0, got {version_proc.returncode}")
    expected = f"icloud-keychain {version}\n".encode()
    if version_proc.stdout != expected:
        raise SystemExit(
            f"--version: expected {expected!r}, got {version_proc.stdout!r}"
        )
    ok("version")

    expect_nonzero(run(binary, ["--help", "set"]), "--help extra", "ExtraArguments")
    expect_nonzero(run(binary, ["--version", "1"]), "--version extra", "ExtraArguments")
    expect_nonzero(
        run(binary, ["set", "--bogus", "s", "a", "p"]), "unknown flag", "UnexpectedFlag"
    )
    expect_nonzero(
        run(binary, ["set", "--help", "--sync"]),
        "help mixed with flags",
        "ExtraArguments",
    )
    expect_nonzero(
        run(binary, ["delete", "s", "a"]), "delete without scope", "ScopeRequired"
    )
    expect_nonzero(
        run(binary, ["set", "--scope", "any", "s", "a", "p"]),
        "set any",
        "ScopeAnyForbidden",
    )

    cleanup_needed = False
    try:
        empty = run(binary, ["set", "--local", "--stdin", service, account], stdin=b"")
        cleanup_needed = empty.returncode == 0
        expect_nonzero(
            empty,
            "empty stdin",
            "EmptyPassword",
        )
        overlimit = run(
            binary,
            ["set", "--local", "--stdin", service, account],
            stdin=b"x" * (STDIN_MAX + 1),
        )
        cleanup_needed = overlimit.returncode == 0
        expect_nonzero(
            overlimit,
            "overlimit stdin",
            "StreamTooLong",
        )
    finally:
        if cleanup_needed:
            cleanup = run(binary, ["delete", "--local", service, account])
            if cleanup.returncode != 0 and b"ItemNotFound" not in cleanup.stderr:
                raise SystemExit(f"could not clean unexpected test item: {service}")

    read_fd, write_fd = os.pipe()
    os.close(read_fd)
    try:
        closed = subprocess.run(
            [binary, "--version"],
            stdout=write_fd,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
    finally:
        os.close(write_fd)
    if closed.returncode == 0:
        raise SystemExit("closed stdout: expected nonzero exit")
    ok("closed stdout")

    print(f"ok: {passed}/{passed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
