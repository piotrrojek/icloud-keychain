#!/usr/bin/env python3
"""Opt-in native integration; only creates/deletes UUID-namespaced dummy items."""

import argparse
import json
from pathlib import Path
import subprocess
import uuid


def cleanup_items(run, scopes, service, account):
    failed = []
    for scope in sorted(scopes):
        try:
            result = run("delete", "--scope", scope, "--", service, account, ok=False)
        except (subprocess.TimeoutExpired, OSError):
            failed.append(scope)
            continue
        if result.returncode != 0 and b"ItemNotFound" not in result.stderr:
            failed.append(scope)
    if failed:
        raise RuntimeError(
            f"Dummy cleanup needs attention: {service!r}, account {account!r}, scopes {failed}"
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--run-local", action="store_true")
    parser.add_argument(
        "--run-icloud",
        action="store_true",
        help="also test iCloud scope isolation; requires a signed provisioned app",
    )
    args = parser.parse_args()
    if not (args.run_local or args.run_icloud):
        parser.error("explicit --run-local or --run-icloud is required")

    binary = str(args.binary.resolve(strict=True))
    service = f"icloud-keychain-test/{uuid.uuid4()}/ę / metadata"
    account = "dummy account:one"
    scopes = ["local", "icloud"] if args.run_icloud else ["local"]

    def run(*argv, data=None, ok=True):
        result = subprocess.run(
            [binary, *argv],
            input=data if data is not None else b"",
            capture_output=True,
            timeout=20,
        )
        if ok and result.returncode != 0:
            # Inputs/outputs deliberately excluded: this pattern must never log secrets.
            raise AssertionError(f"{argv[0]} failed with status {result.returncode}")
        return result

    def get(scope):
        return run("get", "--raw", "--scope", scope, "--", service, account).stdout

    cleanup = set()
    try:
        for scope in scopes:
            cleanup.add(scope)
            run(
                "set",
                "--scope",
                scope,
                "--stdin",
                "--raw",
                "--",
                service,
                account,
                data=b"original dummy\x00\xff\n\r\n",
            )
            assert get(scope) == b"original dummy\x00\xff\n\r\n"
            rejected = run(
                "set",
                "--scope",
                scope,
                "--stdin",
                "--",
                service,
                account,
                data=b"\r\n",
                ok=False,
            )
            assert rejected.returncode != 0
            assert b"EmptyPassword" in rejected.stderr
            assert get(scope) == b"original dummy\x00\xff\n\r\n"
            run(
                "set",
                "--scope",
                scope,
                "--stdin",
                "--",
                service,
                account,
                data=b"updated dummy\r\n",
            )
            assert get(scope) == b"updated dummy"
            rows = json.loads(
                run("list", "--scope", scope, "--json", "--", service).stdout
            )
            assert rows == [{"service": service, "account": account, "scope": scope}]
            run(
                "set",
                "--scope",
                scope,
                "--stdin",
                "--allow-empty",
                "--",
                service,
                account,
                data=b"",
            )
            empty = get(scope)
            assert empty == b"", f"empty update returned {len(empty)} bytes"

        if args.run_icloud:
            ambiguous = run("get", "--scope", "any", "--", service, account, ok=False)
            assert ambiguous.returncode != 0 and b"AmbiguousItem" in ambiguous.stderr
            run("set", "--local", "--stdin", "--", service, account, data=b"local only")
            assert get("icloud") == b""
            run("delete", "--local", "--", service, account)
            cleanup.remove("local")
            assert get("icloud") == b""
            assert (
                run("get", "--scope", "any", "--raw", "--", service, account).stdout
                == b""
            )
    finally:
        cleanup_items(run, cleanup, service, account)

    for scope in scopes:
        absent = run("get", "--scope", scope, "--", service, account, ok=False)
        assert absent.returncode != 0 and b"ItemNotFound" in absent.stderr
    print("Native dummy-item integration passed; dummy items removed.")


if __name__ == "__main__":
    main()
