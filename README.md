# icloud-keychain

macOS-only CLI for the login (file) keychain and the app’s iCloud-synced data-protection keychain. Linux is out of scope.

Version **2.0.0** (major bump: `delete` now requires an explicit store). Authoritative version is `build.zig.zon`. An installed Homebrew package is the last published tap revision, not live git. Source changes become available through Homebrew only after a release and a matching tap update.

Requires **Zig 0.15.2** exactly (see `.zig-version`). Zig 0.16 does not build this tree.

## Install

```bash
brew tap piotrrojek/tap
brew install piotrrojek/tap/icloud-keychain
```

Or download the `.pkg` / tarball from [Releases](https://github.com/piotrrojek/icloud-keychain/releases).

## Scope

| Scope | Store |
|---|---|
| `local` (`--local`) | Default file keychain (normally login) |
| `icloud` (`--sync`) | App access-group synchronizable data-protection keychain |
| `any` | Query both stores (get/list only) |

`get`/`list` with `any` may fail if the sync entitlement is unavailable. Unsigned local users should pass `--local`. `--scope any` is forbidden on `set` and `delete`.

## Usage

Flags may appear after the command and after positionals, but not after `--`. `--local` and `--sync` are aliases, not `--scope` values.

```
icloud-keychain set [options] <service> <account> [<password>|-]
icloud-keychain get [options] <service> <account>
icloud-keychain delete [options] <service> <account>
icloud-keychain list [options] [filter]
icloud-keychain doctor
icloud-keychain --help | -h
icloud-keychain --version | -v
```

Scope (after the subcommand): `--scope local|icloud|any`, `--local` (`--scope local`), `--sync` (`--scope icloud`).

- **set** defaults to `local` and rejects `--scope any`. Password `-` or `--stdin` reads stdin. `--allow-empty` is required to store an empty secret. `--raw` keeps stdin bytes (no newline strip).
- **get** defaults to `any` and errors if more than one item matches. `--raw` writes the secret bytes with no extra newline.
- **delete** requires `--scope local|icloud` or `--local`/`--sync`.
- **list** defaults to `any`. `--json` prints `[{service,account,scope}, ...]`. `--names-only` / `--accounts-only` are line-oriented; `--null` uses NUL separators with those formats. These formats reject values containing their delimiter before printing any records; use JSON for arbitrary metadata. A names filter is a prefix; with `--accounts-only` the positional argument is an exact service.
- **doctor** prints local diagnostics only (unsigned/signed app id and access group, profile-declared authorization and expiry, graphical session). Exit 1 if local iCloud prerequisites are missing. No secrets and no SecItem calls. Advisory: it does not prove remote sync.

Exit 0: success, `--help`, `--version`, and `doctor` when local iCloud prerequisites are present. Exit 1: usage/parse errors (`Error: EmptyPassword`, `Error: MissingArguments`, …), keychain errors, write failures, and `doctor` when those prerequisites are missing.

Prefer stdin over a password argv. Validate the secret *before* starting the process. `pipefail` cannot un-write a completed `set`.

Stdin is limited to 4 MiB. By default, one trailing LF or CRLF is removed; `--raw` disables trimming. Use `set --stdin --raw` and `get --raw` together for a byte-exact round trip.

Legacy file-keychain items may omit service or account metadata; `list` represents those fields as empty strings rather than failing the whole listing.

```python
import subprocess

password = "prevalidated-secret"  # generate and check this first
subprocess.run(
    ["icloud-keychain", "set", "--stdin", "dotfiles/example", "piotrrojek"],
    input=password,
    check=True,
    text=True,
)
```

## Build and test

```bash
# Zig 0.15.2 on PATH
zig build
zig build test
python3 tests/cli_smoke.py zig-out/bin/icloud-keychain
```

CI and release jobs pin **macOS 15 + Xcode 16.3 (SDK 15.4)**. Newer SDKs can omit plain `arm64-macos` exports, which Zig 0.15.2 silently drops. If an older Xcode is installed, select it per command without changing the system default:

```bash
DEVELOPER_DIR=/Applications/Xcode_16.3.app/Contents/Developer zig build
DEVELOPER_DIR=/Applications/Xcode_16.3.app/Contents/Developer zig build test
```

`SDKROOT`, `-Dsdk=/absolute/path/to/MacOSX15.4.sdk`, and `--sysroot` select the application SDK. They **do not fix Zig's own build-runner bootstrap**: that uses `xcrun --sdk macosx --show-sdk-path` before project settings run. A lone older SDK directory is therefore insufficient for ordinary `zig build` on an incompatible host. Missing libc symbols while linking the build runner indicate this bootstrap problem, not an application failure. The project checks the selected application SDK and avoids combining a linker sysroot with SDK-prefixed library paths.

Unit tests live in `src/tests.zig`. Opt-in dummy keychain tests (UUID names, write+delete, does not certify remote sync):

```bash
python3 tests/keychain_integration.py zig-out/bin/icloud-keychain --run-local
python3 tests/keychain_integration.py path/to/icloud-keychain.app/Contents/MacOS/icloud-keychain --run-icloud
```

## Zsh autocomplete

Homebrew and the `.pkg` install a completion into `site-functions`. Services/accounts complete from `list` metadata. Default offers names containing `/`; include system entries with:

```zsh
zstyle ':icloud-keychain:include-system' enabled yes
```

## License

MIT
