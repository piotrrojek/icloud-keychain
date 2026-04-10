# Homebrew Distribution

This app requires codesigning + entitlements + provisioning profile for iCloud Keychain access, so Homebrew can't build from source. Instead, a pre-built signed/notarized `.app` bundle is distributed via a Homebrew tap.

Users install via:

```bash
brew install piotrrojek/tap/icloud-keychain
```

## Setup

### 1. GitHub Secrets

Add these to the `piotrrojek/icloud-keychain` repo settings (Settings > Secrets and variables > Actions):

| Secret | Value |
|---|---|
| `CERTIFICATE_P12` | Base64-encoded `.p12` export of Developer ID Application + Installer certs |
| `CERTIFICATE_PASSWORD` | Password for the `.p12` |
| `PROVISIONING_PROFILE` | Base64-encoded `DeveloperID.provisionprofile` |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | `RE4JN752MW` |
| `APPLE_APP_PASSWORD` | App-specific password from appleid.apple.com |

To encode files as base64:

```bash
base64 -i certificate.p12 | pbcopy
base64 -i DeveloperID.provisionprofile | pbcopy
```

### 2. Create the Homebrew tap repo

```bash
gh repo create piotrrojek/homebrew-tap --public --clone
cd homebrew-tap
mkdir -p Formula
cp /path/to/icloud-keychain-zig/Formula/icloud-keychain.rb Formula/
git add Formula/icloud-keychain.rb
git commit -m "Add icloud-keychain formula"
git push
```

### 3. Release

```bash
git tag v1.0.0
git push origin v1.0.0
```

CI will build, sign, notarize, and upload to GitHub Releases. Check the CI output for the SHA256 hash, then update `Formula/icloud-keychain.rb` in the `homebrew-tap` repo with the correct `sha256` and `version`.

## How it works

- `.github/workflows/release.yml` — on tag push, builds universal binary, creates signed `.app` bundle, notarizes it, packages as `.pkg` and `.tar.gz`, uploads both to GitHub Releases
- `Formula/icloud-keychain.rb` — template Homebrew formula that downloads the `.tar.gz`, installs the `.app` bundle, and symlinks the binary into `bin`
