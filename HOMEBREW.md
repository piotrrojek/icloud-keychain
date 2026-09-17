# Homebrew distribution

The CLI needs a signed `.app` bundle (Developer ID + entitlements + provisioning profile) for iCloud access, so Homebrew cannot build from source. Releases ship a notarized universal tarball; the tap formula only downloads that artifact.

```bash
brew install piotrrojek/tap/icloud-keychain
```

A newer git checkout is not what `brew` runs. The installed formula stays on the last approved tap revision until someone copies the generated formula into `piotrrojek/homebrew-tap` and that change is merged. There is no automatic tap publish.

## Upgrade an existing installation

Homebrew 6 requires explicit trust for non-official taps. A fully qualified fresh install grants trust to that formula, but an older installation may still need it before checking for updates. Prefer formula-level trust rather than trusting every current and future item in a tap:

```bash
brew trust --formula piotrrojek/tap/icloud-keychain
brew update
brew upgrade piotrrojek/tap/icloud-keychain
icloud-keychain --version
```

`brew update` refreshes definitions; `brew upgrade` installs the new executable. Check `brew outdated --verbose piotrrojek/tap/icloud-keychain` to inspect availability without upgrading. Version 2 requires `--local` or `--sync` for deletion; review callers before upgrading.

## GitHub Actions secrets

Store these in the `piotrrojek/icloud-keychain` repo (Settings → Secrets and variables → Actions). Do not export them into shell dotfiles.

| Secret | Value |
|---|---|
| `CERTIFICATE_P12` | Base64-encoded `.p12` of Developer ID Application + Installer certs |
| `CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `PROVISIONING_PROFILE` | Base64-encoded `DeveloperID.provisionprofile` |
| `APPLE_ID` | Apple ID email |
| `APPLE_TEAM_ID` | `RE4JN752MW` |
| `APPLE_APP_PASSWORD` | App-specific password from appleid.apple.com |

Encode files with `base64 -i certificate.p12` (copy by hand into the secret field).

## Release (manual)

1. Land the version in `build.zig.zon` (single source of truth). Tag `v` plus that version, e.g. `v2.0.0`.
2. The release workflow checks the tag against the manifest and runs tests **before** decoding credentials, then signs, notarizes, and uploads:
   - `icloud-keychain-<version>-macos-universal.pkg`
   - `icloud-keychain-<version>-macos-universal.tar.gz`
   - `icloud-keychain.rb` (generated from that tarball’s SHA-256 and tag)
3. After the GitHub Release looks right, copy `icloud-keychain.rb` into `piotrrojek/homebrew-tap` in a separate, reviewed commit. Do not point scripts at the tap repo.

`scripts/homebrew-formula.sh` can regenerate the formula from a local tarball. It never writes the tap.
