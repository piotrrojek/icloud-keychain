# icloud-keychain

CLI tool to manage macOS Keychain items with optional iCloud sync. Written in Zig.

## Install

```bash
brew tap piotrrojek/tap
brew install piotrrojek/tap/icloud-keychain
```

Or download the `.pkg` from [Releases](https://github.com/piotrrojek/icloud-keychain/releases).

## Usage

```
icloud-keychain set [--sync] <service> <account> <password>
icloud-keychain get <service> <account>
icloud-keychain delete <service> <account>
icloud-keychain list [service-filter]
```

`--sync` enables iCloud Keychain sync (requires entitlements). Without it, secrets are stored in the local login keychain.

## Tutorial

Full walkthrough: [Building an iCloud Keychain CLI in Zig](https://piotrrojek.io/blog/icloud-keychain-cli-zig/)

## License

MIT
